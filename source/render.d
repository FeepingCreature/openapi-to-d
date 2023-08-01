module render;

import boilerplate;
import config;
import std.algorithm;
import std.array;
import std.file;
import std.format;
import std.path;
import std.range;
import std.stdio;
import std.string;
import std.typecons;
import std.uni;
import std.utf;
import types;

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
                // string[string] object
                if (objectType.additionalProperties.apply!(a => cast(StringType) a.type !is null).get(false))
                {
                    string prefix = null;
                    string typeStr = "string[string]";
                    if (optional)
                    {
                        prefix ~= "    @(This.Default)\n";
                        typeStr = nullableType("string", "[string]", allowNull);
                    }
                    if (objectType.additionalProperties.get.minProperties.apply!(a => a == 1).get(false))
                    {
                        prefix ~= "    @NonEmpty\n";
                    }
                    return format!"%s    %s%s %s;\n"(prefix, typeStr, modifier, name);
                }
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

private Tuple!(string, "typeName", Nullable!string, "import_") resolveReference(const Reference reference)
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

private string renderComment(string comment, int indent, string source)
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

private bool isArrayModifier(string modifier)
{
    return modifier.endsWith("[]");
}

public alias keyToTypeName = target => target.split("/").back;

public alias asFieldName = type => chain(type.front.toLower.only, type.dropOne).toUTF8;

unittest
{
    assert("Foo".asFieldName == "foo");
    assert("FooBar".asFieldName == "fooBar");
}

private alias screamingSnakeToCamelCase = a => a
    .split("_")
    .map!toLower
    .capitalizeAllButFirst
    .join;

unittest
{
    assert("FOO".screamingSnakeToCamelCase == "foo");
    assert("FOO_BAR".screamingSnakeToCamelCase == "fooBar");
}

private alias capitalizeAllButFirst = range => chain(range.front.only, range.drop(1).map!capitalize);

private alias capitalizeFirst = range => chain(range.front.toUpper.only, range.drop(1)).toUTF8;

// Quick and dirty plural to singular conversion.
private string singularize(string name)
{
    if (name.endsWith("s"))
    {
        return name.dropBack(1);
    }
    return name;
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

private string indent(string text)
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
