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
import std.uni;
import std.utf;
import text.json.Decode;

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

struct Config
{
    const(string)[] source;

    string targetFolder;

    SchemaConfig[string] schemas;

    mixin(GenerateAll);
}

struct SchemaConfig
{
    @(This.Default!true)
    bool include = true;

    @(This.Default)
    const(string)[] invariant_;

    mixin(GenerateAll);
}

Config loadConfig(string path)
{
    const root = Loader.fromFile(path).load;
    const JSONValue jsonValue = root.toJson(No.ordered);

    return decodeJson!(Config, decodeConfig)(jsonValue);
}

const(string)[] decodeConfig(T : const(string)[])(const JSONValue value)
{
    if (value.type == JSONType.string)
    {
        return [value.str];
    }
    return value.decodeJson!(string[]);
}

private alias _ = decodeConfig!(string[]);

class Render
{
    @(This.Default!(() => ["boilerplate"]))
    string[] imports;

    @(This.Default)
    string[] types;

    SchemaConfig schemaConfig;

    string modulePrefix;

    bool[string] typesBeingGenerated;

    string renderObject(string key, const Type value, const string[] invariants, string description)
    {
        const name = key.keyToTypeName;

        if (auto objectType = cast(ObjectType) value)
        {
            return renderStruct(name, objectType, invariants, description);
        }
        if (auto allOf = cast(AllOf) value)
        {
            if (allOf.children.count!(a => cast(Reference) a) <= 1
                && allOf.children.count!(a => cast(ObjectType) a) <= 1)
            {
                auto refChildren = allOf.children.map!(a => cast(Reference) a).find!"a";
                auto objChildren = allOf.children.map!(a => cast(ObjectType) a).find!"a";
                auto substitute = new ObjectType(null, null);
                string extra = null;

                substitute.setSource(value.source);
                if (!objChildren.empty)
                {
                    auto obj = objChildren.front;

                    substitute.properties ~= obj.properties;
                    substitute.required ~= obj.required;
                }
                if (!refChildren.empty)
                {
                    auto reference = refChildren.front;
                    // struct, one member, aliased to this.
                    const fieldName = reference.target.keyToTypeName.asFieldName;

                    substitute.properties ~= TableEntry!Type(fieldName, reference);
                    substitute.required ~= fieldName;
                    extra = format!"alias %s this;"(fieldName);
                }
                return renderStruct(name, substitute, invariants, description, extra);
            }
        }
        stderr.writefln!"ERR: not renderable %s; %s"(key, value.classinfo.name);
        assert(false);
    }

    string renderStruct(string name, ObjectType objectType, const(string)[] invariants, string description,
        string extra = null)
    {
        string result;

        if (!description.empty)
        {
            result ~= description.renderComment(0, objectType.source);
        }
        result ~= format!"immutable struct %s\n{\n"(name);
        string extraTypes, members;
        foreach (tableEntry; objectType.properties)
        {
            const required = objectType.required.canFind(tableEntry.key);
            const optional = !required;
            const allowNull = true;

            members ~= renderMember(tableEntry.key.fixReservedIdentifiers, tableEntry.value,
                optional, allowNull, extraTypes);
            members ~= "\n";
        }
        if (!objectType.additionalProperties.isNull)
        {
            Type elementType = objectType.additionalProperties.get.type;
            Nullable!int minProperties = objectType.additionalProperties.get.minProperties;
            const optional = false, allowNull = true;

            members ~= renderMember("additionalProperties", elementType, optional, allowNull, extraTypes, "[string]");
            members ~= "\n";
            if (!minProperties.isNull)
            {
                invariants ~= format!"this.additionalProperties.length >= %s"(minProperties.get);
            }
        }

        result ~= extraTypes;
        result ~= members;
        foreach (invariant_; invariants)
        {
            result ~= format!"    invariant (%s);\n\n"(invariant_);
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
        if (!objectType.additionalProperties.isNull)
        {
            result ~= "    alias additionalProperties this;\n\n";
        }
        result ~= "    mixin(GenerateAll);\n";
        result ~= "}\n";
        return result;
    }

    void renderEnum(string name, string[] members, string source, string description)
    {
        string result;

        if (!description.empty)
        {
            result ~= description.renderComment(0, source);
        }
        result ~= format!"enum %s\n{\n"(name);
        foreach (member; members)
        {
            result ~= "    " ~ member.screamingSnakeToCamelCase ~ ",\n";
        }
        result ~= "}\n";
        types ~= result;
    }

    string renderMember(string name, Type type, bool optional, bool allowNull, ref string extraTypes,
        string modifier = "")
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
                const fieldAllowNull = false;
                return format!"    @(This.Default)\n    %s %s;\n"(nullableType("bool", "", fieldAllowNull), name);
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
            else if (!stringType.enum_.empty)
            {
                actualType = name.capitalize;
                extraTypes ~= format!"    enum %s\n    {\n"(actualType);
                foreach (member; stringType.enum_)
                {
                    extraTypes ~= "        " ~ member.screamingSnakeToCamelCase ~ ",\n";
                }
                extraTypes ~= "    }\n\n";
            }

            if (optional)
            {
                return format!"%s    @(This.Default)\n    %s %s;\n"(
                    udaPrefix, nullableType(actualType, modifier, allowNull), name);
            }
            return format!"%s    %s%s %s;\n"(udaPrefix, actualType, modifier, name);
        }
        if (auto objectType = cast(ObjectType) type)
        {
            if (objectType.properties.empty)
            {
                imports ~= "std.json";
                if (optional)
                {
                    return format!"    @(This.Default)\n    %s %s;\n"(
                        nullableType("JSONValue", modifier, allowNull), name);
                }
                return format!"    JSONValue%s %s;\n"(modifier, name);
            }
        }
        if (auto arrayType = cast(ArrayType) type)
        {
            // if we want an invariant, we must allow Nullable.
            const allowElementNull = arrayType.minItems.isNull;
            const member = renderMember(name, arrayType.items, optional, allowElementNull, extraTypes, modifier ~ "[]");

            if (!arrayType.minItems.isNull)
            {
                if (arrayType.minItems.get == 1)
                {
                    return "    @NonEmpty\n" ~ member;
                }
                if (arrayType.minItems.get > 1)
                {
                    return member ~ format!"\n    invariant (this.%s.length >= %s);\n"(name, arrayType.minItems.get);
                }
            }
            return member;
        }
        if (auto reference = cast(Reference) type)
        {
            const result = resolveReference(reference);

            if (!result.import_.isNull)
            {
                imports ~= result.import_.get;
            }
            const typeName = result.typeName;

            if (optional)
            {
                return format!"    @(This.Default)\n    %s %s;\n"(nullableType(typeName, modifier, allowNull), name);
            }
            return format!"    %s%s %s;\n"(typeName, modifier, name);
        }

        // render as subtype
        const capitalizedName = name.capitalizeFirst;
        const typeName = modifier.isArrayModifier ? capitalizedName.singularize : capitalizedName;

        extraTypes ~= renderObject(typeName, type, null, null).indent ~ "\n";
        if (optional)
        {
            return format!"    @(This.Default)\n    %s %s;\n"(nullableType(typeName, modifier, allowNull), name);
        }
        return format!"    %s%s %s;\n"(typeName, modifier, name);
    }

    Tuple!(string, "typeName", Nullable!string, "import_") resolveReference(const Reference reference)
    {
        const typeName = reference.target.keyToTypeName;
        if (typeName in this.typesBeingGenerated)
        {
            return typeof(return)(typeName, Nullable!string(this.modulePrefix ~ "." ~ typeName));
        }
        return .resolveReference(reference);
    }

    private string nullableType(string type, string modifier, bool allowNullInit)
    {
        if (allowNullInit && modifier.isArrayModifier)
        {
            // we can just use the type itself as the nullable type
            return type ~ modifier;
        }
        imports ~= "std.typecons";
        if (modifier.empty)
        {
            return format!"Nullable!%s"(type);
        }
        return format!"Nullable!(%s%s)"(type, modifier);
    }

    mixin(GenerateThis);
}

private bool isArrayModifier(string modifier)
{
    return modifier.endsWith("[]");
}

Tuple!(string, "typeName", Nullable!string, "import_") resolveReference(const Reference reference)
{
    const typeName = reference.target.keyToTypeName;
    const matchingImports = dirEntries("src", "*.d", SpanMode.depth)
        .chain(dirEntries("include", "*.d", SpanMode.depth))
        .filter!(file => !file.name.endsWith("Test.d"))
        .map!(a => a.readText)
        .filter!(a => a.canFind(format!"struct %s\n"(typeName))
            || a.canFind(format!"enum %s\n"(typeName)))
        .map!(a => a.find("module ").drop("module ".length).until(";").toUTF8)
        .array;

    if (matchingImports.empty)
    {
        stderr.writefln!"WARN: no import found for type %s"(reference.target);
    }

    if (matchingImports.length > 1)
    {
        stderr.writefln!"WARN: multiple module sources for %s: %s, using %s"(
            reference.target, matchingImports, matchingImports.front);
    }

    if (!matchingImports.empty)
    {
        return typeof(return)(typeName, matchingImports.front.nullable);
    }
    return typeof(return)(typeName, Nullable!string());
}

alias keyToTypeName = target => target.split("/").back;

alias asFieldName = type => chain(type.front.toLower.only, type.dropOne).toUTF8;

unittest
{
    assert("Foo".asFieldName == "foo");
    assert("FooBar".asFieldName == "fooBar");
}

// Quick and dirty plural to singular conversion.
private string singularize(string name)
{
    if (name.endsWith("s"))
    {
        return name.dropBack(1);
    }
    return name;
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

string indent(string text)
{
    string indentLine(string line)
    {
        return "    " ~ line;
    }

    return text
        .split("\n")
        .map!(a => a.empty ? a : indentLine(a))
        .join("\n");
}

abstract class Type
{
    @(This.Exclude)
    string source;

    void setSource(string source)
    {
        this.source = source;
    }

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

    @(This.Default)
    Nullable!AdditionalProperties additionalProperties;

    override void setSource(string source)
    {
        super.setSource(source);
        foreach (entry; properties)
        {
            entry.value.setSource(source);
        }
    }

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
            source = this.source;
            description = this.description;
            additionalProperties = this.additionalProperties;
            return value;
        }
    }

    mixin(GenerateAll);
}

class AdditionalProperties
{
    Type type;

    @(This.Default)
    Nullable!int minProperties;

    mixin(GenerateAll);
}

class ArrayType : Type
{
    Type items;

    @(This.Default)
    Nullable!int minItems;

    override void setSource(string source)
    {
        super.setSource(source);
        this.items.setSource(source);
    }

    override Type transform(Type delegate(Type) dg)
    {
        auto transformed = new ArrayType(dg(this.items), this.minItems, this.description);
        transformed.setSource(this.source);
        return transformed;
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

    override void setSource(string source)
    {
        super.setSource(source);
        foreach (child; children)
        {
            child.setSource(source);
        }
    }

    override Type transform(Type delegate(Type) dg)
    {
        auto transformed = new AllOf(this.children.map!(a => dg(a)).array, this.description);
        transformed.setSource(this.source);
        return transformed;
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

JSONValue toJson(const Node node, Flag!"ordered" ordered)
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
            if (ordered)
            {
                // Make an array, to preserve order.
                JSONValue[] result;
                foreach (.string key, const Node value; node)
                {
                    result ~= JSONValue(["key": JSONValue(key), "value": value.toJson(ordered)]);
                }
                return JSONValue(result);
            }
            else
            {
                JSONValue[.string] result;
                foreach (.string key, const Node value; node)
                {
                    result[key] = value.toJson(ordered);
                }
                return JSONValue(result);
            }
        case sequence:
            JSONValue[] result;
            foreach (const Node value; node)
            {
                result ~= value.toJson(ordered);
            }
            return JSONValue(result);
        case invalid:
            assert(false);
    }
}

private alias frontOrNull = range => range.empty ? Nullable!(ElementType!(typeof(range)))() : range.front.nullable;

private alias screamingSnakeToCamelCase = a => a
    .split("_")
    .map!toLower
    .capitalizeAllButFirst
    .join;

private alias capitalizeAllButFirst = range => chain(range.front.only, range.drop(1).map!capitalize);

private alias capitalizeFirst = range => chain(range.front.toUpper.only, range.drop(1)).toUTF8;

unittest
{
    assert("FOO".screamingSnakeToCamelCase == "foo");
    assert("FOO_BAR".screamingSnakeToCamelCase == "fooBar");
}

private string fixReservedIdentifiers(string name)
{
    switch (name)
    {
        static foreach (identifier; reservedIdentifiers)
        {
        case identifier:
            return identifier ~ "_";
        }
        default:
            return name;
    }
}

private enum reservedIdentifiers = [
    "abstract", "alias", "align", "asm", "assert", "auto",
    "body", "bool", "break", "byte",
    "case", "cast", "catch", "cdouble", "cent", "cfloat", "char", "class", "const", "continue", "creal",
    "dchar", "debug", "default", "delegate", "delete", "deprecated", "do", "double",
    "else", "enum", "export", "extern",
    "false", "final", "finally", "float", "for", "foreach", "foreach_reverse", "function",
    "goto",
    "idouble", "if", "ifloat", "immutable", "import", "in", "inout", "int", "interface", "invariant", "ireal", "is",
    "lazy", "long",
    "macro", "mixin", "module",
    "new", "nothrow", "null",
    "out", "override",
    "package", "pragma", "private", "protected", "public", "pure",
    "real", "ref", "return",
    "scope", "shared", "short", "static", "struct", "super", "switch", "synchronized",
    "template", "this", "throw", "true", "try", "typeid", "typeof",
    "ubyte", "ucent", "uint", "ulong", "union", "unittest", "ushort",
    "version", "void",
    "wchar", "while", "with",
];
