# Rhino Compute Server

[![Build status](https://ci.appveyor.com/api/projects/status/unmnwi57we5nvnfi/branch/master?svg=true)](https://ci.appveyor.com/project/mcneel/compute-rhino3d/branch/master)
[![Discourse users](https://img.shields.io/discourse/https/discourse.mcneel.com/users.svg)](https://discourse.mcneel.com/c/rhino-developer/compute-rhino3d/90)

![https://www.rhino3d.com/compute](https://www.rhino3d.com/en/7.420921340460724505/images/rhino-compute-new.svg)

## REST API for RhinoCommon and Grasshopper

For more information, see https://www.rhino3d.com/compute.

Compute is built on top of Rhino 8 for Windows and can run anywhere Rhino 8 for Windows can run.

🛠 Start with ["Developing with Rhino Compute"](https://developer.rhino3d.com/guides/compute/development/) to run Compute locally for testing and debugging.

📡 See ["Deploying Rhino Compute"](https://developer.rhino3d.com/guides/compute/deploy-to-iis/) to setup your own Compute server.


## Branch Enhancements & Differences 🚀

This branch introduces several improvements and behavioral changes compared to the original [mcneel/compute.rhino3d](https://github.com/mcneel/compute.rhino3d) fork, primarily focused on better UI integration and robust data handling.

### 📋 IO Schema Updates
- **JSON Standardization**: Updated serialization naming convention from lowercase to `camelCase` across all IO schemas for better compatibility with modern web frameworks.
- **Enhanced Metadata**: Extended `IoParamSchema` and `InputParamSchema` to include `Id`, `GroupName`, and `Values`.
- **Object Identification**: Introduced a unique `Id` property to `ResthopperObject` for improved tracking of serialized geometry.
- **Explicit Serialization**: Applied `[JsonProperty]` decorations to all schema classes for consistent API responses.

### 🧠 Behavioral Improvements
- **Input Change Detection**: Implemented `AlreadySet()` logic to compare incoming data trees with cached values. This prevents unnecessary solution re-calculations if the input hasn't actually changed.
- **Advanced Contextual Support**: Enhanced logic for `IGH_ContextualParameter` using reflection to call specialized assignment methods, ensuring robust data injection for complex GH components.
- **Versioned Serialization**: Geometry serialization now explicitly respects requested Rhino versions, ensuring data integrity across different client environments.
- **Smart String Handling**: Added defensive unescaping logic for Text/File types to ensure characters are handled correctly regardless of source formatting.

### 🎨 UI & Metadata Features
- **Hierarchical Grouping**: Added `GetGroupName()` which recursively traverses Grasshopper groups to build breadcrumb strings (e.g., `Category::SubCategory`), allowing the API to report the visual organization of the canvas.
- **Value List Extraction**: The API now extracts key-value pairs from contextual parameters (like Value Lists or Dropdowns), enabling clients to render user-friendly selection UI.
- **Dynamic Web/UI Goo**: Integration of reflection-based logic to handle specialized data types like `WebDisplay`, `FileDataGoo`, and `UISchemaGoo`.

