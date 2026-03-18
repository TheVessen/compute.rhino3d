# ============================================================
# time-startup.ps1
# Measures how long rhino-compute takes to fully start.
#
# Usage:
#   .\time-startup.ps1
#   .\time-startup.ps1 -Token "your-real-token"
#   .\time-startup.ps1 -Token "your-token" -Image "rhino-compute-x9"
# ============================================================
param(
    [string]$Token   = "your-token-here",
    [string]$Image   = "rhino-compute-x9",
    [int]$Timeout    = 180       # seconds before giving up
)

$ErrorActionPreference = "Stop"
$ContainerName = "rc-timing-test"

function Elapsed($since) { [math]::Round(((Get-Date) - $since).TotalSeconds, 2) }

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Rhino Compute Startup Timer" -ForegroundColor Cyan
Write-Host "  Image : $Image" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --- Clean up any leftover test container ---
$existing = docker ps -aq --filter "name=$ContainerName" 2>$null
if ($existing) {
    Write-Host "Removing leftover container '$ContainerName'..." -ForegroundColor Yellow
    docker rm -f $ContainerName | Out-Null
}

# --- Start the container ---
$T0 = Get-Date
Write-Host "[$($T0.ToString('HH:mm:ss.fff'))]  docker run ..." -ForegroundColor White

docker run -d `
    --name $ContainerName `
    -p 6500:6500 `
    -e RHINO_TOKEN=$Token `
    $Image | Out-Null

Write-Host ""

# -------------------------------------------------------
# MILESTONE 1 – main server responds on /healthcheck
# -------------------------------------------------------
Write-Host "  Polling http://localhost:6500/healthcheck ..." -ForegroundColor Gray

$mainReady = $null
$deadline  = $T0.AddSeconds($Timeout)

while ((Get-Date) -lt $deadline) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:6500/healthcheck" `
                               -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        if ($r.StatusCode -eq 200) {
            $mainReady = Elapsed $T0
            break
        }
    } catch {}
    Start-Sleep -Milliseconds 500
}

if ($null -eq $mainReady) {
    Write-Host "  ✗  Main server did not respond within $Timeout s — aborting." -ForegroundColor Red
    docker rm -f $ContainerName | Out-Null
    exit 1
}

Write-Host "  ✓  Main server ready        ── $mainReady s" -ForegroundColor Green

# -------------------------------------------------------
# MILESTONE 2 – child process (CG) finishes loading GH
# -------------------------------------------------------
Write-Host "  Waiting for Grasshopper child process ..." -ForegroundColor Gray

$ghReady = $null
$deadline = $T0.AddSeconds($Timeout)

while ((Get-Date) -lt $deadline) {
    $logs = docker logs $ContainerName 2>&1 | Out-String
    if ($logs -match "CG\s+\[.*\] Application started") {
        $ghReady = Elapsed $T0
        break
    }
    Start-Sleep -Milliseconds 500
}

if ($null -eq $ghReady) {
    Write-Host "  ⚠  GH child did not finish within $Timeout s (it may still be loading)." -ForegroundColor Yellow
} else {
    Write-Host "  ✓  Grasshopper fully loaded  ── $ghReady s" -ForegroundColor Green
}

# -------------------------------------------------------
# SUMMARY
# -------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Results" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ("  Main server ready:    {0,7} s" -f $mainReady)
if ($ghReady) {
    Write-Host ("  Fully ready (GH):     {0,7} s" -f $ghReady)
}
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# -------------------------------------------------------
# KEEP OR REMOVE
# -------------------------------------------------------
$keep = Read-Host "Keep container running? [y/N]"
if ($keep -match '^[yY]$') {
    Write-Host "Container '$ContainerName' is still running on http://localhost:6500" -ForegroundColor Green
} else {
    docker rm -f $ContainerName | Out-Null
    Write-Host "Container removed." -ForegroundColor Gray
}

