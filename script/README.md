## Installing the Custom Compute Flavor

Follow these steps to install the custom VektorNode flavor for production:

1. **Install rhino.compute**  
   Follow the official instructions: [Deploy to IIS](https://developer.rhino3d.com/guides/compute/deploy-to-iis/). Use the bootstrap script as described.

2. **Update to VektorNode Flavor**  
   Run the PowerShell script: [`module_update_compute.ps1`](update_compute_server/module_update_compute.ps1).  
   This will back up the original compute installation and apply the VektorNode flavor.

3. **Usage**  
   Use rhino.compute as usual.  
   To enable "File to block" instances, set `RHINO_COMPUTE_CREATE_HEADLESS_DOC` in [`Config.cs`](../src/compute.geometry/Config.cs).
