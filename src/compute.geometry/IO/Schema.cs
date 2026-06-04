using System;
using System.Collections.Generic;
using Newtonsoft.Json;
using Rhino.Geometry;

namespace Resthopper.IO
{
    public class Schema
    {
        public Schema() {}

        [JsonProperty("absoluteTolerance", DefaultValueHandling = DefaultValueHandling.Ignore)]
        public double AbsoluteTolerance { get; set; } = 0;

        [JsonProperty("angleTolerance", DefaultValueHandling = DefaultValueHandling.Ignore)]
        public double AngleTolerance { get; set; } = 0;

        [JsonProperty("modelUnits")]
        public string ModelUnits { get; set; } = Rhino.UnitSystem.Millimeters.ToString();

        [JsonProperty("dataVersion")]
        public int DataVersion { get; set; } = 7;

        [JsonProperty("algo")]
        public string Algo { get; set; }

        [JsonProperty("filename")]
        public string FileName { get; set; }

        [JsonProperty("pointer")]
        public string Pointer { get; set; }

        [JsonProperty("cacheSolve")]
        public bool CacheSolve { get; set; } = false;

        [JsonProperty("recursionlevel", DefaultValueHandling = DefaultValueHandling.Ignore)]
        public int RecursionLevel { get; set; } = 0;

        [JsonProperty("values")]
        public List<DataTree<ResthopperObject>> Values { get; set; } = new List<DataTree<ResthopperObject>>();

        [JsonProperty("warnings", DefaultValueHandling = DefaultValueHandling.Ignore)]
        public List<string> Warnings { get; set; } = new List<string>();

        [JsonProperty("errors", DefaultValueHandling = DefaultValueHandling.Ignore)]
        public List<string> Errors { get; set; } = new List<string>();
    }

    public class IoQuerySchema
    {
        [JsonProperty("requestedFile")]
        public string RequestedFile { get; set; }
    }

    public class IoParamSchema
    {
        [JsonProperty("name")]
        public string Name { get; set; }

        [JsonProperty("nickname")]
        public string Nickname { get; set; }

        [JsonProperty("paramType")]
        public string ParamType { get; set; }

        [JsonProperty("id")]
        public string Id { get; set; }
    }

    public class InputParamSchema : IoParamSchema
    {
        [JsonProperty("description")]
        public string Description { get; set; }

        [JsonProperty("atLeast")]
        public int AtLeast { get; set; } = 1;

        [JsonProperty("atMost")]
        public int AtMost { get; set; } = int.MaxValue;

        [JsonProperty("treeAccess")]
        public bool TreeAccess { get; set; } = false;

        [JsonProperty("default")]
        public object Default { get; set; } = null;

        [JsonProperty("minimum")]
        public object Minimum { get; set; } = null;

        [JsonProperty("maximum")]
        public object Maximum { get; set; } = null;

        [JsonProperty("groupName")]
        public string GroupName { get; set; } = null;

        [JsonProperty("values")]
        public Dictionary<string, string> Values { get; set; } = null;
    }

    public class IoResponseSchema
    {
        [JsonProperty("description")]
        public string Description { get; set; }

        [JsonProperty("filename")]
        public string FileName { get; set; }

        [JsonProperty("cachekey")]
        public string CacheKey { get; set; }

        [JsonProperty("inputnames")]
        public List<string> InputNames { get; set; }

        [JsonProperty("outputnames")]
        public List<string> OutputNames { get; set; }

        [JsonProperty("icon")]
        public string Icon { get; set; }

        [JsonProperty("inputs")]
        public List<InputParamSchema> Inputs { get; set; }

        [JsonProperty("outputs")]
        public List<IoParamSchema> Outputs { get; set; }

        [JsonProperty("warnings")]
        public List<string> Warnings { get; set; } = new List<string>();

        [JsonProperty("errors")]
        public List<string> Errors { get; set; } = new List<string>();
    }

    public class HttpRecord
    {
        public HttpRecord()
        {

        }
        public string IoRequest { get; set; }
        public string IoResponse { get; set; }
        public string SolveRequest { get; set; }
        public string SolveResponse { get; set; }
        public Schema Schema { get; set; }
        public IoResponseSchema IoResponseSchema { get; set; }
    }

    public class ResthopperObject : IEquatable<ResthopperObject>
    {
        [JsonProperty("type")]
        public string Type { get; set; }

        [JsonProperty("data")]
        public string Data { get; set; }

        [JsonIgnore]
        public object ResolvedData { get; set; }
        
        [JsonProperty(PropertyName = "id")]
        public Guid Id { get; set; }

        [JsonConstructor]
        public ResthopperObject() {}

        public ResthopperObject(object obj)
        {
            if (obj is GeometryBase geometry)
            {
                Data = geometry.ToJSON(new Rhino.FileIO.SerializationOptions() { RhinoVersion = 7 });
            }
            else
            {
#if COMPUTE_CORE
                Data = JsonConvert.SerializeObject(obj, compute.geometry.GeometryResolver.Settings);
#else
                Data = JsonConvert.SerializeObject(obj);
#endif
            }
            Type = obj.GetType().FullName;
        }

        public bool Equals(ResthopperObject other)
        {
            return string.Equals(Type, other.Type) && string.Equals(Data, other.Data);
        }
    }
}
