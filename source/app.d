module app;

import argparse;
import boilerplate;
import config;
import dyaml;
import render;
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

    foreach (source; config.source) {
        foreach (key, type; loader.load(source).schemas) {
            type.setSource(source);
            schemas[key] ~= type;
            keysInOrder ~= key;
        }
    }

    auto allKeysSet = keysInOrder
        .map!(key => tuple!("key", "value")(key.keyToTypeName, true))
        .assocArray;
    const packagePath = config.targetFolder.pathToModule;

    foreach (key; keysInOrder)
    {
        const types = schemas[key];
        const type = pickBestType(types);
        const name = key.keyToTypeName;
        auto schemaConfig = config.schemas.get(name, SchemaConfig());

        if (!schemaConfig.include)
            continue;

        auto render = new Render(schemaConfig, config.targetFolder.pathToModule, allKeysSet);

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

        auto outputPath = buildPath(config.targetFolder, name ~ ".d");
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

Type decode(T)(const JSONValue value)
if (is(T == Type))
in (value.type == JSONType.array)
{
    string type = value.hasKey("type") ? value.getEntry("type").str : null;
    if (value.hasKey("allOf"))
    {
        const description = value.hasKey("description") ? value.getEntry("description").str : null;

        return new AllOf(value.getEntry("allOf").decodeJson!(Type[], .decode), description);
    }
    if (value.hasKey("$ref"))
    {
        return new Reference(value.getEntry("$ref").decodeJson!string);
    }
    if (type == "object" || type.empty && value.hasKey("properties"))
    {
        return value.toObject.decodeJson!(ObjectType, .decode);
    }
    if (type == "string")
    {
        return value.toObject.decodeJson!(StringType, .decode);
    }
    if (type == "array")
    {
        return value.toObject.decodeJson!(ArrayType, .decode);
    }
    if (type == "bool" || type == "boolean")
    {
        return value.toObject.decodeJson!(BooleanType, .decode);
    }
    assert(false, format!"I don't know what this is: %s"(value));
}

AdditionalProperties decode(T : AdditionalProperties)(const JSONValue value)
in (value.type == JSONType.array)
{
    auto type = decode!Type(value);
    auto additionalProperties = Nullable!int();

    if (value.hasKey("minProperties"))
    {
        additionalProperties = value.getEntry("minProperties").decodeJson!int;
    }
    return new AdditionalProperties(type, additionalProperties);
}

private alias _ = decode!Type;
private alias _ = decode!AdditionalProperties;

class OpenApiFile
{
    Type[string] schemas;

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
            Type[string] result = null;

            foreach (JSONValue pair; jsonValue.getEntry("components").getEntry("schemas").array)
            {
                const key = pair["key"].str;

                result[format!"components/schemas/%s"(key)] = pair["value"].decodeJson!(Type, decode);
            }
            this.files[path] = new OpenApiFile(result);
        }
        return this.files[path];
    }

    mixin(GenerateToString);
}

alias valueObjectify = (string[] range) => range.front.valueObjectify.only.chain(range.dropOne).array;
alias valueObjectify = (string line) => format!"This immutable value type represents %s"(
    line.front.toLower.only.chain(line.dropOne));

bool hasKey(JSONValue table, string key)
in (table.isTable)
{
    return table.array.any!(a => a["key"] == JSONValue(key));
}

JSONValue getEntry(JSONValue table, string key)
in (table.isTable)
{
    foreach (value; table.array)
    {
        if (value["key"].str == key)
        {
            return value["value"];
        }
    }
    assert(false, format!"No key %s in table %s"(key, table));
}

JSONValue toObject(JSONValue table)
in (table.isTable)
{
    JSONValue[string] result;
    foreach (value; table.array)
    {
        result[value["key"].str] = value["value"];
    }
    return JSONValue(result);
}

bool isTable(JSONValue value)
{
    return value.type == JSONType.array && value.array.all!(
        a => a.type == JSONType.object && a.object.length == 2
            && "key" in a && "value" in a && a["key"].type == JSONType.string);
}
