# Fork changes — Vektornode / Selva vs. upstream `compute.rhino3d`

This is a **fork** of McNeel's [compute.rhino3d](https://github.com/mcneel/compute.rhino3d).
Every divergence from upstream is tagged in source with a `VEKTORNODE:` comment so it can be
found by grep, and listed here so the whole delta is visible in one place.

> **Find every change in source:**
> ```
> grep -rn "VEKTORNODE" src/
> ```
> Block-level changes are wrapped in banners:
> ```
> // ── BEGIN VEKTORNODE: SELVA FIX — <topic> ──
> ...
> // ── END   VEKTORNODE: SELVA FIX — <topic> ──
> ```

Tags used:
- **SELVA** — behavior/feature added for the Selva product.
- **SELVA FIX** — a bug fix relative to upstream (wrapped in BEGIN/END banners).
- **PARAM-ID** — threads the source Grasshopper parameter's Instance Guid through the IO model.
- **IO-HANDLERS** — extra input/output type handlers + schema metadata not in upstream.

---

## Changes

### 1. Contextual-geometry struct deserialization (SELVA FIX)
**File:** `src/compute.geometry/GrasshopperDefinition.cs` — `DeserializeGeometry` + `TryDeserializeStruct`
**Branch:** `fix/contextual-geometry-struct-deserialization`

Upstream `DeserializeGeometry` assumed geometry inputs always arrive as a Rhino **archive**
dictionary (`{version, archive3dm, ...}`) and called `CommonObject.FromJSON` only. But struct
geometry — **Circle, Arc, Line** — has no archive form; our own output serializer emits it as
**property JSON** (`{"Radius":…,"Plane":…,…}`), which `FromJSON` cannot rehydrate → it returned
null → zero geometry / failed solve (e.g. a `Get Geometry` input fed a Circle).

Fix: try the archive shape first, then fall back to coercing known curve-like structs to a
`Curve` (`Circle`/`Arc` → `ArcCurve`, `Line` → `LineCurve`). Mirrors the existing
`DeserializeCurve` try-then-fallback pattern. **Input-side only** — the output serializer is
left unchanged so consumers that already parse the struct property JSON keep working.
To cover more structs later (Rectangle3d, Box, …) add a line in `DeserializeGeometry`.

### 2. Multipart proxy passthrough (SELVA FIX)
**File:** `src/rhino.compute/ReverseProxy.cs` (~L312)

Upstream read every POST body as a string and re-sent it as `application/json`, destroying the
multipart boundary — so `grasshopper/validate` and other file uploads broke behind IIS. Fix:
detect `multipart/form-data` and stream the body through as-is, preserving boundary + binary
content and forwarding `Content-Length`.

### 3. Schema-extraction endpoints (SELVA)
**Files:** `src/compute.geometry/FixedEndpoints.cs` (~L27), `src/compute.geometry/GrasshopperValidationHelper.cs` (entire file)

Adds the `grasshopper/schema` family of endpoints (definition IO + validation) used by Selva to
introspect a definition's inputs/outputs. Not present in upstream/8.x.

### 4. Headless doc creation default ON (SELVA)
**File:** `src/compute.geometry/Config.cs` (~L110)

Default for headless Rhino document creation flipped to **on** (upstream default is `false`).

### 5. Parameter-Id threading (PARAM-ID)
**Files:** `src/compute.geometry/GrasshopperDefinition.cs` (~L625), `src/compute.geometry/IO/Schema.cs` (L68, L131)

Every emitted `ResthopperObject` is tagged with its source Grasshopper parameter's Instance Guid
(`ResthopperObject.Id` / `IoParamSchema.Id`) so the client can demux outputs by parameter.

### 6. Extra IO handlers + metadata (IO-HANDLERS)
**Files:** `src/compute.geometry/GrasshopperDefinition.cs` (~L719, Color output), `src/compute.geometry/IO/Schema.cs` (L84)

Additional output type handler(s) (e.g. Color) and extra input metadata (UI grouping +
enumerated values) carried on the schema. Not in upstream/8.x.

### 7. Selva serializable-goo SDK seam (SELVA)
**File:** `src/compute.geometry/GrasshopperDefinition.cs` (~L641, and a DEPRECATED block ~L659)

Any Goo implementing `ISelvaSerializableGoo` (matched by interface name) owns its own wire
format. The block at ~L659 is marked **DEPRECATED — delete in a future major** (legacy
serialization of older Selva output Goos).

---

_Keep this file in sync: when you add or remove a `VEKTORNODE:` marker in source, update the list above._
