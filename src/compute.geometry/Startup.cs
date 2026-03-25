using System;
using System.Linq;
using Carter;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.DependencyInjection;
using Serilog;

namespace compute.geometry
{
    public class Startup
    {
        //https://github.com/mcneel/rhino/blob/e1192835cbf03f662d0cf857ee9239b84109eeed/src4/rhino4/Plug-ins/RhinoCodePlugins/RhinoCodePlugin/AssemblyInfo.cs
        static readonly Guid s_rhinoCodePluginId = new Guid("c9cba87a-23ce-4f15-a918-97645c05cde7");

        //https://github.com/mcneel/rhino/blob/8.x/src4/rhino4/Plug-ins/Commands/Properties/AssemblyInfo.cs
        static readonly Guid s_rhinoCommandsPluginId = new Guid("02bf604d-799c-4cc2-830e-8d72f21b14b7");

        public void ConfigureServices(IServiceCollection services)
        {
            services.AddCors(options =>
            {
                options.AddDefaultPolicy(
                    builder =>
                    {
                        builder.AllowAnyOrigin().AllowAnyHeader();
                    });
            });
            services.AddHealthChecks();
            services.AddCarter();
        }

        public void Configure(IApplicationBuilder app)
        {
            RhinoCoreStartup();

            app.UseRouting();
            app.UseCors();
            app.UseEndpoints(builder =>
            {
                builder.MapHealthChecks("/healthcheck");
                builder.MapCarter();
            });
        }

        void RhinoCoreStartup()
        {
            var t0 = DateTime.Now;
            Log.Information("RhinoCore initializing (license validation may take a few seconds)...");
            Program.RhinoCore = new Rhino.Runtime.InProcess.RhinoCore(null, Rhino.Runtime.InProcess.WindowStyle.NoWindow);
            Log.Information("RhinoCore ready in {Elapsed:F2}s", (DateTime.Now - t0).TotalSeconds);

            if (Config.Debug)
                Rhino.RhinoApp.SendWriteToConsole = true;

            Environment.SetEnvironmentVariable("RHINO_TOKEN", null, EnvironmentVariableTarget.Process);
            Rhino.Runtime.HostUtils.OnExceptionReport += (source, ex) =>
            {
                Log.Error(ex, "An exception occurred while processing request");
                Logging.LogExceptionData(ex);
            };

            var tStep = DateTime.Now;

            // NOTE:
            // andyopayne 11/19/2024 (RH-84777)
            // The commands.rhp needs to be loaded so that some features suchs as the gltf exporter will work.
            // This is a temporary solution until the gltf exporter is moved into Rhinocommon or Rhino.UI
            Log.Information("(1/4) Loading rhino commands plugin");
            if (Rhino.PlugIns.PlugIn.LoadPlugIn(s_rhinoCommandsPluginId))
            {
                Log.Information("Successfully loaded commands plugin");
            }
            else
            {
                Log.Error("Error loading rhino commands plugin.");
            }
            Log.Information("(1/4) done in {Elapsed:F2}s", (DateTime.Now - tStep).TotalSeconds);
            tStep = DateTime.Now;

            // NOTE:
            // eirannejad 10/02/2024 (COMPUTE-268)
            // Ensure RhinoCode plugin (Rhino plugin) is loaded. This plugin registers scripting
            // languages and starts the scripting server that communicates with rhinocode CLI. It also makes
            // the ScriptEditor and RhinoCodeLogs commands available.
            // For Rhino.Compute use cases, the ScriptEditor and rhinocode CLI are not going to be used.
            // The first time a Grasshopper definition with any scripting component on it is passed to Compute,
            // the script environments (especially python 3) will be initialized. This increases the execution
            // time on the first run on any script component. However after that the script components should run
            // normally. The scripting environment will only re-initialize when a new version of Rhino is installed.
            // eirannejad 12/3/2024 (COMPUTE-268)
            // This load is placed before Grasshopper in case GH needs to load any plugins published by the
            // new scripting tools in Rhino >= 8
            Log.Information("(2/4) Loading rhino scripting plugin");
            if (Rhino.PlugIns.PlugIn.LoadPlugIn(s_rhinoCodePluginId))
            {
                Log.Information("Successfully loaded scripting plugin");

                // eirannejad 12/3/2024 (COMPUTE-268)
                // now configuring scripting env to avoid using rhino progressbar and
                // dump init and package install messages to Rhino.RhinoApp.Write
                if (Rhino.RhinoApp.GetPlugInObject(s_rhinoCodePluginId) is object rhinoCodeController)
                {
                    ((dynamic)rhinoCodeController).SendReportsToConsole = true;
                    Log.Information("Configured scripting plugin for compute");
                }
            }
            // If plugin load fails, let compute run, but log the error
            else
            {
                Log.Error("Error loading rhino scripting plugin. Grasshopper script components are going to fail");
            }
            Log.Information("(2/4) done in {Elapsed:F2}s", (DateTime.Now - tStep).TotalSeconds);
            tStep = DateTime.Now;

            // Load GH at startup so it can get initialized on the main thread
            if (Config.LoadGrasshopper)
            {
                Log.Information("(3/4) Loading grasshopper");
#if LINUX
                LinkYakPackagesToGHLibraries();
                var ghpath = RhinoInside.Resolver.RhinoSystemDirectory + "/Plug-ins/Grasshopper/GrasshopperPlugin.rhp";
                var pluginresult = Rhino.PlugIns.PlugIn.LoadPlugIn(ghpath, out Guid ghid);
                Log.Information("Grasshopper plugin load result: {Result}, id: {Id}", pluginresult, ghid);
                var pluginObject = Rhino.RhinoApp.GetPlugInObject(ghid) as Grasshopper.Plugin.GH_RhinoScriptInterface;
                Log.Information("GH_RhinoScriptInterface cast result: {IsNull}", pluginObject == null ? "null (cast failed)" : "ok");
                if (pluginObject != null)
                {
                    Log.Information("Calling RunHeadless() directly");
                    pluginObject.RunHeadless();
                    Log.Information("RunHeadless() returned");
                    Log.Information("GH loaded assemblies: {Count}", Grasshopper.Instances.ComponentServer?.Libraries?.Count ?? -1);
                }
                else
                {
                    // Cast failed (version mismatch?) — fall back to reflection like non-Linux path
                    Log.Warning("GH_RhinoScriptInterface cast failed, falling back to reflection for RunHeadless");
                    var pluginObjectFallback = Rhino.RhinoApp.GetPlugInObject(ghid);
                    Log.Information("Fallback plugin object type: {Type}", pluginObjectFallback?.GetType().FullName ?? "null");
                    var runheadless = pluginObjectFallback?.GetType().GetMethod("RunHeadless");
                    if (runheadless != null)
                    {
                        Log.Information("Calling RunHeadless() via reflection");
                        runheadless.Invoke(pluginObjectFallback, null);
                        Log.Information("RunHeadless() via reflection returned");
                    }
                    else
                        Log.Error("RunHeadless not found on Grasshopper plugin object — GHA components will not be loaded");
                }
#else
                var pluginObject = Rhino.RhinoApp.GetPlugInObject("Grasshopper");
                var runheadless = pluginObject?.GetType().GetMethod("RunHeadless");
                if (runheadless != null)
                    runheadless.Invoke(pluginObject, null);
#endif
            }
            else
            {
                Log.Information("(3/4) Skipping grasshopper (disabled via RHINO_COMPUTE_LOAD_GRASSHOPPER)");
            }
            Log.Information("(3/4) done in {Elapsed:F2}s", (DateTime.Now - tStep).TotalSeconds);
            tStep = DateTime.Now;

            Log.Information("(4/4) Loading compute plug-ins");
            var loadComputePlugins = typeof(Rhino.PlugIns.PlugIn).GetMethod("LoadComputeExtensionPlugins");
            if (loadComputePlugins != null)
                loadComputePlugins.Invoke(null, null);
            Log.Information("(4/4) done in {Elapsed:F2}s", (DateTime.Now - tStep).TotalSeconds);

        }

#if LINUX
        // GH on Linux only scans its Libraries folder — it does NOT scan the Yak packages directory.
        // This method finds all GHAs in the Yak packages dir and symlinks them into GH Libraries
        // so that any installed Yak plugin is picked up automatically by RunHeadless().
        static void LinkYakPackagesToGHLibraries()
        {
            var packagesDir = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "mcneel", "rhinoceros", "packages", "9.0"
            );
            var ghLibraries = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Grasshopper", "Libraries"
            );

            if (!System.IO.Directory.Exists(packagesDir))
            {
                Log.Information("Yak packages dir not found, skipping GHA linking: {Path}", packagesDir);
                return;
            }

            System.IO.Directory.CreateDirectory(ghLibraries);

            var ghaFiles = System.IO.Directory.GetFiles(packagesDir, "*.gha", System.IO.SearchOption.AllDirectories)
                .Where(f => f.Contains("/net7.0/") || f.Contains("/net8.0/") || f.Contains("/net9.0/"));

            foreach (var gha in ghaFiles)
            {
                var dest = System.IO.Path.Combine(ghLibraries, System.IO.Path.GetFileName(gha));
                if (!System.IO.File.Exists(dest))
                {
                    System.IO.File.CreateSymbolicLink(dest, gha);
                    Log.Information("Linked GHA: {Name} -> {Source}", System.IO.Path.GetFileName(gha), gha);
                }
            }
        }
#endif

    }
}
