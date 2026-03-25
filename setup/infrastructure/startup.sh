#!/bin/bash
set -e

# ============================================================
# Rhino.Compute — Automated Server Setup
# This script runs on first boot via GCP metadata_startup_script
# ============================================================

LOG_FILE="/var/log/rhino-compute-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Setup started at $(date) ==="

# ============================================================
# 1. Install base dependencies
# ============================================================
echo ">>> Installing dependencies..."
apt update
apt install -y wget gpg nano git curl ca-certificates

# ============================================================
# 2. Install .NET 9 SDK
# ============================================================
echo ">>> Installing .NET 9..."
wget https://dotnet.microsoft.com/download/dotnet/scripts/v1/dotnet-install.sh \
  -O /tmp/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
/tmp/dotnet-install.sh --channel 9.0 --install-dir /usr/share/dotnet
rm /tmp/dotnet-install.sh

# Make dotnet available system-wide
echo 'export DOTNET_ROOT=/usr/share/dotnet' >> /etc/profile.d/dotnet.sh
echo 'export PATH=$PATH:$DOTNET_ROOT' >> /etc/profile.d/dotnet.sh
export DOTNET_ROOT=/usr/share/dotnet
export PATH=$PATH:$DOTNET_ROOT
ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet

# ============================================================
# 3. Add McNeel package repo and install Rhino runtime
# ============================================================
echo ">>> Adding McNeel repo and installing Rhino runtime..."
wget -qO- https://mcneel-packages.s3.amazonaws.com/mcneel-packages.gpg.key \
  | gpg --dearmor -o /usr/share/keyrings/mcneel-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/mcneel-archive-keyring.gpg] \
  https://mcneel-packages.s3.amazonaws.com/deb stable main" \
  | tee /etc/apt/sources.list.d/mcneel.list

apt update && apt install -y rhino-compute yak-cli

# Make yak always use /root as HOME so packages install where the service can find them
echo 'alias yak="HOME=/root yak"' >> /etc/bash.bashrc

# ============================================================
# 3b. Install Selva plugin via Yak and link into GH Libraries folder
# Run as root so packages land in /root/.local/share (where the service looks)
# GH on Linux scans /root/.config/Grasshopper/Libraries/ — Yak packages dir is NOT scanned
# ============================================================
echo ">>> Installing Selva plugin..."
HOME=/root yak install selva

echo ">>> Installing Hops plugin..."
HOME=/root yak install hops

# ============================================================
# 3c. Pre-create GH Libraries symlinks before service starts
# RunHeadless() on Rhino 9 Linux recreates the GH config dir on first boot,
# wiping any symlinks the C# startup code created. By creating them here
# (before the service starts), they survive first-time initialization.
# The C# code handles packages installed later.
# ============================================================
echo ">>> Pre-creating GH Libraries symlinks..."
GH_LIBS=/root/.config/Grasshopper/Libraries
PKG_DIR=/root/.local/share/mcneel/rhinoceros/packages/9.0
mkdir -p "$GH_LIBS"

# For each package, find GHAs — prefer net7.0/net8.0/net9.0 over net48
for pkg in "$PKG_DIR"/*/; do
  [ -d "$pkg" ] || continue
  # Collect all GHAs; sort so net[7-9] paths come last (highest), pick last
  gha=$(find "$pkg" -name "*.gha" | sort | tail -1)
  [ -f "$gha" ] || continue
  gha_dir="$(dirname "$gha")"
  for f in "$gha_dir"/*.gha "$gha_dir"/*.dll; do
    [ -f "$f" ] && ln -sf "$f" "$GH_LIBS/$(basename "$f")"
  done
done
echo ">>> GH Libraries: $(ls "$GH_LIBS" 2>/dev/null | wc -l) files linked"

# ============================================================
# 4. Fix NuGet config
# ============================================================
echo ">>> Fixing NuGet config..."
mkdir -p /root/.nuget/NuGet
cat > /root/.nuget/NuGet/NuGet.Config << 'NUGETEOF'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
NUGETEOF

# ============================================================
# 5. Clone repo and build
# ============================================================
echo ">>> Cloning repo (branch: ${repo_branch})..."
cd /opt
git clone ${repo_url} rhino-compute-src
cd rhino-compute-src
git checkout ${repo_branch}
cd src

echo ">>> Building..."
dotnet restore compute.sln
dotnet build compute.sln -c Release

# ============================================================
# 6. Create systemd service
# ============================================================
echo ">>> Creating systemd service..."
cat > /etc/systemd/system/rhino-compute.service << 'SERVICEEOF'
[Unit]
Description=Rhino.Compute Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/rhino-compute-src/src
Environment=DOTNET_ROOT=/usr/share/dotnet
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/share/dotnet
Environment=HOME=/root
Environment=RHINO_TOKEN=${rhino_token}
Environment=RHINO_COMPUTE_KEY=${api_key}
ExecStart=/usr/share/dotnet/dotnet run --project rhino.compute --configuration Release --no-build -- --urls http://0.0.0.0:6500 --childcount 1 --spawn-on-startup
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF

# ============================================================
# 7. Enable and start the service
# ============================================================
echo ">>> Starting rhino-compute service..."
systemctl daemon-reload
systemctl enable rhino-compute
systemctl start rhino-compute

# ============================================================
# 8. Auto-shutdown timer (if configured)
# ============================================================
%{ if max_uptime_hours > 0 ~}
echo ">>> Scheduling auto-shutdown in ${max_uptime_hours} hour(s)..."
shutdown -h +$(( ${max_uptime_hours} * 60 ))
%{ endif ~}

echo "=== Setup completed at $(date) ==="
echo "=== Server should be running on http://0.0.0.0:6500 ==="
