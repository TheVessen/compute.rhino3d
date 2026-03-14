# Compute8 Branch Differences from upstream/8.x

## Overview
**Total changes:** 1506 insertions, 379 deletions across 20 files

---

## 1. NEW FILES (Selva-Specific)

### GrasshopperValidationHelper.cs (96 lines)
**Location:** `src/compute.geometry/GrasshopperValidationHelper.cs`

Helper class for validating Grasshopper definition files:
- `ArchiveFromBytes(byte[] byteArray)` - Loads .gh/.ghx files (tries binary then XML format)
- `DocumentFromArchive(GH_Archive archive)` - Extracts GH_Document from archive
- `GetSchemaContextBakeComponents(GH_Document doc)` - Finds "ContextBakeComponent" objects with Schema output
- `GetSchemaParentComponent(GH_Component contextBake)` - Navigates to parent component providing Schema data
- `GetEmbeddedSchema(IGH_DocumentObject obj)` - Extracts embedded schema from UI Builder component
- `SchemaToJson(object schema)` - Converts schema to JSON
- `ErrorResult(string fileName, string message)` - Creates error response objects
- `SuccessResult(string fileName, JArray schemas)` - Creates success response objects

**Purpose:** Validates that Grasshopper definitions are properly configured for Selva use (have Schema, ContextBake, UI Builder components)

---

### update_compute_selva.ps1 (352 lines)
**Location:** `src/compute.geometry/update_compute_server/update_compute_selva.ps1`

PowerShell deployment script for Selva-specific compute installation:
- Downloads compute binaries
- Extracts to installation directory
- Configures Windows service
- Manages service startup/stopping
- Handles path configuration

---

## 2. MODIFIED FILES

### GrasshopperDefinition.cs (890 lines, ~280+ insertions)

**Major additions:**

#### a) Contextual Parameter Support
Handles IGH_ContextualParameter objects with support for:
- Boolean type support
- Number type support
- Integer type support
- Color type support (NEW)
- Text type support
- Point type support
- Other geometry types

Uses reflection to call: `contextualParameter.GetType().GetMethod("AssignContextualDataTree")`

#### b) Color Type Support
- New case in switch statement for Color parameters
- Deserializes JSON color values to GH_Colour objects
- Integrates with contextual parameter assignment

#### c) File Input Handling
- New logic to handle file inputs in Grasshopper definitions
- Path resolution and validation
- Support for relative/absolute paths

#### d) DataTree Serialization Improvements
- Enhanced handling of output data serialization
- Better type checking for geometry objects
- Improved context data assignment

#### e) ContextBake Component Support
- Recognition of special "ContextBakeComponent" for output handling
- Integration with validation endpoint

**Summary:** Adds approximately 280 lines of logic for handling Selva-specific features (contextual params, colors, file inputs, context bake)

---

### Schema.cs (111 lines changed, ~51 deletions, ~60 additions)

**Key removals (what was deleted):**
- `ResthopperObject.Id` property (Guid type) - REMOVED
- `InputParamSchema.Id` property - REMOVED
- `InputParamSchema.GroupName` property - REMOVED
- `InputParamSchema.Values` property - REMOVED
- All explicit [JsonProperty] decorators from param classes

**Key changes:**
- Renamed JSON properties to lowercase:
  - `"absoluteTolerance"` → `"absolutetolerance"`
  - `"angleTolerance"` → `"angletolerance"`
  - `"modelUnits"` → `"modelunits"`
  - `"dataVersion"` → `"dataversion"`
  - `"cacheSolve"` → `"cachesolve"`

- Changed `[JsonProperty("name")]` → `[JsonProperty(PropertyName = "name")]` syntax
- Removed blank line separators between properties
- Removed whitespace/formatting

**⚠️ IMPORTANT:** These Schema changes are NOT compatible with upstream/9.x which uses `SchemaDataFormat` enum and `GrasshopperValues` instead. Don't manually migrate these.

---

### DataCache.cs (60 lines changed)

**Additions:**

1. **File Caching System**
   - `CreateCacheKey(string input)` - Creates MD5-based cache keys
   - `LooksLikeACacheKey(string key)` - Validates cache key format
   - `DefinitionCacheDirectory` property - AppData\McNeel\rhino.compute\definitioncache

2. **Cache Management**
   - `CompareFilesByDate()` - Sorts files by last access time
   - `CGCacheDirectory()` - Garbage collection for old cached definitions
   - File expiration logic (removes files not accessed recently)

3. **New Data Structures**
   - `CachedDefinition` class - Stores definition + runtime serial number
   - `CachedResults` class - Stores definition + serial number + JSON

**Purpose:** Improves performance by caching parsed Grasshopper definitions locally, avoiding reparsing the same files

---

### FixedEndpoints.cs (83 lines changed, +84 lines)

**New endpoint added:**
```
POST /grasshopper/validate
```

**GET behavior (metadata):**
Returns JSON with endpoint info:
```json
{
  "endpoint": "grasshopper/validate",
  "status": "available",
  "description": "Validates Grasshopper definition files (.gh/.ghx) for use with compute.",
  "usage": "POST multipart/form-data with one or more .gh or .ghx files."
}
```

**POST behavior (validation):**
- Accepts multipart/form-data with .gh or .ghx files
- For each file:
  1. Loads archive using `GrasshopperValidationHelper.ArchiveFromBytes()`
  2. Extracts GH_Document
  3. Searches for ContextBakeComponent with "Schema" input
  4. Validates Schema comes from "GH_UIBuilderComponent"
  5. Returns results with errors or embedded schemas

**Returns:**
- List of validation results (success or error for each file)
- Schemas embedded in UI Builder components

---

### Config.cs (6 lines changed)

**Changes:**
- Added setting for headless document creation
- Configuration option for running Rhino in headless mode (no UI)
- Default value adjustment

---

### .gitignore (21 lines added)

**New entries:**
- Visual Studio files (.vs/, obj/, bin/)
- Rider IDE files (.idea/, *.DotSettings.user)
- Other IDE-specific ignores

---

### Documentation Changes

#### README.md (20 lines changed)
- Updated with Selva-specific information
- Modified badges and images
- Updated usage instructions

#### CHANGELOG.HOPS.md (42 lines changed)
- Added entries for new features
- Documented Selva enhancements
- Version history updates

#### script/README.md (14 lines added)
- Documentation for scripts directory
- Installation/deployment instructions

---

### CI/CD Changes

#### .github/workflows/workflow_ci.yml (11 lines changed)
- Updated workflow configuration
- Likely added Selva-specific build steps

---

### Project Files

#### compute.geometry.csproj (2 lines changed)
- Version updates
- Dependency adjustments

#### compute.geometry.sln (24 lines added - NEW FILE)
- Solution file (previously didn't exist)

#### rhino.compute.csproj (2 lines changed)
- Version updates

#### rhino.compute.sln (24 lines added - NEW FILE)
- Solution file (previously didn't exist)

---

### PowerShell Scripts

#### script/production/module_update_compute.ps1 (16 lines changed)
- Updated paths/logic for Selva deployment

#### update_compute_server/module_update_compute.ps1 (105 lines added - NEW)
- New module update script

---

### ResthopperEndpoints.cs (4 lines changed)
- Minor formatting/logic changes
- Likely related to validation endpoint integration

---

## Summary of Custom Changes

### Selva-Specific Features (Worth Keeping)
✅ **GrasshopperValidationHelper.cs** - Validation infrastructure
✅ **FixedEndpoints validation endpoint** - Validation API
✅ **DataCache improvements** - Performance optimization
✅ **GrasshopperDefinition contextual params** - Contextual parameter support
✅ **GrasshopperDefinition Color support** - Color type handling
✅ **update_compute_selva.ps1** - Deployment tooling
✅ **Config headless setting** - Server configuration

### NOT Worth Migrating to 9.x
❌ **Schema.cs changes** - 9.x uses incompatible SchemaDataFormat enum approach

---

## Key Takeaways

1. **Your custom work is primarily Selva-focused**, not core compute improvements
2. **GrasshopperValidationHelper is the centerpiece** - it enables the validation endpoint
3. **DataCache adds important performance optimization**
4. **Schema.cs changes should NOT be ported** - 9.x has a completely different approach
5. **GrasshopperDefinition enhancements** - contextual params and color support are valuable but check if 9.x upstream already has similar implementations
