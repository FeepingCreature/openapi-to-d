module app;

import argparse;
import boilerplate;
import dyaml;
import std.algorithm;
import std.array;
import std.file;
import std.json;
import std.path;
import std.range;
import std.stdio;
import std.string;
import std.typecons;
import std.utf;
import text.json.Decode;

@(Command.Description("Convert OpenAPI specification to serialized-ready D structs"))
struct Arguments
{
    @(PositionalArgument(0).Description("OpenAPI input file"))
    string input;

    @(NamedArgument.Required.Description("Output file that will be written"))
    string output;

    // often invariants are not easily expressed in OpenAPI.
    @(NamedArgument("bonus-invariant").Description("Inject an additional invariant into the type"))
    string[] bonusInvariants;

    @(NamedArgument.Description("Types that will be generated"))
    string[] type;
}

mixin CLI!Arguments.main!((const Arguments arguments)
{
    auto loader = new SchemaLoader;
    auto outputFile = File(arguments.output, "w");
    auto moduleName = arguments.output
        .stripExtension
        .split("/")
        .removeLeading("src")
        .removeLeading("export")
        .join(".");

    auto schemas = loader.load(arguments.input).schemas;
    const string[] types = arguments.type.empty ? [moduleName.split(".").back] : arguments.type;
    auto render = new Render(types, arguments.decodeInvariantArgs, arguments.input);

    foreach (name; types)
    {
        auto match = schemas
            .keys
            .find!(a => a.split("/").back == name)
            .frontOrNull;

        if (match.isNull)
        {
            auto available = schemas.keys.map!(a => a.split("/").back).array;

            stderr.writefln!"ERROR: unknown type '%s' of %s"(name, available);
            return 1;
        }

        const key = match.get;
        const value = schemas[key];

        if (cast(ObjectType) value)
        {
            render.renderObject(key, value, value.description);
            continue;
        }
        if (auto allOf = cast(AllOf) value)
        {
            foreach (child; allOf.children)
            {
                if (auto objectType = cast(ObjectType) child)
                {
                    if (auto dataObj = objectType.findKey("data"))
                    {
                        render.renderObject(key, dataObj, value.description);
                    }
                }
            }
        }
    }

    outputFile.writefln!"// GENERATED FILE, DO NOT EDIT!";
    outputFile.writefln!"module %s;"(moduleName);
    outputFile.writefln!"";

    foreach (import_; render.imports.sort.uniq)
    {
        outputFile.writefln!"import %s;"(import_);
    }
    foreach (struct_; render.structs)
    {
        outputFile.writefln!"%s"(struct_);
    }
    return 0;
});

string[][string] decodeInvariantArgs(Arguments arguments)
{
    string[][string] result = null;

    foreach (invariant_; arguments.bonusInvariants)
    {
        with (invariant_.findSplit("=").rename!("key", "_", "value"))
        {
            result[key] ~= value;
        }
    }
    return result;
}

class Render
{
    @(This.Default!(() => ["boilerplate"]))
    string[] imports;

    @(This.Default)
    string[] structs;

    string[] requestedTypes;

    string[][string] bonusInvariants;

    string source;

    void renderObject(string key, const Type value, string description)
    {
        const name = key.split("/").back;

        if (cast(ObjectType) value)
        {
            renderStruct(name, value, description);
            return;
        }
        if (auto allOf = cast(AllOf) value)
        {
            if (allOf.children.length == 1)
            {
                // struct, one member, aliased to this.
                if (auto reference = cast(Reference) allOf.children[0])
                {
                    auto substitute = new ObjectType;
                    const fieldName = reference.target.referenceToType.asFieldName;

                    substitute.properties ~= TableEntry!Type(fieldName, reference);
                    substitute.required ~= fieldName;
                    renderStruct(name, substitute, description, format!"alias %s this;"(fieldName));
                    return;
                }
                // allOf with one direct inline type: just flatten it into a struct.
                // When is this useful...?
                renderObject(key, allOf.children[0], description);
                return;
            }
        }
        stderr.writefln!"WARN: not renderable %s; %s"(key, value.classinfo.name);
    }

    void renderStruct(string name, const Type type, string description, string extra = null)
    in (cast(ObjectType) type)
    {
        auto objectType = cast(ObjectType) type;
        string result = "\n";

        if (!description.empty)
        {
            result ~= description.renderComment(0, this.source);
        }
        result ~= format!"immutable struct %s\n{\n"(name);
        foreach (tableEntry; objectType.properties)
        {
            const required = objectType.required.canFind(tableEntry.key);

            result ~= renderMember(tableEntry.key, tableEntry.value, !required);
            result ~= "\n";
        }
        if (name in this.bonusInvariants)
        {
            foreach (invariant_; this.bonusInvariants.get(name, null))
            {
                result ~= format!"    invariant (%s);\n\n"(invariant_);
            }
        }
        if (!extra.empty)
        {
            result ~= format!"    %s\n\n"(extra);
        }
        if (!objectType.required.empty)
        {
            // disabling this() on a struct with all-optional fields
            // results in an unconstructable type
            result ~= "    @disable this();\n\n";
        }
        result ~= "    mixin(GenerateAll);\n";
        result ~= "}";
        structs ~= result;
    }

    string renderMember(string name, Type type, bool optional, string modifier = "")
    {
        if (auto booleanType = cast(BooleanType) type)
        {
            if (optional)
            {
                assert(modifier == "");
                if (!booleanType.default_.isNull)
                {
                    return format!"    @(This.Default!%s)\n    bool %s;\n"(booleanType.default_.get, name);
                }
                imports ~= "std.typecons";
                return format!"    @(This.Default)\n    Nullable!bool %s;\n"(name);
            }
            return format!"    bool%s %s;\n"(modifier, name);
        }
        if (auto stringType = cast(StringType) type)
        {
            string udaPrefix = "";
            if (!stringType.minLength.isNull && stringType.minLength.get == 1)
            {
                udaPrefix = "    @NonEmpty\n";
            }
            string actualType = "string";

            if (stringType.format_ == "date-time")
            {
                actualType = "SysTime";
                imports ~= "std.datetime";
            }

            if (optional)
            {
                imports ~= "std.typecons";
                return format!"%s    @(This.Default)\n    %s %s;\n"(udaPrefix, nullableType(actualType, modifier), name);
            }
            return format!"%s    %s%s %s;\n"(udaPrefix, actualType, modifier, name);
        }
        if (auto objectType = cast(ObjectType) type)
        {
            imports ~= "std.json";
            if (optional)
            {
                imports ~= "std.typecons";
                return format!"    @(This.Default)\n    %s %s;\n"(nullableType("JSONValue", modifier), name);
            }
            return format!"    JSONValue%s %s;\n"(modifier, name);
        }
        if (auto arrayType = cast(ArrayType) type)
        {
            if (arrayType.minItems == 1)
            {
                return "    @NonEmpty\n"
                    ~ renderMember(name, arrayType.items, optional, modifier ~ "[]");
            }
            return renderMember(name, arrayType.items, optional, modifier ~ "[]");
        }
        if (auto reference = cast(Reference) type)
        {
            const typeName = reference.target.referenceToType;
            const matchingImports = dirEntries("src", "*.d", SpanMode.depth)
                .chain(dirEntries("include", "*.d", SpanMode.depth))
                .filter!(file => !file.name.endsWith("Test.d"))
                .map!(a => a.readText)
                .filter!(a => a.canFind(format!"struct %s\n"(typeName))
                    || a.canFind(format!"enum %s\n"(typeName)))
                .map!(a => a.find("module ").drop("module ".length).until(";").toUTF8)
                .array;

            if (matchingImports.empty && !this.requestedTypes.canFind(typeName))
            {
                stderr.writefln!"WARN: no import found for type %s"(reference.target);
            }

            if (matchingImports.length > 1)
            {
                stderr.writefln!"WARN: multiple module sources for %s: %s, using %s"(
                    reference.target, matchingImports, matchingImports.front);
            }

            if (!matchingImports.empty)
                imports ~= matchingImports.front;

            if (optional)
            {
                imports ~= "std.typecons";
                return format!"    @(This.Default)\n    %s %s;\n"(nullableType(typeName, modifier), name);
            }
            return format!"    %s%s %s;\n"(typeName, modifier, name);
        }
        assert(false, format!"TODO %s"(type));
    }

    mixin(GenerateThis);
}

alias referenceToType = target => target.split("/").back;

alias asFieldName = type => chain(type.front.toLower.only, type.dropOne).toUTF8;

unittest
{
    assert("Foo".asFieldName == "foo");
    assert("FooBar".asFieldName == "fooBar");
}

abstract class Type
{
    @(This.Default)
    string description;

    // are we monadic yet
    abstract Type transform(Type delegate(Type) dg);

    mixin(GenerateAll);
}

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

private alias _ = decode!Type;

struct TableEntry(T)
{
    string key;

    T value;

    mixin(GenerateAll);
}

class ObjectType : Type
{
    @(This.Default!null)
    TableEntry!Type[] properties;

    @(This.Default!null)
    string[] required;

    Type findKey(string key)
    {
        return properties
            .filter!(a => a.key == key)
            .frontOrNull
            .apply!"a.value"
            .get(null);
    }

    override Type transform(Type delegate(Type) dg)
    {
        with (ObjectType.Builder())
        {
            properties = this.properties
                .map!(a => TableEntry!Type(a.key, dg(a.value)))
                .array;
            required = this.required;
            description = this.description;
            return value;
        }
    }

    mixin(GenerateAll);
}

class ArrayType : Type
{
    Type items;

    @(This.Default)
    Nullable!int minItems;

    override Type transform(Type delegate(Type) dg)
    {
        return new ArrayType(dg(this.items), this.minItems, this.description);
    }

    mixin(GenerateAll);
}

class StringType : Type
{
    @(This.Default)
    string[] enum_;

    @(This.Default)
    Nullable!string format_;

    @(This.Default)
    Nullable!int minLength;

    override Type transform(Type delegate(Type) dg)
    {
        return this;
    }

    mixin(GenerateAll);
}

class BooleanType : Type
{
    @(This.Default)
    Nullable!bool default_;

    override Type transform(Type delegate(Type) dg)
    {
        return this;
    }

    mixin(GenerateAll);
}

class AllOf : Type
{
    Type[] children;

    override Type transform(Type delegate(Type) dg)
    {
        return new AllOf(this.children.map!(a => dg(a)).array, this.description);
    }

    mixin(GenerateAll);
}

class Reference : Type
{
    string target;

    override Type transform(Type delegate(Type) dg)
    {
        return this;
    }

    mixin(GenerateAll);
}

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
            const JSONValue jsonValue = root.toJson;
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

string renderComment(string comment, int indent, string source)
{
    const spacer = ' '.repeat(indent).array;
    const lines = [format!"This value object has been generated from %s:"(source)] ~ comment
        .strip
        .split("\n")
        .strip!(a => a.empty);

    return format!"%s/**\n"(spacer)
        ~ lines.map!(line => format!"%s * %s"(spacer, line).stripRight ~ "\n").join
        ~ format!"%s */\n"(spacer);
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

JSONValue toJson(const Node node)
{
    final switch (node.type) with (NodeType) {
        case null_: return JSONValue(null_);
        case merge: assert(false);
        case boolean: return JSONValue(node.get!bool);
        case integer: return JSONValue(node.get!int);
        case decimal: return JSONValue(node.get!int);
        case binary: return JSONValue(node.get!int);
        case timestamp: return JSONValue(node.get!(.string));
        case string: return JSONValue(node.get!(.string));
        case mapping:
            // Make an array, because order.
            JSONValue[] result;
            foreach (.string key, const Node value; node)
            {
                result ~= JSONValue(["key": JSONValue(key), "value": value.toJson]);
            }
            return JSONValue(result);
        case sequence:
            JSONValue[] result;
            foreach (const Node value; node)
            {
                result ~= value.toJson;
            }
            return JSONValue(result);
        case invalid:
            assert(false);
    }
}

string nullableType(string type, string modifier)
{
    if (modifier.empty)
    {
        return format!"Nullable!%s"(type);
    }
    return format!"Nullable!(%s%s)"(type, modifier);
}

private alias removeLeading = (range, element) => choose(range.front == element, range.dropOne, range);

private alias frontOrNull = range => range.empty ? Nullable!(ElementType!(typeof(range)))() : range.front.nullable;
