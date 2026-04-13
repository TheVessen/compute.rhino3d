using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Threading.Tasks;
using Carter;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Routing;
using System.Linq;
using GH_IO.Serialization;
using Grasshopper.Kernel;
using Newtonsoft.Json.Linq;

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
                { "compute", Assembly.GetExecutingAssembly().GetName().Version.ToString() },
            };
            string git_sha = null; // appveyor will replace this
            values.Add("git_sha", git_sha);

            ctx.Response.ContentType= "application/json";
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
            // GET or empty POST → return usage info
            bool hasFiles = ctx.Request.HasFormContentType && ctx.Request.Form.Files.Count > 0;
            bool hasJsonBody = !ctx.Request.HasFormContentType
                && ctx.Request.ContentType != null
                && ctx.Request.ContentType.StartsWith("application/json", StringComparison.OrdinalIgnoreCase);

            if (ctx.Request.Method == "GET" || (!hasFiles && !hasJsonBody))
            {
                ctx.Response.ContentType = "application/json";
                await ctx.Response.WriteAsync(Newtonsoft.Json.JsonConvert.SerializeObject(new
                {
                    endpoint = "grasshopper/schema",
                    status = "available",
                    description = "Extracts the embedded schema from Grasshopper definition files (.gh/.ghx). Returns the full schema (inputs, outputs, metadata) when the definition is correctly wired (Context Bake → UI Builder with an embedded schema).",
                    usage = new
                    {
                        file_upload = "POST multipart/form-data with one or more .gh or .ghx files.",
                        url = "POST application/json with { \"urls\": [\"https://…/file.gh\"] } or { \"url\": \"https://…/file.gh\" }."
                    }
                }));
                return;
            }

            var results = new List<JObject>();

            if (hasFiles)
            {
                foreach (var file in ctx.Request.Form.Files)
                {
                    var fileName = !string.IsNullOrEmpty(file.FileName) ? file.FileName : file.Name;
                    try
                    {
                        using var stream = file.OpenReadStream();
                        using var mem = new MemoryStream();
                        stream.CopyTo(mem);

                        var archive = GrasshopperValidationHelper.ArchiveFromBytes(mem.ToArray());
                        results.Add(ExtractSchemaFromArchive(fileName, archive));
                    }
                    catch (Exception ex)
                    {
                        results.Add(GrasshopperValidationHelper.ErrorResult(fileName, ex.Message));
                    }
                }
            }
            else // JSON body with URLs
            {
                string body;
                using (var reader = new StreamReader(ctx.Request.Body))
                    body = await reader.ReadToEndAsync();

                JObject json;
                try { json = JObject.Parse(body); }
                catch { json = null; }

                if (json == null)
                {
                    ctx.Response.StatusCode = 400;
                    ctx.Response.ContentType = "application/json";
                    await ctx.Response.WriteAsync(Newtonsoft.Json.JsonConvert.SerializeObject(new { error = "Invalid JSON body." }));
                    return;
                }

                // Accept either { "url": "..." } or { "urls": ["...", ...] }
                var urls = new List<string>();
                if (json["urls"] is JArray arr)
                    urls.AddRange(arr.Values<string>().Where(u => !string.IsNullOrWhiteSpace(u)));
                else if (json["url"] is JValue single && single.Type == JTokenType.String)
                    urls.Add(single.Value<string>());

                if (urls.Count == 0)
                {
                    ctx.Response.StatusCode = 400;
                    ctx.Response.ContentType = "application/json";
                    await ctx.Response.WriteAsync(Newtonsoft.Json.JsonConvert.SerializeObject(new { error = "Provide 'url' or 'urls' in the JSON body." }));
                    return;
                }

                foreach (var url in urls)
                {
                    var fileName = url;
                    try
                    {
                        var archive = await GrasshopperValidationHelper.ArchiveFromUrlAsync(url);
                        results.Add(ExtractSchemaFromArchive(fileName, archive));
                    }
                    catch (Exception ex)
                    {
                        results.Add(GrasshopperValidationHelper.ErrorResult(fileName, ex.Message));
                    }
                }
            }

            ctx.Response.ContentType = "application/json";
            await ctx.Response.WriteAsync(Newtonsoft.Json.JsonConvert.SerializeObject(results));
        }

        static JObject ExtractSchemaFromArchive(string fileName, GH_Archive archive)
        {
            if (archive == null)
                return GrasshopperValidationHelper.ErrorResult(fileName, "Failed to load the Grasshopper document.");

            var doc = GrasshopperValidationHelper.DocumentFromArchive(archive);
            if (doc == null)
                return GrasshopperValidationHelper.ErrorResult(fileName, "Failed to extract definition from archive.");

            var schemaComponents = GrasshopperValidationHelper.GetSchemaContextBakeComponents(doc);
            if (schemaComponents.Count == 0)
                return GrasshopperValidationHelper.ErrorResult(fileName,
                    "This definition has no outputs defined. " +
                    "Add a 'Context Bake' component, connect a 'UI Builder' component to its first input, " +
                    "and make sure the Schema output param is named 'Schema'.");

            var schemas = new JArray();
            foreach (var component in schemaComponents)
            {
                var parent = GrasshopperValidationHelper.GetSchemaParentComponent(component);
                if (parent?.GetType().Name != "GH_UIBuilderComponent")
                    return GrasshopperValidationHelper.ErrorResult(fileName, "The 'Schema' source is not coming from a 'UI Builder' component.");

                var schema = GrasshopperValidationHelper.GetEmbeddedSchema(parent);
                if (schema == null)
                    return GrasshopperValidationHelper.ErrorResult(fileName,
                        "The UI Builder component was found but contains no embedded schema. Configure and save your schema inside the UI Builder component.");

                schemas.Add(GrasshopperValidationHelper.SchemaToJson(schema));
            }

            return GrasshopperValidationHelper.SuccessResult(fileName, schemas);
        }
    }
}

