module app;

import argparse;
import boilerplate;
import config;
import dyaml;
import render;
import route;
import SchemaLoader : OpenApiFile, SchemaLoader;
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
        auto types = schemas[key];
        auto type = pickBestType(types);
        const name = key.keyToTypeName;
        auto schemaConfig = config.schemas.get(name, SchemaConfig());

        if (!schemaConfig.include)
            continue;

        while (auto arrayType = cast(ArrayType) type)
        {
            type = arrayType.items;
        }

        auto render = new Render(config.componentFolder.pathToModule, allKeysSet, schemas);

        bool rendered = false;

        if (auto objectType = cast(ObjectType) type)
        {
            // Looks like an event. Just render 'data'.
            if (auto dataObj = objectType.findKey("data"))
            {
                render.types ~= render.renderObject(key, dataObj, schemaConfig.invariant_, type.description);
            }
            else
            {
                render.types ~= render.renderObject(key, type, schemaConfig.invariant_, type.description);
            }
            rendered = true;
        }
        else if (auto stringType = cast(StringType) type)
        {
            if (!stringType.enum_.empty)
            {
                render.renderEnum(name, stringType.enum_, type.source, type.description);
                rendered = true;
            }
            else if (name.endsWith("Id"))
            {
                render.renderIdType(name, type.source, type.description);
                rendered = true;
            }
            else
            {
                // will be inlined
                continue;
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
                const references = allOf.children.map!(a => cast(Reference) a).filter!"a".array;
                const objects = allOf.children.map!(a => cast(ObjectType) a).filter!"a".array;

                if (allOf.children.length == references.length + objects.length)
                {
                    // Any mix of refs and objects: refs are just inlined into the object.
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
    if (!config.serviceFolder.empty)
    {
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

            auto render = new Render(config.componentFolder.pathToModule, allKeysSet, schemas);

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
    }

    return 0;
});

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
