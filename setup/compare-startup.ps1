# ============================================================
# compare-startup.ps1
# Runs both Docker and native startup timers back-to-back,
# then prints a side-by-side comparison.
#
# Measures what matters for production: time until ALL child
# processes are ready to handle requests.
#
# Usage:
#   .\compare-startup.ps1
#   .\compare-startup.ps1 -Token "your-real-token"
#   .\compare-startup.ps1 -Token "your-token" -Runs 5
#   .\compare-startup.ps1 -Token "your-token" -ChildCount 4 -Runs 3
#   .\compare-startup.ps1 -Token "your-token" -DockerOnly
#   .\compare-startup.ps1 -Token "your-token" -NativeOnly
# ============================================================
param(
    [string]$Token      = "your-token-here",
    [string]$Image      = "rhino-compute-x9",
    [int]$ChildCount    = 4,
    [int]$Runs          = 3,
    [int]$Timeout       = 300,
    [int]$Port          = 6500,
    [switch]$NoBuild,
    [switch]$DockerOnly,
    [switch]$NativeOnly
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

# Child ports: 6001, 6002, ... 6001+ChildCount-1
$ChildPorts = @(0..($ChildCount - 1) | ForEach-Object { 6001 + $_ })

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------
function Get-Stats($values) {
    if (-not $values -or $values.Count -eq 0) { return @{ Avg = $null; Min = $null; Max = $null; All = @() } }
    return @{
        Avg = [math]::Round(($values | Measure-Object -Average).Average, 2)
        Min = [math]::Round(($values | Measure-Object -Minimum).Minimum, 2)
        Max = [math]::Round(($values | Measure-Object -Maximum).Maximum, 2)
        All = $values
    }
}

function Get-Elapsed($since) { [math]::Round(((Get-Date) - $since).TotalSeconds, 2) }

function Kill-Tree($processId) {
    & taskkill /T /F /PID $processId 2>$null | Out-Null
}

function Wait-PortsFree($ports, $timeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $anyBusy = $false
        foreach ($p in $ports) {
            try {
                Invoke-WebRequest -Uri "http://localhost:$p/" `
                    -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop | Out-Null
                $anyBusy = $true
                break
            } catch {}
        }
        if (-not $anyBusy) { return $true }
        Write-Host "    Waiting for ports to free..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
    }
    return $false
}

# -------------------------------------------------------
# Wait for all children to be ready (polls /version on
# each child port). Returns seconds elapsed or $null.
# -------------------------------------------------------
function Wait-AllChildrenReady($T0, $deadline) {
    $readyPorts = @{}
    $firstChildTime = $null
    $lastChildTime  = $null

    while ((Get-Date) -lt $deadline) {
        foreach ($cp in $ChildPorts) {
            if ($readyPorts.ContainsKey($cp)) { continue }
            try {
                $r = Invoke-WebRequest -Uri "http://localhost:$cp/version" `
                                       -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
                if ($r.StatusCode -eq 200) {
                    $elapsed = Get-Elapsed $T0
                    $readyPorts[$cp] = $elapsed
                    if ($null -eq $firstChildTime) { $firstChildTime = $elapsed }
                    $lastChildTime = $elapsed
                    Write-Host "    child :$cp ready at ${elapsed}s" -ForegroundColor DarkGray
                }
            } catch {}
        }

        if ($readyPorts.Count -ge $ChildCount) { break }
        Start-Sleep -Milliseconds 500
    }

    return @{
        AllReady   = ($readyPorts.Count -ge $ChildCount)
        FirstChild = $firstChildTime
        LastChild  = $lastChildTime
        Count      = $readyPorts.Count
    }
}

# For Docker: use docker exec + curl to poll child ports
# from inside the container (avoids needing to expose them).
function Wait-AllChildrenReady-Docker($T0, $deadline, $containerName) {
    $readyPorts = @{}
    $firstChildTime = $null
    $lastChildTime  = $null

    while ((Get-Date) -lt $deadline) {
        foreach ($cp in $ChildPorts) {
            if ($readyPorts.ContainsKey($cp)) { continue }
            $status = docker exec $containerName curl -s -o /dev/null -w "%{http_code}" `
                          --max-time 1 "http://localhost:$cp/version" 2>$null
            if ($status -eq "200") {
                $elapsed = Get-Elapsed $T0
                $readyPorts[$cp] = $elapsed
                if ($null -eq $firstChildTime) { $firstChildTime = $elapsed }
                $lastChildTime = $elapsed
                Write-Host "    child :$cp ready at ${elapsed}s" -ForegroundColor DarkGray
            }
        }

        if ($readyPorts.Count -ge $ChildCount) { break }
        Start-Sleep -Milliseconds 500
    }

    return @{
        AllReady   = ($readyPorts.Count -ge $ChildCount)
        FirstChild = $firstChildTime
        LastChild  = $lastChildTime
        Count      = $readyPorts.Count
    }
}

# -------------------------------------------------------
# Docker timings
# Returns @{ Main = float[]; FirstChild = float[]; AllReady = float[] }
# -------------------------------------------------------
function Run-DockerTimings {
    $ContainerName = "rc-timing-test"
    $mainResults       = @()
    $firstChildResults = @()
    $allReadyResults   = @()

    for ($run = 1; $run -le $Runs; $run++) {
        Write-Host "  Docker run $run / $Runs" -ForegroundColor White

        $existing = docker ps -aq --filter "name=$ContainerName" 2>$null
        if ($existing) { docker rm -f $ContainerName | Out-Null }

        $T0 = Get-Date
        docker run -d `
            --name $ContainerName `
            -p ${Port}:6500 `
            -e RHINO_TOKEN=$Token `
            -e RHINO_COMPUTE_CHILD_COUNT=$ChildCount `
            $Image | Out-Null

        # Milestone 1 – proxy healthcheck
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
            Write-Host "    ✗  Proxy timed out" -ForegroundColor Red
            docker rm -f $ContainerName | Out-Null
            continue
        }
        Write-Host "    ✓  Proxy ready ${mainReady}s" -ForegroundColor Green
        $mainResults += $mainReady

        # Milestone 2 – all children ready
        $children = Wait-AllChildrenReady-Docker $T0 $T0.AddSeconds($Timeout) $ContainerName

        if (-not $children.AllReady) {
            Write-Host "    ⚠  Only $($children.Count)/$ChildCount children ready within ${Timeout}s" -ForegroundColor Yellow
        } else {
            Write-Host "    ✓  All $ChildCount children ready ${children.LastChild}s" -ForegroundColor Green
        }

        if ($children.FirstChild) { $firstChildResults += $children.FirstChild }
        if ($children.LastChild -and $children.AllReady) { $allReadyResults += $children.LastChild }

        docker rm -f $ContainerName | Out-Null
        if ($run -lt $Runs) { Start-Sleep -Seconds 2 }
        Write-Host ""
    }

    return @{ Main = $mainResults; FirstChild = $firstChildResults; AllReady = $allReadyResults }
}

# -------------------------------------------------------
# Native timings
# Returns @{ Main = float[]; FirstChild = float[]; AllReady = float[] }
# -------------------------------------------------------
function Run-NativeTimings {
    $SrcPath     = (Resolve-Path (Join-Path $ScriptDir "..\src")).Path
    $ProjectPath = Join-Path $SrcPath "rhino.compute"

    if (-not (Test-Path $ProjectPath)) {
        Write-Host "  ERROR: Project not found at $ProjectPath" -ForegroundColor Red
        return @{ Main = @(); FirstChild = @(); AllReady = @() }
    }

    # Find built exe
    $builtExe = $null
    foreach ($cfg in @("Release","Debug")) {
        $candidate = Get-ChildItem -Path (Join-Path $ProjectPath "bin\$cfg") `
                                   -Filter "rhino.compute.exe" -Recurse -ErrorAction SilentlyContinue |
                     Select-Object -First 1
        if ($candidate) { $builtExe = $candidate.FullName; break }
    }

    if ($builtExe) {
        $runExe  = $builtExe
        $runArgs = "--port $Port --childcount $ChildCount --spawn-on-startup"
    } elseif (-not $NoBuild) {
        $runExe  = "dotnet"
        $runArgs = "run --project `"$ProjectPath`" --no-build -- --port $Port --childcount $ChildCount --spawn-on-startup"
    } else {
        Write-Host "  ERROR: No binary found and -NoBuild set." -ForegroundColor Red
        return @{ Main = @(); FirstChild = @(); AllReady = @() }
    }

    $mainResults       = @()
    $firstChildResults = @()
    $allReadyResults   = @()

    # All ports to check: main + children
    $allPorts = @($Port) + $ChildPorts

    for ($run = 1; $run -le $Runs; $run++) {
        Write-Host "  Native run $run / $Runs" -ForegroundColor White

        if (-not (Wait-PortsFree $allPorts 15)) {
            Write-Host "    ✗  Ports still occupied — skipping run." -ForegroundColor Red
            continue
        }

        $env:RHINO_TOKEN = $Token
        $T0 = Get-Date

        $proc = Start-Process -FilePath $runExe -ArgumentList $runArgs `
                    -NoNewWindow -PassThru -WorkingDirectory $SrcPath

        # Milestone 1 – proxy healthcheck
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
            Write-Host "    ✗  Proxy timed out" -ForegroundColor Red
            Kill-Tree $proc.Id
            continue
        }
        Write-Host "    ✓  Proxy ready ${mainReady}s" -ForegroundColor Green
        $mainResults += $mainReady

        # Milestone 2 – all children ready (poll each child port)
        $children = Wait-AllChildrenReady $T0 $T0.AddSeconds($Timeout)

        if (-not $children.AllReady) {
            Write-Host "    ⚠  Only $($children.Count)/$ChildCount children ready within ${Timeout}s" -ForegroundColor Yellow
        } else {
            Write-Host "    ✓  All $ChildCount children ready ${children.LastChild}s" -ForegroundColor Green
        }

        if ($children.FirstChild) { $firstChildResults += $children.FirstChild }
        if ($children.LastChild -and $children.AllReady) { $allReadyResults += $children.LastChild }

        # Kill and wait for full cleanup
        Kill-Tree $proc.Id
        try { $proc.WaitForExit(10000) } catch {}
        Write-Host ""
    }

    return @{ Main = $mainResults; FirstChild = $firstChildResults; AllReady = $allReadyResults }
}

# -------------------------------------------------------
# Format helpers for comparison table
# -------------------------------------------------------
function Format-Row($label, $stats) {
    if ($null -eq $stats.Avg) { return "  {0,-28}  {1}" -f $label, "n/a" }
    $vals = ($stats.All | ForEach-Object { "${_}s" }) -join "  "
    return "  {0,-28}  avg={1}s  min={2}s  max={3}s  ({4})" -f $label, $stats.Avg, $stats.Min, $stats.Max, $vals
}

function Format-Delta($dStats, $nStats) {
    if ($null -eq $dStats.Avg -or $null -eq $nStats.Avg) { return }
    $diff = [math]::Round($dStats.Avg - $nStats.Avg, 2)
    $pct  = if ($nStats.Avg -ne 0) { [math]::Round(($diff / $nStats.Avg) * 100, 1) } else { 0 }
    $sign = if ($diff -ge 0) { "+" } else { "" }
    $color = if ($diff -ge 0) { "Yellow" } else { "Green" }
    Write-Host ("  {0,-28}  {1}{2}s ({1}{3}%)" -f "Delta (Docker - Native)", $sign, $diff, $pct) -ForegroundColor $color
}

# ============================================================
# MAIN
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Startup Comparison: Docker vs Native" -ForegroundColor Cyan
Write-Host "  Children    : $ChildCount" -ForegroundColor Cyan
Write-Host "  Runs/mode   : $Runs" -ForegroundColor Cyan
Write-Host "  Timeout     : ${Timeout}s" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$docker = @{ Main = @(); FirstChild = @(); AllReady = @() }
$native = @{ Main = @(); FirstChild = @(); AllReady = @() }

# --- Docker ---
if (-not $NativeOnly) {
    Write-Host "────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  DOCKER  (image: $Image)" -ForegroundColor Yellow
    Write-Host "────────────────────────────────────────" -ForegroundColor DarkGray
    $docker = Run-DockerTimings
    Write-Host ""
}

# --- Native ---
if (-not $DockerOnly) {
    Write-Host "────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  NATIVE" -ForegroundColor Yellow
    Write-Host "────────────────────────────────────────" -ForegroundColor DarkGray
    $native = Run-NativeTimings
    Write-Host ""
}

# -------------------------------------------------------
# Side-by-side comparison
# -------------------------------------------------------
$dMain  = Get-Stats $docker.Main
$dFirst = Get-Stats $docker.FirstChild
$dAll   = Get-Stats $docker.AllReady
$nMain  = Get-Stats $native.Main
$nFirst = Get-Stats $native.FirstChild
$nAll   = Get-Stats $native.AllReady

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  COMPARISON  ($Runs runs, $ChildCount children)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Write-Host ""
Write-Host "  Proxy ready (healthcheck):" -ForegroundColor White
Write-Host (Format-Row "Docker" $dMain)
Write-Host (Format-Row "Native" $nMain)
Format-Delta $dMain $nMain

Write-Host ""
Write-Host "  First child ready:" -ForegroundColor White
Write-Host (Format-Row "Docker" $dFirst)
Write-Host (Format-Row "Native" $nFirst)
Format-Delta $dFirst $nFirst

Write-Host ""
Write-Host "  All $ChildCount children ready (production-ready):" -ForegroundColor White
Write-Host (Format-Row "Docker" $dAll)
Write-Host (Format-Row "Native" $nAll)
Format-Delta $dAll $nAll

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
