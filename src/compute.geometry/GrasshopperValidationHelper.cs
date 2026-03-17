using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using GH_IO.Serialization;
using Grasshopper.Kernel;
using Newtonsoft.Json.Linq;

namespace compute.geometry
{
    internal static class GrasshopperValidationHelper
    {
        public static GH_Archive ArchiveFromBytes(byte[] byteArray)
        {
            try
            {
                var byteArchive = new GH_Archive();
                if (byteArchive.Deserialize_Binary(byteArray))
                    return byteArchive;
            }
            catch (Exception) { }

            var xmlArchive = new GH_Archive();
            if (xmlArchive.Deserialize_Xml(System.Text.Encoding.UTF8.GetString(byteArray)))
                return xmlArchive;

            return null;
        }

        public static GH_Document DocumentFromArchive(GH_Archive archive)
        {
            var doc = new GH_Document();
            return archive.ExtractObject(doc, "Definition") ? doc : null;
        }

        public static List<GH_Component> GetSchemaContextBakeComponents(GH_Document doc)
        {
            return doc.Objects
                .Where(o => o.GetType().Name == "ContextBakeComponent")
                .OfType<GH_Component>()
                .Where(c => c.Params.Input.Count > 0
                    && c.Params.Input[0].Sources.Any(s => s.NickName == "Schema"))
                .ToList();
        }

        public static IGH_DocumentObject GetSchemaParentComponent(GH_Component contextBake)
        {
            var source = contextBake.Params.Input[0].Sources.FirstOrDefault(s => s.NickName == "Schema");
            return source?.Attributes?.GetTopLevel?.DocObject;
        }

        public static object GetEmbeddedSchema(IGH_DocumentObject uiBuilderComponent)
        {
            return uiBuilderComponent.GetType()
                .GetField("_embeddedSchema", BindingFlags.NonPublic | BindingFlags.Instance)
                ?.GetValue(uiBuilderComponent);
        }

        public static JObject SchemaToJson(object schema)
        {
            var t = schema.GetType();
            T Prop<T>(string name) => (T)(t.GetProperty(name)?.GetValue(schema) ?? default(T));

            var inputs  = Prop<System.Collections.IList>("Inputs");
            var outputs = Prop<System.Collections.IList>("Outputs");
            var tags    = Prop<System.Collections.IList>("Tags");

            return new JObject
            {
                ["name"]        = Prop<string>("Name"),
                ["description"] = Prop<string>("Description"),
                ["author"]      = Prop<string>("Author"),
                ["tags"]        = tags != null
                    ? new JArray(tags.Cast<object>().Select(t2 => t2?.ToString()))
                    : new JArray(),
                ["inputs"]  = SerializeParamList(inputs),
                ["outputs"] = SerializeParamList(outputs),
            };
        }

        // Serializes a list of schema parameters (inputs or outputs) into a JArray.
        // Each item is reflected to extract all simple-value properties (primitives, strings, enums).
        private static JArray SerializeParamList(System.Collections.IList list)
        {
            var arr = new JArray();
            if (list == null) return arr;
            foreach (var item in list)
                if (item != null) arr.Add(SerializeSchemaParam(item));
            return arr;
        }

        private static JObject SerializeSchemaParam(object param)
        {
            var obj = new JObject();
            foreach (var prop in param.GetType()
                                      .GetProperties(BindingFlags.Public | BindingFlags.Instance)
                                      .Where(p => p.CanRead && p.GetIndexParameters().Length == 0))
            {
                try
                {
                    var val = prop.GetValue(param);
                    if (val == null) continue;
                    var vt = val.GetType();
                    if (vt.IsPrimitive || vt == typeof(string) || vt.IsEnum)
                        obj[prop.Name] = JToken.FromObject(val);
                }
                catch { /* skip unreadable or unsupported properties */ }
            }
            return obj;
        }

        public static JObject ErrorResult(string fileName, string message) => new JObject
        {
            ["fileName"] = fileName,
            ["error"]    = message
        };

        public static JObject SuccessResult(string fileName, JArray schemas) => new JObject
        {
            ["fileName"] = fileName,
            ["schemas"]  = schemas
        };
    }
}
