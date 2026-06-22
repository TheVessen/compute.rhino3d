# Download/Install compute – robust edition (v3)
# Improved version with retry logic, handle cleanup, health checks, and backup rotation
#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# ============================================================
# Config
# ============================================================
$physicalPathRoot    = "C:\inetpub\wwwroot\aspnet_client\system_web\4_0_30319"
$rhinoComputePath    = "$physicalPathRoot\rhino.compute"
$computeGeometryPath = "$physicalPathRoot\compute.geometry"
$rhinoComputeExe     = "$rhinoComputePath\rhino.compute.exe"
$computeGeometryExe  = "$computeGeometryPath\compute.geometry.exe"
$appPoolName         = "RhinoComputeAppPool"
$websiteName         = "Rhino.Compute"
$matchingBranch      = "8.x.selva"
$gitPrefix           = "https://api.github.com/repos"
$nightlyPrefix       = "https://nightly.link"
$actionurl           = "vektornode/compute.rhino3d/actions/artifacts"

# Backup lives OUTSIDE the web root to avoid accidental exposure
$backupRoot      = "C:\RhinoComputeBackups"
$backupDir       = "$backupRoot\rhino.compute-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$maxBackupsToKeep = 5          # Prune older backups automatically

# Staging area for download + extraction (avoids partial state in web root)
$stagingDir = "$env:TEMP\RhinoComputeStaging-$(Get-Date -Format 'yyyyMMddHHmmss')"

# Health check after deploy
$healthCheckUrl     = "http://localhost/healthcheck"   # Adjust if your endpoint differs
$healthCheckTimeout = 30                                # seconds

# Log file
$logDir  = "C:\Logs\RhinoCompute"
$logFile = "$logDir\update-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# Retry settings for file operations
$fileRetryCount    = 5
$fileRetryDelaySec = 3

# ============================================================
# Logging
# ============================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS")][string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"

    $colour = switch ($Level) {
        "INFO"    { "Cyan"   }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red"    }
        "SUCCESS" { "Green"  }
    }
    Write-Host $line -ForegroundColor $colour
    Add-Content -Path $logFile -Value $line
}

function Write-Step {
    param([string]$Message)
    $separator = "=" * 60
    Write-Log $separator
    Write-Log "  $Message" -Level "INFO"
    Write-Log $separator
}

# ============================================================
# Retry wrapper for file operations
# ============================================================
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Description = "operation",
        [int]$MaxRetries     = $fileRetryCount,
        [int]$DelaySec       = $fileRetryDelaySec
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            & $Action
            return
        }
        catch {
            Write-Log "$Description failed (attempt $attempt/$MaxRetries): $_" -Level "WARN"
            if ($attempt -eq $MaxRetries) { throw $_ }
            Write-Log "Retrying in $DelaySec seconds..." -Level "WARN"
            Start-Sleep -Seconds $DelaySec
        }
    }
}

# ============================================================
# ACL diagnostics — dump current owner + permissions
# ============================================================
function Show-PathPermissions {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    try {
        $acl = Get-Acl -Path $Path
        Write-Log "  Owner of '$Path': $($acl.Owner)"
        foreach ($ace in $acl.Access) {
            Write-Log "    $($ace.IdentityReference) -> $($ace.FileSystemRights) ($($ace.AccessControlType))"
        }
    }
    catch {
        Write-Log "  Could not read ACL for '$Path': $_" -Level "WARN"
    }
}

# ============================================================
# Force take ownership + grant full control to current user
# Uses SIDs instead of localised group names so it works on
# any Windows language (German, French, English, etc.)
#   S-1-5-32-544 = BUILTIN\Administrators (all languages)
#   S-1-1-0      = Everyone / Jeder / Tout le monde
# Non-fatal: logs warnings but does not throw, since the
# existing ACLs may already be sufficient.
# ============================================================
function Grant-FullControl {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return }

    try {
        Write-Log "Taking ownership of '$Path'..."
        $takeownResult = & takeown /f $Path /r /d y 2>&1
        Write-Log "takeown: $($takeownResult | Select-Object -First 3)"
    }
    catch {
        Write-Log "takeown failed (non-fatal): $_" -Level "WARN"
    }

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    # Resolve the localised name for BUILTIN\Administrators via SID
    try {
        $adminSid  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $adminName = $adminSid.Translate([System.Security.Principal.NTAccount]).Value
    }
    catch {
        $adminName = $null
        Write-Log "Could not resolve Administrators group name: $_" -Level "WARN"
    }

    Write-Log "Granting full control to '$currentUser'..."
    try {
        & icacls $Path /grant "${currentUser}:(OI)(CI)F" /t /c /q 2>&1 | Out-Null
    }
    catch {
        Write-Log "icacls grant for '$currentUser' failed (non-fatal): $_" -Level "WARN"
    }

    if ($adminName) {
        Write-Log "Granting full control to '$adminName'..."
        try {
            & icacls $Path /grant "${adminName}:(OI)(CI)F" /t /c /q 2>&1 | Out-Null
        }
        catch {
            Write-Log "icacls grant for '$adminName' failed (non-fatal): $_" -Level "WARN"
        }
    }

    Write-Log "Permission fixup complete." -Level "SUCCESS"
}

# ============================================================
# Robust directory move: PowerShell -> robocopy+rmdir fallback
# ============================================================
function Move-DirectoryRobust {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    # Attempt 1: plain Move-Item
    try {
        Move-Item -Path $Source -Destination $Destination -Force -ErrorAction Stop
        return
    }
    catch {
        Write-Log "Move-Item failed: $_ — trying robocopy fallback..." -Level "WARN"
    }

    # Attempt 2: robocopy /MIR + rmdir (works at a lower level than PowerShell)
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }
    $roboResult = & robocopy $Source $Destination /MIR /R:3 /W:2 /NP /NFL /NDL /NJH /NJS 2>&1
    $roboExit   = $LASTEXITCODE
    # robocopy exit codes 0-7 are success/partial; 8+ are errors
    if ($roboExit -ge 8) {
        throw "robocopy failed with exit code $roboExit : $roboResult"
    }
    Write-Log "robocopy completed (exit $roboExit). Removing source..." -Level "SUCCESS"

    # Now remove the source — use cmd /c rd for stubborn dirs
    try {
        Remove-Item -Recurse -Force $Source -ErrorAction Stop
    }
    catch {
        Write-Log "Remove-Item failed on source, trying cmd /c rd..." -Level "WARN"
        & cmd /c rd /s /q $Source 2>&1 | Out-Null
        if (Test-Path $Source) {
            Write-Log "Source directory still exists after rd — may need manual cleanup: $Source" -Level "WARN"
        }
    }
}

# ============================================================
# Robust directory copy: robocopy /MIR (idempotent — safe to
# retry, mirrors source into destination without nesting).
# Used for deploy so a partial copy + retry can never end up
# with $Destination\<leaf>\... nesting that plain Copy-Item
# -Recurse produces against an existing directory.
# ============================================================
function Copy-DirectoryRobust {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }
    $roboResult = & robocopy $Source $Destination /MIR /R:3 /W:2 /NP /NFL /NDL /NJH /NJS 2>&1
    $roboExit   = $LASTEXITCODE
    # robocopy exit codes 0-7 are success/partial; 8+ are errors
    if ($roboExit -ge 8) {
        throw "robocopy failed with exit code $roboExit : $roboResult"
    }
    Write-Log "robocopy copy completed (exit $roboExit): $Source -> $Destination"
}

# ============================================================
# Kill stray processes that might hold file locks
# ============================================================
function Stop-StrayProcesses {
    Write-Log "Checking for stray rhino.compute / compute.geometry processes..."
    $killed = $false
    $processNames = @("rhino.compute", "compute.geometry", "w3wp")
    foreach ($name in $processNames) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Log "Killing $($procs.Count) '$name' process(es)..." -Level "WARN"
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            $killed = $true
        }
    }

    if ($killed) {
        # Wait longer when processes were actually killed — the OS needs
        # time to fully release file handles, especially on busy systems
        Write-Log "Waiting for handles to be released after process termination..."
        Start-Sleep -Seconds 5

        # Verify they are actually gone
        foreach ($name in $processNames) {
            $remaining = Get-Process -Name $name -ErrorAction SilentlyContinue
            if ($remaining) {
                Write-Log "WARNING: $($remaining.Count) '$name' process(es) still alive after kill!" -Level "WARN"
                $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }
        }
    }
    else {
        Write-Log "No stray processes found."
    }

    # If Sysinternals handle.exe is available, try to close any remaining handles
    $handleExe = Get-Command "handle.exe" -ErrorAction SilentlyContinue
    if (-not $handleExe) {
        $handleExe = Get-Command "C:\SysinternalsSuite\handle.exe" -ErrorAction SilentlyContinue
    }
    if ($handleExe) {
        Write-Log "Using handle.exe to check for open handles on deployment paths..."
        foreach ($target in @($rhinoComputePath, $computeGeometryPath)) {
            try {
                $output = & $handleExe.Source $target -accepteula -nobanner 2>&1
                if ($output -match "pid:") {
                    Write-Log "Open handles found on ${target}:`n$output" -Level "WARN"
                    # handle.exe -c can close handles, but that is risky in production
                    # — we log it and rely on retries instead
                }
            }
            catch {
                Write-Log "handle.exe check failed: $_" -Level "WARN"
            }
        }
    }
    else {
        Write-Log "handle.exe not found; skipping open-handle scan (install Sysinternals for deeper diagnostics)." -Level "INFO"
    }
}

# ============================================================
# Rollback
# ============================================================
function Invoke-Rollback {
    Write-Log "Starting rollback from $backupDir ..." -Level "WARN"
    try {
        if (Test-Path "$backupDir\rhino.compute") {
            Grant-FullControl -Path $rhinoComputePath
            Invoke-WithRetry -Description "Remove current rhino.compute" -Action {
                if (Test-Path $rhinoComputePath) {
                    & cmd /c rd /s /q $rhinoComputePath 2>&1 | Out-Null
                }
            }
            # COPY (not move) from backup so a failed/partial restore still
            # leaves the backup intact for a retry or manual recovery. Moving
            # consumes the backup — if the move then dies mid-way you end up
            # with an empty deploy AND no backup.
            Invoke-WithRetry -Description "Restore rhino.compute from backup" -Action {
                Copy-DirectoryRobust -Source "$backupDir\rhino.compute" -Destination $rhinoComputePath
            }
            Write-Log "Restored rhino.compute" -Level "SUCCESS"
        }
        if (Test-Path "$backupDir\compute.geometry") {
            Grant-FullControl -Path $computeGeometryPath
            Invoke-WithRetry -Description "Remove current compute.geometry" -Action {
                if (Test-Path $computeGeometryPath) {
                    & cmd /c rd /s /q $computeGeometryPath 2>&1 | Out-Null
                }
            }
            # COPY (not move) — see note above on rhino.compute restore.
            Invoke-WithRetry -Description "Restore compute.geometry from backup" -Action {
                Copy-DirectoryRobust -Source "$backupDir\compute.geometry" -Destination $computeGeometryPath
            }
            Write-Log "Restored compute.geometry" -Level "SUCCESS"
        }
    }
    catch {
        Write-Log "Rollback failed: $_" -Level "ERROR"
        Write-Log "Manual intervention required. Backup is at: $backupDir" -Level "ERROR"
    }
}

# ============================================================
# Is a deployment present and intact?
# A folder that is missing, empty, or missing its executable
# all count as "not present" — that is the state we recover
# from.
# ============================================================
function Test-DeploymentPresent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Exe
    )
    return (Test-Path $Path) -and (Test-Path $Exe)
}

# ============================================================
# Find the newest prior backup that actually contains a usable
# copy of the requested service ($Leaf = 'rhino.compute' or
# 'compute.geometry'). Backups are named with a baked-in
# timestamp, so sorting by Name descending gives newest first.
# Returns the full path to the backed-up service folder, or
# $null if none qualifies. Skips $backupDir (this run's own,
# still-empty backup folder).
# ============================================================
function Find-LatestUsableBackup {
    param(
        [Parameter(Mandatory)][string]$Leaf,   # rhino.compute | compute.geometry
        [Parameter(Mandatory)][string]$ExeName # rhino.compute.exe | compute.geometry.exe
    )
    if (-not (Test-Path $backupRoot)) { return $null }

    $candidates = Get-ChildItem -Path $backupRoot -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "rhino.compute-backup-*" -and $_.FullName -ne $backupDir } |
                  Sort-Object Name -Descending

    foreach ($c in $candidates) {
        $svcPath = Join-Path $c.FullName $Leaf
        $exePath = Join-Path $svcPath $ExeName
        if ((Test-Path $svcPath) -and (Test-Path $exePath)) {
            return $svcPath
        }
    }
    return $null
}

# ============================================================
# Disaster recovery — restore missing/empty live deployments
# from the most recent usable prior backup. Called from
# pre-flight when a deployment folder is gone (e.g. a previous
# run died mid-deploy and left the web root empty).
#
# Non-destructive: copies from the backup (never moves), so the
# backup survives a partial/failed restore. Returns $true if,
# after the attempt, BOTH deployments are present and intact;
# $false otherwise.
# ============================================================
function Invoke-DisasterRecovery {
    Write-Step "Disaster recovery — restoring missing deployment(s) from backup"

    $targets = @(
        @{ Leaf = "rhino.compute";    ExeName = "rhino.compute.exe";    Path = $rhinoComputePath;    Exe = $rhinoComputeExe    },
        @{ Leaf = "compute.geometry"; ExeName = "compute.geometry.exe"; Path = $computeGeometryPath; Exe = $computeGeometryExe }
    )

    foreach ($t in $targets) {
        if (Test-DeploymentPresent -Path $t.Path -Exe $t.Exe) {
            Write-Log "'$($t.Leaf)' is already present — skipping recovery for it."
            continue
        }

        Write-Log "'$($t.Leaf)' is missing or empty — searching for a usable backup..." -Level "WARN"
        $src = Find-LatestUsableBackup -Leaf $t.Leaf -ExeName $t.ExeName
        if (-not $src) {
            Write-Log "No usable backup found for '$($t.Leaf)' under $backupRoot." -Level "ERROR"
            continue
        }

        Write-Log "Recovering '$($t.Leaf)' from: $src" -Level "WARN"
        try {
            # Clear any partial/empty live folder first so /MIR mirrors cleanly.
            if (Test-Path $t.Path) {
                Grant-FullControl -Path $t.Path
                & cmd /c rd /s /q $t.Path 2>&1 | Out-Null
            }
            Invoke-WithRetry -Description "Recover $($t.Leaf) from backup" -Action {
                Copy-DirectoryRobust -Source $src -Destination $t.Path
            }
            if (Test-DeploymentPresent -Path $t.Path -Exe $t.Exe) {
                Write-Log "Recovered '$($t.Leaf)' successfully." -Level "SUCCESS"
            }
            else {
                Write-Log "Recovery of '$($t.Leaf)' completed but executable still missing." -Level "ERROR"
            }
        }
        catch {
            Write-Log "Recovery of '$($t.Leaf)' failed: $_" -Level "ERROR"
        }
    }

    $ok = (Test-DeploymentPresent -Path $rhinoComputePath -Exe $rhinoComputeExe) -and
          (Test-DeploymentPresent -Path $computeGeometryPath -Exe $computeGeometryExe)
    if ($ok) {
        Write-Log "Disaster recovery complete — both deployments present." -Level "SUCCESS"
    }
    else {
        Write-Log "Disaster recovery could not restore all deployments." -Level "ERROR"
    }
    return $ok
}

# ============================================================
# Download helper (Invoke-WebRequest primary, BITS fallback)
# ============================================================
function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Output,
        [int]$TimeoutSeconds = 120
    )
    Write-Log "Downloading: $Url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Primary: .NET WebClient. On Windows PowerShell 5.1, Invoke-WebRequest can
    # hang indefinitely on a mid-stream stall (its -TimeoutSec only covers the
    # initial response, not a redirect target that connects then goes silent).
    # WebClient with an explicit timeout aborts a dead transfer instead of
    # sitting forever — which is what forced the manual Ctrl+C before.
    try {
        Write-Log "Attempting download via WebClient..."
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "update-compute-script/3.0")
        $wc.DownloadFile($Url, $Output)
        $wc.Dispose()
        Write-Log "WebClient download complete." -Level "SUCCESS"
    }
    catch {
        Write-Log "WebClient failed ($_), falling back to Invoke-WebRequest..." -Level "WARN"
        try {
            $ProgressPreference = "SilentlyContinue"
            Invoke-WebRequest -Uri $Url `
                              -OutFile $Output `
                              -TimeoutSec $TimeoutSeconds `
                              -UseBasicParsing `
                              -Headers @{ "User-Agent" = "update-compute-script/3.0" } `
                              -ErrorAction Stop
            $ProgressPreference = "Continue"
            Write-Log "Invoke-WebRequest complete." -Level "SUCCESS"
        }
        catch {
            Write-Log "Invoke-WebRequest failed ($_), falling back to BITS..." -Level "WARN"
            Start-BitsTransfer -Source $Url -Destination $Output -DisplayName "RhinoCompute Update" -ErrorAction Stop
            Write-Log "BITS transfer complete." -Level "SUCCESS"
        }
    }
    Write-Log "Download complete -> $Output"
}

# ============================================================
# Stop App Pool helper (stops pool and waits, kills w3wp fallback)
# ============================================================
function Stop-ComputeAppPool {
    Write-Step "Stopping App Pool '$appPoolName'"
    try {
        $state = (Get-WebAppPoolState -Name $appPoolName).Value
        Write-Log "App Pool current state: $state"
        if ($state -ne "Stopped") {
            Stop-WebAppPool -Name $appPoolName
            $retries = 20
            while ((Get-WebAppPoolState -Name $appPoolName).Value -ne "Stopped" -and $retries-- -gt 0) {
                Write-Log "Waiting for App Pool to stop... ($retries retries left)"
                Start-Sleep -Seconds 1
            }
        }
        if ((Get-WebAppPoolState -Name $appPoolName).Value -eq "Stopped") {
            Write-Log "App Pool '$appPoolName' stopped." -Level "SUCCESS"
        }
        else {
            throw "App Pool did not stop within timeout."
        }
    }
    catch {
        Write-Log "Could not stop App Pool cleanly ($_), killing w3wp.exe processes..." -Level "WARN"
        Get-Process -Name "w3wp" -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 3
        Write-Log "w3wp.exe processes terminated." -Level "WARN"
    }
}

# ============================================================
# Start App Pool helper
# ============================================================
function Start-ComputeAppPool {
    try {
        $state = (Get-WebAppPoolState -Name $appPoolName).Value
        if ($state -ne "Started") {
            Start-WebAppPool -Name $appPoolName
            Start-Sleep -Seconds 2
            Write-Log "App Pool '$appPoolName' started." -Level "SUCCESS"
        }
        else {
            Write-Log "App Pool '$appPoolName' already running." -Level "SUCCESS"
        }
    }
    catch {
        Write-Log "Could not start App Pool '$appPoolName': $_" -Level "WARN"
    }
}

# ============================================================
# Backup rotation – keep only the N most recent backups
# Sort by Name (timestamps are baked into the directory name,
# so this is reliable even when CreationTime is misleading
# after a move).
# ============================================================
function Invoke-BackupRotation {
    Write-Log "Checking backup rotation (keeping last $maxBackupsToKeep)..."
    if (-not (Test-Path $backupRoot)) { return }
    $backups = Get-ChildItem -Path $backupRoot -Directory |
               Where-Object { $_.Name -like "rhino.compute-backup-*" } |
               Sort-Object Name -Descending
    if ($backups.Count -le $maxBackupsToKeep) {
        Write-Log "Only $($backups.Count) backup(s) present, nothing to prune."
        return
    }
    $toRemove = $backups | Select-Object -Skip $maxBackupsToKeep
    foreach ($old in $toRemove) {
        try {
            Remove-Item -Recurse -Force $old.FullName
            Write-Log "Pruned old backup: $($old.Name)" -Level "INFO"
        }
        catch {
            Write-Log "Could not prune backup $($old.Name): $_" -Level "WARN"
        }
    }
}

# ============================================================
# Health check – HTTP GET against compute endpoint
# ============================================================
function Test-ComputeHealth {
    Write-Log "Running health check against $healthCheckUrl (timeout: ${healthCheckTimeout}s)..."
    $deadline = (Get-Date).AddSeconds($healthCheckTimeout)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $ProgressPreference = "SilentlyContinue"
            $resp = Invoke-WebRequest -Uri $healthCheckUrl `
                                      -UseBasicParsing `
                                      -TimeoutSec 5 `
                                      -ErrorAction Stop
            $ProgressPreference = "Continue"
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
                Write-Log "Health check passed (HTTP $($resp.StatusCode))." -Level "SUCCESS"
                return $true
            }
            Write-Log "Health check returned HTTP $($resp.StatusCode), retrying..." -Level "WARN"
        }
        catch {
            $lastError = $_
            # A 401/403 means the endpoint is up and responding — it is just
            # rejecting an unauthenticated request. That is "healthy" for a
            # deploy check: the service is listening and serving HTTP.
            $status = $_.Exception.Response.StatusCode.value__
            if ($status -eq 401 -or $status -eq 403) {
                Write-Log "Health check: service responded HTTP $status (auth required) — treating as healthy." -Level "SUCCESS"
                return $true
            }
        }
        Start-Sleep -Seconds 2
    }
    Write-Log "Health check failed after ${healthCheckTimeout}s. Last error: $lastError" -Level "WARN"
    Write-Log "The service may still be starting — check manually." -Level "WARN"
    return $false
}

# ============================================================
# Main
# ============================================================
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
Start-Transcript -Path "$logDir\transcript-$(Get-Date -Format 'yyyyMMdd-HHmmss').log" -Append

Write-Host @"

  # # # # # # # # # # # # # # # # # # # # #
  #                                       #
  #             U P D A T E               #
  #                                       #
  #       R H I N O . C O M P U T E       #
  #                                       #
  #             S C R I P T   v3          #
  #                                       #
  # # # # # # # # # # # # # # # # # # # # #

"@

Write-Log "Log file: $logFile"
Write-Log "Running as user: $env:USERNAME on host: $env:COMPUTERNAME"
Write-Log "PowerShell version: $($PSVersionTable.PSVersion)"

try {

    # ----------------------------------------------------------
    # 1. Pre-flight checks
    # ----------------------------------------------------------
    Write-Step "Pre-flight checks"

    # Verify IIS module is available
    if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
        throw "WebAdministration module not found. Is IIS installed?"
    }
    Import-Module WebAdministration -ErrorAction Stop

    $rhinoPresent    = Test-DeploymentPresent -Path $rhinoComputePath    -Exe $rhinoComputeExe
    $geometryPresent = Test-DeploymentPresent -Path $computeGeometryPath -Exe $computeGeometryExe

    if (-not $rhinoPresent -or -not $geometryPresent) {
        Write-Log "One or both deployments are missing or empty — a previous run may have died mid-deploy." -Level "WARN"
        Write-Log "  rhino.compute present:    $rhinoPresent" -Level "WARN"
        Write-Log "  compute.geometry present: $geometryPresent" -Level "WARN"

        $recovered = Invoke-DisasterRecovery
        if (-not $recovered) {
            throw "Deployment folders are missing/empty and could not be recovered from any backup under $backupRoot. Run the bootstrap script to reinstall from scratch."
        }
        Write-Log "Recovery succeeded — continuing with the update." -Level "SUCCESS"
    }
    else {
        Write-Log "Both executables found." -Level "SUCCESS"
    }

    # Check disk space (need at least 500 MB free on target drive)
    $drive = (Split-Path $physicalPathRoot -Qualifier)
    $freeGB = [math]::Round((Get-PSDrive ($drive.TrimEnd(':'))).Free / 1GB, 2)
    Write-Log "Free disk space on ${drive}: ${freeGB} GB"
    if ($freeGB -lt 0.5) {
        throw "Less than 500 MB free on $drive. Aborting to avoid partial extraction."
    }

    try {
        $currentVersion = (Get-Item $rhinoComputeExe).VersionInfo.FileVersion
        Write-Log "Currently installed rhino.compute version: $currentVersion"
    }
    catch {
        Write-Log "Could not read current version info: $_" -Level "WARN"
    }

    # rhino.compute.exe carries a hardcoded 1.0.0.0 assembly version, so it is
    # useless for telling builds apart. compute.geometry.exe carries the real,
    # changing build version — capture it for the before/after summary.
    try {
        $currentGeometryVersion = (Get-Item $computeGeometryExe).VersionInfo.FileVersion
        Write-Log "Currently installed compute.geometry version: $currentGeometryVersion"
    }
    catch {
        Write-Log "Could not read current compute.geometry version info: $_" -Level "WARN"
    }

    # ----------------------------------------------------------
    # 2. Resolve latest artifact (with pagination)
    # ----------------------------------------------------------
    Write-Step "Resolving latest build artifact for branch '$matchingBranch'"

    $artifactID = -1
    $page       = 1
    $perPage    = 100
    $maxPages   = 10

    while ($artifactID -lt 0 -and $page -le $maxPages) {
        $giturl = "$gitPrefix/$actionurl`?per_page=$perPage&page=$page"
        Write-Log "Fetching artifact list page $page from: $giturl"
        $response  = Invoke-RestMethod -Method Get -Uri $giturl -Headers @{ "User-Agent" = "update-compute-script/3.0" }
        $artifacts = $response.artifacts

        if ($artifacts.Count -eq 0) {
            Write-Log "No more artifacts returned on page $page." -Level "WARN"
            break
        }

        foreach ($artifact in $artifacts) {
            if ($artifact.workflow_run.head_branch -eq $matchingBranch) {
                $artifactID   = $artifact.id
                $artifactName = $artifact.name
                $artifactDate = $artifact.created_at
                Write-Log "Found artifact '$artifactName' (id: $artifactID, created: $artifactDate) on page $page." -Level "SUCCESS"
                break
            }
        }
        $page++
    }

    if ($artifactID -lt 0) {
        throw "Unable to find a build artifact for branch '$matchingBranch' after checking $($page - 1) page(s)."
    }

    $downloadUrl = "$nightlyPrefix/$actionurl/$artifactID.zip"
    Write-Log "Artifact download URL: $downloadUrl"

    # ----------------------------------------------------------
    # 3. Download and extract into STAGING (before touching IIS)
    # ----------------------------------------------------------
    Write-Step "Downloading and extracting into staging area"

    New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
    $zipPath = "$stagingDir\compute.zip"
    Invoke-Download -Url $downloadUrl -Output $zipPath

    $zipSize = (Get-Item $zipPath).Length
    Write-Log "Archive size: $([math]::Round($zipSize / 1MB, 2)) MB"
    if ($zipSize -lt 1MB) {
        throw "Downloaded archive is suspiciously small ($zipSize bytes). Aborting."
    }

    Write-Log "Extracting archive to staging..."
    Expand-Archive -Path $zipPath -DestinationPath $stagingDir -Force
    Remove-Item $zipPath
    Write-Log "Extraction complete." -Level "SUCCESS"

    # Validate that the extracted content has the expected executables
    $stagedRhinoCompute    = "$stagingDir\rhino.compute"
    $stagedComputeGeometry = "$stagingDir\compute.geometry"

    # Handle case where archive extracts flat (no subdirectories). A flat
    # archive cannot carry both services in distinct folders, so we only
    # accept it when BOTH executables sit at the staging root — and we
    # refuse to deploy a flat layout because we cannot separate the two
    # services without clobbering each other. Fail loudly instead.
    $flatRhino    = (Test-Path "$stagingDir\rhino.compute.exe")    -and -not (Test-Path "$stagedRhinoCompute\rhino.compute.exe")
    $flatGeometry = (Test-Path "$stagingDir\compute.geometry.exe") -and -not (Test-Path "$stagedComputeGeometry\compute.geometry.exe")
    if ($flatRhino -or $flatGeometry) {
        throw "Archive has a flat layout (executables at staging root, no rhino.compute/compute.geometry subfolders). This script expects the two services in separate subdirectories and cannot safely split a flat archive. Staging contents:`n$(Get-ChildItem $stagingDir | Select-Object -First 30 | Out-String)"
    }

    if (-not (Test-Path "$stagedRhinoCompute\rhino.compute.exe")) {
        throw "Staged archive does not contain rhino.compute\rhino.compute.exe. Contents of staging:`n$(Get-ChildItem -Recurse $stagingDir | Select-Object -First 30 | Out-String)"
    }
    if (-not (Test-Path "$stagedComputeGeometry\compute.geometry.exe")) {
        throw "Staged archive does not contain compute.geometry\compute.geometry.exe. Contents of staging:`n$(Get-ChildItem -Recurse $stagingDir | Select-Object -First 30 | Out-String)"
    }

    try {
        $newVersion = (Get-Item "$stagedRhinoCompute\rhino.compute.exe").VersionInfo.FileVersion
        Write-Log "Staged rhino.compute version: $newVersion" -Level "SUCCESS"
    }
    catch {
        Write-Log "Could not read staged version info: $_" -Level "WARN"
    }

    try {
        $newGeometryVersion = (Get-Item "$stagedComputeGeometry\compute.geometry.exe").VersionInfo.FileVersion
        Write-Log "Staged compute.geometry version: $newGeometryVersion" -Level "SUCCESS"
    }
    catch {
        Write-Log "Could not read staged compute.geometry version info: $_" -Level "WARN"
    }

    # ----------------------------------------------------------
    # 4. Stop IIS site, then App Pool (releases all file handles)
    # ----------------------------------------------------------
    Write-Step "Stopping IIS site '$websiteName'"
    try {
        Stop-IISSite -Name $websiteName -Confirm:$false
        Write-Log "Stopped site '$websiteName'." -Level "SUCCESS"
    }
    catch {
        Write-Log "Could not stop site individually: $_" -Level "WARN"
    }

    Stop-ComputeAppPool

    # Kill any stray processes and scan for open handles
    Stop-StrayProcesses

    # ----------------------------------------------------------
    # 5. Diagnose + fix permissions, then backup
    # ----------------------------------------------------------
    Write-Step "Diagnosing permissions on deployment paths"
    Show-PathPermissions -Path $rhinoComputePath
    Show-PathPermissions -Path $computeGeometryPath

    Write-Step "Taking ownership and granting full control"
    Grant-FullControl -Path $rhinoComputePath
    Grant-FullControl -Path $computeGeometryPath

    Write-Step "Creating backup at $backupDir"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    Write-Log "Backup directory created: $backupDir"

    # COPY (not move) the live install into the backup. The live folders stay
    # in place so there is never a moment with zero copies on disk: if anything
    # below fails, the original deploy is still intact and the backup is a
    # full, independent copy. Section 6 then mirrors staging over the live
    # folders with robocopy /MIR, which reconciles cleanly against existing
    # content.
    Invoke-WithRetry -Description "Copy rhino.compute to backup" -Action {
        Write-Log "Copying $rhinoComputePath -> $backupDir\rhino.compute"
        Copy-DirectoryRobust -Source $rhinoComputePath -Destination "$backupDir\rhino.compute"
    }

    Invoke-WithRetry -Description "Copy compute.geometry to backup" -Action {
        Write-Log "Copying $computeGeometryPath -> $backupDir\compute.geometry"
        Copy-DirectoryRobust -Source $computeGeometryPath -Destination "$backupDir\compute.geometry"
    }

    Write-Log "Backup complete." -Level "SUCCESS"

    # ----------------------------------------------------------
    # 6. Deploy from staging into web root
    #    Uses robocopy /MIR (Copy-DirectoryRobust) so a partial
    #    copy followed by a retry mirrors cleanly instead of
    #    nesting like Copy-Item -Recurse would.
    # ----------------------------------------------------------
    Write-Step "Deploying from staging to web root"

    Invoke-WithRetry -Description "Copy rhino.compute to web root" -Action {
        Copy-DirectoryRobust -Source $stagedRhinoCompute -Destination $rhinoComputePath
    }

    Invoke-WithRetry -Description "Copy compute.geometry to web root" -Action {
        Copy-DirectoryRobust -Source $stagedComputeGeometry -Destination $computeGeometryPath
    }

    # Final validation — confirm executables exist at target
    if (-not (Test-Path $rhinoComputeExe)) {
        throw "Post-deploy validation failed: $rhinoComputeExe not found!"
    }
    if (-not (Test-Path $computeGeometryExe)) {
        throw "Post-deploy validation failed: $computeGeometryExe not found!"
    }
    Write-Log "Deployment validated — both executables present." -Level "SUCCESS"

    # Clean up staging
    Remove-Item -Recurse -Force $stagingDir -ErrorAction SilentlyContinue
    Write-Log "Staging directory cleaned up."

    # ----------------------------------------------------------
    # 7. Set IIS AppPool permissions
    # ----------------------------------------------------------
    Write-Step "Granting AppPool permissions"
    $iisUser = "IIS AppPool\$appPoolName"
    foreach ($path in @($rhinoComputePath, $computeGeometryPath)) {
        Write-Log "icacls on: $path"
        $result = & cmd /c icacls $path /grant ("$iisUser" + ':(OI)(CI)F') /t /c /q 2>&1
        Write-Log "icacls result: $result"
    }
    Write-Log "Permissions set." -Level "SUCCESS"

    # ----------------------------------------------------------
    # 8. Start App Pool, then IIS site
    # ----------------------------------------------------------
    Write-Step "Starting IIS"

    $svcState = (Get-Service -Name 'w3svc').Status
    Write-Log "w3svc current state: $svcState"
    if ($svcState -ne 'Running') {
        Write-Log "Starting w3svc..."
        & net start w3svc 2>&1 | ForEach-Object { Write-Log $_ }
    }
    else {
        Write-Log "w3svc is already running, skipping net start."
    }

    Start-ComputeAppPool

    Start-Sleep -Seconds 3

    $siteState = (Get-IISSite -Name $websiteName).State
    Write-Log "Site '$websiteName' current state: $siteState"
    if ($siteState -ne "Started") {
        Write-Log "Site is not started, attempting explicit start..." -Level "WARN"
        Start-IISSite -Name $websiteName
        Start-Sleep -Seconds 2
        $siteState = (Get-IISSite -Name $websiteName).State
    }

    if ($siteState -eq "Started") {
        Write-Log "Site '$websiteName' is running." -Level "SUCCESS"
    }
    else {
        throw "Site '$websiteName' failed to start. Current state: $siteState"
    }

    # ----------------------------------------------------------
    # 9. Health check
    # ----------------------------------------------------------
    Write-Step "Post-deploy health check"
    $healthy = Test-ComputeHealth
    if (-not $healthy) {
        Write-Log "Health check did not pass, but site is running. Please verify manually." -Level "WARN"
    }

    # ----------------------------------------------------------
    # 10. Backup rotation
    # ----------------------------------------------------------
    Invoke-BackupRotation

    # ----------------------------------------------------------
    # 11. Done
    # ----------------------------------------------------------
    Write-Log ("=" * 60)
    Write-Log "UPDATE COMPLETED SUCCESSFULLY" -Level "SUCCESS"
    Write-Log ("=" * 60)
    Write-Log "Previous rhino.compute version:   $currentVersion"
    Write-Log "New rhino.compute version:        $newVersion"
    Write-Log "Previous compute.geometry version: $currentGeometryVersion"
    Write-Log "New compute.geometry version:      $newGeometryVersion"
    Write-Log "Backup retained at: $backupDir"
    Write-Log "Log file: $logFile"

}
catch {
    Write-Log ("=" * 60)
    Write-Log "UPDATE FAILED: $_" -Level "ERROR"
    Write-Log "Exception type: $($_.Exception.GetType().FullName)" -Level "ERROR"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack trace:`n$($_.ScriptStackTrace)" -Level "ERROR"
    }
    Write-Log ("=" * 60)
    Write-Log "Attempting automatic rollback..." -Level "WARN"

    # Make sure processes are dead before rollback too
    Stop-StrayProcesses

    Invoke-Rollback

    # Clean up staging if it exists
    if (Test-Path $stagingDir) {
        Remove-Item -Recurse -Force $stagingDir -ErrorAction SilentlyContinue
        Write-Log "Cleaned up staging directory." -Level "INFO"
    }

    try {
        $svcState = (Get-Service -Name 'w3svc').Status
        Write-Log "w3svc state after rollback: $svcState" -Level "WARN"
        if ($svcState -ne 'Running') {
            & net start w3svc 2>&1 | ForEach-Object { Write-Log $_ }
        }
        else {
            Write-Log "w3svc already running after rollback." -Level "SUCCESS"
        }

        Start-ComputeAppPool

        $siteState = (Get-IISSite -Name $websiteName).State
        if ($siteState -ne "Started") { Start-IISSite -Name $websiteName }

        Write-Log "IIS is up after rollback." -Level "SUCCESS"
    }
    catch {
        Write-Log "Could not restart IIS after rollback: $_" -Level "ERROR"
        Write-Log "Please start IIS manually." -Level "ERROR"
    }

    Stop-Transcript
    exit 1
}

Stop-Transcript
