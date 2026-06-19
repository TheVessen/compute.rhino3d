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
# 2. Install .NET 10 SDK
# ============================================================
echo ">>> Installing .NET 10..."
wget https://dotnet.microsoft.com/download/dotnet/scripts/v1/dotnet-install.sh \
  -O /tmp/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
/tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet
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

# Configure Yak to always use root's home directory
export HOME=/root
export YAK_DATA_DIR=/root/.config/Yak

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
