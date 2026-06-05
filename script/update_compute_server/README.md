# Rhino.Compute Server — Setup & Update (Selva fork)

Runs the custom **`8.x.selva`** branch from `VektorNode/compute.rhino3d` on Windows Server.

## What runs on the box

- **rhino.compute** — HTTP front-end
- **compute.geometry** — the geometry worker (needs Rhino installed)
- Served by IIS site `Rhino.Compute` (app pool `RhinoComputeAppPool`) from
  `C:\inetpub\wwwroot\aspnet_client\system_web\4_0_30319\`

## First-time setup (once)

Elevated PowerShell on a **Windows Server** box:

```powershell
git clone https://github.com/VektorNode/compute.rhino3d.git
cd compute.rhino3d; git checkout 8.x.selva
Set-ExecutionPolicy Bypass -Scope Process -Force
& ".\script\production\boostrap_server.ps1"
```

Set your license + key, then reboot:

```powershell
[Environment]::SetEnvironmentVariable('RHINO_TOKEN',        '<token>',      'Machine')
[Environment]::SetEnvironmentVariable('RHINO_COMPUTE_KEY',  '<api-key>',    'Machine')
[Environment]::SetEnvironmentVariable('RHINO_COMPUTE_URLS', 'http://+:80',  'Machine')
```

> The bootstrap installs the upstream `8.x` build. Run the update below once to switch to `8.x.selva`.

## Update to latest Selva build (the routine task)

Elevated PowerShell on the server:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url = "https://raw.githubusercontent.com/VektorNode/compute.rhino3d/8.x.selva/script/update_compute_server/update_compute_selva.ps1"
Invoke-Expression (Invoke-RestMethod -Uri $url)
```

The script downloads the newest `8.x.selva` build, backs up the current one, deploys, restarts IIS, health-checks, and **auto-rolls back if anything fails**.

> Must be **run as Administrator** — `iex` skips the admin check, so it won't warn you if you forget.

## Run it remotely (from your machine)

One-time on the server: `Enable-PSRemoting -Force`. Then:

```powershell
Invoke-Command -ComputerName YOUR-SERVER -Credential (Get-Credential) `
    -FilePath ".\script\update_compute_server\update_compute_selva.ps1"
```

## Reference

| Setting          | Value                                                    |
|------------------|----------------------------------------------------------|
| Web root         | `C:\inetpub\wwwroot\aspnet_client\system_web\4_0_30319`  |
| IIS site / pool  | `Rhino.Compute` / `RhinoComputeAppPool`                  |
| Branch           | `8.x.selva`                                              |
| Backups          | `C:\RhinoComputeBackups\` (last 5)                       |
| Logs             | `C:\Logs\RhinoCompute\`                                  |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Could not create SSL/TLS secure channel` | Run the `Tls12` line first |
| Fails on `takeown`/`icacls` | PowerShell wasn't elevated — re-launch as Admin |
| `Unable to find a build artifact` | No recent CI build on `8.x.selva` — check the Actions tab |
| `404` on the raw URL | Repo is private — use a GitHub token |
| `executable not found` | Run the first-time setup first; update only updates an existing install |
| Broke after update | Auto-rolled back; previous build is in `C:\RhinoComputeBackups\` |

Every run logs to `C:\Logs\RhinoCompute\` — look there first.
