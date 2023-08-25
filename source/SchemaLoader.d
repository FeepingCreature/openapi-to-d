module SchemaLoader;

import boilerplate;
import dyaml;
import route;
import std.algorithm;
import std.array;
import std.format;
import std.json;
import std.path;
import std.typecons;
import text.json.Decode;
import ToJson;
import types;

class SchemaLoader
{
    OpenApiFile[string] files;

    OpenApiFile load(string path)
    {
        path = path.asNormalizedPath.array;
        if (path !in this.files)
        {
            const root = Loader.fromFile(path).load;
            const JSONValue jsonValue = root.toJson(Yes.ordered);
            Route[] routes = null;
            Type[string] schemas = null;
            Parameter[string] parameters = null;

            if (jsonValue.hasKey("paths"))
            {
                foreach (JSONValue pair; jsonValue.getEntry("paths").array)
                {
                    const url_ = pair["key"].str;
                    const routeJson = pair["value"].toObject.object;

                    auto routeParametersJson = routeJson.get("parameters", JSONValue((JSONValue[]).init));
                    auto routeParameters_ = routeParametersJson.decodeJson!(Parameter[], route.decode);

                    foreach (string method_, JSONValue endpoint; routeJson)
                    {
                        if (method_ == "parameters")
                            continue;

                        auto routeDto = endpoint.toObject.decodeJson!(RouteDto, route.decode);

                        Type schema_ = null;
                        if (endpoint.hasKey("requestBody"))
                        {
                            schema_ = endpoint.getEntry("requestBody")
                                .getEntry("content")
                                .getEntry("application/json")
                                .getEntry("schema")
                                .decodeJson!(Type, types.decode);
                        }
                        string[] responseCodes_ = endpoint.getEntry("responses").array
                            .map!(pair => pair["key"].str)
                            .array;

                        with (Route.Builder())
                        {
                            url = url_;
                            method = method_;
                            summary = routeDto.summary;
                            operationId = routeDto.operationId;
                            schema = schema_;
                            parameters = routeParameters_ ~ routeDto.parameters;
                            responseCodes = responseCodes_;
                            routes ~= builderValue;
                        }
                    }
                }
            }

            string description = null;
            if (jsonValue.hasKey("info") && jsonValue.getEntry("info").hasKey("description"))
            {
                description = jsonValue.getEntry("info").getEntry("description").str;
            }

            foreach (JSONValue pair; jsonValue.getEntry("components").getEntry("schemas").array)
            {
                const key = pair["key"].str;

                schemas[format!"components/schemas/%s"(key)] = pair["value"]
                    .decodeJson!(Type, types.decode);
            }
            if (jsonValue.getEntry("components").hasKey("parameters"))
            {
                foreach (JSONValue pair; jsonValue.getEntry("components").getEntry("parameters").array)
                {
                    const key = pair["key"].str;

                    parameters[format!"components/parameters/%s"(key)] = pair["value"]
                        .decodeJson!(Parameter, route.decode);
                }
            }
            this.files[path] = new OpenApiFile(path, description, routes, schemas, parameters);
        }
        return this.files[path];
    }

    mixin(GenerateToString);
}

class OpenApiFile
{
    string path;

    string description;

    Route[] routes;

    Type[string] schemas;

    Parameter[string] parameters;

    mixin(GenerateAll);
}

struct RouteDto
{
    string summary;

    string operationId;

    @(This.Default)
    Parameter[] parameters;

    mixin(GenerateAll);
}