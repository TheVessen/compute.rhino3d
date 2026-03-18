# ============================================================
# time-startup-native.ps1
# Measures rhino.compute startup time running natively on
# Windows (no Docker). Requires a built project.
#
# Usage:
#   .\time-startup-native.ps1
#   .\time-startup-native.ps1 -Token "your-real-token"
#   .\time-startup-native.ps1 -Token "your-token" -Runs 5
#   .\time-startup-native.ps1 -Token "your-token" -Runs 3 -Port 6500 -NoBuild
#
# Prerequisites:
#   Build once before running:
#     cd ..\src
#     dotnet build compute.sln -c Release
# ============================================================
param(
    [string]$Token    = "your-token-here",
    [string]$SrcPath  = "",        # auto-detected as ..\src relative to this script
    [int]$Port        = 6500,
    [int]$Runs        = 3,
    [int]$Timeout     = 180,       # seconds per run before giving up
    [switch]$NoBuild               # pass to skip dotnet build check
)

$ErrorActionPreference = "Stop"

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------
function Get-Elapsed($since) { [math]::Round(((Get-Date) - $since).TotalSeconds, 2) }

function Get-Stats($values) {
    if (-not $values) { return "  n/a" }
    $avg = [math]::Round(($values | Measure-Object -Average).Average, 2)
    $min = [math]::Round(($values | Measure-Object -Minimum).Minimum, 2)
    $max = [math]::Round(($values | Measure-Object -Maximum).Maximum, 2)
    $all = ($values | ForEach-Object { "${_}s" }) -join "  "
    return "  avg=${avg}s  min=${min}s  max=${max}s  ($all)"
}

function Kill-Tree($pid) {
    # Kill the whole process tree rooted at $pid (dotnet run + app + compute.geometry)
    & taskkill /T /F /PID $pid 2>$null | Out-Null
}

function Read-Logs($stdoutFile, $stderrFile) {
    $a = if (Test-Path $stdoutFile) { Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue } else { "" }
    $b = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue } else { "" }
    return "$a`n$b"
}

# -------------------------------------------------------
# Resolve paths
# -------------------------------------------------------
if (-not $SrcPath) {
    $SrcPath = Join-Path $PSScriptRoot "..\src"
}
$SrcPath     = (Resolve-Path $SrcPath).Path
$ProjectPath = Join-Path $SrcPath "rhino.compute"

if (-not (Test-Path $ProjectPath)) {
    Write-Host "ERROR: Project not found at: $ProjectPath" -ForegroundColor Red
    exit 1
}

# -------------------------------------------------------
# Check the project has been built (Release, then Debug)
# -------------------------------------------------------
$builtExe = $null
foreach ($cfg in @("Release","Debug")) {
    $candidate = Get-ChildItem -Path (Join-Path $ProjectPath "bin\$cfg") `
                               -Filter "rhino.compute.exe" -Recurse -ErrorAction SilentlyContinue |
                 Select-Object -First 1
    if ($candidate) { $builtExe = $candidate.FullName; break }
}

if (-not $builtExe -and $NoBuild) {
    Write-Host ""
    Write-Host "ERROR: No built binary found and -NoBuild was set." -ForegroundColor Red
    Write-Host "  Run this first from the src folder:" -ForegroundColor Yellow
    Write-Host "    dotnet build compute.sln -c Release" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# Build mode: exe directly (fastest) > dotnet run --no-build > dotnet run (with build)
if ($builtExe) {
    $runExe  = $builtExe
    $runArgs = "--port $Port --childcount 1 --spawn-on-startup"
    $runMode = "exe ($($builtExe -replace '.*\\bin\\','bin\'))"
} elseif (-not $NoBuild) {
    Write-Host ""
    Write-Host "  No pre-built binary found — will build first (adds time to run 1)." -ForegroundColor Yellow
    Write-Host "  Run 'dotnet build compute.sln -c Release' in src\ to avoid this." -ForegroundColor Yellow
    Write-Host ""
    $runExe  = "dotnet"
    $runArgs = "run --project `"$ProjectPath`" -- --port $Port --childcount 1 --spawn-on-startup"
    $runMode = "dotnet run (with build)"
} else {
    $runExe  = "dotnet"
    $runArgs = "run --project `"$ProjectPath`" --no-build -- --port $Port --childcount 1 --spawn-on-startup"
    $runMode = "dotnet run --no-build"
}

# -------------------------------------------------------
# Print header
# -------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Rhino Compute Startup Timer (native)" -ForegroundColor Cyan
Write-Host "  Mode : $runMode" -ForegroundColor Cyan
Write-Host "  Port : $Port" -ForegroundColor Cyan
Write-Host "  Runs : $Runs" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# -------------------------------------------------------
# Main loop
# -------------------------------------------------------
$mainResults = @()
$ghResults   = @()

for ($run = 1; $run -le $Runs; $run++) {

    Write-Host "──────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Run $run / $Runs" -ForegroundColor White
    Write-Host "──────────────────────────────────────" -ForegroundColor DarkGray

    $stdoutLog = [System.IO.Path]::GetTempFileName()
    $stderrLog = [System.IO.Path]::GetTempFileName()

    # Pass RHINO_TOKEN into the child process environment
    $env:RHINO_TOKEN = $Token

    $T0 = Get-Date
    Write-Host "  [$($T0.ToString('HH:mm:ss.fff'))]  Starting server..." -ForegroundColor White

    $proc = Start-Process `
        -FilePath        $runExe `
        -ArgumentList    $runArgs `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError  $stderrLog `
        -NoNewWindow `
        -PassThru `
        -WorkingDirectory $SrcPath

    # ---------------------------------------------------
    # MILESTONE 1 – main server responds on /healthcheck
    # ---------------------------------------------------
    $mainReady = $null
    $deadline  = $T0.AddSeconds($Timeout)

    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$Port/healthcheck" `
                                   -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
            if ($r.StatusCode -eq 200) { $mainReady = Get-Elapsed $T0; break }
        } catch {}
        Start-Sleep -Milliseconds 500
    }

    if ($null -eq $mainReady) {
        Write-Host "  ✗  Main server timed out — skipping run." -ForegroundColor Red
        Kill-Tree $proc.Id
        Remove-Item $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
        continue
    }

    Write-Host "  ✓  Main server ready        ── $mainReady s" -ForegroundColor Green
    $mainResults += $mainReady

    # ---------------------------------------------------
    # MILESTONE 2 – compute.geometry (CG) finishes GH load
    # ---------------------------------------------------
    $ghReady  = $null
    $deadline = $T0.AddSeconds($Timeout)

    while ((Get-Date) -lt $deadline) {
        $logs = Read-Logs $stdoutLog $stderrLog
        if ($logs -match "CG\s+\[.*\]\s+Application started") {
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

    # ---------------------------------------------------
    # Teardown – kill the whole process tree
    # ---------------------------------------------------
    Kill-Tree $proc.Id
    Remove-Item $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
    Write-Host ""

    # Short pause so the port is freed before the next run
    if ($run -lt $Runs) { Start-Sleep -Seconds 3 }
}

# -------------------------------------------------------
# Aggregate summary
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

