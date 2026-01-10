<#
.SYNOPSIS
    Updates Rhino Compute on multiple servers with zero downtime using rolling updates.

.DESCRIPTION
    This script performs a rolling update across all compute servers:
    1. Takes one server out of rotation (via load balancer)
    2. Stops the service
    3. Backs up current version
    4. Deploys new version
    5. Starts the service
    6. Health checks
    7. Puts server back in rotation
    8. Repeats for next server

.PARAMETER ServerList
    Array of server hostnames/IPs to update. Can also provide a file path with one server per line.

.PARAMETER ComputeBinariesPath
    Path to new compiled binaries. Default: ..\src\dist\rhino.compute

.PARAMETER InstallPath
    Install path on remote servers. Default: C:\RhinoCompute

.PARAMETER LoadBalancerUrl
    URL of your load balancer API (if applicable) for automatic traffic management

.PARAMETER Credential
    PSCredential for remote servers. If not provided, will prompt.

.PARAMETER WaitBetweenServers
    Seconds to wait between server updates. Default: 30

.PARAMETER SkipHealthCheck
    Skip health check validation (not recommended)

.EXAMPLE
    .\Update-ComputeCluster.ps1 -ServerList "compute1.local","compute2.local","compute3.local"

.EXAMPLE
    .\Update-ComputeCluster.ps1 -ServerList "servers.txt" -WaitBetweenServers 60
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$ServerList,

    [Parameter(Mandatory = $false)]
    [string]$ComputeBinariesPath = "..\src\dist\rhino.compute",

    [Parameter(Mandatory = $false)]
    [string]$InstallPath = "C:\RhinoCompute",

    [Parameter(Mandatory = $false)]
    [int]$Port = 5000,

    [Parameter(Mandatory = $false)]
    [string]$LoadBalancerUrl,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [int]$WaitBetweenServers = 30,

    [Parameter(Mandatory = $false)]
    [switch]$SkipHealthCheck
)

$ErrorActionPreference = "Stop"

Write-Host "=== Rhino Compute Cluster Update ===" -ForegroundColor Cyan
Write-Host ""

# Parse server list (could be array or file path)
$servers = @()
if ($ServerList.Count -eq 1 -and (Test-Path $ServerList[0])) {
    Write-Host "Loading server list from file: $($ServerList[0])" -ForegroundColor Yellow
    $servers = Get-Content $ServerList[0] | Where-Object { $_.Trim() -ne "" }
}
else {
    $servers = $ServerList
}

Write-Host "Servers to update: $($servers.Count)" -ForegroundColor Cyan
$servers | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
Write-Host ""

# Validate binaries exist
$binariesFullPath = Resolve-Path $ComputeBinariesPath -ErrorAction Stop
if (-not (Test-Path "$binariesFullPath\rhino.compute.exe")) {
    Write-Error "Compute binaries not found at: $binariesFullPath"
    exit 1
}

# Get build version/timestamp for tracking
$buildVersion = (Get-Item "$binariesFullPath\rhino.compute.exe").LastWriteTime.ToString("yyyyMMdd-HHmmss")
Write-Host "Build version: $buildVersion" -ForegroundColor Cyan
Write-Host ""

# Prompt for credentials if not provided
if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter credentials for remote servers"
}

# Function to check server health
function Test-ServerHealth {
    param([string]$Server, [int]$Port = 5000)

    try {
        $response = Invoke-WebRequest -Uri "http://${Server}:${Port}/healthcheck/ready" -TimeoutSec 10 -UseBasicParsing
        return $response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

# Function to update a single server
function Update-SingleServer {
    param([string]$Server, [int]$Port)

    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    Write-Host "Updating: $Server" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray

    try {
        # Step 1: Remove from load balancer (if configured)
        if ($LoadBalancerUrl) {
            Write-Host "  [1/8] Removing from load balancer..." -ForegroundColor Yellow
            # TODO: Add your load balancer API call here
            # Invoke-RestMethod -Uri "$LoadBalancerUrl/backend/remove" -Method POST -Body @{server=$Server}
            Write-Host "  ⚠ Manual step: Remove $Server from load balancer" -ForegroundColor Yellow
            Read-Host "  Press Enter when server is removed from rotation"
        }
        else {
            Write-Host "  [1/8] Skipping load balancer step (no URL provided)" -ForegroundColor Gray
        }

        # Step 2: Test connectivity
        Write-Host "  [2/8] Testing connectivity..." -ForegroundColor Yellow
        $testConnection = Test-Connection -ComputerName $Server -Count 1 -Quiet
        if (-not $testConnection) {
            throw "Cannot reach server: $Server"
        }
        Write-Host "  ✓ Server is reachable" -ForegroundColor Green

        # Step 3: Stop service
        Write-Host "  [3/8] Stopping RhinoCompute service..." -ForegroundColor Yellow
        Invoke-Command -ComputerName $Server -Credential $Credential -ScriptBlock {
            Stop-Service -Name "RhinoCompute" -Force
            Start-Sleep -Seconds 3
        }
        Write-Host "  ✓ Service stopped" -ForegroundColor Green

        # Step 4: Backup current version
        Write-Host "  [4/8] Backing up current version..." -ForegroundColor Yellow
        $backupName = "backup_$buildVersion"
        Invoke-Command -ComputerName $Server -Credential $Credential -ArgumentList $InstallPath, $backupName -ScriptBlock {
            param($InstallPath, $BackupName)
            $backupPath = "$InstallPath\$BackupName"
            if (Test-Path $backupPath) {
                Remove-Item -Path $backupPath -Recurse -Force
            }
            $filesToBackup = Get-ChildItem -Path $InstallPath -Exclude "backup_*", "logs", "nssm.exe"
            New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
            $filesToBackup | Copy-Item -Destination $backupPath -Recurse -Force
        }
        Write-Host "  ✓ Backup created: $backupName" -ForegroundColor Green

        # Step 5: Deploy new binaries
        Write-Host "  [5/8] Deploying new binaries..." -ForegroundColor Yellow
        $session = New-PSSession -ComputerName $Server -Credential $Credential

        # Copy files to remote server
        Copy-Item -Path "$binariesFullPath\*" -Destination $InstallPath -ToSession $session -Recurse -Force

        Remove-PSSession $session
        Write-Host "  ✓ New binaries deployed" -ForegroundColor Green

        # Step 6: Start service
        Write-Host "  [6/8] Starting RhinoCompute service..." -ForegroundColor Yellow
        Invoke-Command -ComputerName $Server -Credential $Credential -ScriptBlock {
            Start-Service -Name "RhinoCompute"
            Start-Sleep -Seconds 10
        }
        Write-Host "  ✓ Service started" -ForegroundColor Green

        # Step 7: Health check
        Write-Host "  [7/8] Running health checks..." -ForegroundColor Yellow
        if (-not $SkipHealthCheck) {
            $healthCheckAttempts = 0
            $maxAttempts = 12
            $healthy = $false

            while ($healthCheckAttempts -lt $maxAttempts -and -not $healthy) {
                $healthCheckAttempts++
                Write-Host "  Attempt $healthCheckAttempts/$maxAttempts..." -ForegroundColor Gray
                $healthy = Test-ServerHealth -Server $Server -Port $Port
                if (-not $healthy) {
                    Start-Sleep -Seconds 5
                }
            }

            if ($healthy) {
                Write-Host "  ✓ Health check passed" -ForegroundColor Green
            }
            else {
                throw "Health check failed after $maxAttempts attempts"
            }
        }
        else {
            Write-Host "  ⚠ Health check skipped" -ForegroundColor Yellow
        }

        # Step 8: Add back to load balancer
        if ($LoadBalancerUrl) {
            Write-Host "  [8/8] Adding back to load balancer..." -ForegroundColor Yellow
            # TODO: Add your load balancer API call here
            # Invoke-RestMethod -Uri "$LoadBalancerUrl/backend/add" -Method POST -Body @{server=$Server}
            Write-Host "  ⚠ Manual step: Add $Server back to load balancer" -ForegroundColor Yellow
            Read-Host "  Press Enter when server is back in rotation"
        }
        else {
            Write-Host "  [8/8] Skipping load balancer step" -ForegroundColor Gray
        }

        Write-Host "  ✓✓✓ Server update completed successfully ✓✓✓" -ForegroundColor Green
        return $true

    }
    catch {
        Write-Host "  ✗✗✗ Update failed: $($_.Exception.Message) ✗✗✗" -ForegroundColor Red
        Write-Host ""
        Write-Host "Rollback instructions:" -ForegroundColor Yellow
        Write-Host "  1. Connect to $Server" -ForegroundColor Gray
        Write-Host "  2. Run: Stop-Service RhinoCompute" -ForegroundColor Gray
        Write-Host "  3. Run: Copy-Item '$InstallPath\backup_$buildVersion\*' -Destination '$InstallPath' -Recurse -Force" -ForegroundColor Gray
        Write-Host "  4. Run: Start-Service RhinoCompute" -ForegroundColor Gray
        return $false
    }
}

# Main update loop
$successCount = 0
$failCount = 0
$totalServers = $servers.Count

for ($i = 0; $i -lt $totalServers; $i++) {
    $server = $servers[$i]
    $serverNum = $i + 1

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Server $serverNum of $totalServers : $($server.PadRight(26)) ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan

    $success = Update-SingleServer -Server $server -Port $Port

    if ($success) {
        $successCount++
    }
    else {
        $failCount++

        Write-Host ""
        $continue = Read-Host "Update failed for $server. Continue with remaining servers? (Y/N)"
        if ($continue -ne "Y") {
            Write-Host "Update process aborted by user." -ForegroundColor Red
            break
        }
    }

    # Wait between servers (except for the last one)
    if ($i -lt ($totalServers - 1)) {
        Write-Host ""
        Write-Host "Waiting $WaitBetweenServers seconds before next server..." -ForegroundColor Yellow
        Start-Sleep -Seconds $WaitBetweenServers
    }
}

# Summary
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host "=== Update Summary ===" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host "Total servers:    $totalServers" -ForegroundColor Gray
Write-Host "Successful:       $successCount" -ForegroundColor Green
Write-Host "Failed:           $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Gray" })
Write-Host ""

if ($failCount -eq 0) {
    Write-Host "✓ Cluster update completed successfully!" -ForegroundColor Green
}
else {
    Write-Host "⚠ Some servers failed to update. Check logs above." -ForegroundColor Yellow
}
Write-Host ""
