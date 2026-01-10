<#
.SYNOPSIS
    Deploys Rhino Compute cluster on Azure using VM Scale Set.

.DESCRIPTION
    Creates a complete Azure infrastructure for Rhino Compute:
    - VM Scale Set with Windows Server VMs
    - Azure Load Balancer with health probes
    - Auto-scale rules based on CPU
    - Custom script extension to install Rhino Compute
    - Storage account for scripts and binaries

.PARAMETER ResourceGroupName
    Azure Resource Group name. Will be created if doesn't exist.

.PARAMETER Location
    Azure region (e.g., "eastus", "westeurope", "australiaeast")

.PARAMETER VMSize
    VM size. Default: Standard_D4s_v3 (4 vCPUs, 16 GB RAM)
    Recommended sizes: Standard_D4s_v3, Standard_D8s_v3, Standard_F8s_v2

.PARAMETER InstanceCount
    Initial number of VM instances. Default: 3

.PARAMETER MinInstances
    Minimum instances for auto-scale. Default: 2

.PARAMETER MaxInstances
    Maximum instances for auto-scale. Default: 10

.PARAMETER RhinoInstallerUrl
    URL to Rhino installer (must be publicly accessible or in Azure Storage)

.PARAMETER ComputeBinariesPath
    Local path to compiled rhino.compute binaries

.PARAMETER ApiKey
    Optional API key for Rhino Compute authentication

.PARAMETER ChildCount
    Number of compute.geometry child processes per VM. Default: 4

.EXAMPLE
    .\Deploy-AzureVMScaleSet.ps1 -ResourceGroupName "rg-rhinocompute-prod" -Location "eastus"

.EXAMPLE
    .\Deploy-AzureVMScaleSet.ps1 `
        -ResourceGroupName "rg-compute" `
        -Location "westeurope" `
        -VMSize "Standard_D8s_v3" `
        -InstanceCount 5 `
        -MaxInstances 20 `
        -ApiKey "my-secret-key"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string]$Location,

    [Parameter(Mandatory=$false)]
    [string]$VMSize = "Standard_D4s_v3",

    [Parameter(Mandatory=$false)]
    [int]$InstanceCount = 3,

    [Parameter(Mandatory=$false)]
    [int]$MinInstances = 2,

    [Parameter(Mandatory=$false)]
    [int]$MaxInstances = 10,

    [Parameter(Mandatory=$false)]
    [string]$RhinoInstallerUrl,

    [Parameter(Mandatory=$false)]
    [string]$ComputeBinariesPath = "..\..\src\dist\rhino.compute",

    [Parameter(Mandatory=$false)]
    [string]$ApiKey,

    [Parameter(Mandatory=$false)]
    [int]$ChildCount = 4
)

$ErrorActionPreference = "Stop"

Write-Host "=== Azure Rhino Compute Deployment ===" -ForegroundColor Cyan
Write-Host ""

# Check if Azure CLI is installed
try {
    $azVersion = az version --output json | ConvertFrom-Json
    Write-Host "✓ Azure CLI version: $($azVersion.'azure-cli')" -ForegroundColor Green
} catch {
    Write-Error "Azure CLI not found! Please install: https://aka.ms/installazurecli"
    exit 1
}

# Check if logged in
$account = az account show 2>$null
if (-not $account) {
    Write-Host "Not logged in to Azure. Running 'az login'..." -ForegroundColor Yellow
    az login
}

$accountInfo = az account show | ConvertFrom-Json
Write-Host "✓ Logged in as: $($accountInfo.user.name)" -ForegroundColor Green
Write-Host "✓ Subscription: $($accountInfo.name)" -ForegroundColor Green
Write-Host ""

# Generate unique names
$timestamp = Get-Date -Format "yyyyMMddHHmm"
$vmssName = "vmss-rhinocompute"
$lbName = "lb-rhinocompute"
$pipName = "pip-rhinocompute-lb"
$storageAccountName = "storhinocompute$($timestamp.Substring(0,12))"  # Max 24 chars, lowercase
$containerName = "deployment"
$nsgName = "nsg-rhinocompute"

Write-Host "Deployment Configuration:" -ForegroundColor Cyan
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor Gray
Write-Host "  Location: $Location" -ForegroundColor Gray
Write-Host "  VM Size: $VMSize" -ForegroundColor Gray
Write-Host "  Initial Instances: $InstanceCount" -ForegroundColor Gray
Write-Host "  Auto-scale: $MinInstances - $MaxInstances instances" -ForegroundColor Gray
Write-Host ""

# Step 1: Create Resource Group
Write-Host "[1/8] Creating Resource Group..." -ForegroundColor Yellow
az group create --name $ResourceGroupName --location $Location --output none
Write-Host "  ✓ Resource Group: $ResourceGroupName" -ForegroundColor Green

# Step 2: Create Storage Account for deployment files
Write-Host "[2/8] Creating Storage Account for deployment files..." -ForegroundColor Yellow
az storage account create `
    --name $storageAccountName `
    --resource-group $ResourceGroupName `
    --location $Location `
    --sku Standard_LRS `
    --output none

$storageKey = az storage account keys list `
    --resource-group $ResourceGroupName `
    --account-name $storageAccountName `
    --query "[0].value" -o tsv

az storage container create `
    --name $containerName `
    --account-name $storageAccountName `
    --account-key $storageKey `
    --output none

Write-Host "  ✓ Storage Account: $storageAccountName" -ForegroundColor Green

# Step 3: Upload compute binaries to Azure Storage
Write-Host "[3/8] Uploading compute binaries to Azure Storage..." -ForegroundColor Yellow
$binariesFullPath = Resolve-Path $ComputeBinariesPath -ErrorAction Stop

# Create a zip of binaries
$zipPath = "$env:TEMP\rhino.compute.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath }
Compress-Archive -Path "$binariesFullPath\*" -DestinationPath $zipPath

az storage blob upload `
    --account-name $storageAccountName `
    --account-key $storageKey `
    --container-name $containerName `
    --name "rhino.compute.zip" `
    --file $zipPath `
    --output none

Remove-Item $zipPath
Write-Host "  ✓ Binaries uploaded" -ForegroundColor Green

# Step 4: Upload installation script
Write-Host "[4/8] Uploading installation script..." -ForegroundColor Yellow

# Create cloud-init style script
$installScript = @"
# Azure VM Initialization Script for Rhino Compute
`$ErrorActionPreference = "Stop"

Write-Host "Starting Rhino Compute installation..."

# Download compute binaries from Azure Storage
`$storageUrl = "https://$storageAccountName.blob.core.windows.net/$containerName/rhino.compute.zip"
`$binariesZip = "C:\rhino.compute.zip"
`$installPath = "C:\RhinoCompute"

Invoke-WebRequest -Uri `$storageUrl -OutFile `$binariesZip

# Extract binaries
Expand-Archive -Path `$binariesZip -DestinationPath `$installPath -Force
Remove-Item `$binariesZip

# Download and run Install-ComputeServer.ps1
`$scriptUrl = "https://$storageAccountName.blob.core.windows.net/$containerName/Install-ComputeServer.ps1"
`$scriptPath = "C:\Install-ComputeServer.ps1"
Invoke-WebRequest -Uri `$scriptUrl -OutFile `$scriptPath

# Run installation
$(if ($RhinoInstallerUrl) { "& `$scriptPath -RhinoInstallerPath 'C:\rhino_installer.exe' -ComputeBinariesPath `$installPath -Port 5000 -ChildCount $ChildCount$(if ($ApiKey) { " -ApiKey '$ApiKey'" })" }
else { "& `$scriptPath -ComputeBinariesPath `$installPath -Port 5000 -ChildCount $ChildCount$(if ($ApiKey) { " -ApiKey '$ApiKey'" })" })

Write-Host "Rhino Compute installation completed!"
"@

$installScriptPath = "$env:TEMP\azure-install.ps1"
Set-Content -Path $installScriptPath -Value $installScript

az storage blob upload `
    --account-name $storageAccountName `
    --account-key $storageKey `
    --container-name $containerName `
    --name "azure-install.ps1" `
    --file $installScriptPath `
    --output none

# Upload Install-ComputeServer.ps1
az storage blob upload `
    --account-name $storageAccountName `
    --account-key $storageKey `
    --container-name $containerName `
    --name "Install-ComputeServer.ps1" `
    --file "..\Install-ComputeServer.ps1" `
    --output none

Remove-Item $installScriptPath
Write-Host "  ✓ Scripts uploaded" -ForegroundColor Green

# Step 5: Create Network Security Group
Write-Host "[5/8] Creating Network Security Group..." -ForegroundColor Yellow
az network nsg create `
    --resource-group $ResourceGroupName `
    --name $nsgName `
    --output none

# Allow port 5000 for compute
az network nsg rule create `
    --resource-group $ResourceGroupName `
    --nsg-name $nsgName `
    --name "AllowCompute" `
    --priority 100 `
    --direction Inbound `
    --access Allow `
    --protocol Tcp `
    --destination-port-ranges 5000 `
    --output none

Write-Host "  ✓ NSG created with compute port rules" -ForegroundColor Green

# Step 6: Create Public IP for Load Balancer
Write-Host "[6/8] Creating Public IP for Load Balancer..." -ForegroundColor Yellow
az network public-ip create `
    --resource-group $ResourceGroupName `
    --name $pipName `
    --sku Standard `
    --allocation-method Static `
    --output none

$publicIp = az network public-ip show `
    --resource-group $ResourceGroupName `
    --name $pipName `
    --query "ipAddress" -o tsv

Write-Host "  ✓ Public IP: $publicIp" -ForegroundColor Green

# Step 7: Create VM Scale Set with Load Balancer
Write-Host "[7/8] Creating VM Scale Set with Load Balancer..." -ForegroundColor Yellow
Write-Host "  This may take 5-10 minutes..." -ForegroundColor Gray

# Get SAS URL for the install script
$sasExpiry = (Get-Date).AddHours(2).ToString("yyyy-MM-ddTHH:mm:ssZ")
$scriptSasUrl = az storage blob generate-sas `
    --account-name $storageAccountName `
    --account-key $storageKey `
    --container-name $containerName `
    --name "azure-install.ps1" `
    --permissions r `
    --expiry $sasExpiry `
    --full-uri -o tsv

az vmss create `
    --resource-group $ResourceGroupName `
    --name $vmssName `
    --image Win2022Datacenter `
    --vm-sku $VMSize `
    --instance-count $InstanceCount `
    --admin-username "azureuser" `
    --admin-password "RhinoCompute2026!@#" `
    --public-ip-address $pipName `
    --load-balancer $lbName `
    --backend-pool-name "computeBackendPool" `
    --vnet-name "vnet-rhinocompute" `
    --subnet "subnet-compute" `
    --nsg $nsgName `
    --upgrade-policy-mode Automatic `
    --output none

Write-Host "  ✓ VM Scale Set created: $vmssName" -ForegroundColor Green

# Configure Load Balancer Health Probe and Rules
Write-Host "  Configuring Load Balancer..." -ForegroundColor Yellow

az network lb probe create `
    --resource-group $ResourceGroupName `
    --lb-name $lbName `
    --name "healthProbe" `
    --protocol Http `
    --port 5000 `
    --path "/healthcheck/ready" `
    --output none

az network lb rule create `
    --resource-group $ResourceGroupName `
    --lb-name $lbName `
    --name "computeRule" `
    --protocol Tcp `
    --frontend-port 80 `
    --backend-port 5000 `
    --backend-pool-name "computeBackendPool" `
    --probe-name "healthProbe" `
    --output none

Write-Host "  ✓ Load Balancer configured with health probes" -ForegroundColor Green

# Add Custom Script Extension to VMs
Write-Host "  Installing Rhino Compute on VMs..." -ForegroundColor Yellow

$customScriptConfig = @{
    fileUris = @($scriptSasUrl)
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -File azure-install.ps1"
} | ConvertTo-Json -Compress

az vmss extension set `
    --resource-group $ResourceGroupName `
    --vmss-name $vmssName `
    --name CustomScriptExtension `
    --publisher Microsoft.Compute `
    --version 1.10 `
    --settings $customScriptConfig `
    --output none

Write-Host "  ✓ Installation script deployed to all VMs" -ForegroundColor Green
Write-Host "  ⏳ VMs are installing Rhino Compute in the background..." -ForegroundColor Yellow

# Step 8: Configure Auto-scale
Write-Host "[8/8] Configuring Auto-scale..." -ForegroundColor Yellow

# Scale out when CPU > 75%
az monitor autoscale create `
    --resource-group $ResourceGroupName `
    --resource $vmssName `
    --resource-type Microsoft.Compute/virtualMachineScaleSets `
    --name "autoscale-compute" `
    --min-count $MinInstances `
    --max-count $MaxInstances `
    --count $InstanceCount `
    --output none

az monitor autoscale rule create `
    --resource-group $ResourceGroupName `
    --autoscale-name "autoscale-compute" `
    --condition "Percentage CPU > 75 avg 5m" `
    --scale out 2 `
    --output none

# Scale in when CPU < 25%
az monitor autoscale rule create `
    --resource-group $ResourceGroupName `
    --autoscale-name "autoscale-compute" `
    --condition "Percentage CPU < 25 avg 5m" `
    --scale in 1 `
    --output none

Write-Host "  ✓ Auto-scale configured (CPU-based)" -ForegroundColor Green

# Summary
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host "=== Deployment Complete ===" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Load Balancer Public IP: " -NoNewline -ForegroundColor Yellow
Write-Host "http://$publicIp" -ForegroundColor Green
Write-Host ""
Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Gray
Write-Host "VM Scale Set: $vmssName" -ForegroundColor Gray
Write-Host "Load Balancer: $lbName" -ForegroundColor Gray
Write-Host "Storage Account: $storageAccountName" -ForegroundColor Gray
Write-Host ""
Write-Host "Auto-scale: $MinInstances - $MaxInstances instances (currently: $InstanceCount)" -ForegroundColor Gray
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. Wait 10-15 minutes for VMs to complete installation" -ForegroundColor Gray
Write-Host "  2. Test health: http://$publicIp/healthcheck/ready" -ForegroundColor Gray
Write-Host "  3. Monitor in Azure Portal: https://portal.azure.com" -ForegroundColor Gray
Write-Host ""
Write-Host "Management Commands:" -ForegroundColor Yellow
Write-Host "  View VMs:      az vmss list-instances -g $ResourceGroupName -n $vmssName -o table" -ForegroundColor Gray
Write-Host "  Scale manual:  az vmss scale -g $ResourceGroupName -n $vmssName --new-capacity 5" -ForegroundColor Gray
Write-Host "  Update:        Use .\Update-AzureVMSS.ps1 (see azure folder)" -ForegroundColor Gray
Write-Host "  Delete all:    az group delete -n $ResourceGroupName --yes" -ForegroundColor Gray
Write-Host ""
Write-Host "Admin Credentials:" -ForegroundColor Yellow
Write-Host "  Username: azureuser" -ForegroundColor Gray
Write-Host "  Password: RhinoCompute2026!@#" -ForegroundColor Gray
Write-Host "  (Change password in Azure Portal for production!)" -ForegroundColor Red
Write-Host ""
