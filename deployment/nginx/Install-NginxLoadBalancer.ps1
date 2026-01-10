<#
.SYNOPSIS
    Installs and configures NGINX as a load balancer for Rhino Compute.

.DESCRIPTION
    Downloads and sets up NGINX for Windows as a load balancer.
    Configures it as a Windows Service for automatic startup.

.PARAMETER InstallPath
    Where to install NGINX. Default: C:\nginx

.PARAMETER BackendServers
    Array of backend compute servers in format "ip:port". Example: @("192.168.1.10:5000","192.168.1.11:5000")

.PARAMETER ListenPort
    Port for NGINX to listen on. Default: 80

.EXAMPLE
    .\Install-NginxLoadBalancer.ps1 -BackendServers @("192.168.1.10:5000","192.168.1.11:5000")
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$InstallPath = "C:\nginx",

    [Parameter(Mandatory = $true)]
    [string[]]$BackendServers,

    [Parameter(Mandatory = $false)]
    [int]$ListenPort = 80
)

$ErrorActionPreference = "Stop"

Write-Host "=== NGINX Load Balancer Installation ===" -ForegroundColor Cyan
Write-Host ""

# Check if running as Administrator
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator!"
    exit 1
}

# 1. Download NGINX
Write-Host "[1/5] Downloading NGINX..." -ForegroundColor Yellow
$nginxVersion = "1.24.0"  # Update to latest stable version as needed
$nginxUrl = "http://nginx.org/download/nginx-$nginxVersion.zip"
$nginxZip = "$env:TEMP\nginx.zip"

Invoke-WebRequest -Uri $nginxUrl -OutFile $nginxZip
Write-Host "  ✓ Downloaded NGINX $nginxVersion" -ForegroundColor Green

# 2. Extract NGINX
Write-Host "[2/5] Extracting NGINX..." -ForegroundColor Yellow
if (Test-Path $InstallPath) {
    Write-Host "  ! Install path exists, will be overwritten" -ForegroundColor Yellow
    # Stop service if running
    $nginxService = Get-Service -Name "nginx" -ErrorAction SilentlyContinue
    if ($nginxService) {
        Stop-Service -Name "nginx" -Force
        & "$InstallPath\nssm.exe" remove nginx confirm 2>$null
    }
    Remove-Item -Path $InstallPath -Recurse -Force
}

Expand-Archive -Path $nginxZip -DestinationPath "$env:TEMP\nginx" -Force
Move-Item -Path "$env:TEMP\nginx\nginx-$nginxVersion" -Destination $InstallPath
Remove-Item -Path $nginxZip, "$env:TEMP\nginx" -Recurse -Force
Write-Host "  ✓ Extracted to $InstallPath" -ForegroundColor Green

# 3. Configure NGINX
Write-Host "[3/5] Configuring NGINX..." -ForegroundColor Yellow

# Build upstream server list
$upstreamConfig = ""
foreach ($server in $BackendServers) {
    $upstreamConfig += "        server $server max_fails=3 fail_timeout=30s weight=1;`n"
}

# Read the template config from the same directory as this script
$configTemplate = Get-Content -Path "$PSScriptRoot\nginx.conf" -Raw

# Replace the upstream servers section
$configTemplate = $configTemplate -replace '#BACKEND_SERVERS_PLACEHOLDER', $upstreamConfig.TrimEnd()

# Replace listen port if not 80
if ($ListenPort -ne 80) {
    $configTemplate = $configTemplate -replace 'listen 80;', "listen $ListenPort;"
}

# Write config
$configPath = "$InstallPath\conf\nginx.conf"
Set-Content -Path $configPath -Value $configTemplate -Force

Write-Host "  ✓ Configuration written to $configPath" -ForegroundColor Green
Write-Host "  Backend servers:" -ForegroundColor Gray
foreach ($server in $BackendServers) {
    Write-Host "    - $server" -ForegroundColor Gray
}

# 4. Test configuration
Write-Host "[4/5] Testing NGINX configuration..." -ForegroundColor Yellow
$testResult = & "$InstallPath\nginx.exe" -t -c "$configPath" 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Configuration is valid" -ForegroundColor Green
}
else {
    Write-Error "Configuration test failed: $testResult"
    exit 1
}

# 5. Install as Windows Service
Write-Host "[5/5] Installing as Windows Service..." -ForegroundColor Yellow

# Download NSSM
$nssmPath = "$InstallPath\nssm.exe"
if (-not (Test-Path $nssmPath)) {
    Write-Host "  Downloading NSSM..." -ForegroundColor Yellow
    $nssmZip = "$env:TEMP\nssm.zip"
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip
    Expand-Archive -Path $nssmZip -DestinationPath "$env:TEMP\nssm" -Force
    Copy-Item -Path "$env:TEMP\nssm\nssm-2.24\win64\nssm.exe" -Destination $nssmPath
    Remove-Item -Path $nssmZip, "$env:TEMP\nssm" -Recurse -Force
}

# Install service
$nginxExe = Join-Path $InstallPath "nginx.exe"
& $nssmPath install nginx $nginxExe
& $nssmPath set nginx AppDirectory $InstallPath
& $nssmPath set nginx DisplayName "NGINX Load Balancer"
& $nssmPath set nginx Description "NGINX load balancer for Rhino Compute servers"
& $nssmPath set nginx Start SERVICE_AUTO_START
& $nssmPath set nginx AppStdout "$InstallPath\logs\service-stdout.log"
& $nssmPath set nginx AppStderr "$InstallPath\logs\service-stderr.log"

Write-Host "  ✓ Service 'nginx' installed" -ForegroundColor Green

# Configure firewall
Write-Host "  Configuring firewall..." -ForegroundColor Yellow
$firewallRule = Get-NetFirewallRule -DisplayName "NGINX Load Balancer" -ErrorAction SilentlyContinue
if ($firewallRule) {
    Remove-NetFirewallRule -DisplayName "NGINX Load Balancer"
}
New-NetFirewallRule -DisplayName "NGINX Load Balancer" -Direction Inbound -Protocol TCP -LocalPort $ListenPort -Action Allow | Out-Null
Write-Host "  ✓ Firewall rule created for port $ListenPort" -ForegroundColor Green

# Start the service
Write-Host ""
Write-Host "Starting NGINX service..." -ForegroundColor Yellow
Start-Service -Name "nginx"
Start-Sleep -Seconds 3

$service = Get-Service -Name "nginx"
if ($service.Status -eq "Running") {
    Write-Host "  ✓ NGINX started successfully!" -ForegroundColor Green
}
else {
    Write-Warning "Service is not running. Status: $($service.Status)"
    Write-Host "Check logs at: $InstallPath\logs" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "NGINX is now running on: http://localhost:$ListenPort" -ForegroundColor Green
Write-Host "Configuration: $configPath" -ForegroundColor Gray
Write-Host "Logs: $InstallPath\logs" -ForegroundColor Gray
Write-Host ""
Write-Host "Service Management:" -ForegroundColor Yellow
Write-Host "  Start:   Start-Service nginx" -ForegroundColor Gray
Write-Host "  Stop:    Stop-Service nginx" -ForegroundColor Gray
Write-Host "  Restart: Restart-Service nginx" -ForegroundColor Gray
Write-Host "  Reload:  & '$InstallPath\nginx.exe' -s reload" -ForegroundColor Gray
Write-Host ""
Write-Host "Testing:" -ForegroundColor Yellow
Write-Host "  Health:  http://localhost:$ListenPort/healthcheck/ready" -ForegroundColor Gray
Write-Host "  Status:  http://localhost:$ListenPort/nginx_status" -ForegroundColor Gray
Write-Host ""
