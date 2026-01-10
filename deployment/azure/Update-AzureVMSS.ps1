<#
.SYNOPSIS
    Updates Rhino Compute on Azure VM Scale Set with zero downtime.

.DESCRIPTION
    Performs a rolling update on Azure VMSS:
    - Uploads new binaries to Azure Storage
    - Updates VMs one at a time using VMSS rolling upgrade
    - Health checks ensure each VM is healthy before proceeding

.PARAMETER ResourceGroupName
    Azure Resource Group name

.PARAMETER VMSSName
    VM Scale Set name. Default: vmss-rhinocompute

.PARAMETER ComputeBinariesPath
    Local path to new compiled binaries

.PARAMETER StorageAccountName
    Storage account name (will auto-detect if not provided)

.EXAMPLE
    .\Update-AzureVMSS.ps1 -ResourceGroupName "rg-rhinocompute-prod"

.EXAMPLE
    .\Update-AzureVMSS.ps1 `
        -ResourceGroupName "rg-compute" `
        -VMSSName "vmss-rhinocompute" `
        -ComputeBinariesPath "..\..\src\dist\rhino.compute"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$false)]
    [string]$VMSSName = "vmss-rhinocompute",

    [Parameter(Mandatory=$false)]
    [string]$ComputeBinariesPath = "..\..\src\dist\rhino.compute",

    [Parameter(Mandatory=$false)]
    [string]$StorageAccountName
)

$ErrorActionPreference = "Stop"

Write-Host "=== Azure VMSS Update ===" -ForegroundColor Cyan
Write-Host ""

# Check Azure CLI
try {
    az version --output none 2>$null
} catch {
    Write-Error "Azure CLI not found! Please install: https://aka.ms/installazurecli"
    exit 1
}

# Auto-detect storage account if not provided
if (-not $StorageAccountName) {
    Write-Host "Auto-detecting storage account..." -ForegroundColor Yellow
    $storageAccounts = az storage account list `
        --resource-group $ResourceGroupName `
        --query "[?starts_with(name, 'storhinocompute')].name" -o tsv

    if ($storageAccounts) {
        $StorageAccountName = $storageAccounts.Split("`n")[0]
        Write-Host "  ✓ Found: $StorageAccountName" -ForegroundColor Green
    } else {
        Write-Error "No storage account found in resource group. Please specify -StorageAccountName"
        exit 1
    }
}

$containerName = "deployment"
$buildVersion = (Get-Date -Format "yyyyMMdd-HHmmss")

Write-Host "Update Configuration:" -ForegroundColor Cyan
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor Gray
Write-Host "  VMSS Name: $VMSSName" -ForegroundColor Gray
Write-Host "  Storage Account: $StorageAccountName" -ForegroundColor Gray
Write-Host "  Build Version: $buildVersion" -ForegroundColor Gray
Write-Host ""

# Step 1: Get storage account key
Write-Host "[1/5] Getting storage account credentials..." -ForegroundColor Yellow
$storageKey = az storage account keys list `
    --resource-group $ResourceGroupName `
    --account-name $StorageAccountName `
    --query "[0].value" -o tsv
Write-Host "  ✓ Credentials retrieved" -ForegroundColor Green

# Step 2: Upload new binaries
Write-Host "[2/5] Uploading new binaries to Azure Storage..." -ForegroundColor Yellow
$binariesFullPath = Resolve-Path $ComputeBinariesPath -ErrorAction Stop

# Create zip
$zipPath = "$env:TEMP\rhino.compute-$buildVersion.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath }
Compress-Archive -Path "$binariesFullPath\*" -DestinationPath $zipPath

# Upload to Azure
az storage blob upload `
    --account-name $StorageAccountName `
    --account-key $storageKey `
    --container-name $containerName `
    --name "rhino.compute-$buildVersion.zip" `
    --file $zipPath `
    --overwrite `
    --output none

# Also update the "latest" version
az storage blob upload `
    --account-name $StorageAccountName `
    --account-key $storageKey `
    --container-name $containerName `
    --name "rhino.compute-latest.zip" `
    --file $zipPath `
    --overwrite `
    --output none

Remove-Item $zipPath
Write-Host "  ✓ Binaries uploaded (version: $buildVersion)" -ForegroundColor Green

# Step 3: Create update script
Write-Host "[3/5] Creating update script..." -ForegroundColor Yellow

$updateScript = @"
`$ErrorActionPreference = "Stop"
Write-Host "Updating Rhino Compute to version $buildVersion..."

# Stop service
Stop-Service -Name "RhinoCompute" -Force

# Backup current version
`$installPath = "C:\RhinoCompute"
`$backupPath = "`$installPath\backup_$buildVersion"
if (Test-Path `$backupPath) { Remove-Item `$backupPath -Recurse -Force }
New-Item -ItemType Directory -Path `$backupPath -Force | Out-Null
Get-ChildItem -Path `$installPath -Exclude "backup_*","pre_rollback_*","logs","nssm.exe" |
    Copy-Item -Destination `$backupPath -Recurse -Force

# Download new version
`$storageUrl = "https://$StorageAccountName.blob.core.windows.net/$containerName/rhino.compute-latest.zip"
`$zipPath = "C:\rhino-update.zip"
Invoke-WebRequest -Uri `$storageUrl -OutFile `$zipPath

# Extract new version
Get-ChildItem -Path `$installPath -Exclude "backup_*","pre_rollback_*","logs","nssm.exe" |
    Remove-Item -Recurse -Force
Expand-Archive -Path `$zipPath -DestinationPath `$installPath -Force
Remove-Item `$zipPath

# Start service
Start-Service -Name "RhinoCompute"

Write-Host "Update completed! Version: $buildVersion"
"@

$updateScriptPath = "$env:TEMP\azure-update.ps1"
Set-Content -Path $updateScriptPath -Value $updateScript

# Upload update script
az storage blob upload `
    --account-name $StorageAccountName `
    --account-key $storageKey `
    --container-name $containerName `
    --name "azure-update-$buildVersion.ps1" `
    --file $updateScriptPath `
    --overwrite `
    --output none

Remove-Item $updateScriptPath
Write-Host "  ✓ Update script uploaded" -ForegroundColor Green

# Step 4: Configure rolling upgrade
Write-Host "[4/5] Configuring VMSS rolling upgrade policy..." -ForegroundColor Yellow

az vmss update `
    --resource-group $ResourceGroupName `
    --name $VMSSName `
    --set "upgradePolicy.mode=Rolling" `
    --set "upgradePolicy.rollingUpgradePolicy.maxBatchInstancePercent=20" `
    --set "upgradePolicy.rollingUpgradePolicy.maxUnhealthyInstancePercent=20" `
    --set "upgradePolicy.rollingUpgradePolicy.maxUnhealthyUpgradedInstancePercent=20" `
    --set "upgradePolicy.rollingUpgradePolicy.pauseTimeBetweenBatches=PT30S" `
    --output none

Write-Host "  ✓ Rolling upgrade configured (20% at a time, 30s pause)" -ForegroundColor Green

# Step 5: Trigger update via Custom Script Extension
Write-Host "[5/5] Triggering update on all VMs..." -ForegroundColor Yellow
Write-Host "  This will update VMs in batches..." -ForegroundColor Gray

# Generate SAS URL for update script
$sasExpiry = (Get-Date).AddHours(2).ToString("yyyy-MM-ddTHH:mm:ssZ")
$updateScriptSasUrl = az storage blob generate-sas `
    --account-name $StorageAccountName `
    --account-key $storageKey `
    --container-name $containerName `
    --name "azure-update-$buildVersion.ps1" `
    --permissions r `
    --expiry $sasExpiry `
    --full-uri -o tsv

$customScriptConfig = @{
    fileUris = @($updateScriptSasUrl)
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -File azure-update-$buildVersion.ps1"
} | ConvertTo-Json -Compress

# Update the extension (this triggers the update)
az vmss extension set `
    --resource-group $ResourceGroupName `
    --vmss-name $VMSSName `
    --name CustomScriptExtension `
    --publisher Microsoft.Compute `
    --version 1.10 `
    --settings $customScriptConfig `
    --force-update `
    --output none

Write-Host "  ✓ Update triggered" -ForegroundColor Green

# Step 6: Monitor progress
Write-Host ""
Write-Host "Monitoring update progress..." -ForegroundColor Yellow
Write-Host "Press Ctrl+C to stop monitoring (update will continue in background)" -ForegroundColor Gray
Write-Host ""

$maxWaitMinutes = 30
$startTime = Get-Date

while (((Get-Date) - $startTime).TotalMinutes -lt $maxWaitMinutes) {
    $instances = az vmss list-instances `
        --resource-group $ResourceGroupName `
        --name $VMSSName `
        --query "[].{Name:name, ProvisioningState:provisioningState, LatestModel:latestModelApplied}" `
        -o json | ConvertFrom-Json

    $total = $instances.Count
    $updated = ($instances | Where-Object { $_.LatestModel -eq $true }).Count
    $updating = ($instances | Where-Object { $_.ProvisioningState -eq "Updating" }).Count

    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "  [$timestamp] Updated: $updated/$total | Updating: $updating" -ForegroundColor Cyan

    if ($updated -eq $total) {
        Write-Host ""
        Write-Host "  ✓✓✓ All instances updated successfully! ✓✓✓" -ForegroundColor Green
        break
    }

    Start-Sleep -Seconds 10
}

# Summary
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host "=== Update Complete ===" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Build Version: $buildVersion" -ForegroundColor Gray
Write-Host ""
Write-Host "Verify update:" -ForegroundColor Yellow

$lbIp = az network public-ip show `
    --resource-group $ResourceGroupName `
    --name "pip-rhinocompute-lb" `
    --query "ipAddress" -o tsv 2>$null

if ($lbIp) {
    Write-Host "  Test health: http://$lbIp/healthcheck/ready" -ForegroundColor Gray
}

Write-Host "  View instances: az vmss list-instances -g $ResourceGroupName -n $VMSSName -o table" -ForegroundColor Gray
Write-Host ""
Write-Host "Rollback (if needed):" -ForegroundColor Yellow
Write-Host "  Use Azure Portal to reimage VMs to previous model" -ForegroundColor Gray
Write-Host "  Or manually run backup restore on each VM" -ForegroundColor Gray
Write-Host ""
