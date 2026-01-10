<#
.SYNOPSIS
    Installs Rhino Compute on a fresh Windows Server as a Windows Service.

.DESCRIPTION
    This script automates the complete setup of a Rhino Compute server:
    - Installs .NET 8 Runtime (if needed)
    - Installs Rhino 8 (if needed)
    - Deploys rhino.compute binaries
    - Configures as Windows Service using NSSM
    - Sets up firewall rules
    - Configures environment variables

.PARAMETER RhinoInstallerPath
    Path to Rhino installer .exe file. If not provided, must be installed manually first.

.PARAMETER ComputeBinariesPath
    Path to compiled rhino.compute binaries. Default: ..\src\dist\rhino.compute

.PARAMETER InstallPath
    Where to install compute on the server. Default: C:\RhinoCompute

.PARAMETER Port
    Port for Rhino Compute to listen on. Default: 5000

.PARAMETER ChildCount
    Number of compute.geometry child processes. Default: 4

.PARAMETER ApiKey
    Optional API key for authentication

.EXAMPLE
    .\Install-ComputeServer.ps1 -RhinoInstallerPath "C:\Downloads\rhino_8_installer.exe"

.EXAMPLE
    .\Install-ComputeServer.ps1 -Port 8080 -ChildCount 8 -ApiKey "my-secret-key"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$RhinoInstallerPath,

    [Parameter(Mandatory=$false)]
    [string]$ComputeBinariesPath = "..\src\dist\rhino.compute",

    [Parameter(Mandatory=$false)]
    [string]$InstallPath = "C:\RhinoCompute",

    [Parameter(Mandatory=$false)]
    [int]$Port = 5000,

    [Parameter(Mandatory=$false)]
    [int]$ChildCount = 4,

    [Parameter(Mandatory=$false)]
    [string]$ApiKey = ""
)

$ErrorActionPreference = "Stop"

Write-Host "=== Rhino Compute Server Installation ===" -ForegroundColor Cyan
Write-Host ""

# Check if running as Administrator
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator!"
    exit 1
}

# 1. Check .NET 8 Runtime
Write-Host "[1/7] Checking .NET 8 Runtime..." -ForegroundColor Yellow
try {
    $dotnetVersion = dotnet --version 2>$null
    if ($dotnetVersion -and $dotnetVersion.StartsWith("8.")) {
        Write-Host "  ✓ .NET 8 Runtime found: $dotnetVersion" -ForegroundColor Green
    } else {
        throw "Wrong version"
    }
} catch {
    Write-Host "  Installing .NET 8 Runtime..." -ForegroundColor Yellow
    $dotnetUrl = "https://download.visualstudio.microsoft.com/download/pr/3a2e7a7c-5c7f-4e9d-89e5-f7b3f2b3f935/8b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b/windowsdesktop-runtime-8.0.0-win-x64.exe"
    $dotnetInstaller = "$env:TEMP\dotnet-runtime-8.exe"

    Invoke-WebRequest -Uri $dotnetUrl -OutFile $dotnetInstaller
    Start-Process -FilePath $dotnetInstaller -ArgumentList "/quiet", "/norestart" -Wait
    Remove-Item $dotnetInstaller

    Write-Host "  ✓ .NET 8 Runtime installed" -ForegroundColor Green
}

# 2. Check Rhino Installation
Write-Host "[2/7] Checking Rhino 8 installation..." -ForegroundColor Yellow
$rhinoPath = "C:\Program Files\Rhino 8\System\Rhino.exe"
if (Test-Path $rhinoPath) {
    Write-Host "  ✓ Rhino 8 found at: $rhinoPath" -ForegroundColor Green
} else {
    if ($RhinoInstallerPath -and (Test-Path $RhinoInstallerPath)) {
        Write-Host "  Installing Rhino 8..." -ForegroundColor Yellow
        Start-Process -FilePath $RhinoInstallerPath -ArgumentList "/quiet", "/norestart" -Wait
        Write-Host "  ✓ Rhino 8 installed" -ForegroundColor Green
    } else {
        Write-Error "Rhino 8 not found! Please install Rhino 8 manually or provide -RhinoInstallerPath parameter."
        exit 1
    }
}

# 3. Create Installation Directory
Write-Host "[3/7] Creating installation directory..." -ForegroundColor Yellow
if (Test-Path $InstallPath) {
    Write-Host "  ! Directory exists, will be overwritten" -ForegroundColor Yellow
    Remove-Item -Path $InstallPath -Recurse -Force
}
New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
Write-Host "  ✓ Created: $InstallPath" -ForegroundColor Green

# 4. Copy Binaries
Write-Host "[4/7] Copying compute binaries..." -ForegroundColor Yellow
$binariesFullPath = Resolve-Path $ComputeBinariesPath -ErrorAction Stop
if (-not (Test-Path $binariesFullPath)) {
    Write-Error "Compute binaries not found at: $binariesFullPath. Please build the project first!"
    exit 1
}

Copy-Item -Path "$binariesFullPath\*" -Destination $InstallPath -Recurse -Force
Write-Host "  ✓ Binaries copied to $InstallPath" -ForegroundColor Green

# 5. Configure Environment Variables
Write-Host "[5/7] Configuring environment variables..." -ForegroundColor Yellow
$envVars = @{
    "RHINO_COMPUTE_URLS" = "http://localhost:$Port"
    "RHINO_COMPUTE_LOG_PATH" = "$InstallPath\logs"
    "RHINO_COMPUTE_LOG_RETAIN_DAYS" = "10"
}

if ($ApiKey) {
    $envVars["RHINO_COMPUTE_KEY"] = $ApiKey
}

foreach ($key in $envVars.Keys) {
    [System.Environment]::SetEnvironmentVariable($key, $envVars[$key], [System.EnvironmentVariableTarget]::Machine)
    Write-Host "  Set: $key = $($envVars[$key])" -ForegroundColor Gray
}
Write-Host "  ✓ Environment variables configured" -ForegroundColor Green

# 6. Install as Windows Service using NSSM
Write-Host "[6/7] Installing Windows Service..." -ForegroundColor Yellow

# Download NSSM if not present
$nssmPath = "$InstallPath\nssm.exe"
if (-not (Test-Path $nssmPath)) {
    Write-Host "  Downloading NSSM (Non-Sucking Service Manager)..." -ForegroundColor Yellow
    $nssmZip = "$env:TEMP\nssm.zip"
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip
    Expand-Archive -Path $nssmZip -DestinationPath "$env:TEMP\nssm" -Force
    Copy-Item -Path "$env:TEMP\nssm\nssm-2.24\win64\nssm.exe" -Destination $nssmPath
    Remove-Item -Path $nssmZip, "$env:TEMP\nssm" -Recurse -Force
}

# Remove existing service if present
$serviceName = "RhinoCompute"
$existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "  Removing existing service..." -ForegroundColor Yellow
    & $nssmPath stop $serviceName
    & $nssmPath remove $serviceName confirm
}

# Install new service
$computeExe = Join-Path $InstallPath "rhino.compute.exe"
$arguments = "--port $Port --childcount $ChildCount --spawn-on-startup"

& $nssmPath install $serviceName $computeExe $arguments
& $nssmPath set $serviceName AppDirectory $InstallPath
& $nssmPath set $serviceName DisplayName "Rhino Compute Server"
& $nssmPath set $serviceName Description "Rhino Compute geometry server for processing Rhino/Grasshopper tasks"
& $nssmPath set $serviceName Start SERVICE_AUTO_START
& $nssmPath set $serviceName AppStdout "$InstallPath\logs\service-stdout.log"
& $nssmPath set $serviceName AppStderr "$InstallPath\logs\service-stderr.log"

# Crash recovery settings - auto-restart on failure
& $nssmPath set $serviceName AppExit Default Restart
& $nssmPath set $serviceName AppRestartDelay 5000  # Wait 5 seconds before restart
& $nssmPath set $serviceName AppThrottle 10000     # Throttle restarts if failing repeatedly (10 sec)

# Log rotation settings
& $nssmPath set $serviceName AppStdoutCreationDisposition 4  # Append to existing log
& $nssmPath set $serviceName AppStderrCreationDisposition 4  # Append to existing log
& $nssmPath set $serviceName AppRotateFiles 1                # Enable log rotation
& $nssmPath set $serviceName AppRotateOnline 1               # Rotate while service running
& $nssmPath set $serviceName AppRotateSeconds 86400          # Rotate daily (24 hours)
& $nssmPath set $serviceName AppRotateBytes 10485760         # Rotate at 10MB

Write-Host "  ✓ Service 'RhinoCompute' installed" -ForegroundColor Green

# 7. Configure Firewall
Write-Host "[7/7] Configuring Windows Firewall..." -ForegroundColor Yellow
$firewallRule = Get-NetFirewallRule -DisplayName "Rhino Compute" -ErrorAction SilentlyContinue
if ($firewallRule) {
    Remove-NetFirewallRule -DisplayName "Rhino Compute"
}
New-NetFirewallRule -DisplayName "Rhino Compute" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
Write-Host "  ✓ Firewall rule created for port $Port" -ForegroundColor Green

# Start the service
Write-Host ""
Write-Host "Starting Rhino Compute service..." -ForegroundColor Yellow
Start-Service -Name $serviceName
Start-Sleep -Seconds 5

$service = Get-Service -Name $serviceName
if ($service.Status -eq "Running") {
    Write-Host "  ✓ Service started successfully!" -ForegroundColor Green
} else {
    Write-Warning "Service is not running. Status: $($service.Status)"
    Write-Host "Check logs at: $InstallPath\logs" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Rhino Compute is now running on: http://localhost:$Port" -ForegroundColor Green
Write-Host "Installation path: $InstallPath" -ForegroundColor Gray
Write-Host "Logs location: $InstallPath\logs" -ForegroundColor Gray
Write-Host ""
Write-Host "Service Management Commands:" -ForegroundColor Yellow
Write-Host "  Start:   Start-Service RhinoCompute" -ForegroundColor Gray
Write-Host "  Stop:    Stop-Service RhinoCompute" -ForegroundColor Gray
Write-Host "  Restart: Restart-Service RhinoCompute" -ForegroundColor Gray
Write-Host "  Status:  Get-Service RhinoCompute" -ForegroundColor Gray
Write-Host ""
Write-Host "Health check: http://localhost:$Port/healthcheck/ready" -ForegroundColor Gray
Write-Host ""
