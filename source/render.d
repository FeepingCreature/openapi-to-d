module render;

import boilerplate;
import config;
import reverseResponseCodes;
import route;
import SchemaLoader : SchemaLoader;
import std.algorithm;
import std.array;
import std.exception;
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

    string modulePrefix;

    bool[string] typesBeingGenerated;

    // for resolving references when inlining
    Type[][string] schemas;

    string renderObject(string key, const Type value, const string[] invariants, string description)
    {
        const name = key.keyToTypeName;

        if (auto objectType = cast(ObjectType) value)
        {
            return renderStruct(name, objectType, invariants, description);
        }
        if (auto allOf = cast(AllOf) value)
        {
            auto refChildren = allOf.children.map!(a => cast(Reference) a).filter!"a".array;
            auto objChildren = allOf.children.map!(a => cast(ObjectType) a).filter!"a".array;

            if (allOf.children.length == refChildren.length + objChildren.length)
            {
                // generate object with all refs but one inlined
                auto substitute = new ObjectType(null, null);
                string extra = null;

                substitute.setSource(value.source);
                /**
                 * We can make exactly one ref child the alias-this.
                 * How do we pick? Easy: Use the one with the most properties.
                 */
                Reference refWithMostProperties = null;
                // Resolve all references in the course of looking for the fattest child
                Type[string] resolvedReferences;
                foreach (child; allOf.children)
                {
                    auto refChild = cast(Reference) child;
                    if (!refChild)
                        continue;
                    Type loadSchema()
                    {
                        const string relPath = refChild.target.until("#/").array.toUTF8;
                        const string schemaName = refChild.target.find("#/").drop("#/".length);
                        if (relPath.empty)
                        {
                            // try to find schema in own set.
                            assert(schemaName in this.schemas, format!"%s missing in %s"(
                                schemaName, this.schemas.keys));
                            return this.schemas[schemaName].pickBestType;
                        }
                        // We don't usually look at reference targets, so
                        // we manually invoke the loader just this once.
                        const string path = value.source.dirName.buildNormalizedPath(relPath);
                        auto loader = new SchemaLoader;
                        auto file = loader.load(path);
                        assert(schemaName in file.schemas, format!"%s missing in %s"(
                            schemaName, file.schemas.keys));
                        return file.schemas[schemaName];
                    }
                    auto schema = loadSchema;
                    resolvedReferences[refChild.target] = schema;
                    if (auto obj = cast(ObjectType) schema)
                    {
                        if (!refWithMostProperties)
                        {
                            refWithMostProperties = refChild;
                        }
                        else if (auto oldObj = cast(ObjectType) resolvedReferences[refWithMostProperties.target])
                        {
                            if (obj.properties.length > oldObj.properties.length)
                            {
                                refWithMostProperties = refChild;
                            }
                        }
                    }
                }

                foreach (child; allOf.children)
                {
                    if (auto obj = cast(ObjectType) child)
                    {
                        substitute.properties ~= obj.properties;
                        substitute.required ~= obj.required;
                    }
                    else if (auto refChild = cast(Reference) child)
                    {
                        if (refChild is refWithMostProperties)
                            continue;
                        if (!refChild.target.canFind("#/"))
                        {
                            stderr.writefln!"Don't understand reference target %s"(refChild.target);
                            assert(false);
                        }

                        auto schema = resolvedReferences[refChild.target];

                        if (auto obj = cast(ObjectType) schema)
                        {
                            substitute.properties ~= obj.properties;
                            substitute.required ~= obj.required;
                        }
                        else
                        {
                            stderr.writefln!"Reference %s target %s isn't an object; cannot inline"(
                                refChild, schema);
                            assert(false);
                        }
                    }
                    else assert(false);
                }
                if (refWithMostProperties)
                {
                    // use it for the alias-this reference
                    const fieldName = refWithMostProperties.target.keyToTypeName.asFieldName;

                    substitute.properties ~= TableEntry!Type(fieldName, refWithMostProperties);
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

    void renderIdType(string name, string source, string description)
    {
        string result;

        if (!description.empty)
        {
            result ~= description.renderComment(0, source);
        }
        result ~= format!"struct %s\n{\n"(name);
        result ~= "    import messaging.IdType : IdType;\n\n";
        result ~= format!"    mixin IdType!%s;\n"(name);
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
        if (auto numberType = cast(NumberType) type)
        {
            return format!"    double%s %s;\n"(modifier, name);
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

    string renderRoutes(string name, string source, string description, const Route[] routes,
        const Parameter[string] parameterComponents)
    {
        string[] lines;
        string[] extraTypes;

        imports ~= "messaging.Context : Context";
        imports ~= "net.http.ResponseCode";
        imports ~= "net.rest.Method";

        lines ~= "/**";
        lines ~= linebreak(" * ", " * ", ["This boundary interface has been generated from ", source ~ ":"]);
        lines ~= description.split("\n").map!strip.strip!(a => a.empty).map!(a => stripRight(" * " ~ a)).array;
        lines ~= " */";
        lines ~= format!"interface %s"(name);
        lines ~= "{";
        foreach (i, route; routes)
        {
            const availableParameters = route.parameters
                .map!(a => resolveParameter(a, parameterComponents))
                .filter!(a => a.in_ == "path")
                .array;

            const(ValueParameter) findParameterWithName(string name)
            {
                enforce(availableParameters.any!(a => a.name == name),
                    format!"route parameter with name \"%s\" not found"(name));
                return availableParameters.find!(a => a.name == name).front;
            }

            const urlParameters = route.url.split("/")
                .filter!(a => a.startsWith("{") && a.endsWith("}"))
                .map!(name => findParameterWithName(name.dropOne.dropBackOne))
                .array;
            string[] dParameters = null;

            foreach (urlParameter; urlParameters)
            {
                const type = urlParameter.schema;

                if (auto refType = cast(Reference) type)
                {
                    const result = resolveReference(refType);

                    if (!result.import_.isNull)
                    {
                        imports ~= result.import_.get;
                    }
                    dParameters ~= format!"const %s %s"(result.typeName, urlParameter.name);
                }
                else if (auto strType = cast(StringType) type)
                {
                    dParameters ~= format!"const string %s"(urlParameter.name);
                }
                else
                {
                    assert(false, format!"Type currently unsupported for URL parameters: %s"(type));
                }
            }

            string bodyType = "void";

            if (route.schema)
            {
                if (auto refType = cast(Reference) route.schema)
                {
                    const result = resolveReference(refType);

                    if (!result.import_.isNull)
                    {
                        imports ~= result.import_.get;
                    }
                    bodyType = result.typeName;
                }
                else
                {
                    bodyType = route.operationId.capitalizeFirst;
                    extraTypes ~= "\n" ~ renderObject(bodyType, route.schema, null, null);
                }
                dParameters ~= "const " ~ bodyType;
            }

            if (i > 0) lines ~= "";
            lines ~= route.description.strip.split("\n").strip!(a => a.empty).renderComment(4);
            lines ~= linebreak((4).spaces, (12).spaces, [
                format!"@(Method.%s!("(route.method.capitalizeFirst),
                "JsonFormat, ",
                format!"%s, "(route.schema ? bodyType : "void"),
                format!"\"%s\"))"(route.url),
            ]);
            foreach (responseCode; route.responseCodes)
            {
                if (responseCode.startsWith("2")) continue;
                // produced by the networking lib
                if (responseCode == "422") continue;

                const member = codeToMember(responseCode);
                const exception = pickException(responseCode);

                lines ~= format!"    @(Throws!(%s, ResponseCode.%s.expand))"(exception, member);
            }
            lines ~= linebreak((4).spaces, (8).spaces, [
                format!"public void %s("(route.operationId),
            ] ~ dParameters.map!(a => a ~ ", ").array ~ [
                "const Context context);"
            ]);
        }
        lines ~= "}";
        // retro to counteract retro in app.d (sorry)
        types ~= extraTypes.retro.array;
        return lines.join("\n") ~ "\n";
    }

    private string pickException(string responseCode)
    {
        string from(string package_, string member)
        {
            imports ~= package_;
            return member;
        }
        switch (responseCode)
        {
            case "404": return from("util.NoSuchElementException", "NoSuchElementException");
            case "409": return from("util.IllegalArgumentException", "IllegalArgumentException");
            default: return from("std.exception", "Exception");
        }
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

// If we have both a type definition for X and a link to X in another yml,
// then ignore the reference declarations.
Type pickBestType(Type[] list)
{
    auto nonReference = list.filter!(a => !cast(Reference) a);

    if (!nonReference.empty)
    {
        return nonReference.front;
    }
    return list.front;
}

// Given a list of fragments, linebreak and indent them to avoid exceeding 120 columns per line.
private string[] linebreak(string firstLineIndent, string restLineIndent, string[] fragments)
{
    string[] lines = null;
    string line = null;

    string lineIndent() { return lines.empty ? firstLineIndent : restLineIndent; }

    void flush()
    {
        if (line.empty) return;
        lines ~= (lineIndent ~ line.stripLeft).stripRight;
        line = null;
    }

    foreach (fragment; fragments)
    {
        if (lineIndent.length + line.length + fragment.length > 120) flush;
        line ~= fragment;
    }
    flush;
    return lines;
}

private const(ValueParameter) resolveParameter(const Parameter param, const Parameter[string] components)
{
    if (auto reference = cast(RefParameter) param)
    {
        enforce(reference.target.startsWith("#/"), format!"cannot resolve indirect $ref parameter (TODO) \"%s\""(
            reference.target));

        const target = reference.target["#/".length .. $];

        enforce(target in components,
            format!"cannot find target for $ref parameter \"%s\""(reference.target));
        return components[target].resolveParameter(components);
    }
    if (auto valParameter = cast(ValueParameter) param)
    {
        return valParameter;
    }
    assert(false, format!"Unknown parameter type %s"(param.classinfo.name));
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
    const lines = [format!"This value object has been generated from %s:"(source)] ~ comment
        .strip
        .split("\n")
        .strip!(a => a.empty);

    return renderComment(lines, indent).join("\n") ~ "\n";
}

private string[] renderComment(const string[] lines, int indent)
{
    const spacer = ' '.repeat(indent).array;

    return [format!"%s/**"(spacer)]
        ~ lines.map!(line => format!"%s * %s"(spacer, line).stripRight).array
        ~ format!"%s */"(spacer);
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
        return (4).spaces ~ line;
    }

    return text
        .split("\n")
        .map!(a => a.empty ? a : indentLine(a))
        .join("\n");
}

private alias spaces = i => ' '.repeat(i).array.idup;
