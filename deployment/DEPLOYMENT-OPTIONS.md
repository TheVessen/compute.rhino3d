# Rhino Compute Deployment Options Comparison

Quick guide to help you choose the right deployment method for your needs.

## Quick Decision Matrix

| If you need... | Use this |
|----------------|----------|
| **Quick test/development** | Single server + [Install-ComputeServer.ps1](Install-ComputeServer.ps1) |
| **Small team, fixed infrastructure** | 2-3 servers + NGINX ([README.md](README.md)) |
| **Auto-scaling in the cloud** | Azure VMSS ([azure/README.md](azure/README.md)) |
| **Hybrid (cloud + on-premise)** | Both Azure + Private servers with same scripts |
| **Maximum control, minimum cost** | Private servers + NGINX |
| **Minimum management overhead** | Azure VMSS |

## Detailed Comparison

### Option 1: Single Server (Development/Testing)

**Best for:** Development, testing, small projects

**Setup:**
```powershell
.\Install-ComputeServer.ps1 -RhinoInstallerPath "C:\rhino_installer.exe"
```

**Pros:**
- ✅ Simplest setup (5-10 minutes)
- ✅ No infrastructure complexity
- ✅ Lowest cost
- ✅ Easy to debug

**Cons:**
- ❌ No redundancy (single point of failure)
- ❌ No load balancing
- ❌ Limited capacity
- ❌ Downtime during updates

**Cost:**
- Single Windows Server: ~$50-150/month (or free if on-premise)

---

### Option 2: Private Servers + NGINX Load Balancer

**Best for:** Established teams, on-premise infrastructure, predictable workloads

**Setup:**
```powershell
# On each compute server
.\Install-ComputeServer.ps1

# On load balancer server
.\nginx\Install-NginxLoadBalancer.ps1 -BackendServers @("server1:5000","server2:5000")
```

**Pros:**
- ✅ Full control over infrastructure
- ✅ No cloud vendor lock-in
- ✅ Predictable costs
- ✅ Use existing hardware
- ✅ High availability
- ✅ Zero-downtime updates

**Cons:**
- ❌ Manual scaling (can't auto-scale)
- ❌ You manage hardware/OS updates
- ❌ Need network infrastructure
- ❌ More initial setup time

**Cost:**
- 3 Windows Servers: Variable (on-premise) or ~$150-450/month (cloud VMs)
- NGINX: Free (open source)
- Total: Depends on hardware

**Time Investment:**
- Initial setup: 30-60 minutes
- Updates: 15-30 minutes (automated via [Update-ComputeCluster.ps1](Update-ComputeCluster.ps1))

---

### Option 3: Azure VM Scale Set (VMSS)

**Best for:** Cloud-native deployments, variable workloads, auto-scaling needs

**Setup:**
```powershell
.\azure\Deploy-AzureVMScaleSet.ps1 -ResourceGroupName "rg-compute" -Location "eastus"
```

**Pros:**
- ✅ Fully automated deployment (15-20 min)
- ✅ Auto-scaling (2-10+ instances)
- ✅ Managed load balancer
- ✅ Managed health checks
- ✅ Zero-downtime updates
- ✅ Built-in monitoring
- ✅ Pay only for what you use
- ✅ Global deployment (multiple regions)

**Cons:**
- ❌ Cloud costs (ongoing)
- ❌ Requires Azure subscription
- ❌ Vendor lock-in
- ❌ Complexity for simple needs

**Cost (East US, as of 2026):**
- 3x Standard_D4s_v3 VMs: ~$417/month
- Load Balancer: ~$45/month
- Storage/Networking: ~$10/month
- **Total: ~$470/month** (scales with usage)

**Time Investment:**
- Initial setup: 15-20 minutes (mostly automated)
- Updates: 10-20 minutes (fully automated via [Update-AzureVMSS.ps1](azure/Update-AzureVMSS.ps1))

---

### Option 4: Hybrid (Azure + Private Servers)

**Best for:** Gradual cloud migration, geo-distribution, disaster recovery

**Setup:**
```powershell
# Deploy Azure VMSS
.\azure\Deploy-AzureVMScaleSet.ps1 -ResourceGroupName "rg-compute" -Location "eastus"

# Setup private servers
.\Install-ComputeServer.ps1

# Configure DNS or global load balancer to route between both
```

**Pros:**
- ✅ Best of both worlds
- ✅ Disaster recovery (failover)
- ✅ Geo-distribution
- ✅ Gradual cloud migration
- ✅ Burst to cloud when needed

**Cons:**
- ❌ Most complex setup
- ❌ Need global load balancer (Azure Traffic Manager, Cloudflare, etc.)
- ❌ Higher costs
- ❌ More management overhead

**Cost:**
- Azure VMSS: ~$470/month
- Private servers: Variable
- Global LB: ~$50-100/month
- **Total: $500-1000+/month**

---

## Feature Comparison Matrix

| Feature | Single Server | Private + NGINX | Azure VMSS | Hybrid |
|---------|--------------|-----------------|------------|--------|
| **Setup Time** | 5-10 min | 30-60 min | 15-20 min | 1-2 hours |
| **High Availability** | ❌ | ✅ | ✅ | ✅ |
| **Load Balancing** | ❌ | ✅ (NGINX) | ✅ (Azure LB) | ✅ |
| **Auto-scaling** | ❌ | ❌ | ✅ | Partial |
| **Zero-downtime Updates** | ❌ | ✅ | ✅ | ✅ |
| **Crash Recovery** | ✅ | ✅ | ✅ | ✅ |
| **Log Rotation** | ✅ | ✅ | ✅ | ✅ |
| **Monitoring** | Manual | [Monitor-ComputeCluster.ps1](Monitor-ComputeCluster.ps1) | Azure Monitor | Both |
| **Rollback** | Manual | [Rollback-ComputeServer.ps1](Rollback-ComputeServer.ps1) | Azure Reimage | Both |
| **Cost (3 servers)** | ~$50-150 | ~$150-450 | ~$470 | $500-1000+ |
| **Vendor Lock-in** | None | None | Azure | Partial |
| **Management Overhead** | Low | Medium | Low | High |

---

## Choosing Based on Team Size

### Solo Developer / Startup (1-5 users)
→ **Single Server** or **2 Private Servers + NGINX**
- Lowest cost
- Simplest management
- Can upgrade later

### Small Team (5-20 users)
→ **Private Servers + NGINX** or **Azure VMSS (small)**
- Need reliability
- Growing workloads
- Budget conscious

### Medium Team (20-100 users)
→ **Azure VMSS** or **Private Cluster**
- Need auto-scaling
- Variable workloads
- Professional monitoring

### Enterprise (100+ users)
→ **Azure VMSS (multi-region)** or **Hybrid**
- Global users
- High availability critical
- Disaster recovery needed

---

## Choosing Based on Workload Type

### **Predictable, steady workload** (e.g., internal team tools)
→ **Private Servers + NGINX**
- Fixed capacity works fine
- Lower cost than cloud
- No need for auto-scaling

### **Variable, spiky workload** (e.g., customer-facing API)
→ **Azure VMSS**
- Auto-scale up during peaks
- Scale down to save costs
- Pay for what you use

### **Development/Testing**
→ **Single Server**
- Minimal cost
- Easy to rebuild
- Quick iterations

### **Production with strict uptime requirements**
→ **Azure VMSS** or **Hybrid**
- Built-in redundancy
- Auto-healing
- Global distribution

---

## Migration Paths

### Start Simple → Grow

```
1. Single Server (development)
   ↓
2. Private Servers + NGINX (production)
   ↓
3. Azure VMSS (when scaling needs emerge)
   ↓
4. Hybrid (for global presence)
```

All deployment scripts are compatible, so you can:
- Start with private servers
- Add Azure later
- Use same update scripts for both
- Migrate gradually

---

## Example Scenarios

### Scenario 1: Architecture Firm
**Need:** 10 architects using Grasshopper for building designs
**Recommendation:** **Private Servers + NGINX**
- 2-3 servers on-premise
- Controlled costs
- Data stays in-house
- Sufficient capacity

### Scenario 2: SaaS Product
**Need:** Public API for external developers, unpredictable usage
**Recommendation:** **Azure VMSS**
- Auto-scale based on demand
- Global deployment
- Pay for actual usage
- Professional monitoring

### Scenario 3: Research Institution
**Need:** Batch processing of parametric models
**Recommendation:** **Azure VMSS with scheduled scaling**
- Scale up during research hours
- Scale down at night
- Cost optimization
- Burst capacity when needed

### Scenario 4: International Consultancy
**Need:** Teams in US, Europe, Asia
**Recommendation:** **Hybrid or Multi-region Azure**
- Azure VMSS in multiple regions (eastus, westeurope, southeastasia)
- Low latency worldwide
- Regional data compliance
- High availability

---

## Cost Optimization Tips

### For Private Servers:
1. Use existing hardware
2. Run multiple child processes per server
3. Schedule maintenance windows
4. Monitor CPU usage to right-size

### For Azure:
1. **Reserved Instances** - Save up to 72%
2. **Spot VMs** - Save up to 90% (for non-critical)
3. **Auto-shutdown** dev/test environments
4. **Right-size VMs** based on actual usage
5. **Enable auto-scale** to reduce idle capacity

---

## Summary Recommendations

| Scenario | Deployment Choice | Est. Cost/Month |
|----------|------------------|-----------------|
| Personal projects | Single Server | $0-50 |
| Small team, on-premise | 2-3 Servers + NGINX | $0-100 |
| Small team, cloud | Azure VMSS (2-3 instances) | $300-400 |
| Growing team | Private Servers + NGINX | $100-300 |
| SaaS/Public API | Azure VMSS (auto-scale) | $500-1500 |
| Enterprise | Azure VMSS (multi-region) | $1500-5000+ |

---

## Still Not Sure?

**Start here:**

1. **For testing/proof-of-concept:**
   ```powershell
   .\Install-ComputeServer.ps1
   ```

2. **For production (small scale):**
   ```powershell
   # Setup 2-3 servers
   .\Install-ComputeServer.ps1
   .\nginx\Install-NginxLoadBalancer.ps1
   ```

3. **For production (cloud/scalable):**
   ```powershell
   .\azure\Deploy-AzureVMScaleSet.ps1 -ResourceGroupName "rg-test" -Location "eastus"
   ```

You can always migrate later! The scripts are designed to work together.

---

## Getting Help

- Private deployment: See [README.md](README.md)
- Azure deployment: See [azure/README.md](azure/README.md)
- Rhino Compute docs: https://developer.rhino3d.com/guides/compute/
