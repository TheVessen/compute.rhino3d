<#
.SYNOPSIS
    Rolls back Rhino Compute to a previous backup version.

.DESCRIPTION
    Restores a compute server to a previous version from backup.
    Can be run locally or remotely on one or multiple servers.

.PARAMETER ServerList
    Array of server hostnames/IPs to rollback. Leave empty for local server.

.PARAMETER InstallPath
    Install path on server(s). Default: C:\RhinoCompute

.PARAMETER BackupName
    Name of backup to restore. If not specified, will show available backups.

.PARAMETER Credential
    PSCredential for remote servers.

.EXAMPLE
    .\Rollback-ComputeServer.ps1
    Lists available backups on local server

.EXAMPLE
    .\Rollback-ComputeServer.ps1 -BackupName "backup_20260110-143022"
    Rolls back local server to specific backup

.EXAMPLE
    .\Rollback-ComputeServer.ps1 -ServerList "compute1","compute2" -BackupName "backup_20260110-143022"
    Rolls back multiple remote servers
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string[]]$ServerList = @(),

    [Parameter(Mandatory=$false)]
    [string]$InstallPath = "C:\RhinoCompute",

    [Parameter(Mandatory=$false)]
    [string]$BackupName,

    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential
)

$ErrorActionPreference = "Stop"

Write-Host "=== Rhino Compute Rollback ===" -ForegroundColor Cyan
Write-Host ""

# If no servers specified, run locally
$isLocal = ($ServerList.Count -eq 0)
if ($isLocal) {
    $ServerList = @("localhost")
}

# Prompt for credentials if remote and not provided
if (-not $isLocal -and -not $Credential) {
    $Credential = Get-Credential -Message "Enter credentials for remote servers"
}

# Function to list available backups
function Get-AvailableBackups {
    param([string]$Server, [string]$InstallPath, [PSCredential]$Credential)

    if ($Server -eq "localhost") {
        $backups = Get-ChildItem -Path $InstallPath -Directory -Filter "backup_*" -ErrorAction SilentlyContinue
        return $backups | Select-Object Name, LastWriteTime
    } else {
        $backups = Invoke-Command -ComputerName $Server -Credential $Credential -ArgumentList $InstallPath -ScriptBlock {
            param($InstallPath)
            Get-ChildItem -Path $InstallPath -Directory -Filter "backup_*" -ErrorAction SilentlyContinue |
                Select-Object Name, LastWriteTime
        }
        return $backups
    }
}

# Function to rollback a single server
function Rollback-SingleServer {
    param(
        [string]$Server,
        [string]$InstallPath,
        [string]$BackupName,
        [PSCredential]$Credential
    )

    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    Write-Host "Rolling back: $Server" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray

    try {
        # List available backups
        Write-Host "  [1/5] Checking available backups..." -ForegroundColor Yellow
        $availableBackups = Get-AvailableBackups -Server $Server -InstallPath $InstallPath -Credential $Credential

        if ($availableBackups.Count -eq 0) {
            throw "No backups found in $InstallPath"
        }

        Write-Host "  Available backups:" -ForegroundColor Gray
        $availableBackups | ForEach-Object {
            Write-Host "    - $($_.Name) ($(($_.LastWriteTime).ToString('yyyy-MM-dd HH:mm:ss')))" -ForegroundColor Gray
        }

        # Validate backup exists
        $backupExists = $availableBackups | Where-Object { $_.Name -eq $BackupName }
        if (-not $backupExists) {
            throw "Backup '$BackupName' not found!"
        }

        Write-Host "  ✓ Backup found: $BackupName" -ForegroundColor Green

        # Stop service
        Write-Host "  [2/5] Stopping RhinoCompute service..." -ForegroundColor Yellow
        if ($Server -eq "localhost") {
            Stop-Service -Name "RhinoCompute" -Force -ErrorAction Stop
        } else {
            Invoke-Command -ComputerName $Server -Credential $Credential -ScriptBlock {
                Stop-Service -Name "RhinoCompute" -Force
            }
        }
        Start-Sleep -Seconds 3
        Write-Host "  ✓ Service stopped" -ForegroundColor Green

        # Create backup of current state (before rollback)
        Write-Host "  [3/5] Backing up current state..." -ForegroundColor Yellow
        $preRollbackBackup = "pre_rollback_$(Get-Date -Format 'yyyyMMdd-HHmmss')"

        if ($Server -eq "localhost") {
            $backupPath = "$InstallPath\$preRollbackBackup"
            New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
            $filesToBackup = Get-ChildItem -Path $InstallPath -Exclude "backup_*","pre_rollback_*","logs","nssm.exe"
            $filesToBackup | Copy-Item -Destination $backupPath -Recurse -Force
        } else {
            Invoke-Command -ComputerName $Server -Credential $Credential -ArgumentList $InstallPath, $preRollbackBackup -ScriptBlock {
                param($InstallPath, $PreRollbackBackup)
                $backupPath = "$InstallPath\$PreRollbackBackup"
                New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
                $filesToBackup = Get-ChildItem -Path $InstallPath -Exclude "backup_*","pre_rollback_*","logs","nssm.exe"
                $filesToBackup | Copy-Item -Destination $backupPath -Recurse -Force
            }
        }
        Write-Host "  ✓ Current state backed up to: $preRollbackBackup" -ForegroundColor Green

        # Restore from backup
        Write-Host "  [4/5] Restoring from backup..." -ForegroundColor Yellow

        if ($Server -eq "localhost") {
            $sourcePath = "$InstallPath\$BackupName\*"
            $filesToDelete = Get-ChildItem -Path $InstallPath -Exclude "backup_*","pre_rollback_*","logs","nssm.exe"
            $filesToDelete | Remove-Item -Recurse -Force
            Copy-Item -Path $sourcePath -Destination $InstallPath -Recurse -Force
        } else {
            Invoke-Command -ComputerName $Server -Credential $Credential -ArgumentList $InstallPath, $BackupName -ScriptBlock {
                param($InstallPath, $BackupName)
                $sourcePath = "$InstallPath\$BackupName\*"
                $filesToDelete = Get-ChildItem -Path $InstallPath -Exclude "backup_*","pre_rollback_*","logs","nssm.exe"
                $filesToDelete | Remove-Item -Recurse -Force
                Copy-Item -Path $sourcePath -Destination $InstallPath -Recurse -Force
            }
        }
        Write-Host "  ✓ Files restored from $BackupName" -ForegroundColor Green

        # Start service
        Write-Host "  [5/5] Starting RhinoCompute service..." -ForegroundColor Yellow
        if ($Server -eq "localhost") {
            Start-Service -Name "RhinoCompute"
        } else {
            Invoke-Command -ComputerName $Server -Credential $Credential -ScriptBlock {
                Start-Service -Name "RhinoCompute"
            }
        }
        Start-Sleep -Seconds 10
        Write-Host "  ✓ Service started" -ForegroundColor Green

        # Verify service is running
        if ($Server -eq "localhost") {
            $serviceStatus = (Get-Service -Name "RhinoCompute").Status
        } else {
            $serviceStatus = Invoke-Command -ComputerName $Server -Credential $Credential -ScriptBlock {
                (Get-Service -Name "RhinoCompute").Status
            }
        }

        if ($serviceStatus -eq "Running") {
            Write-Host "  ✓✓✓ Rollback completed successfully ✓✓✓" -ForegroundColor Green
            Write-Host "  Service is running" -ForegroundColor Green
        } else {
            Write-Warning "Service status: $serviceStatus"
        }

        return $true

    } catch {
        Write-Host "  ✗✗✗ Rollback failed: $($_.Exception.Message) ✗✗✗" -ForegroundColor Red
        return $false
    }
}

# Main logic
if (-not $BackupName) {
    # No backup specified - list available backups for first server
    Write-Host "No backup specified. Available backups on $($ServerList[0]):" -ForegroundColor Yellow
    Write-Host ""

    $backups = Get-AvailableBackups -Server $ServerList[0] -InstallPath $InstallPath -Credential $Credential

    if ($backups.Count -eq 0) {
        Write-Host "No backups found!" -ForegroundColor Red
        exit 1
    }

    $backups | Sort-Object LastWriteTime -Descending | ForEach-Object {
        Write-Host "  $($_.Name)" -ForegroundColor Cyan
        Write-Host "    Created: $(($_.LastWriteTime).ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "To rollback, run:" -ForegroundColor Yellow
    Write-Host "  .\Rollback-ComputeServer.ps1 -BackupName 'backup_XXXXXXXX-XXXXXX'" -ForegroundColor Gray
    exit 0
}

# Perform rollback
$successCount = 0
$failCount = 0

foreach ($server in $ServerList) {
    Write-Host ""
    $success = Rollback-SingleServer -Server $server -InstallPath $InstallPath -BackupName $BackupName -Credential $Credential

    if ($success) {
        $successCount++
    } else {
        $failCount++
    }
}

# Summary
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host "=== Rollback Summary ===" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host "Total servers:    $($ServerList.Count)" -ForegroundColor Gray
Write-Host "Successful:       $successCount" -ForegroundColor Green
Write-Host "Failed:           $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Gray" })
Write-Host ""

if ($failCount -eq 0) {
    Write-Host "✓ Rollback completed successfully!" -ForegroundColor Green
} else {
    Write-Host "⚠ Some servers failed to rollback. Check logs above." -ForegroundColor Yellow
}
Write-Host ""
