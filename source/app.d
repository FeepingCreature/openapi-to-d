module app;

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

void main(string[] args)
{
    assert(args.length == 2);
    auto loader = new SchemaLoader;
    string[] imports;
    string[] structs;
    foreach (key, value; loader.load(args[1]).schemas)
    {
        if (cast(ObjectType) value)
        {
            structs ~= renderStruct(key.split("/").back, value, imports);
        }
    }
    foreach (import_; imports.sort)
    {
        writefln!"import %s;"(import_);
    }
    foreach (struct_; structs)
    {
        writefln!"%s"(struct_);
    }
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
        return new AllOf(value.getEntry("allOf").decodeJson!(Type[], .decode));
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

string renderStruct(string name, Type type, ref string[] imports)
in (cast(ObjectType) type)
{
    auto objectType = cast(ObjectType) type;
    string result = "\n";
    if (!type.description.empty)
    {
        result ~= type.description.renderComment(0);
    }
    result ~= format!"immutable struct %s\n{\n"(name);
    foreach (tableEntry; objectType.properties)
    {
        bool required = objectType.required.canFind(name);
        result ~= renderMember(tableEntry.key, tableEntry.value, !required, imports);
        result ~= "\n";
    }
    result ~= "    mixin(GenerateAll);\n";
    result ~= "}";
    return result;
}

string renderComment(string comment, int indent)
{
    const spacer = ' '.repeat(indent).array;
    const lines = comment
        .strip
        .split("\n")
        .strip!(a => a.empty)
        .valueObjectify;
    if (lines.length == 1)
    {
        return format!"%s/// %s\n"(spacer, lines.front);
    }
    return format!"%s/**\n"(spacer)
        ~ lines.map!(line => format!"%s * %s\n"(spacer, line)).join
        ~ format!"%s */\n"(spacer);
}

alias valueObjectify = (string[] range) => range.front.valueObjectify.only.chain(range.dropOne).array;
alias valueObjectify = (string line) => format!"This immutable value type represents %s"(
    line.front.toLower.only.chain(line.dropOne));

string renderMember(string name, Type type, bool optional, ref string[] imports, string modifier = "")
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
            return format!"    @(This.Default)\n    bool %s;\n"(name);
        }
        return format!"    bool%s %s;\n"(modifier, name);
    }
    if (auto stringType = cast(StringType) type)
    {
        return format!"    string%s %s;\n"(modifier, name);
    }
    if (auto objectType = cast(ObjectType) type)
    {
        return format!"    JSONValue%s %s;\n"(modifier, name);
    }
    if (auto arrayType = cast(ArrayType) type)
    {
        return renderMember(name, arrayType.items, optional, imports, modifier ~ "[]");
    }
    if (auto reference = cast(Reference) type)
    {
        const typeName = reference.target.split("/").back;
        const import_ = dirEntries("include", "*.d", SpanMode.depth)
            .filter!(file => !file.name.endsWith("Test.d"))
            .map!(a => a.readText)
            .filter!(a => a.canFind(format!"struct %s\n"(typeName)))
            .frontOrNull
            .apply!(a => a.find("module ").drop("module ".length).until(";").toUTF8);

        if (!import_.isNull && !imports.canFind(import_.get))
            imports ~= import_.get;

        return format!"    %s%s %s;\n"(typeName, modifier, name);
    }
    assert(false, format!"TODO %s"(type));
}

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

private alias frontOrNull = range => range.empty ? Nullable!(ElementType!(typeof(range)))() : range.front.nullable;
