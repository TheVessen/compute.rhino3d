# ============================================================
# time-startup.ps1
# Measures how long rhino-compute takes to fully start.
# Runs multiple times and reports average, min, max.
#
# Usage:
#   .\time-startup.ps1
#   .\time-startup.ps1 -Token "your-real-token"
#   .\time-startup.ps1 -Token "your-token" -Runs 5
#   .\time-startup.ps1 -Token "your-token" -Image "rhino-compute-x9" -Runs 3
# ============================================================
param(
    [string]$Token   = "your-token-here",
    [string]$Image   = "rhino-compute-x9",
    [int]$Runs       = 3,
    [int]$Timeout    = 180
)

$ErrorActionPreference = "Stop"
$ContainerName = "rc-timing-test"

function Get-Elapsed($since) { [math]::Round(((Get-Date) - $since).TotalSeconds, 2) }

function Get-Stats($values) {
    if (-not $values) { return "  n/a" }
    $avg = [math]::Round(($values | Measure-Object -Average).Average, 2)
    $min = [math]::Round(($values | Measure-Object -Minimum).Minimum, 2)
    $max = [math]::Round(($values | Measure-Object -Maximum).Maximum, 2)
    $all = ($values | ForEach-Object { "${_}s" }) -join "  "
    return "  avg=${avg}s  min=${min}s  max=${max}s  ($all)"
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Rhino Compute Startup Timer" -ForegroundColor Cyan
Write-Host "  Image : $Image" -ForegroundColor Cyan
Write-Host "  Runs  : $Runs" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$mainResults = @()
$ghResults   = @()

for ($run = 1; $run -le $Runs; $run++) {
    Write-Host "──────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Run $run / $Runs" -ForegroundColor White
    Write-Host "──────────────────────────────────────" -ForegroundColor DarkGray

    # --- Clean up any leftover test container ---
    $existing = docker ps -aq --filter "name=$ContainerName" 2>$null
    if ($existing) { docker rm -f $ContainerName | Out-Null }

    # --- Start container ---
    $T0 = Get-Date
    Write-Host "  [$($T0.ToString('HH:mm:ss.fff'))]  Starting container..." -ForegroundColor White

    docker run -d `
        --name $ContainerName `
        -p 6500:6500 `
        -e RHINO_TOKEN=$Token `
        $Image | Out-Null

    # -------------------------------------------------------
    # MILESTONE 1 – main server responds on /healthcheck
    # -------------------------------------------------------
    $mainReady = $null
    $deadline  = $T0.AddSeconds($Timeout)

    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:6500/healthcheck" `
                                   -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
            if ($r.StatusCode -eq 200) { $mainReady = Get-Elapsed $T0; break }
        } catch {}
        Start-Sleep -Milliseconds 500
    }

    if ($null -eq $mainReady) {
        Write-Host "  ✗  Main server timed out — skipping run." -ForegroundColor Red
        docker rm -f $ContainerName | Out-Null
        continue
    }

    Write-Host "  ✓  Main server ready        ── $mainReady s" -ForegroundColor Green
    $mainResults += $mainReady

    # -------------------------------------------------------
    # MILESTONE 2 – child process (CG) finishes loading GH
    # -------------------------------------------------------
    $ghReady  = $null
    $deadline = $T0.AddSeconds($Timeout)

    while ((Get-Date) -lt $deadline) {
        $logs = docker logs $ContainerName 2>&1 | Out-String
        if ($logs -match "CG\s+\[.*\] Application started") {
            $ghReady = Get-Elapsed $T0
            break
        }
        Start-Sleep -Milliseconds 500
    }

    if ($null -eq $ghReady) {
        Write-Host "  ⚠  GH child did not finish within $Timeout s." -ForegroundColor Yellow
    } else {
        Write-Host "  ✓  Grasshopper fully loaded  ── $ghReady s" -ForegroundColor Green
        $ghResults += $ghReady
    }

    # Remove container before next run
    docker rm -f $ContainerName | Out-Null
    Write-Host ""

    # Short pause between runs so the port is released
    if ($run -lt $Runs) { Start-Sleep -Seconds 2 }
}

# -------------------------------------------------------
# AGGREGATE SUMMARY
# -------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Summary ($Runs runs)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Main server ready:"
Write-Host (Get-Stats $mainResults)
Write-Host "  Fully ready (GH):"
Write-Host (Get-Stats $ghResults)
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

