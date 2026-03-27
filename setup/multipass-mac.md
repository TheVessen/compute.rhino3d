# Rhino.Compute on macOS
## Setup via Multipass — x9 Branch

---

## Overview

This guide sets up Rhino.Compute from the x9 branch inside a local Ubuntu VM
using Multipass (a lightweight VM manager by Canonical). This mirrors the
production Linux environment.

**Quickest path:** use the automation script — see [Automated Setup](#automated-setup).

---

## Prerequisites

- macOS with Homebrew installed
- A Core-Hour Billing Token from McNeel:
  https://developer.rhino3d.com/guides/compute/core-hour-billing/

> **Warning:** Without a `RHINO_TOKEN` the server starts but any Rhino/Grasshopper
> computation crashes with a `PAL_SEHException`. The token is required for real work.

---

## Automated Setup

The fastest way. Run this on your Mac — it creates the VM and configures everything inside it automatically:

```bash
chmod +x multipass-launch.sh
./multipass-launch.sh
```

Or with a token:

```bash
RHINO_TOKEN=your-token-here ./multipass-launch.sh
```

Once done, skip to [Connect from your Mac](#connect-from-your-mac).

---

## Manual Setup

### Step 1 — Install Multipass

```bash
brew install multipass
```

### Step 2 — Create the VM

```bash
multipass launch noble --name rhino-compute --cpus 4 --memory 8G --disk 10G
```

This creates an Ubuntu 24.04 VM with 4 CPUs, 8 GB RAM, 10 GB disk.

### Step 3 — Open a shell and switch to root

```bash
multipass shell rhino-compute
sudo -s
```

### Step 4 — Run the setup script inside the VM

Copy `multipass-setup.sh` into the VM and run it:

```bash
# From your Mac (in a separate terminal):
multipass transfer multipass-setup.sh rhino-compute:/root/multipass-setup.sh

# Inside the VM:
chmod +x /root/multipass-setup.sh
RHINO_TOKEN=your-token-here /root/multipass-setup.sh
```

Or follow the manual steps below.

---

### Step 4a — Install dependencies

```bash
apt update && apt install -y wget gpg nano git curl
```

### Step 4b — Install .NET 9

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

> **Gotcha:** If you skip the `echo` lines, `dotnet` will not be found after
> you re-enter the VM.

### Step 4c — Add McNeel package repository

```bash
wget -qO- https://mcneel-packages.s3.amazonaws.com/mcneel-packages.gpg.key \
  | gpg --dearmor -o /usr/share/keyrings/mcneel-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/mcneel-archive-keyring.gpg] \
  https://mcneel-packages.s3.amazonaws.com/deb stable main" \
  | tee /etc/apt/sources.list.d/mcneel.list

apt update && apt install -y rhino-compute
```

### Step 4d — Fix NuGet config

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

> **Gotcha:** Without this, `dotnet build` fails with
> "NuGet.Config is not valid XML. Root element is missing."

### Step 4e — Clone and build

```bash
cd /home
git clone https://github.com/VektorNode/compute.rhino3d.git rhino-compute-src
cd rhino-compute-src
git checkout 9.x.selva
cd src
dotnet build compute.sln -c Release
```

> **Gotcha:** Use `compute.sln` explicitly — there are multiple solution files
> and `dotnet build` alone will fail.

### Step 4f — Set token and start

```bash
export RHINO_TOKEN=your-token-here
echo 'export RHINO_TOKEN=your-token-here' >> ~/.bashrc

dotnet run --project rhino.compute --configuration Release \
  --no-build -- --urls http://0.0.0.0:6500 \
  --childcount 1 --spawn-on-startup
```

> **Gotcha:** `--urls http://0.0.0.0:6500` is required. Without it the server
> only listens inside the VM and your Mac cannot reach it.

---

## Connect from your Mac

### Find the VM's IP

```bash
multipass info rhino-compute
```

Look for the `IPv4` line (e.g. `192.168.2.2`).

### Test the connection

```bash
curl http://192.168.2.2:6500/healthcheck
```

### Configure your client

```typescript
const COMPUTE_SERVER = 'http://192.168.2.2:6500';
```

---

## Serving Grasshopper Definition Files

The server fetches `.gh` files from URLs — those URLs must be reachable
**from inside the VM**, not just from your Mac.

| URL | Works? | Why |
|-----|--------|-----|
| `http://localhost:5500/...` | No | localhost = the VM |
| `http://127.0.0.1:5500/...` | No | same reason |
| `http://192.168.2.1:5500/...` | Yes | your Mac's actual IP |

If using VS Code Live Server, add to your VS Code settings:

```json
"liveServer.settings.host": "0.0.0.0"
```

---

## Managing the VM

```bash
# Re-enter after closing terminal
multipass shell rhino-compute

# Stop (keeps everything installed)
multipass stop rhino-compute

# Start again
multipass start rhino-compute

# Delete completely
multipass delete rhino-compute && multipass purge

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
| `dotnet: command not found` | Run `export DOTNET_ROOT=/usr/share/dotnet && export PATH=$PATH:$DOTNET_ROOT` |
| `NuGet.Config is not valid XML` | Recreate NuGet config (Step 4d) |
| `Specify which project or solution file` | Use `dotnet build compute.sln -c Release` |
| Mac cannot connect (connection refused) | Add `--urls http://0.0.0.0:6500` when starting |
| `PAL_SEHException` on computation | Set `RHINO_TOKEN` |
| Live Server not reachable from VM | Set `"liveServer.settings.host": "0.0.0.0"` and use Mac's IP |
| VM IP changed after restart | Run `multipass info rhino-compute` to get new IP |
