using System;
using System.Collections.Generic;
using System.Reflection;
using System.Threading.Tasks;
using Carter;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Routing;
using System.Linq;
using Newtonsoft.Json.Linq;
using Rhino.PlugIns;

namespace compute.geometry
{
    public class FixedEndPointsModule : ICarterModule
    {
        public void AddRoutes(IEndpointRouteBuilder app)
        {
            app.MapGet("", HomePage);
            app.MapGet("version", GetVersion);
            app.MapGet("servertime", ServerTime);
            app.MapGet("plugins/rhino/installed", GetInstalledPluginsRhino);
            app.MapGet("plugins/gh/installed", GetInstalledPluginsGrasshopper);
            app.MapPost("grasshopper/schema", GetGrasshopperSchema);
        }

        static void HomePage(HttpContext context)
        {
            context.Response.Redirect("https://www.rhino3d.com/compute");
        }

        static async Task GetVersion(HttpContext ctx)
        {
            var values = new Dictionary<string, string>
            {
                { "rhino", Rhino.RhinoApp.Version.ToString() },
                { "compute", Assembly.GetExecutingAssembly().GetName().Version.ToString() }
            };
            string git_sha = null; // appveyor will replace this
            values.Add("git_sha", git_sha);

            ctx.Response.ContentType = "application/json";
            await ctx.Response.WriteAsJsonAsync(values);
        }

        static async Task ServerTime(HttpContext ctx)
        {
            ctx.Response.ContentType = "application/json";
            await ctx.Response.WriteAsJsonAsync(DateTime.UtcNow);
        }

        static async Task GetInstalledPluginsRhino(HttpContext ctx)
        {
            var rhPluginInfo = new SortedDictionary<string, string>();
            foreach (var k in Rhino.PlugIns.PlugIn.GetInstalledPlugIns().Keys)
            {
                var info = Rhino.PlugIns.PlugIn.GetPlugInInfo(k);
                //Could also use: info.IsLoaded
                if (info != null && !rhPluginInfo.ContainsKey(info.Name) && !info.ShipsWithRhino)
                {
                    rhPluginInfo.Add(info.Name, info.Version);
                }
            }

            ctx.Response.ContentType = "application/json";
            await ctx.Response.WriteAsJsonAsync(rhPluginInfo);
        }

        static async Task GetInstalledPluginsGrasshopper(HttpContext ctx)
        {
            var ghPluginInfo = new SortedDictionary<string, string>();
            foreach (var obj in Grasshopper.Instances.ComponentServer.ObjectProxies.Where(o => o != null))
            {
                var asm = Grasshopper.Instances.ComponentServer.FindAssemblyByObject(obj.Guid);
                if (asm != null && !string.IsNullOrEmpty(asm.Name) && !asm.IsCoreLibrary && !ghPluginInfo.ContainsKey(asm.Name))
                {
                    var version = (string.IsNullOrEmpty(asm.Version)) ? asm.Assembly.GetName().Version.ToString() : asm.Version;
                    ghPluginInfo.Add(asm.Name, version);
                }
            }
            ctx.Response.ContentType = "application/json";
            await ctx.Response.WriteAsJsonAsync(ghPluginInfo);
        }

        static async Task GetGrasshopperSchema(HttpContext ctx)
        {
            if (ctx.Request.Method == "GET" || !ctx.Request.HasFormContentType || ctx.Request.Form.Files.Count == 0)
            {
                ctx.Response.ContentType = "application/json";
                await ctx.Response.WriteAsync(Newtonsoft.Json.JsonConvert.SerializeObject(new
                {
                    endpoint = "grasshopper/schema",
                    status = "available",
                    description = "Extracts the embedded schema from Grasshopper definition files (.gh/.ghx). Returns the full schema (inputs, outputs, metadata) when the definition is correctly wired (Context Bake → UI Builder with an embedded schema).",
                    usage = "POST multipart/form-data with one or more .gh or .ghx files."
                }));
                return;
            }

            var results = new List<JObject>();

            foreach (var file in ctx.Request.Form.Files)
            {
                var fileName = !string.IsNullOrEmpty(file.FileName) ? file.FileName : file.Name;
                try
                {
                    using var stream = file.OpenReadStream();
                    using var mem = new MemoryStream();
                    stream.CopyTo(mem);

                    var archive = GrasshopperValidationHelper.ArchiveFromBytes(mem.ToArray());
                    if (archive == null) { results.Add(GrasshopperValidationHelper.ErrorResult(fileName, "Failed to load the Grasshopper document.")); continue; }

                    var doc = GrasshopperValidationHelper.DocumentFromArchive(archive);
                    if (doc == null) { results.Add(GrasshopperValidationHelper.ErrorResult(fileName, "Failed to extract definition from archive.")); continue; }

                    var schemaComponents = GrasshopperValidationHelper.GetSchemaContextBakeComponents(doc);
                    if (schemaComponents.Count == 0)
                    {
                        results.Add(GrasshopperValidationHelper.ErrorResult(fileName,
                            "This definition has no outputs defined. " +
                            "Add a 'Context Bake' component, connect a 'UI Builder' component to its first input, " +
                            "and make sure the Schema output param is named 'Schema'."));
                        continue;
                    }

                    var schemas = new JArray();
                    string error = null;

                    foreach (var component in schemaComponents)
                    {
                        var parent = GrasshopperValidationHelper.GetSchemaParentComponent(component);
                        if (parent?.GetType().Name != "GH_UIBuilderComponent")
                        {
                            error = "The 'Schema' source is not coming from a 'UI Builder' component.";
                            break;
                        }

                        var schema = GrasshopperValidationHelper.GetEmbeddedSchema(parent);
                        if (schema == null)
                        {
                            error = "The UI Builder component was found but contains no embedded schema. Configure and save your schema inside the UI Builder component.";
                            break;
                        }

                        schemas.Add(GrasshopperValidationHelper.SchemaToJson(schema));
                    }

                    results.Add(error != null
                        ? GrasshopperValidationHelper.ErrorResult(fileName, error)
                        : GrasshopperValidationHelper.SuccessResult(fileName, schemas));
                }
                catch (Exception ex)
                {
                    results.Add(GrasshopperValidationHelper.ErrorResult(fileName, ex.Message));
                }
            }

            ctx.Response.ContentType = "application/json";
            await ctx.Response.WriteAsync(Newtonsoft.Json.JsonConvert.SerializeObject(results));
        }
    }
}

