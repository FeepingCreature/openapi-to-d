module app;

import argparse;
import boilerplate;
import config;
import dyaml;
import render;
import route;
import std.algorithm;
import std.array;
import std.file;
import std.json;
import std.path;
import std.range;
import std.stdio;
import std.string;
import std.typecons;
import std.uni;
import std.utf;
import text.json.Decode;
import ToJson;
import types;

@(Command.Description("Convert OpenAPI specification to serialized-ready D structs"))
struct Arguments
{
    @(PositionalArgument(0).Description("openapi-to-d configuration file"))
    string config;
}

mixin CLI!Arguments.main!((const Arguments arguments)
{
    auto loader = new SchemaLoader;
    auto config = loadConfig(arguments.config);
    Type[][string] schemas;
    string[] keysInOrder;
    OpenApiFile[] files = config.source.map!(a => loader.load(a)).array;

    foreach (file; files)
    {
        foreach (key, type; file.schemas)
        {
            type.setSource(file.path);
            schemas[key] ~= type;
            keysInOrder ~= key;
        }
    }

    auto allKeysSet = keysInOrder
        .map!(key => tuple!("key", "value")(key.keyToTypeName, true))
        .assocArray;

    // write domain files
    foreach (key; keysInOrder)
    {
        const types = schemas[key];
        const type = pickBestType(types);
        const name = key.keyToTypeName;
        auto schemaConfig = config.schemas.get(name, SchemaConfig());

        if (!schemaConfig.include)
            continue;

        auto render = new Render(config.componentFolder.pathToModule, allKeysSet);

        bool rendered = false;

        if (cast(ObjectType) type)
        {
            render.types ~= render.renderObject(key, type, schemaConfig.invariant_, type.description);
            rendered = true;
        }
        else if (auto stringType = cast(StringType) type)
        {
            if (!stringType.enum_.empty)
            {
                render.renderEnum(name, stringType.enum_, type.source, type.description);
                rendered = true;
            }
        }
        else if (auto allOf = cast(AllOf) type)
        {
            foreach (child; allOf.children)
            {
                if (auto objectType = cast(ObjectType) child)
                {
                    // Looks like an event. Just render 'data'.
                    if (auto dataObj = objectType.findKey("data"))
                    {
                        render.types ~= render.renderObject(key, dataObj, schemaConfig.invariant_, type.description);
                        rendered = true;
                        break;
                    }
                }
            }
            if (!rendered)
            {
                // Object plus a reference just gets it as a field aliased to this.
                if (allOf.children.count!(a => cast(Reference) a) == 1
                    && allOf.children.count!(a => cast(ObjectType) a) == 1)
                {
                    render.types ~= render.renderObject(key, type, schemaConfig.invariant_, type.description);
                    rendered = true;
                }
            }
        }
        else if (auto reference = cast(Reference) type)
        {
            // do nothing, we'll get it another way
            continue;
        }
        if (!rendered)
        {
            stderr.writefln!"Cannot render value for type %s: %s"(name, type.classinfo.name);
            return 1;
        }

        auto outputPath = buildPath(config.componentFolder, name ~ ".d");
        auto outputFile = File(outputPath, "w");

        outputFile.writefln!"// GENERATED FILE, DO NOT EDIT!";
        outputFile.writefln!"module %s;"(outputPath.stripExtension.pathToModule);
        outputFile.writefln!"";

        foreach (import_; render.imports.sort.uniq)
        {
            outputFile.writefln!"import %s;"(import_);
        }
        outputFile.writefln!"";
        foreach (generatedType; render.types.retro)
        {
            outputFile.write(generatedType);
        }
        outputFile.close;
    }
    // write service files
    foreach (file; files)
    {
        auto routes = file.routes
            .filter!(a => config.operations.get(a.operationId, OperationConfig()).include)
            .array;

        if (routes.empty)
            continue;

        const packagePrefix = config.serviceFolder.pathToModule;
        const name = file.path.baseName.stripExtension.kebabToCamelCase;
        const module_ = only(packagePrefix, name).join(".");
        const outputPath = buildPath(config.serviceFolder, name ~ ".d");
        auto outputFile = File(outputPath, "w");

        auto render = new Render(config.componentFolder.pathToModule, allKeysSet);

        render.types ~= render.renderRoutes(name, file.path, file.description, routes, file.parameters);

        // TODO render method writeToFile
        outputFile.writefln!"// GENERATED FILE, DO NOT EDIT!";
        outputFile.writefln!"module %s;"(module_);
        outputFile.writefln!"";

        foreach (import_; render.imports.sort.uniq)
        {
            outputFile.writefln!"import %s;"(import_);
        }
        outputFile.writefln!"";
        foreach (generatedType; render.types.retro)
        {
            outputFile.write(generatedType);
        }

        outputFile.close;
    }

    return 0;
});

// If we have both a type definition for X and a link to X in another yml,
// then ignore the reference declarations.
const(Type) pickBestType(const Type[] list)
{
    auto nonReference = list.filter!(a => !cast(Reference) a);

    if (!nonReference.empty)
    {
        return nonReference.front;
    }
    return list.front;
}

private string pathToModule(string path)
{
    return path
        .split("/")
        .filter!(a => !a.empty)
        .removeLeading("src")
        .removeLeading("export")
        .join(".");
}

private alias removeLeading = (range, element) => choose(range.front == element, range.dropOne, range);

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
            if (jsonValue.hasKey("info"))
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

alias valueObjectify = (string[] range) => range.front.valueObjectify.only.chain(range.dropOne).array;
alias valueObjectify = (string line) => format!"This immutable value type represents %s"(
    line.front.toLower.only.chain(line.dropOne));

private alias kebabToCamelCase = text => text
    .splitter("-")
    .map!capitalizeFirst
    .join;

unittest
{
    assert("foo".kebabToCamelCase == "Foo");
    assert("foo-bar".kebabToCamelCase == "FooBar");
}

private alias capitalizeFirst = range => chain(range.front.toUpper.only, range.drop(1)).toUTF8;
