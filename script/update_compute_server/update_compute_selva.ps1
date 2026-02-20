
# Download/Install compute
# Improved version of https://github.com/mcneel/compute.rhino3d/blob/81916f35a5ef45a99b27fb5e31d591decfa184ee/script/update-compute.ps1
#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# ============================================================
# Config
# ============================================================
$physicalPathRoot       = "C:\inetpub\wwwroot\aspnet_client\system_web\4_0_30319"
$rhinoComputePath       = "$physicalPathRoot\rhino.compute"
$computeGeometryPath    = "$physicalPathRoot\compute.geometry"
$rhinoComputeExe        = "$rhinoComputePath\rhino.compute.exe"
$computeGeometryExe     = "$computeGeometryPath\compute.geometry.exe"
$appPoolName            = "RhinoComputeAppPool"
$websiteName            = "Rhino.Compute"
$matchingBranch         = "Compute8"
$gitPrefix              = "https://api.github.com/repos"
$nightlyPrefix          = "https://nightly.link"
$actionurl              = "vektornode/compute.rhino3d/actions/artifacts"

# Backup lives OUTSIDE the web root to avoid accidental exposure
$backupRoot             = "C:\RhinoComputeBackups"
$backupDir              = "$backupRoot\rhino.compute-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# Log file
$logDir                 = "C:\Logs\RhinoCompute"
$logFile                = "$logDir\update-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

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

    # Console colour
    $colour = switch ($Level) {
        "INFO"    { "Cyan" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
    }
    Write-Host $line -ForegroundColor $colour

    # File
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
# Rollback
# ============================================================
function Invoke-Rollback {
    Write-Log "Starting rollback from $backupDir ..." -Level "WARN"
    try {
        if (Test-Path "$backupDir\rhino.compute") {
            if (Test-Path $rhinoComputePath) { Remove-Item -Recurse -Force $rhinoComputePath }
            Move-Item -Path "$backupDir\rhino.compute"    -Destination $rhinoComputePath
            Write-Log "Restored rhino.compute" -Level "SUCCESS"
        }
        if (Test-Path "$backupDir\compute.geometry") {
            if (Test-Path $computeGeometryPath) { Remove-Item -Recurse -Force $computeGeometryPath }
            Move-Item -Path "$backupDir\compute.geometry" -Destination $computeGeometryPath
            Write-Log "Restored compute.geometry" -Level "SUCCESS"
        }
    } catch {
        Write-Log "Rollback failed: $_" -Level "ERROR"
        Write-Log "Manual intervention required. Backup is at: $backupDir" -Level "ERROR"
    }
}

# ============================================================
# Download helper (BITS primary, Invoke-WebRequest fallback)
# ============================================================
function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Output,
        [int]$TimeoutSeconds = 120
    )
    Write-Log "Downloading: $Url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        Write-Log "Attempting download via Invoke-WebRequest..."
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $Url `
                          -OutFile $Output `
                          -TimeoutSec $TimeoutSeconds `
                          -UseBasicParsing `
                          -Headers @{ "User-Agent" = "update-compute-script/2.0" } `
                          -ErrorAction Stop
        $ProgressPreference = "Continue"
        Write-Log "Invoke-WebRequest complete." -Level "SUCCESS"
    } catch {
        Write-Log "Invoke-WebRequest failed ($_), falling back to BITS..." -Level "WARN"
        Start-BitsTransfer -Source $Url -Destination $Output -DisplayName "RhinoCompute Update" -ErrorAction Stop
        Write-Log "BITS transfer complete." -Level "SUCCESS"
    }

    Write-Log "Download complete -> $Output"
}

# ============================================================
# Main
# ============================================================

# Start transcript (captures everything, including external process output)
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
Start-Transcript -Path "$logDir\transcript-$(Get-Date -Format 'yyyyMMdd-HHmmss').log" -Append

Write-Host @"

  # # # # # # # # # # # # # # # # # # # # #
  #                                       #
  #             U P D A T E               #
  #                                       #
  #       R H I N O . C O M P U T E       #
  #                                       #
  #             S C R I P T               #
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

    if (-not (Test-Path $computeGeometryExe)) {
        throw "compute.geometry executable not found at: $computeGeometryExe. Run the bootstrap script first."
    }
    if (-not (Test-Path $rhinoComputeExe)) {
        throw "rhino.compute executable not found at: $rhinoComputeExe. Run the bootstrap script first."
    }
    Write-Log "Both executables found." -Level "SUCCESS"

    # Log currently installed version (if the exe exposes a version)
    try {
        $currentVersion = (Get-Item $rhinoComputeExe).VersionInfo.FileVersion
        Write-Log "Currently installed rhino.compute version: $currentVersion"
    } catch {
        Write-Log "Could not read current version info: $_" -Level "WARN"
    }

    # ----------------------------------------------------------
    # 2. Resolve latest artifact (with pagination)
    # ----------------------------------------------------------
    Write-Step "Resolving latest build artifact for branch '$matchingBranch'"

    $artifactID   = -1
    $page         = 1
    $perPage      = 100
    $maxPages     = 10   # safety cap -- avoids infinite loops on huge repos

    while ($artifactID -lt 0 -and $page -le $maxPages) {
        $giturl  = "$gitPrefix/$actionurl`?per_page=$perPage&page=$page"
        Write-Log "Fetching artifact list page $page from: $giturl"

        $response  = Invoke-RestMethod -Method Get -Uri $giturl -Headers @{ "User-Agent" = "update-compute-script/2.0" }
        $artifacts = $response.artifacts

        if ($artifacts.Count -eq 0) {
            Write-Log "No more artifacts returned on page $page." -Level "WARN"
            break
        }

        foreach ($artifact in $artifacts) {
            if ($artifact.workflow_run.head_branch -eq $matchingBranch) {
                $artifactID   = $artifact.id
                $artifactName = $artifact.name
                Write-Log "Found artifact '$artifactName' (id: $artifactID) on page $page." -Level "SUCCESS"
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
    # 3. Stop IIS (only the target site first, fall back to w3svc)
    # ----------------------------------------------------------
    Write-Step "Stopping IIS site '$websiteName'"

    try {
        Stop-IISSite -Name $websiteName -Confirm:$false
        Write-Log "Stopped site '$websiteName'." -Level "SUCCESS"
    } catch {
        Write-Log "Could not stop site individually, falling back to stopping w3svc: $_" -Level "WARN"
        & net stop w3svc /y
        Write-Log "w3svc stopped."
    }

    # ----------------------------------------------------------
    # 4. Backup
    # ----------------------------------------------------------
    Write-Step "Creating backup at $backupDir"

    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    Write-Log "Backup directory created: $backupDir"

    Write-Log "Moving $rhinoComputePath -> $backupDir\rhino.compute"
    Move-Item -Path $rhinoComputePath    -Destination $backupDir

    Write-Log "Moving $computeGeometryPath -> $backupDir\compute.geometry"
    Move-Item -Path $computeGeometryPath -Destination $backupDir

    Write-Log "Backup complete." -Level "SUCCESS"

    # ----------------------------------------------------------
    # 5. Download and extract
    # ----------------------------------------------------------
    Write-Step "Downloading latest build"

    $zipPath = "$physicalPathRoot\compute.zip"
    Invoke-Download -Url $downloadUrl -Output $zipPath

    $zipSize = (Get-Item $zipPath).Length
    Write-Log "Archive size: $([math]::Round($zipSize / 1MB, 2)) MB"

    if ($zipSize -lt 1MB) {
        throw "Downloaded archive is suspiciously small ($zipSize bytes). Aborting."
    }

    Write-Step "Extracting archive"
    Expand-Archive -Path $zipPath -DestinationPath $physicalPathRoot -Force
    Remove-Item $zipPath
    Write-Log "Extraction complete, zip removed." -Level "SUCCESS"

    # Log new version
    try {
        $newVersion = (Get-Item $rhinoComputeExe).VersionInfo.FileVersion
        Write-Log "Newly installed rhino.compute version: $newVersion" -Level "SUCCESS"
    } catch {
        Write-Log "Could not read new version info: $_" -Level "WARN"
    }

    # ----------------------------------------------------------
    # 6. Set IIS AppPool permissions
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
    # 7. Start IIS
    # ----------------------------------------------------------
    Write-Step "Starting IIS"

    # w3svc may already be running if only the site was stopped - that is fine
    $svcState = (Get-Service -Name 'w3svc').Status
    Write-Log "w3svc current state: $svcState"
    if ($svcState -ne 'Running') {
        Write-Log "Starting w3svc..."
        & net start w3svc 2>&1 | ForEach-Object { Write-Log $_ }
    } else {
        Write-Log "w3svc is already running, skipping net start."
    }

    # Give IIS a moment to settle before checking site state
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
    } else {
        throw "Site '$websiteName' failed to start. Current state: $siteState"
    }

    # ----------------------------------------------------------
    # 8. Done
    # ----------------------------------------------------------
    Write-Log ("=" * 60)
    Write-Log "UPDATE COMPLETED SUCCESSFULLY" -Level "SUCCESS"
    Write-Log ("=" * 60)
    Write-Log "Backup retained at: $backupDir"
    Write-Log "Log file: $logFile"

} catch {

    Write-Log ("=" * 60)
    Write-Log "UPDATE FAILED: $_" -Level "ERROR"
    Write-Log ("=" * 60)
    Write-Log "Attempting automatic rollback..." -Level "WARN"

    Invoke-Rollback

    # Try to bring IIS back up regardless
    try {
        $svcState = (Get-Service -Name 'w3svc').Status
        Write-Log "w3svc state after rollback: $svcState" -Level "WARN"
        if ($svcState -ne 'Running') {
            & net start w3svc 2>&1 | ForEach-Object { Write-Log $_ }
        } else {
            Write-Log "w3svc already running after rollback." -Level "SUCCESS"
        }
        # Ensure the site itself is started
        $siteState = (Get-IISSite -Name $websiteName).State
        if ($siteState -ne "Started") {
            Start-IISSite -Name $websiteName
        }
        Write-Log "IIS is up after rollback." -Level "SUCCESS"
    } catch {
        Write-Log "Could not restart IIS after rollback: $_" -Level "ERROR"
        Write-Log "Please start IIS manually." -Level "ERROR"
    }

    Stop-Transcript
    exit 1
}

Stop-Transcript