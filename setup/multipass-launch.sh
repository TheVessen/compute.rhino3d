#!/usr/bin/env bash
# ============================================================
# multipass-launch.sh  (macOS)
# Creates a Multipass VM and sets up Rhino.Compute inside it.
#
# Usage:
#   ./multipass-launch.sh
#   RHINO_TOKEN=your-token ./multipass-launch.sh
#   RHINO_TOKEN=your-token CPUS=8 MEMORY=16G ./multipass-launch.sh
#
# Env vars:
#   RHINO_TOKEN   - Rhino Core-Hour Billing token (optional but needed for real work)
#   VM_NAME       - VM name (default: rhino-compute)
#   CPUS          - CPU count (default: 4)
#   MEMORY        - RAM (default: 8G)
#   DISK          - Disk size (default: 10G)
#   CHILD_COUNT   - Number of compute.geometry children (default: 1)
# ============================================================

set -e

VM_NAME="${VM_NAME:-rhino-compute}"
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-8G}"
DISK="${DISK:-10G}"
CHILD_COUNT="${CHILD_COUNT:-1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo ""; echo "==> $1"; }
ok()  { echo "    ✓  $1"; }

# -------------------------------------------------------
# Check Multipass is installed
# -------------------------------------------------------
if ! command -v multipass &>/dev/null; then
    echo ""
    echo "ERROR: multipass not found."
    echo "Install it with:  brew install multipass"
    echo "Or download from: https://multipass.run/install"
    exit 1
fi

echo ""
echo "============================================================"
echo "  Rhino.Compute — Multipass Setup (macOS)"
echo "  VM name    : $VM_NAME"
echo "  CPUs       : $CPUS"
echo "  Memory     : $MEMORY"
echo "  Disk       : $DISK"
echo "  Children   : $CHILD_COUNT"
echo "  Token      : $([ -n "$RHINO_TOKEN" ] && echo "set" || echo "NOT SET (computations will fail)")"
echo "============================================================"
echo ""

# -------------------------------------------------------
# Create or reuse VM
# -------------------------------------------------------
if multipass list | grep -q "^$VM_NAME\s"; then
    log "VM '$VM_NAME' already exists — reusing it"
    multipass start "$VM_NAME" 2>/dev/null || true
    ok "VM is running"
else
    log "Creating VM '$VM_NAME'"
    multipass launch noble \
        --name "$VM_NAME" \
        --cpus "$CPUS" \
        --memory "$MEMORY" \
        --disk "$DISK"
    ok "VM created"
fi

# -------------------------------------------------------
# Transfer setup script
# -------------------------------------------------------
log "Transferring setup script to VM"
multipass transfer "$SCRIPT_DIR/multipass-setup.sh" "$VM_NAME:/root/multipass-setup.sh"
ok "Script transferred"

# -------------------------------------------------------
# Run setup inside VM
# -------------------------------------------------------
log "Running setup inside VM (this takes a few minutes...)"

if [ -n "$RHINO_TOKEN" ]; then
    multipass exec "$VM_NAME" -- sudo env \
        RHINO_TOKEN="$RHINO_TOKEN" \
        CHILD_COUNT="$CHILD_COUNT" \
        bash /root/multipass-setup.sh
else
    multipass exec "$VM_NAME" -- sudo env \
        CHILD_COUNT="$CHILD_COUNT" \
        bash /root/multipass-setup.sh
fi

# -------------------------------------------------------
# Print connection info
# -------------------------------------------------------
VM_IP=$(multipass info "$VM_NAME" | grep IPv4 | awk '{print $2}')

echo ""
echo "============================================================"
echo "  Done! Rhino.Compute is ready."
echo "============================================================"
echo ""
echo "  Start the server:"
echo "    multipass exec $VM_NAME -- sudo /root/start-compute.sh"
echo ""
echo "  Or open a shell:"
echo "    multipass shell $VM_NAME"
echo "    sudo /root/start-compute.sh"
echo ""
echo "  Once running, connect from your Mac:"
echo "    http://${VM_IP}:6500"
echo ""
echo "  Healthcheck:"
echo "    curl http://${VM_IP}:6500/healthcheck"
echo ""
