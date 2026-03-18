# Rhino.Compute (x9 Branch) - Docker Setup

Automated Docker setup for running Rhino.Compute from the x9 branch on Linux.

## Quick Start

### 1. Build the image (one time)

Open PowerShell, **navigate to this `setup` folder**, and run:

```powershell
cd D:\Coding\compute.rhino3d\setup
docker build -t rhino-compute-x9 .
```

> ⚠️ **Important:** run the build from inside the `setup` folder.
> If you run it from the repo root, Docker picks up the old Windows-based
> Dockerfile there instead, and the build will fail.

Alternatively, from the repo root:

```powershell
docker build -t rhino-compute-x9 -f setup/Dockerfile setup
```

If the repo URL in the Dockerfile needs to be changed:

```powershell
docker build -t rhino-compute-x9 `
  --build-arg REPO_URL=https://your-repo-url.git `
  --build-arg BRANCH=x9 .
```

This takes a few minutes the first time. Everything is installed and built automatically.

### 2. Run it

**With a token (required for actual computations):**

```powershell
docker run -p 6500:6500 -e RHINO_TOKEN=your-token-here rhino-compute-x9
```

**Without a token (server starts but computations will fail):**

```powershell
docker run -p 6500:6500 rhino-compute-x9
```

The server listens on `http://localhost:6500` from your Windows machine.

### 3. Connect from your app or Grasshopper

- **From a local app (TypeScript, Python, etc.):** connect to `http://localhost:6500`
- **From Grasshopper/Hops:** set the server to `http://localhost:6500` and the API key to your RHINO_TOKEN value

## Important: File URLs Inside Docker

When your app sends a Grasshopper definition URL to the server, that URL must be
reachable **from inside the container**, not just from Windows.

| From Windows                       | From inside Docker                        |
| ---------------------------------- | ----------------------------------------- |
| `http://localhost:5500`            | Does NOT work (localhost = the container) |
| `http://127.0.0.1:5500`            | Does NOT work (same reason)               |
| `http://host.docker.internal:5500` | WORKS (resolves to your Windows host)     |

So if you are serving .gh files via Live Server on port 5500, use:

```
http://host.docker.internal:5500/path/to/your/definition.gh
```

## Ports

| Port | Purpose                   | Accessible from host?  |
| ---- | ------------------------- | ---------------------- |
| 6500 | Main rhino.compute server | Yes (via -p 6500:6500) |
| 6001 | Child compute.geometry    | No (internal only)     |

The main server on 6500 is bound to `0.0.0.0` so it is reachable from outside
the container. The child process on 6001 stays on localhost inside the container
and is only used internally by the main server.

## Useful Commands

**Stop the server:**

Press `Ctrl+C` in the terminal where it is running, or from another PowerShell:

```powershell
docker ps                        # find the container ID
docker stop <container_id>
```

**Open a shell inside a running container:**

```powershell
docker ps                        # find the container ID
docker exec -it $(docker ps -q --filter ancestor=rhino-compute-x9) /bin/bash
```

**View logs of a running container:**

```powershell
docker logs -f <container_id>
```

**Rebuild after Dockerfile changes:**

```powershell
docker build -t rhino-compute-x9 .
```

**Save container state (if you made changes inside and want to keep them):**

```powershell
docker ps                        # find the container ID
docker commit <container_id> rhino-compute-x9-custom
```

## Development Workflow

If you want to edit the source code on Windows and build inside the container,
mount a local clone as a volume.

### Step 1: Clone on Windows

```powershell
cd C:\Projects
git clone <REPO_URL> rhino-compute-src
cd rhino-compute-src
git checkout x9
```

### Step 2: Run with volume mount

```powershell
docker run -it -p 6500:6500 `
  -e RHINO_TOKEN=your-token-here `
  -v "C:\Projects\rhino-compute-src:/home/rhino-compute-src" `
  rhino-compute-x9 /bin/bash
```

### Step 3: Build and run inside the container

```bash
cd /home/rhino-compute-src/src
dotnet build compute.sln -c Release
dotnet run --project rhino.compute --configuration Release --no-build -- --urls http://0.0.0.0:6500 --childcount 1 --spawn-on-startup
```

Edit files in VS Code on Windows, build and run inside the container. Changes
are reflected immediately because the volume mount keeps them in sync.

## Troubleshooting

**"Connection refused" from Windows:**
The server might be listening on localhost inside the container instead of
0.0.0.0. Make sure you are using the start.sh script or passing
`--urls http://0.0.0.0:6500` when running manually.

**Computations fail with PAL_SEHException:**
Most likely the RHINO_TOKEN is not set. Restart with
`-e RHINO_TOKEN=your-token-here`.

**Build fails with NuGet errors:**
The Dockerfile already creates a clean NuGet.Config. If you still get errors,
try `dotnet restore compute.sln` before building.

**Port already in use:**
Change the host port: `-p 7000:6500` and connect to `http://localhost:7000`.

**Git Bash mangles paths:**
Use PowerShell instead, or prefix paths with double slashes in Git Bash
(e.g. `//bin/bash` instead of `/bin/bash`).

**Container disappears after exit:**
If you used `docker run` without removing `--rm` from the command, the container
is deleted on exit. Either drop `--rm` or use `docker commit` to save the state
before exiting.

**"host.docker.internal" not resolving:**
This hostname is specific to Docker Desktop. If you are using Docker Engine on
bare Linux, use the host machine's actual IP address instead.

## Questions?

Contact luis@mcneel.com for issues with the Rhino.Compute Linux project.
