# Rhino Compute Deployment Toolkit

Automated deployment scripts for Rhino Compute that work on both Azure and private infrastructure, with no IIS requirement.

## Overview

This toolkit provides a complete solution for deploying and managing Rhino Compute clusters:

- **No IIS required** - Runs as Windows Service using Kestrel
- **Cloud-agnostic** - Works on Azure VMs, AWS EC2, or private servers
- **Zero-downtime updates** - Rolling updates across your cluster
- **Automatic crash recovery** - Service auto-restarts on failure
- **Load balancing** - NGINX-based load balancer with health checks
- **Comprehensive logging** - Application and service logs with rotation
- **Easy rollback** - Restore previous versions if updates fail

## Architecture

```
        Internet
            ↓
    [NGINX Load Balancer]
            ↓
    ┌───────┼───────┐
    ↓       ↓       ↓
[Compute] [Compute] [Compute]
 Server1   Server2   Server3
    ↓       ↓       ↓
Windows   Windows   Windows
Service   Service   Service
```

## Prerequisites

### On All Servers:
- Windows Server 2019 or later
- PowerShell 5.1 or later
- Administrator access
- Network connectivity between servers

### On Load Balancer Server (can be separate or one of the compute servers):
- Same as above

### For Remote Management:
- PowerShell remoting enabled on all servers
- Credentials with admin rights

## Quick Start

### 1. Build the Project

First, build the Rhino Compute binaries:

```powershell
cd c:\Users\felix\coding\compute.rhino3d\src
dotnet publish rhino.compute\rhino.compute.csproj -c Release
```

Binaries will be in: `src\dist\rhino.compute`

### 2. Setup Your First Compute Server

On the target server (or remotely):

```powershell
cd deployment
.\Install-ComputeServer.ps1 -RhinoInstallerPath "C:\Downloads\rhino_8_installer.exe"
```

This will:
- Install .NET 8 Runtime (if needed)
- Install Rhino 8 (if needed)
- Deploy compute binaries
- Create Windows Service with auto-restart
- Configure firewall
- Start the service

**Default settings:**
- Port: 5000
- Install path: `C:\RhinoCompute`
- Child processes: 4

**Custom installation:**
```powershell
.\Install-ComputeServer.ps1 `
    -Port 8080 `
    -ChildCount 8 `
    -ApiKey "my-secret-key" `
    -InstallPath "D:\Apps\RhinoCompute"
```

### 3. Setup Additional Compute Servers

Repeat step 2 on each server you want to add to your cluster.

### 4. Setup Load Balancer

On your load balancer server:

```powershell
cd deployment\nginx
.\Install-NginxLoadBalancer.ps1 -BackendServers @("192.168.1.10:5000","192.168.1.11:5000","192.168.1.12:5000")
```

**Custom port:**
```powershell
.\Install-NginxLoadBalancer.ps1 `
    -BackendServers @("server1:5000","server2:5000","server3:5000") `
    -ListenPort 80
```

### 5. Verify Installation

Test the load balancer:
```powershell
Invoke-WebRequest -Uri "http://your-load-balancer/healthcheck/ready"
```

Test individual servers:
```powershell
Invoke-WebRequest -Uri "http://server1:5000/healthcheck/ready"
Invoke-WebRequest -Uri "http://server2:5000/healthcheck/ready"
```

## Daily Operations

### Updating the Cluster

When you have new code to deploy:

1. **Build new binaries:**
   ```powershell
   cd c:\Users\felix\coding\compute.rhino3d\src
   dotnet publish rhino.compute\rhino.compute.csproj -c Release
   ```

2. **Update the cluster with zero downtime:**
   ```powershell
   cd deployment
   .\Update-ComputeCluster.ps1 -ServerList @("server1","server2","server3")
   ```

   Or use a server list file:
   ```powershell
   .\Update-ComputeCluster.ps1 -ServerList "servers.txt"
   ```

   The script will:
   - Update one server at a time
   - Take each server out of rotation
   - Backup current version
   - Deploy new version
   - Health check before proceeding
   - Wait 30 seconds between servers (configurable)

**Custom update:**
```powershell
.\Update-ComputeCluster.ps1 `
    -ServerList "servers.txt" `
    -WaitBetweenServers 60 `
    -ComputeBinariesPath "..\src\dist\rhino.compute"
```

### Rolling Back

If an update causes issues, rollback to a previous version:

1. **List available backups:**
   ```powershell
   .\Rollback-ComputeServer.ps1 -ServerList "server1"
   ```

2. **Rollback a single server:**
   ```powershell
   .\Rollback-ComputeServer.ps1 `
       -ServerList "server1" `
       -BackupName "backup_20260110-143022"
   ```

3. **Rollback entire cluster:**
   ```powershell
   .\Rollback-ComputeServer.ps1 `
       -ServerList @("server1","server2","server3") `
       -BackupName "backup_20260110-143022"
   ```

### Monitoring

Start continuous monitoring:

```powershell
.\Monitor-ComputeCluster.ps1 -ServerList @("server1","server2","server3")
```

**With email alerts:**
```powershell
.\Monitor-ComputeCluster.ps1 `
    -ServerList "servers.txt" `
    -EmailAlert `
    -SmtpServer "smtp.gmail.com" `
    -EmailFrom "alerts@company.com" `
    -EmailTo "admin@company.com" `
    -CheckIntervalSeconds 30
```

**Run as background task:**
```powershell
Start-Job -FilePath ".\Monitor-ComputeCluster.ps1" -ArgumentList @{ServerList=@("server1","server2","server3")}
```

### Service Management

On individual servers:

```powershell
# Check status
Get-Service RhinoCompute

# Start/Stop/Restart
Start-Service RhinoCompute
Stop-Service RhinoCompute
Restart-Service RhinoCompute

# View logs
Get-Content C:\RhinoCompute\logs\service-stdout.log -Tail 50
Get-Content C:\RhinoCompute\logs\service-stderr.log -Tail 50
```

### Load Balancer Management

```powershell
# Check NGINX status
Get-Service nginx

# Restart NGINX
Restart-Service nginx

# Reload configuration (without restart)
& "C:\nginx\nginx.exe" -s reload

# View NGINX logs
Get-Content C:\nginx\logs\access.log -Tail 50
Get-Content C:\nginx\logs\error.log -Tail 50

# Check backend server status
Invoke-WebRequest -Uri "http://localhost/nginx_status"
```

### Adding/Removing Servers from Load Balancer

Edit the NGINX configuration:

```powershell
notepad C:\nginx\conf\nginx.conf
```

Find the `upstream compute_backend` section and add/remove/comment servers:

```nginx
upstream compute_backend {
    least_conn;
    server 192.168.1.10:5000 max_fails=3 fail_timeout=30s;
    server 192.168.1.11:5000 max_fails=3 fail_timeout=30s;
    # server 192.168.1.12:5000 down;  # Temporarily disabled
    server 192.168.1.13:5000 max_fails=3 fail_timeout=30s;  # New server
}
```

Reload NGINX:
```powershell
& "C:\nginx\nginx.exe" -s reload
```

## Configuration

### Environment Variables (Compute Servers)

Set these before installing or via `[System.Environment]::SetEnvironmentVariable()`:

| Variable | Default | Description |
|----------|---------|-------------|
| `RHINO_COMPUTE_URLS` | `http://localhost:5000` | Listen URLs |
| `RHINO_COMPUTE_KEY` | (none) | API key for authentication |
| `RHINO_COMPUTE_TIMEOUT` | `100` | Request timeout in seconds |
| `RHINO_COMPUTE_MAX_REQUEST_SIZE` | `52428800` | Max request size in bytes (50MB) |
| `RHINO_COMPUTE_LOG_PATH` | `C:\RhinoCompute\logs` | Log directory |
| `RHINO_COMPUTE_LOG_RETAIN_DAYS` | `10` | Days to keep logs |
| `RHINO_COMPUTE_LOAD_GRASSHOPPER` | `true` | Load Grasshopper at startup |
| `RHINO_COMPUTE_CREATE_HEADLESS_DOC` | `false` | Create headless doc per request |
| `RHINO_COMPUTE_DEBUG` | `false` | Enable debug logging |

### Command Line Arguments

The Windows Service runs with these arguments (configurable in install script):

```
rhino.compute.exe --port 5000 --childcount 4 --spawn-on-startup
```

Available options:
- `--port <number>` - Port to listen on
- `--childcount <number>` - Number of child compute.geometry processes
- `--spawn-on-startup` - Launch children at startup
- `--idlespan <number>` - Idle timeout in minutes (default: 60)
- `--apikey <string>` - API key for authentication
- `--timeout <number>` - Request timeout in seconds
- `--max-request-size <number>` - Max body size in bytes

## Logging and Crash Recovery

### Automatic Features

The Windows Service is configured to:

1. **Auto-restart on crash:**
   - Waits 5 seconds before restarting
   - Throttles repeated failures (10 second minimum between restarts)

2. **Log rotation:**
   - Rotates daily OR when logs reach 10MB
   - Keeps logs according to `RHINO_COMPUTE_LOG_RETAIN_DAYS`

3. **Multiple log locations:**
   - Application logs: `C:\RhinoCompute\logs\`
   - Service stdout: `C:\RhinoCompute\logs\service-stdout.log`
   - Service stderr: `C:\RhinoCompute\logs\service-stderr.log`
   - NGINX logs: `C:\nginx\logs\access.log` and `error.log`

### Viewing Crash Information

Check Windows Event Viewer:
```powershell
Get-EventLog -LogName Application -Source "RhinoCompute" -Newest 10
```

Check service restart events:
```powershell
Get-EventLog -LogName System -Source "Service Control Manager" |
    Where-Object { $_.Message -like "*RhinoCompute*" } |
    Select-Object -First 10
```

## Azure Deployment

### Using Azure VMs

1. **Create VM Scale Set** (for auto-scaling):
   - Use Windows Server 2019/2022 Datacenter image
   - Configure custom script extension to run `Install-ComputeServer.ps1`
   - Set up auto-scale rules based on CPU or custom metrics

2. **Create Azure Load Balancer** (alternative to NGINX):
   - Backend pool: Your compute VMs
   - Health probe: `http://VM:5000/healthcheck/ready`
   - Load balancing rule: Port 80 → 5000

3. **Or use the scripts** with Azure VMs as regular Windows servers

### Using Azure Container Instances (optional)

If you want to use Docker instead:
```powershell
# Build image
docker build -t rhinocompute:latest .

# Push to Azure Container Registry
az acr login --name myregistry
docker tag rhinocompute:latest myregistry.azurecr.io/rhinocompute:latest
docker push myregistry.azurecr.io/rhinocompute:latest

# Deploy with Azure Container Instances
az container create --resource-group mygroup --name compute1 --image myregistry.azurecr.io/rhinocompute:latest
```

## Private Infrastructure Deployment

Works identically to Azure - just use private IP addresses for `$ServerList` and backend servers.

### With Active Directory:

Enable PowerShell remoting is easier:
```powershell
# On all servers
Enable-PSRemoting -Force
```

### Without Active Directory:

Configure WinRM with HTTPS and certificate authentication or enable basic auth (less secure).

## Troubleshooting

### Service won't start

1. Check if Rhino is installed:
   ```powershell
   Test-Path "C:\Program Files\Rhino 8\System\Rhino.exe"
   ```

2. Check service logs:
   ```powershell
   Get-Content C:\RhinoCompute\logs\service-stderr.log -Tail 50
   ```

3. Try running manually:
   ```powershell
   cd C:\RhinoCompute
   .\rhino.compute.exe --port 5000
   ```

### Health checks failing

1. Test locally on the server:
   ```powershell
   Invoke-WebRequest -Uri "http://localhost:5000/healthcheck/ready"
   ```

2. Check firewall:
   ```powershell
   Get-NetFirewallRule -DisplayName "Rhino Compute"
   ```

3. Check if port is listening:
   ```powershell
   netstat -ano | findstr :5000
   ```

### Updates failing

1. Check PowerShell remoting:
   ```powershell
   Test-WSMan -ComputerName server1
   ```

2. Verify credentials have admin rights

3. Check available disk space on target servers

### High memory usage

Reduce child count or enable headless doc mode:
```powershell
Stop-Service RhinoCompute
[System.Environment]::SetEnvironmentVariable("RHINO_COMPUTE_CREATE_HEADLESS_DOC", "true", [System.EnvironmentVariableTarget]::Machine)
# Or edit NSSM service args to reduce --childcount
& "C:\RhinoCompute\nssm.exe" set RhinoCompute AppParameters "--port 5000 --childcount 2 --spawn-on-startup"
Start-Service RhinoCompute
```

## File Reference

| File | Purpose |
|------|---------|
| `Install-ComputeServer.ps1` | Initial server setup |
| `Update-ComputeCluster.ps1` | Zero-downtime cluster updates |
| `Rollback-ComputeServer.ps1` | Restore previous version |
| `Monitor-ComputeCluster.ps1` | Continuous health monitoring |
| `nginx/Install-NginxLoadBalancer.ps1` | Setup NGINX load balancer |
| `nginx/nginx.conf` | NGINX configuration template |
| `servers.txt.example` | Example server list file |

## Support

For issues with these scripts, check:
- Windows Event Log (Application and System)
- Service logs in `C:\RhinoCompute\logs\`
- NGINX logs in `C:\nginx\logs\`

For Rhino Compute itself, see:
- https://developer.rhino3d.com/guides/compute/
- https://github.com/mcneel/compute.rhino3d

## License

Same as compute.rhino3d project.
