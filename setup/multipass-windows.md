# Rhino.Compute on Windows
## Setup via Multipass — x9 Branch

---

## Overview

This guide sets up Rhino.Compute from the x9 branch inside a local Ubuntu VM
using Multipass on Windows. This mirrors the production Linux environment.

**Quickest path:** use the automation script — see [Automated Setup](#automated-setup).

---

## Prerequisites

- Windows 10/11 with PowerShell
- Multipass installed: https://multipass.run/install
- A Core-Hour Billing Token from McNeel:
  https://developer.rhino3d.com/guides/compute/core-hour-billing/

> **Note:** Multipass on Windows requires either Hyper-V or VirtualBox as the
> backend. Hyper-V is recommended (built into Windows Pro/Enterprise).
> To enable Hyper-V: `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All`

> **Warning:** Without a `RHINO_TOKEN` the server starts but any Rhino/Grasshopper
> computation crashes with a `PAL_SEHException`. The token is required for real work.

---

## Automated Setup

The fastest way. Run this in PowerShell from the `setup` folder:

```powershell
.\multipass-launch.ps1
```

Or with a token:

```powershell
.\multipass-launch.ps1 -Token "your-token-here"
```

Once done, skip to [Connect from Windows](#connect-from-windows).

---

## Manual Setup

### Step 1 — Install Multipass

Download and install from https://multipass.run/install, or with winget:

```powershell
winget install Canonical.Multipass
```

Restart your terminal after installation.

### Step 2 — Create the VM

```powershell
multipass launch noble --name rhino-compute --cpus 4 --memory 8G --disk 10G
```

This creates an Ubuntu 24.04 VM with 4 CPUs, 8 GB RAM, 10 GB disk.

### Step 3 — Transfer and run the setup script

```powershell
# Transfer the setup script into the VM
multipass transfer setup\multipass-setup.sh rhino-compute:/root/multipass-setup.sh

# Run it inside the VM
multipass exec rhino-compute -- sudo bash /root/multipass-setup.sh
```

Or with a token:

```powershell
multipass exec rhino-compute -- sudo env RHINO_TOKEN=your-token-here bash /root/multipass-setup.sh
```

Or follow the manual steps below.

---

### Step 3a — Open a shell inside the VM

```powershell
multipass shell rhino-compute
```

Then switch to root inside the VM:

```bash
sudo -s
```

### Step 3b — Install dependencies

```bash
apt update && apt install -y wget gpg nano git curl
```

### Step 3c — Install .NET 9

```bash
wget https://dotnet.microsoft.com/download/dotnet/scripts/v1/dotnet-install.sh \
  -O dotnet-install.sh
chmod +x ./dotnet-install.sh
./dotnet-install.sh --channel 9.0 --install-dir /usr/share/dotnet

echo 'export DOTNET_ROOT=/usr/share/dotnet' >> ~/.bashrc
echo 'export PATH=$PATH:$DOTNET_ROOT' >> ~/.bashrc
export DOTNET_ROOT=/usr/share/dotnet
export PATH=$PATH:$DOTNET_ROOT
```

### Step 3d — Add McNeel package repository

```bash
wget -qO- https://mcneel-packages.s3.amazonaws.com/mcneel-packages.gpg.key \
  | gpg --dearmor -o /usr/share/keyrings/mcneel-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/mcneel-archive-keyring.gpg] \
  https://mcneel-packages.s3.amazonaws.com/deb stable main" \
  | tee /etc/apt/sources.list.d/mcneel.list

apt update && apt install -y rhino-compute
```

### Step 3e — Fix NuGet config

```bash
mkdir -p /root/.nuget/NuGet
cat > /root/.nuget/NuGet/NuGet.Config << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
EOF
```

### Step 3f — Clone and build

```bash
cd /home
git clone https://github.com/VektorNode/compute.rhino3d.git rhino-compute-src
cd rhino-compute-src
git checkout 9.x.selva
cd src
dotnet build compute.sln -c Release
```

### Step 3g — Set token and start

```bash
export RHINO_TOKEN=your-token-here
echo 'export RHINO_TOKEN=your-token-here' >> ~/.bashrc

dotnet run --project rhino.compute --configuration Release \
  --no-build -- --urls http://0.0.0.0:6500 \
  --childcount 1 --spawn-on-startup
```

---

## Connect from Windows

### Find the VM's IP

```powershell
multipass info rhino-compute
```

Look for the `IPv4` line (e.g. `172.22.100.5`).

### Test the connection

```powershell
curl http://172.22.100.5:6500/healthcheck
```

### Configure your client

```typescript
const COMPUTE_SERVER = 'http://172.22.100.5:6500';
```

---

## Serving Grasshopper Definition Files

The server fetches `.gh` files from URLs — those URLs must be reachable
**from inside the VM**, not just from Windows.

| URL | Works? | Why |
|-----|--------|-----|
| `http://localhost:5500/...` | No | localhost = the VM |
| `http://127.0.0.1:5500/...` | No | same reason |
| `http://172.22.100.1:5500/...` | Yes | your Windows host IP |

Find your Windows IP as seen from the VM:

```powershell
# On Windows, find the IP on the same subnet as the VM
multipass info rhino-compute  # note VM IP, e.g. 172.22.100.5
ipconfig | findstr "172.22"   # find your Windows IP on same subnet
```

If using VS Code Live Server, add to your VS Code settings:

```json
"liveServer.settings.host": "0.0.0.0"
```

---

## Managing the VM

```powershell
# Re-enter the VM
multipass shell rhino-compute

# Stop (keeps everything installed)
multipass stop rhino-compute

# Start again
multipass start rhino-compute

# Delete completely
multipass delete rhino-compute
multipass purge

# List all VMs
multipass list
```

After re-entering the VM, start the server again:

```bash
sudo -s
cd /home/rhino-compute-src/src
dotnet run --project rhino.compute --configuration Release \
  --no-build -- --urls http://0.0.0.0:6500 \
  --childcount 1 --spawn-on-startup
```

---

## Expected Startup Log

```
RC  [...] Rhino compute started
RC  [...] Starting compute.geometry instance on port 6001
RC  [...] Now listening on: http://0.0.0.0:6500
CG  [...] Child process started
CG  [...] RhinoCore initializing (license validation may take a few seconds)...
CG  [...] RhinoCore ready in ~5s
CG  [...] (1/4) Loading rhino commands plugin
CG  [...] (2/4) Loading rhino scripting plugin
CG  [...] (3/4) Loading grasshopper
CG  [...] (4/4) Loading compute plug-ins
CG  [...] Application started
```

The ~5s RhinoCore initialization is license validation — expected with a token.

Expected errors that are harmless:
- `Error loading rhino commands plugin` — not supported on Linux yet
- `Error loading rhino scripting plugin` — RhinoCode not supported on Linux yet

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `multipass: command not found` | Restart PowerShell after installing Multipass |
| Multipass fails to start VM | Enable Hyper-V: `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All` |
| `dotnet: command not found` in VM | Run `export DOTNET_ROOT=/usr/share/dotnet && export PATH=$PATH:$DOTNET_ROOT` |
| `NuGet.Config is not valid XML` | Recreate NuGet config (Step 3e) |
| `Specify which project or solution file` | Use `dotnet build compute.sln -c Release` |
| Windows cannot connect (connection refused) | Add `--urls http://0.0.0.0:6500` when starting |
| `PAL_SEHException` on computation | Set `RHINO_TOKEN` |
| Live Server not reachable from VM | Set `"liveServer.settings.host": "0.0.0.0"` and use Windows host IP |
| VM IP changed after restart | Run `multipass info rhino-compute` to get new IP |
