# Azure Deployment Guide for Rhino Compute

Complete guide for deploying Rhino Compute on Microsoft Azure with auto-scaling and zero-downtime updates.

## Overview

This guide covers deploying Rhino Compute using:
- **Azure VM Scale Sets (VMSS)** - Auto-scaling Windows VMs
- **Azure Load Balancer** - Distributes traffic with health probes
- **Azure Storage** - Stores deployment scripts and binaries
- **Auto-scale Rules** - Scales based on CPU usage

## Architecture

```
Internet
    ↓
[Azure Load Balancer]
    ↓ (Public IP)
┌───────┼───────┐
↓       ↓       ↓
[VM 1] [VM 2] [VM 3] ... [VM N]
   ↓       ↓       ↓
Windows Windows Windows
Service Service Service
   ↓       ↓       ↓
 Rhino   Rhino   Rhino
Compute Compute Compute

Auto-scale: 2-10 instances
Based on CPU usage
```

## Prerequisites

### On Your Local Machine:

1. **Azure CLI** installed
   ```powershell
   # Install
   winget install Microsoft.AzureCLI

   # Or download from https://aka.ms/installazurecli
   ```

2. **Azure Subscription**
   - Active Azure subscription
   - Contributor or Owner role

3. **Rhino Compute Binaries**
   - Built from source:
   ```powershell
   cd c:\Users\felix\coding\compute.rhino3d\src
   dotnet publish rhino.compute\rhino.compute.csproj -c Release
   ```

### Optional:
- Rhino 8 installer URL (publicly accessible or uploaded to Azure Storage)
- API key for securing your compute endpoints

## Quick Start - Full Deployment

### 1. Login to Azure

```powershell
az login
```

Select your subscription:
```powershell
az account set --subscription "Your Subscription Name"
```

### 2. Deploy Complete Infrastructure

```powershell
cd deployment\azure

.\Deploy-AzureVMScaleSet.ps1 `
    -ResourceGroupName "rg-rhinocompute-prod" `
    -Location "eastus"
```

This single command creates:
- Resource Group
- VM Scale Set (3 instances)
- Azure Load Balancer with health probes
- Public IP address
- Network Security Group
- Storage Account for binaries
- Auto-scale rules (2-10 instances)
- Installs Rhino Compute on all VMs

**Deployment time:** ~15-20 minutes

### 3. Wait for VMs to Install

The VMs will automatically:
1. Download compute binaries
2. Install .NET 8 Runtime
3. Configure Windows Service
4. Start Rhino Compute

**Installation time per VM:** ~5-10 minutes

### 4. Test Your Deployment

Get the public IP:
```powershell
az network public-ip show `
    --resource-group "rg-rhinocompute-prod" `
    --name "pip-rhinocompute-lb" `
    --query "ipAddress" -o tsv
```

Test health endpoint:
```powershell
$ip = "YOUR_PUBLIC_IP"
Invoke-WebRequest "http://$ip/healthcheck/ready"
```

## Custom Deployment Options

### Different VM Size

For more powerful VMs:
```powershell
.\Deploy-AzureVMScaleSet.ps1 `
    -ResourceGroupName "rg-compute" `
    -Location "westeurope" `
    -VMSize "Standard_D8s_v3"  # 8 vCPUs, 32 GB RAM
```

**Recommended VM sizes:**
| Size | vCPUs | RAM | Use Case |
|------|-------|-----|----------|
| Standard_D4s_v3 | 4 | 16 GB | Light workloads |
| Standard_D8s_v3 | 8 | 32 GB | Medium workloads |
| Standard_D16s_v3 | 16 | 64 GB | Heavy workloads |
| Standard_F8s_v2 | 8 | 16 GB | CPU-intensive |

### Custom Auto-scaling

More aggressive scaling:
```powershell
.\Deploy-AzureVMScaleSet.ps1 `
    -ResourceGroupName "rg-compute" `
    -Location "eastus" `
    -InstanceCount 5 `
    -MinInstances 3 `
    -MaxInstances 20
```

### With API Key Security

```powershell
.\Deploy-AzureVMScaleSet.ps1 `
    -ResourceGroupName "rg-compute" `
    -Location "eastus" `
    -ApiKey "your-secret-api-key-here"
```

### Different Azure Region

Choose region closest to your users:
```powershell
# List available regions
az account list-locations -o table

# Deploy to specific region
.\Deploy-AzureVMScaleSet.ps1 `
    -ResourceGroupName "rg-compute" `
    -Location "australiaeast"
```

**Popular regions:**
- `eastus` - East US
- `westeurope` - West Europe
- `southeastasia` - Southeast Asia
- `australiaeast` - Australia East
- `uksouth` - UK South

## Updating Your Deployment

When you make code changes and want to deploy updates:

### 1. Build New Version

```powershell
cd c:\Users\felix\coding\compute.rhino3d\src
dotnet publish rhino.compute\rhino.compute.csproj -c Release
```

### 2. Deploy Update with Zero Downtime

```powershell
cd ..\deployment\azure

.\Update-AzureVMSS.ps1 -ResourceGroupName "rg-rhinocompute-prod"
```

This will:
- Upload new binaries to Azure Storage
- Update VMs in batches (20% at a time)
- Wait 30 seconds between batches
- Health check each VM before proceeding
- **Zero downtime** - Load balancer keeps routing to healthy VMs

**Update time:** ~10-20 minutes (depending on number of instances)

### 3. Monitor Update Progress

The script shows real-time progress:
```
[14:32:10] Updated: 2/5 | Updating: 1
[14:32:20] Updated: 3/5 | Updating: 1
[14:32:30] Updated: 5/5 | Updating: 0
✓✓✓ All instances updated successfully! ✓✓✓
```

## Management Operations

### View All VMs

```powershell
az vmss list-instances `
    -g "rg-rhinocompute-prod" `
    -n "vmss-rhinocompute" `
    -o table
```

### Manual Scaling

Scale to specific number of instances:
```powershell
az vmss scale `
    -g "rg-rhinocompute-prod" `
    -n "vmss-rhinocompute" `
    --new-capacity 10
```

### Check Auto-scale Status

```powershell
az monitor autoscale show `
    -g "rg-rhinocompute-prod" `
    -n "autoscale-compute"
```

### View Auto-scale History

```powershell
az monitor autoscale show `
    -g "rg-rhinocompute-prod" `
    -n "autoscale-compute" `
    --query "autoscaleSettingResourceName"
```

### Modify Auto-scale Rules

Change CPU thresholds:
```powershell
# Scale out when CPU > 80% (instead of 75%)
az monitor autoscale rule update `
    -g "rg-rhinocompute-prod" `
    --autoscale-name "autoscale-compute" `
    --condition "Percentage CPU > 80 avg 5m" `
    --scale out 2
```

### Connect to a VM (for troubleshooting)

```powershell
# Get VM instance ID
az vmss list-instances -g "rg-rhinocompute-prod" -n "vmss-rhinocompute" -o table

# RDP to specific instance
az vmss list-instance-connection-info `
    -g "rg-rhinocompute-prod" `
    -n "vmss-rhinocompute"

# Or use Azure Portal and click "Connect" on the VM
```

### View VM Logs

```powershell
# Get instance ID
$instanceId = "0"

# Run command on VM
az vmss run-command invoke `
    -g "rg-rhinocompute-prod" `
    -n "vmss-rhinocompute" `
    --instance-id $instanceId `
    --command-id RunPowerShellScript `
    --scripts "Get-Content C:\RhinoCompute\logs\service-stdout.log -Tail 50"
```

### Check Load Balancer Health Probes

```powershell
az network lb show `
    -g "rg-rhinocompute-prod" `
    -n "lb-rhinocompute" `
    --query "probes"
```

## Cost Estimation

Based on Azure East US pricing (as of 2026):

### VM Costs (per month)
| VM Size | Hourly | Monthly (730 hrs) | 3 VMs/month |
|---------|--------|-------------------|-------------|
| Standard_D4s_v3 | ~$0.19 | ~$139 | ~$417 |
| Standard_D8s_v3 | ~$0.38 | ~$277 | ~$831 |
| Standard_D16s_v3 | ~$0.77 | ~$562 | ~$1,686 |

### Other Costs
- **Load Balancer:** ~$18/month (Basic) or ~$45/month (Standard)
- **Public IP:** ~$3.60/month
- **Storage Account:** ~$1-5/month (minimal usage)
- **Bandwidth:** ~$0.087/GB outbound

**Example total cost for 3x Standard_D4s_v3 VMs:**
- 3 VMs: $417
- Load Balancer: $45
- Public IP: $4
- Storage: $2
- **Total: ~$468/month**

### Cost Optimization Tips

1. **Use Azure Reserved Instances** - Save up to 72%
   ```powershell
   # 1-year or 3-year commitments
   ```

2. **Use Auto-shutdown** for dev/test environments
   ```powershell
   # Schedule VMs to shut down at night
   ```

3. **Right-size VMs** - Monitor CPU usage and adjust

4. **Use Spot VMs** for non-critical workloads (up to 90% savings)

## Monitoring

### Azure Portal

1. Go to https://portal.azure.com
2. Navigate to your Resource Group
3. Click on the VM Scale Set
4. View:
   - Instance count
   - CPU metrics
   - Health status
   - Scaling events

### Using Azure Monitor

```powershell
# CPU usage across all VMs
az monitor metrics list `
    --resource "/subscriptions/YOUR_SUB/resourceGroups/rg-rhinocompute-prod/providers/Microsoft.Compute/virtualMachineScaleSets/vmss-rhinocompute" `
    --metric "Percentage CPU" `
    --start-time "2026-01-10T00:00:00Z"
```

### Set Up Alerts

```powershell
# Alert when any VM CPU > 90%
az monitor metrics alert create `
    -n "HighCPUAlert" `
    -g "rg-rhinocompute-prod" `
    --scopes "/subscriptions/YOUR_SUB/resourceGroups/rg-rhinocompute-prod/providers/Microsoft.Compute/virtualMachineScaleSets/vmss-rhinocompute" `
    --condition "avg Percentage CPU > 90" `
    --description "Alert when CPU exceeds 90%" `
    --evaluation-frequency 1m `
    --window-size 5m
```

### Application Insights (optional)

For advanced monitoring, integrate Application Insights:
```powershell
# Create Application Insights
az monitor app-insights component create `
    --app "rhinocompute-insights" `
    -g "rg-rhinocompute-prod" `
    --location "eastus"

# Add instrumentation key to VMs as environment variable
```

## Security Best Practices

### 1. Change Default Admin Password

```powershell
# In Azure Portal, go to VM Scale Set > Instances > Select VM > Reset password
```

### 2. Use API Key Authentication

Always deploy with an API key:
```powershell
.\Deploy-AzureVMScaleSet.ps1 `
    -ResourceGroupName "rg-compute" `
    -Location "eastus" `
    -ApiKey "$(New-Guid)"  # Generate random key
```

### 3. Restrict Network Access

Update NSG to allow only specific IPs:
```powershell
az network nsg rule update `
    -g "rg-rhinocompute-prod" `
    --nsg-name "nsg-rhinocompute" `
    -n "AllowCompute" `
    --source-address-prefixes "YOUR_OFFICE_IP/32"
```

### 4. Enable Azure Firewall (optional)

For enterprise deployments, use Azure Firewall or Application Gateway with WAF.

### 5. Use Managed Identities

For accessing Azure resources (Storage, Key Vault) without credentials:
```powershell
az vmss identity assign `
    -g "rg-rhinocompute-prod" `
    -n "vmss-rhinocompute"
```

## Troubleshooting

### VMs not healthy in Load Balancer

Check health probe:
```powershell
# From a VM, test locally
Invoke-WebRequest "http://localhost:5000/healthcheck/ready"

# Check NSG allows port 5000
az network nsg rule show `
    -g "rg-rhinocompute-prod" `
    --nsg-name "nsg-rhinocompute" `
    -n "AllowCompute"
```

### Installation failed on VMs

View custom script extension output:
```powershell
az vmss extension show `
    -g "rg-rhinocompute-prod" `
    --vmss-name "vmss-rhinocompute" `
    -n "CustomScriptExtension"
```

Or RDP to a VM and check:
```
C:\RhinoCompute\logs\service-stderr.log
```

### High costs

Check VM sizes and scaling:
```powershell
# View current instances
az vmss list-instances -g "rg-rhinocompute-prod" -n "vmss-rhinocompute" -o table

# Reduce max instances
az monitor autoscale update `
    -g "rg-rhinocompute-prod" `
    -n "autoscale-compute" `
    --max-count 5
```

### Update failed

Rollback to previous version:
```powershell
# Reimage VMs (restores to last known good image)
az vmss reimage `
    -g "rg-rhinocompute-prod" `
    -n "vmss-rhinocompute"
```

## Cleanup / Deletion

### Delete entire deployment

```powershell
az group delete -n "rg-rhinocompute-prod" --yes --no-wait
```

This removes:
- All VMs
- Load Balancer
- Storage Account
- Network resources
- Everything in the resource group

**Cost stops immediately** (prorated to the hour)

## Next Steps

After deployment:

1. **Test with real workloads** - Send Grasshopper definition requests
2. **Monitor performance** - Watch CPU, memory, response times
3. **Tune auto-scaling** - Adjust thresholds based on actual usage
4. **Set up monitoring** - Configure Azure Monitor alerts
5. **Document your URLs** - Share the public IP with your team
6. **Schedule backups** - Export VMSS configuration periodically

## Alternative: Azure Container Instances

If you prefer Docker containers instead of VMs, you can also deploy using:
- Azure Container Instances (ACI)
- Azure Container Apps
- Azure Kubernetes Service (AKS)

Let me know if you want scripts for container-based deployment!

## Support

For Azure-specific issues:
- Azure documentation: https://docs.microsoft.com/azure
- Azure support: https://azure.microsoft.com/support

For Rhino Compute issues:
- See main [deployment/README.md](../README.md)
- https://developer.rhino3d.com/guides/compute/

## Cost Calculator

Estimate your costs: https://azure.microsoft.com/pricing/calculator/

Select:
- Virtual Machine Scale Sets
- Load Balancer (Standard)
- Storage Accounts
- Bandwidth
