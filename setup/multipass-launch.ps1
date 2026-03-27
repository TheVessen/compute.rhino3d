# ============================================================
# multipass-launch.ps1  (Windows)
# Creates a Multipass VM and sets up Rhino.Compute inside it.
#
# Usage:
#   .\multipass-launch.ps1
#   .\multipass-launch.ps1 -Token "your-token-here"
#   .\multipass-launch.ps1 -Token "your-token" -Cpus 8 -Memory 16G
#
# Parameters:
#   -Token        Rhino Core-Hour Billing token (needed for real work)
#   -VmName       VM name (default: rhino-compute)
#   -Cpus         CPU count (default: 4)
#   -Memory       RAM (default: 8G)
#   -Disk         Disk size (default: 10G)
#   -ChildCount   Number of compute.geometry children (default: 1)
# ============================================================
param(
    [string]$Token      = "",
    [string]$VmName     = "rhino-compute",
    [int]$Cpus          = 4,
    [string]$Memory     = "8G",
    [string]$Disk       = "10G",
    [int]$ChildCount    = 1
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

# -------------------------------------------------------
# Check Multipass is installed
# -------------------------------------------------------
if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "ERROR: multipass not found." -ForegroundColor Red
    Write-Host "Install it with:  winget install Canonical.Multipass" -ForegroundColor Yellow
    Write-Host "Or download from: https://multipass.run/install" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Rhino.Compute — Multipass Setup (Windows)" -ForegroundColor Cyan
Write-Host "  VM name    : $VmName" -ForegroundColor Cyan
Write-Host "  CPUs       : $Cpus" -ForegroundColor Cyan
Write-Host "  Memory     : $Memory" -ForegroundColor Cyan
Write-Host "  Disk       : $Disk" -ForegroundColor Cyan
Write-Host "  Children   : $ChildCount" -ForegroundColor Cyan
$tokenStatus = if ($Token) { "set" } else { "NOT SET (computations will fail)" }
Write-Host "  Token      : $tokenStatus" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -------------------------------------------------------
# Create or reuse VM
# -------------------------------------------------------
$existingVms = multipass list 2>$null | Select-String "^$VmName\s"
if ($existingVms) {
    Write-Host "==> VM '$VmName' already exists — reusing it" -ForegroundColor White
    multipass start $VmName 2>$null
    Write-Host "    ✓  VM is running" -ForegroundColor Green
} else {
    Write-Host "==> Creating VM '$VmName'" -ForegroundColor White
    multipass launch noble `
        --name $VmName `
        --cpus $Cpus `
        --memory $Memory `
        --disk $Disk
    Write-Host "    ✓  VM created" -ForegroundColor Green
}

# -------------------------------------------------------
# Transfer setup script
# -------------------------------------------------------
Write-Host ""
Write-Host "==> Transferring setup script to VM" -ForegroundColor White
$setupScript = Join-Path $ScriptDir "multipass-setup.sh"
if (-not (Test-Path $setupScript)) {
    Write-Host "ERROR: multipass-setup.sh not found at $setupScript" -ForegroundColor Red
    exit 1
}
multipass transfer $setupScript "${VmName}:/root/multipass-setup.sh"
Write-Host "    ✓  Script transferred" -ForegroundColor Green

# -------------------------------------------------------
# Run setup inside VM
# -------------------------------------------------------
Write-Host ""
Write-Host "==> Running setup inside VM (this takes a few minutes...)" -ForegroundColor White

if ($Token) {
    multipass exec $VmName -- sudo env `
        RHINO_TOKEN="$Token" `
        CHILD_COUNT="$ChildCount" `
        bash /root/multipass-setup.sh
} else {
    multipass exec $VmName -- sudo env `
        CHILD_COUNT="$ChildCount" `
        bash /root/multipass-setup.sh
}

# -------------------------------------------------------
# Print connection info
# -------------------------------------------------------
$vmInfo = multipass info $VmName 2>$null | Out-String
$vmIp = ($vmInfo | Select-String "IPv4").ToString().Split()[-1]

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Done! Rhino.Compute is ready." -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Start the server:" -ForegroundColor White
Write-Host "    multipass exec $VmName -- sudo /root/start-compute.sh"
Write-Host ""
Write-Host "  Or open a shell:" -ForegroundColor White
Write-Host "    multipass shell $VmName"
Write-Host "    sudo /root/start-compute.sh"
Write-Host ""
Write-Host "  Once running, connect from Windows:" -ForegroundColor White
Write-Host "    http://${vmIp}:6500"
Write-Host ""
Write-Host "  Healthcheck:" -ForegroundColor White
Write-Host "    curl http://${vmIp}:6500/healthcheck"
Write-Host ""
