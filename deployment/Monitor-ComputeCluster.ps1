<#
.SYNOPSIS
    Monitors Rhino Compute cluster health and sends alerts.

.DESCRIPTION
    Continuously monitors compute servers for:
    - Service status (running/stopped)
    - Health endpoint responsiveness
    - CPU and memory usage
    - Crash/restart events
    - Log errors
    Can send email alerts or write to event log.

.PARAMETER ServerList
    Array of server hostnames/IPs to monitor. Can also be a file path.

.PARAMETER CheckIntervalSeconds
    How often to check health. Default: 60 seconds

.PARAMETER EmailAlert
    Enable email alerts (requires SMTP configuration)

.PARAMETER SmtpServer
    SMTP server for email alerts

.PARAMETER EmailFrom
    From email address

.PARAMETER EmailTo
    To email address(es)

.PARAMETER LogToEventLog
    Write alerts to Windows Event Log

.PARAMETER Credential
    PSCredential for remote servers

.EXAMPLE
    .\Monitor-ComputeCluster.ps1 -ServerList "compute1","compute2","compute3" -CheckIntervalSeconds 30

.EXAMPLE
    .\Monitor-ComputeCluster.ps1 -ServerList "servers.txt" -EmailAlert -SmtpServer "smtp.gmail.com" -EmailFrom "alerts@company.com" -EmailTo "admin@company.com"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$ServerList,

    [Parameter(Mandatory = $false)]
    [int]$CheckIntervalSeconds = 60,

    [Parameter(Mandatory = $false)]
    [int]$Port = 5000,

    [Parameter(Mandatory = $false)]
    [switch]$EmailAlert,

    [Parameter(Mandatory = $false)]
    [string]$SmtpServer,

    [Parameter(Mandatory = $false)]
    [string]$EmailFrom,

    [Parameter(Mandatory = $false)]
    [string[]]$EmailTo,

    [Parameter(Mandatory = $false)]
    [switch]$LogToEventLog,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential
)

$ErrorActionPreference = "Continue"

Write-Host "=== Rhino Compute Cluster Monitor ===" -ForegroundColor Cyan
Write-Host ""

# Parse server list
$servers = @()
if ($ServerList.Count -eq 1 -and (Test-Path $ServerList[0])) {
    $servers = Get-Content $ServerList[0] | Where-Object { $_.Trim() -ne "" }
}
else {
    $servers = $ServerList
}

Write-Host "Monitoring $($servers.Count) servers:" -ForegroundColor Yellow
$servers | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
Write-Host "Check interval: $CheckIntervalSeconds seconds" -ForegroundColor Gray
Write-Host ""

# Validate email settings if enabled
if ($EmailAlert) {
    if (-not $SmtpServer -or -not $EmailFrom -or -not $EmailTo) {
        Write-Error "Email alerts enabled but SMTP settings missing!"
        exit 1
    }
    Write-Host "Email alerts enabled: $EmailFrom -> $($EmailTo -join ', ')" -ForegroundColor Green
}

# Create event log source if needed
if ($LogToEventLog) {
    if (-not [System.Diagnostics.EventLog]::SourceExists("RhinoComputeMonitor")) {
        New-EventLog -LogName Application -Source "RhinoComputeMonitor"
    }
    Write-Host "Event log enabled: Application/RhinoComputeMonitor" -ForegroundColor Green
}

# Prompt for credentials if not provided
if ($Credential -eq $null -and $servers[0] -ne "localhost") {
    $Credential = Get-Credential -Message "Enter credentials for remote servers"
}

# State tracking
$serverStates = @{}
foreach ($server in $servers) {
    $serverStates[$server] = @{
        LastHealthy         = $null
        ConsecutiveFailures = 0
        LastRestartTime     = $null
        TotalRestarts       = 0
    }
}

# Function to send alert
function Send-Alert {
    param(
        [string]$Subject,
        [string]$Message,
        [string]$Severity = "Warning"  # Information, Warning, Error
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $fullMessage = "[$timestamp] $Message"

    # Console output
    $color = switch ($Severity) {
        "Information" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        default { "White" }
    }
    Write-Host $fullMessage -ForegroundColor $color

    # Email alert
    if ($EmailAlert) {
        try {
            Send-MailMessage -From $EmailFrom -To $EmailTo -Subject "[$Severity] $Subject" `
                -Body $fullMessage -SmtpServer $SmtpServer -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host "Failed to send email: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # Event log
    if ($LogToEventLog) {
        $eventType = switch ($Severity) {
            "Information" { "Information" }
            "Warning" { "Warning" }
            "Error" { "Error" }
            default { "Information" }
        }
        Write-EventLog -LogName Application -Source "RhinoComputeMonitor" `
            -EntryType $eventType -EventId 1000 -Message $fullMessage -ErrorAction SilentlyContinue
    }
}

# Function to check server health
function Test-ComputeServer {
    param([string]$Server)

    $result = @{
        ServiceRunning  = $false
        HealthEndpoint  = $false
        CpuUsage        = 0
        MemoryUsageMB   = 0
        RestartDetected = $false
        Errors          = @()
    }

    try {
        # Check if server is reachable
        $ping = Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction SilentlyContinue
        if (-not $ping) {
            $result.Errors += "Server unreachable"
            return $result
        }

        # Check service status
        if ($Server -eq "localhost") {
            $service = Get-Service -Name "RhinoCompute" -ErrorAction SilentlyContinue
        }
        else {
            $service = Invoke-Command -ComputerName $Server -Credential $Credential -ScriptBlock {
                Get-Service -Name "RhinoCompute" -ErrorAction SilentlyContinue
            } -ErrorAction SilentlyContinue
        }

        if ($service) {
            $result.ServiceRunning = ($service.Status -eq "Running")
            if (-not $result.ServiceRunning) {
                $result.Errors += "Service is $($service.Status)"
            }
        }
        else {
            $result.Errors += "Service not found"
        }

        # Check health endpoint
        try {
            $healthResponse = Invoke-WebRequest -Uri "http://${Server}:${Port}/healthcheck/ready" `
                -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            $result.HealthEndpoint = ($healthResponse.StatusCode -eq 200)
        }
        catch {
            $result.Errors += "Health endpoint failed: $($_.Exception.Message)"
        }

        # Get process stats
        if ($result.ServiceRunning) {
            if ($Server -eq "localhost") {
                $process = Get-Process -Name "rhino.compute" -ErrorAction SilentlyContinue
            }
            else {
                $process = Invoke-Command -ComputerName $Server -Credential $Credential -ScriptBlock {
                    Get-Process -Name "rhino.compute" -ErrorAction SilentlyContinue |
                    Select-Object CPU, WorkingSet64, StartTime
                } -ErrorAction SilentlyContinue
            }

            if ($process) {
                $result.CpuUsage = [math]::Round($process.CPU, 2)
                $result.MemoryUsageMB = [math]::Round($process.WorkingSet64 / 1MB, 2)

                # Check for restart (compare start time)
                $currentStartTime = $process.StartTime
                if ($serverStates[$Server].LastRestartTime -and
                    $currentStartTime -ne $serverStates[$Server].LastRestartTime) {
                    $result.RestartDetected = $true
                    $serverStates[$Server].TotalRestarts++
                }
                $serverStates[$Server].LastRestartTime = $currentStartTime
            }
        }

    }
    catch {
        $result.Errors += "Check failed: $($_.Exception.Message)"
    }

    return $result
}

# Main monitoring loop
Write-Host "Starting monitoring... (Press Ctrl+C to stop)" -ForegroundColor Cyan
Write-Host ""

$iteration = 0
while ($true) {
    $iteration++
    $timestamp = Get-Date -Format "HH:mm:ss"

    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    Write-Host "Check #$iteration at $timestamp" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray

    foreach ($server in $servers) {
        $result = Test-ComputeServer -Server $server
        $state = $serverStates[$server]

        # Determine overall health
        $isHealthy = $result.ServiceRunning -and $result.HealthEndpoint

        if ($isHealthy) {
            # Server is healthy
            if ($state.ConsecutiveFailures -gt 0) {
                # Recovery from failure
                Send-Alert -Subject "Server Recovered: $server" `
                    -Message "Server $server has recovered after $($state.ConsecutiveFailures) failures" `
                    -Severity "Information"
            }

            $state.ConsecutiveFailures = 0
            $state.LastHealthy = Get-Date

            # Check for restart
            if ($result.RestartDetected) {
                Send-Alert -Subject "Server Restarted: $server" `
                    -Message "Server $server restarted (Total restarts: $($state.TotalRestarts))" `
                    -Severity "Warning"
            }

            # Status output
            Write-Host "  $server : " -NoNewline -ForegroundColor Gray
            Write-Host "✓ Healthy" -NoNewline -ForegroundColor Green
            Write-Host " | CPU: $($result.CpuUsage)% | RAM: $($result.MemoryUsageMB) MB" -ForegroundColor Gray

        }
        else {
            # Server has issues
            $state.ConsecutiveFailures++

            # Alert on first failure and every 5 failures
            if ($state.ConsecutiveFailures -eq 1 -or $state.ConsecutiveFailures % 5 -eq 0) {
                $errorMsg = $result.Errors -join "; "
                Send-Alert -Subject "Server Unhealthy: $server" `
                    -Message "Server $server is unhealthy (Failure #$($state.ConsecutiveFailures)): $errorMsg" `
                    -Severity "Error"
            }

            Write-Host "  $server : " -NoNewline -ForegroundColor Gray
            Write-Host "✗ Unhealthy" -NoNewline -ForegroundColor Red
            Write-Host " (Failures: $($state.ConsecutiveFailures))" -ForegroundColor Red
            foreach ($errorMsg in $result.Errors) {
                Write-Host "    - $errorMsg" -ForegroundColor Red
            }
        }
    }

    Write-Host ""
    Start-Sleep -Seconds $CheckIntervalSeconds
}
