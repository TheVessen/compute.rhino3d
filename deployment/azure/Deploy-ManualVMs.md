# Deploy Rhino Compute on Azure VMs (Manual Setup)

This guide shows how to deploy Rhino Compute on **manually created Azure VMs** using the same scripts as private servers. This approach gives you more control than VM Scale Sets.

## Architecture

```
Internet
    ↓
[Azure Load Balancer]
    ↓
┌────────┼────────┐
↓        ↓        ↓
[VM 1]  [VM 2]  [VM 3]
Manual  Manual  Manual
Windows Windows Windows
Server  Server  Server
```

## When to Use This Approach

✅ **Use Manual VMs when:**
- You want full control over each VM
- Fixed number of servers (no auto-scaling needed)
- Want to configure VMs individually
- Simpler than VM Scale Sets
- Lower cost (no VMSS overhead)

❌ **Don't use if you need:**
- Auto-scaling based on load
- Automatic VM replacement on failure
- Rolling updates managed by Azure

---

## Step 1: Create Azure VMs

### Option A: Using Azure Portal (GUI)

1. **Go to Azure Portal:** https://portal.azure.com

2. **Create Resource Group:**
   - Click "Resource groups" → "Create"
   - Name: `rg-rhinocompute-prod`
   - Region: `East US` (or your preferred region)
   - Click "Review + create"

3. **Create VMs (repeat for each server):**
   - Click "Virtual machines" → "Create"
   - **Basics:**
     - Resource group: `rg-rhinocompute-prod`
     - Virtual machine name: `vm-compute-01` (then 02, 03, etc.)
     - Region: Same as resource group
     - Image: **Windows Server 2022 Datacenter**
     - Size: `Standard_D4s_v3` (4 vCPUs, 16 GB) - [See size recommendations](#vm-size-recommendations)
     - Username: `azureuser`
     - Password: (create a strong password)
   - **Disks:**
     - OS disk type: `Premium SSD` (recommended)
   - **Networking:**
     - Virtual network: Create new → `vnet-rhinocompute`
     - Subnet: `subnet-compute`
     - Public IP: None (you'll use load balancer)
     - NIC network security group: Basic
     - **Public inbound ports:** Select "RDP (3389)" for initial setup
   - **Management:**
     - Enable auto-shutdown: Optional (for cost savings in dev/test)
   - Click "Review + create"

4. **Create 2-3 VMs** following the same process

### Option B: Using Azure CLI (Faster)

```powershell
# Login
az login

# Variables
$resourceGroup = "rg-rhinocompute-prod"
$location = "eastus"
$vmSize = "Standard_D4s_v3"
$username = "azureuser"
$password = "RhinoCompute2026!@#"  # Change this!

# Create resource group
az group create --name $resourceGroup --location $location

# Create VNet
az network vnet create `
    --resource-group $resourceGroup `
    --name vnet-rhinocompute `
    --address-prefix 10.0.0.0/16 `
    --subnet-name subnet-compute `
    --subnet-prefix 10.0.1.0/24

# Create VMs (loop for multiple VMs)
for ($i=1; $i -le 3; $i++) {
    $vmName = "vm-compute-0$i"

    az vm create `
        --resource-group $resourceGroup `
        --name $vmName `
        --image Win2022Datacenter `
        --size $vmSize `
        --admin-username $username `
        --admin-password $password `
        --vnet-name vnet-rhinocompute `
        --subnet subnet-compute `
        --public-ip-address "" `
        --nsg-rule RDP

    Write-Host "Created $vmName"
}
```

---

## Step 2: Configure VMs for Remote Management

### Enable PowerShell Remoting on Each VM

**Option A: Via RDP (Initial Setup)**

1. **Connect via RDP:**
   ```powershell
   # Get public IP if you created one temporarily
   az vm list-ip-addresses -g $resourceGroup -n vm-compute-01 -o table

   # Or use Azure Bastion / Serial Console
   ```

2. **On each VM, run PowerShell as Administrator:**
   ```powershell
   # Enable PowerShell remoting
   Enable-PSRemoting -Force

   # Configure WinRM for HTTPS (more secure)
   winrm quickconfig -transport:https -force

   # Allow remote management
   Set-NetFirewallRule -Name "WINRM-HTTP-In-TCP" -RemoteAddress Any
   ```

**Option B: Via Azure Run Command (No RDP needed)**

```powershell
# Enable PSRemoting on all VMs
for ($i=1; $i -le 3; $i++) {
    $vmName = "vm-compute-0$i"

    az vm run-command invoke `
        --resource-group $resourceGroup `
        --name $vmName `
        --command-id RunPowerShellScript `
        --scripts "Enable-PSRemoting -Force; Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -RemoteAddress Any"

    Write-Host "Configured $vmName"
}
```

---

## Step 3: Install Rhino Compute on All VMs

### Option A: Remote Installation (Recommended)

From your **local machine**:

```powershell
cd c:\Users\felix\coding\compute.rhino3d\deployment

# Create credential
$username = "azureuser"
$password = ConvertTo-SecureString "RhinoCompute2026!@#" -AsPlainText -Force
$credential = New-PSCredential($username, $password)

# Get VM private IPs
$vm1 = (az vm show -g $resourceGroup -n vm-compute-01 --query "privateIps" -o tsv)
$vm2 = (az vm show -g $resourceGroup -n vm-compute-02 --query "privateIps" -o tsv)
$vm3 = (az vm show -g $resourceGroup -n vm-compute-03 --query "privateIps" -o tsv)

# Install on each VM using Update-ComputeCluster script
.\Update-ComputeCluster.ps1 `
    -ServerList @($vm1, $vm2, $vm3) `
    -Credential $credential
```

**Note:** This uses the update script for initial installation too!

### Option B: Manual Installation on Each VM

**Connect to each VM via RDP and run:**

```powershell
# Download the install script
Invoke-WebRequest `
    -Uri "https://raw.githubusercontent.com/mcneel/compute.rhino3d/Compute8/deployment/Install-ComputeServer.ps1" `
    -OutFile "C:\Install-ComputeServer.ps1"

# Or copy from your local machine
# Copy-Item -Path "\\your-local-machine\share\Install-ComputeServer.ps1" -Destination "C:\"

# Run installation
cd C:\
.\Install-ComputeServer.ps1 `
    -RhinoInstallerPath "C:\rhino_installer.exe" `
    -Port 5000 `
    -ChildCount 4
```

### Option C: Azure Run Command (No RDP)

**Upload binaries to Azure Storage first:**

```powershell
# Create storage account
$storageAccount = "storhinocompute$(Get-Random -Maximum 9999)"
az storage account create `
    --name $storageAccount `
    --resource-group $resourceGroup `
    --location $location `
    --sku Standard_LRS

# Get key
$storageKey = az storage account keys list `
    --resource-group $resourceGroup `
    --account-name $storageAccount `
    --query "[0].value" -o tsv

# Create container
az storage container create `
    --name deployment `
    --account-name $storageAccount `
    --account-key $storageKey

# Upload binaries
$zipPath = "$env:TEMP\rhino.compute.zip"
Compress-Archive -Path "..\src\dist\rhino.compute\*" -DestinationPath $zipPath
az storage blob upload `
    --account-name $storageAccount `
    --account-key $storageKey `
    --container-name deployment `
    --name "rhino.compute.zip" `
    --file $zipPath

# Upload install script
az storage blob upload `
    --account-name $storageAccount `
    --account-key $storageKey `
    --container-name deployment `
    --name "Install-ComputeServer.ps1" `
    --file "Install-ComputeServer.ps1"

# Run on all VMs
$installScript = @"
`$storageUrl = "https://$storageAccount.blob.core.windows.net/deployment"
Invoke-WebRequest -Uri "`$storageUrl/rhino.compute.zip" -OutFile "C:\rhino.compute.zip"
Invoke-WebRequest -Uri "`$storageUrl/Install-ComputeServer.ps1" -OutFile "C:\Install-ComputeServer.ps1"
Expand-Archive -Path "C:\rhino.compute.zip" -DestinationPath "C:\RhinoComputeBinaries" -Force
& "C:\Install-ComputeServer.ps1" -ComputeBinariesPath "C:\RhinoComputeBinaries" -Port 5000 -ChildCount 4
"@

for ($i=1; $i -le 3; $i++) {
    $vmName = "vm-compute-0$i"
    az vm run-command invoke `
        --resource-group $resourceGroup `
        --name $vmName `
        --command-id RunPowerShellScript `
        --scripts $installScript
}
```

---

## Step 4: Create Azure Load Balancer

### Using Azure CLI:

```powershell
$resourceGroup = "rg-rhinocompute-prod"
$lbName = "lb-rhinocompute"

# Create public IP
az network public-ip create `
    --resource-group $resourceGroup `
    --name pip-rhinocompute-lb `
    --sku Standard `
    --allocation-method Static

# Get public IP address
$publicIp = az network public-ip show `
    --resource-group $resourceGroup `
    --name pip-rhinocompute-lb `
    --query "ipAddress" -o tsv

Write-Host "Public IP: $publicIp" -ForegroundColor Green

# Create load balancer
az network lb create `
    --resource-group $resourceGroup `
    --name $lbName `
    --sku Standard `
    --public-ip-address pip-rhinocompute-lb `
    --frontend-ip-name frontendPool `
    --backend-pool-name backendPool

# Create health probe
az network lb probe create `
    --resource-group $resourceGroup `
    --lb-name $lbName `
    --name healthProbe `
    --protocol Http `
    --port 5000 `
    --path "/healthcheck/ready" `
    --interval 15 `
    --threshold 2

# Create load balancing rule (port 80 -> 5000)
az network lb rule create `
    --resource-group $resourceGroup `
    --lb-name $lbName `
    --name computeRule `
    --protocol Tcp `
    --frontend-port 80 `
    --backend-port 5000 `
    --frontend-ip-name frontendPool `
    --backend-pool-name backendPool `
    --probe-name healthProbe `
    --idle-timeout 4

# Add VMs to backend pool
for ($i=1; $i -le 3; $i++) {
    $vmName = "vm-compute-0$i"

    # Get NIC ID
    $nicId = az vm show `
        --resource-group $resourceGroup `
        --name $vmName `
        --query "networkProfile.networkInterfaces[0].id" -o tsv

    # Update NIC to include load balancer backend pool
    az network nic ip-config update `
        --resource-group $resourceGroup `
        --nic-name $(Split-Path $nicId -Leaf) `
        --name ipconfig1 `
        --lb-name $lbName `
        --lb-address-pools backendPool

    Write-Host "Added $vmName to load balancer"
}

Write-Host ""
Write-Host "Load Balancer configured!" -ForegroundColor Green
Write-Host "Public endpoint: http://$publicIp" -ForegroundColor Cyan
```

---

## Step 5: Configure Network Security

### Allow Compute Port (5000) from Load Balancer

```powershell
# Get NSG name (auto-created with VMs)
$nsgName = az network nsg list `
    --resource-group $resourceGroup `
    --query "[0].name" -o tsv

# Add rule to allow port 5000 from load balancer
az network nsg rule create `
    --resource-group $resourceGroup `
    --nsg-name $nsgName `
    --name AllowCompute `
    --priority 100 `
    --direction Inbound `
    --access Allow `
    --protocol Tcp `
    --source-address-prefixes VirtualNetwork `
    --destination-port-ranges 5000

Write-Host "Firewall configured"
```

---

## Step 6: Test Your Deployment

```powershell
# Test load balancer health
$publicIp = az network public-ip show `
    --resource-group $resourceGroup `
    --name pip-rhinocompute-lb `
    --query "ipAddress" -o tsv

Invoke-WebRequest "http://${publicIp}/healthcheck/ready"
```

If successful, you should see:
```
StatusCode        : 200
StatusDescription : OK
```

---

## Updating Your VMs

Use the existing update script:

```powershell
cd c:\Users\felix\coding\compute.rhino3d\deployment

# Get VM IPs
$servers = @()
for ($i=1; $i -le 3; $i++) {
    $ip = az vm show -d -g $resourceGroup -n "vm-compute-0$i" --query "privateIps" -o tsv
    $servers += $ip
}

# Update with zero downtime
.\Update-ComputeCluster.ps1 `
    -ServerList $servers `
    -Credential $credential `
    -Port 5000
```

---

## Monitoring

Use the monitoring script:

```powershell
.\Monitor-ComputeCluster.ps1 `
    -ServerList $servers `
    -Port 5000 `
    -CheckIntervalSeconds 60
```

Or use Azure Monitor in the portal.

---

## VM Size Recommendations

| VM Size | vCPUs | RAM | Price/Month* | Use Case |
|---------|-------|-----|-------------|----------|
| **Standard_B2ms** | 2 | 8 GB | ~$62 | Development/Testing |
| **Standard_D2s_v3** | 2 | 8 GB | ~$96 | Light production |
| **Standard_D4s_v3** | 4 | 16 GB | ~$192 | **Recommended** |
| **Standard_D8s_v3** | 8 | 32 GB | ~$384 | Heavy workloads |
| **Standard_F4s_v2** | 4 | 8 GB | ~$169 | CPU-intensive |

*Prices are approximate for East US region, pay-as-you-go

---

## Cost Optimization

### 1. Use Reserved Instances (Save 40-72%)

```powershell
# Purchase 1-year reservation
az reservations reservation-order purchase `
    --reservation-order-id ORDER_ID `
    --sku Standard_D4s_v3 `
    --location eastus `
    --quantity 3 `
    --term P1Y
```

### 2. Auto-shutdown for Dev/Test

```powershell
# Set auto-shutdown at 7 PM
az vm auto-shutdown `
    --resource-group $resourceGroup `
    --name vm-compute-01 `
    --time 1900
```

### 3. Deallocate VMs when not in use

```powershell
# Stop and deallocate (no compute charges)
az vm deallocate -g $resourceGroup -n vm-compute-01

# Start when needed
az vm start -g $resourceGroup -n vm-compute-01
```

---

## Complete Setup Script

Save this as `Setup-AzureManualVMs.ps1`:

```powershell
#Requires -Version 5.1

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory=$false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory=$false)]
    [int]$VMCount = 3,

    [Parameter(Mandatory=$false)]
    [string]$VMSize = "Standard_D4s_v3",

    [Parameter(Mandatory=$false)]
    [string]$Username = "azureuser",

    [Parameter(Mandatory=$false)]
    [SecureString]$Password
)

# Prompt for password if not provided
if (-not $Password) {
    $Password = Read-Host "Enter VM admin password" -AsSecureString
}

$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))

Write-Host "=== Azure Manual VM Setup ===" -ForegroundColor Cyan

# 1. Create Resource Group
Write-Host "`n[1/5] Creating Resource Group..." -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location --output none

# 2. Create VNet
Write-Host "[2/5] Creating Virtual Network..." -ForegroundColor Yellow
az network vnet create `
    --resource-group $ResourceGroup `
    --name vnet-rhinocompute `
    --address-prefix 10.0.0.0/16 `
    --subnet-name subnet-compute `
    --subnet-prefix 10.0.1.0/24 `
    --output none

# 3. Create VMs
Write-Host "[3/5] Creating VMs..." -ForegroundColor Yellow
for ($i=1; $i -le $VMCount; $i++) {
    $vmName = "vm-compute-$('{0:D2}' -f $i)"
    Write-Host "  Creating $vmName..." -ForegroundColor Gray

    az vm create `
        --resource-group $ResourceGroup `
        --name $vmName `
        --image Win2022Datacenter `
        --size $VMSize `
        --admin-username $Username `
        --admin-password $plainPassword `
        --vnet-name vnet-rhinocompute `
        --subnet subnet-compute `
        --public-ip-address "" `
        --nsg-rule NONE `
        --output none
}

# 4. Create Load Balancer
Write-Host "[4/5] Creating Load Balancer..." -ForegroundColor Yellow
az network public-ip create `
    --resource-group $ResourceGroup `
    --name pip-rhinocompute-lb `
    --sku Standard `
    --output none

az network lb create `
    --resource-group $ResourceGroup `
    --name lb-rhinocompute `
    --sku Standard `
    --public-ip-address pip-rhinocompute-lb `
    --frontend-ip-name frontendPool `
    --backend-pool-name backendPool `
    --output none

az network lb probe create `
    --resource-group $ResourceGroup `
    --lb-name lb-rhinocompute `
    --name healthProbe `
    --protocol Http `
    --port 5000 `
    --path "/healthcheck/ready" `
    --output none

az network lb rule create `
    --resource-group $ResourceGroup `
    --lb-name lb-rhinocompute `
    --name computeRule `
    --protocol Tcp `
    --frontend-port 80 `
    --backend-port 5000 `
    --frontend-ip-name frontendPool `
    --backend-pool-name backendPool `
    --probe-name healthProbe `
    --output none

# 5. Add VMs to Load Balancer
Write-Host "[5/5] Configuring Load Balancer..." -ForegroundColor Yellow
for ($i=1; $i -le $VMCount; $i++) {
    $vmName = "vm-compute-$('{0:D2}' -f $i)"
    $nicId = az vm show --resource-group $ResourceGroup --name $vmName `
        --query "networkProfile.networkInterfaces[0].id" -o tsv
    $nicName = Split-Path $nicId -Leaf

    az network nic ip-config update `
        --resource-group $ResourceGroup `
        --nic-name $nicName `
        --name ipconfig1 `
        --lb-name lb-rhinocompute `
        --lb-address-pools backendPool `
        --output none
}

# Get public IP
$publicIp = az network public-ip show `
    --resource-group $ResourceGroup `
    --name pip-rhinocompute-lb `
    --query "ipAddress" -o tsv

Write-Host "`n=== Setup Complete ===" -ForegroundColor Green
Write-Host "Public IP: $publicIp" -ForegroundColor Cyan
Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Install Rhino Compute on VMs using Install-ComputeServer.ps1"
Write-Host "2. Test: http://$publicIp/healthcheck/ready"
```

---

## Summary: Manual VMs vs. VM Scale Set

| Feature | Manual VMs | VM Scale Set |
|---------|-----------|--------------|
| Control | ✅ Full control | Limited |
| Auto-scaling | ❌ No | ✅ Yes |
| Setup complexity | Medium | Low (automated) |
| Cost | Lower | Slightly higher |
| Updates | Manual scripts | Azure-managed |
| Best for | Fixed workloads | Variable workloads |

**Use Manual VMs when you want more control and don't need auto-scaling!**
