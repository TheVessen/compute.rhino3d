#!/usr/bin/env bash
# ============================================================
# multipass-setup.sh
# Runs INSIDE the Multipass Ubuntu VM to install and build
# Rhino.Compute from the x9 branch.
#
# Usage (inside VM as root):
#   bash /root/multipass-setup.sh
#   RHINO_TOKEN=your-token bash /root/multipass-setup.sh
#
# Env vars:
#   RHINO_TOKEN   - optional, sets token permanently in ~/.bashrc
#   REPO_URL      - git repo to clone (default: VektorNode fork)
#   BRANCH        - branch to checkout (default: 9.x.selva)
#   CHILD_COUNT   - number of child processes (default: 1)
# ============================================================

set -e

REPO_URL="${REPO_URL:-https://github.com/VektorNode/compute.rhino3d.git}"
BRANCH="${BRANCH:-9.x.selva}"
CHILD_COUNT="${CHILD_COUNT:-1}"
INSTALL_DIR="/home/rhino-compute-src"
DOTNET_DIR="/usr/share/dotnet"

log() { echo ""; echo "==> $1"; }
ok()  { echo "    ✓  $1"; }

# -------------------------------------------------------
# Must run as root
# -------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root (sudo -s or sudo bash $0)"
    exit 1
fi

log "Installing system dependencies"
apt-get update -qq
apt-get install -y wget gpg nano git curl ca-certificates
ok "Dependencies installed"

# -------------------------------------------------------
# .NET 9
# -------------------------------------------------------
log "Installing .NET 9 SDK"
if [ -f "$DOTNET_DIR/dotnet" ]; then
    ok ".NET already installed at $DOTNET_DIR — skipping"
else
    wget -q https://dotnet.microsoft.com/download/dotnet/scripts/v1/dotnet-install.sh \
        -O /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --channel 9.0 --install-dir "$DOTNET_DIR" --quiet
    rm /tmp/dotnet-install.sh
    ok ".NET 9 installed"
fi

# Make dotnet available now and on future logins
export DOTNET_ROOT="$DOTNET_DIR"
export PATH="$PATH:$DOTNET_DIR"

grep -q "DOTNET_ROOT" ~/.bashrc || {
    echo "export DOTNET_ROOT=$DOTNET_DIR" >> ~/.bashrc
    echo "export PATH=\$PATH:$DOTNET_DIR" >> ~/.bashrc
    ok "Added dotnet to ~/.bashrc"
}

# -------------------------------------------------------
# McNeel package repo + Rhino runtime
# -------------------------------------------------------
log "Adding McNeel package repository"
if [ ! -f /usr/share/keyrings/mcneel-archive-keyring.gpg ]; then
    wget -qO- https://mcneel-packages.s3.amazonaws.com/mcneel-packages.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/mcneel-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/mcneel-archive-keyring.gpg] \
        https://mcneel-packages.s3.amazonaws.com/deb stable main" \
        | tee /etc/apt/sources.list.d/mcneel.list > /dev/null
    apt-get update -qq
    ok "McNeel repo added"
else
    ok "McNeel repo already configured — skipping"
fi

log "Installing rhino-compute runtime"
apt-get install -y rhino-compute
ok "rhino-compute runtime installed"

# -------------------------------------------------------
# NuGet config
# -------------------------------------------------------
log "Configuring NuGet"
mkdir -p /root/.nuget/NuGet
cat > /root/.nuget/NuGet/NuGet.Config << 'NUGETEOF'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
NUGETEOF
ok "NuGet config written"

# -------------------------------------------------------
# Clone repo
# -------------------------------------------------------
log "Cloning repository ($BRANCH)"
if [ -d "$INSTALL_DIR/.git" ]; then
    ok "Repo already exists at $INSTALL_DIR — pulling latest"
    cd "$INSTALL_DIR"
    git fetch origin
    git checkout "$BRANCH"
    git pull origin "$BRANCH"
else
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    git checkout "$BRANCH"
    ok "Cloned to $INSTALL_DIR"
fi

# -------------------------------------------------------
# Build
# -------------------------------------------------------
log "Building compute.sln (Release)"
cd "$INSTALL_DIR/src"
dotnet build compute.sln -c Release
ok "Build succeeded"

# -------------------------------------------------------
# Token
# -------------------------------------------------------
if [ -n "$RHINO_TOKEN" ]; then
    log "Setting RHINO_TOKEN"
    # Remove any existing token line first
    sed -i '/RHINO_TOKEN/d' ~/.bashrc
    echo "export RHINO_TOKEN=$RHINO_TOKEN" >> ~/.bashrc
    export RHINO_TOKEN="$RHINO_TOKEN"
    ok "RHINO_TOKEN set in ~/.bashrc"
else
    echo ""
    echo "  NOTE: RHINO_TOKEN not set. The server will start but computations"
    echo "  will fail. Set it with:"
    echo "    export RHINO_TOKEN=your-token"
    echo "    echo 'export RHINO_TOKEN=your-token' >> ~/.bashrc"
fi

# -------------------------------------------------------
# Create start script
# -------------------------------------------------------
log "Creating start script at /root/start-compute.sh"
cat > /root/start-compute.sh << STARTEOF
#!/usr/bin/env bash
source ~/.bashrc
cd $INSTALL_DIR/src
exec dotnet run \\
    --project rhino.compute \\
    --configuration Release \\
    --no-build -- \\
    --urls http://0.0.0.0:6500 \\
    --childcount $CHILD_COUNT \\
    --spawn-on-startup
STARTEOF
chmod +x /root/start-compute.sh
ok "Start script created"

# -------------------------------------------------------
# Done
# -------------------------------------------------------
echo ""
echo "============================================================"
echo "  Setup complete!"
echo "============================================================"
echo ""
echo "  Start the server:"
echo "    /root/start-compute.sh"
echo ""
echo "  Or manually:"
echo "    cd $INSTALL_DIR/src"
echo "    dotnet run --project rhino.compute --configuration Release \\"
echo "      --no-build -- --urls http://0.0.0.0:6500 \\"
echo "      --childcount $CHILD_COUNT --spawn-on-startup"
echo ""
echo "  Server will be available at:"
VM_IP=$(hostname -I | awk '{print $1}')
echo "    http://${VM_IP}:6500"
echo ""
