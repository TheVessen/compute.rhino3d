# `POST /io` 500 — "duplicate C# 9.0 language" on Rhino Compute

A quick runbook for one specific, recurring failure. If your symptom doesn't
match section 1 exactly, this is the wrong page.

## 1. Symptom

`POST /io` **intermittently** returns HTTP 500. The Rhino.Compute console /
server log shows:

```
System.ArgumentException: An item with the same key has already been added.
Key: C# 9.0 (mcneel.roslyn.csharp)
   at System.Linq.Enumerable.ToDictionary[...]
   at Rhino.Runtime.Code.Languages.LanguageRegistryQuery.WherePasses(LanguageSpec query)
   at ...BaseScriptComponent...AddedToDocument(GH_Document document)
   at compute.geometry.GrasshopperDefinition.Construct(GH_Archive archive)
```

It throws at **parse time** (deserializing a `.gh` that contains a RhinoCode
**Script** component), *before* any solve. "Intermittent" = Compute runs a pool
of workers; some have a clean language registry, some don't, and routing decides
the outcome.

## 2. Why it happens

RhinoCode (the C#/Python "Script" language providers) exists in **two places**:

1. **Inside the Rhino install** — `C:\Program Files\Rhino 8\Plug-ins\RhinoCode`.
   Advances whenever Rhino is serviced/updated.
2. **A per-user compiled cache** — `%USERPROFILE%\.rhinocode\…` for the account
   that runs Compute (`RhinoComputeUser`). Rebuilt **lazily**, not in lockstep
   with the install.

When Rhino is updated but the service account's `.rhinocode` cache is older, the
worker's registry sees **two providers for the same spec**
`C# 9.0 (mcneel.roslyn.csharp)` — one from the fresh install, one from the stale
cache. `ToDictionary` on that spec → duplicate key → throw.

**It is a version skew, not a duplicate install.** There is usually *no* second
RhinoCode _package_ folder — just install-newer-than-cache.

## 3. Find it (read-only, ~1 min)

Open an **Administrator** PowerShell on the Compute server (the compute app pool
runs as `RhinoComputeUser`; a non-elevated session silently reads nothing from
that profile and looks falsely "clean"). Then:

```powershell
# Compare the bundled plugin's date to the service account's cache date.
Get-Item 'C:\Program Files\Rhino 8\Plug-ins\RhinoCode' |
  Select-Object FullName, LastWriteTime
Get-ChildItem 'C:\Users\RhinoComputeUser\.rhinocode' -Recurse -Directory -EA SilentlyContinue |
  Select-Object LastWriteTime, FullName | Sort-Object LastWriteTime
```

**Cache older than the plugin ⇒ this is your bug.** (Example seen 2026-07-13:
plugin `2026-06-25`, cache `2025-11-14`.)

If you also want to rule out a genuine duplicate *package* at two versions, the
parapet repo has a fuller scanner:
`parapet/packages/app/scripts/find-duplicate-rhinocode.ps1`.

## 4. Fix it (clear the stale cache + recycle)

Still in the **Administrator** PowerShell:

```powershell
Import-Module WebAdministration
$pool = (Get-IISAppPool | Where-Object Name -match 'compute|rhino' | Select-Object -First 1).Name

Stop-WebAppPool -Name $pool
Get-Process -EA SilentlyContinue |
  Where-Object ProcessName -match 'compute\.geometry|rhino\.compute' |
  Stop-Process -Force -EA SilentlyContinue     # kill any lingering workers

Copy-Item 'C:\Users\RhinoComputeUser\.rhinocode' 'C:\rhinocode-cache-backup' -Recurse -Force
Remove-Item 'C:\Users\RhinoComputeUser\.rhinocode' -Recurse -Force -EA SilentlyContinue

Start-WebAppPool -Name $pool     # first /io request rebuilds a clean registry
```

The cache rebuilds on the next request, keyed to the current plugin — one
provider, no duplicate key. (Not sure which pool? `iisreset` restarts all of
IIS.)

> **If instead you *did* find two RhinoCode packages at different versions**
> (different paths/versions on the load path), the fix is different: back up and
> delete the **older** package folder, keep the newest, then recycle as above.

## 5. Verify

Right after the recycle, hammer one script-component definition ~20×. 500s
should drop to **zero**. If they creep back, something is re-staling the
cache — look for a scheduled Rhino updater or a plugin that reinstalls an older
RhinoCode on worker start.

## 6. Keep it from recurring

After any Rhino/RhinoCode servicing update, clear `RhinoComputeUser\.rhinocode`
and recycle once so the cache is rebuilt against the new plugin. Keeping Rhino +
the RhinoCode/Grasshopper script plugin on a **matched, current 8.x** build also
avoids the skew (newer builds hardened the registry against duplicates).

---

*App-side note:* the consumer app can't fix the server, but a **retry** on this
specific 500 usually lands on a healthy worker. See `parapet`'s
`compute-retry.ts` (`retryOnPoisonedWorker`) — uptime cover, not a cure.
