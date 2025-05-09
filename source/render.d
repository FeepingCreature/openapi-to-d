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

    string[string] redirected;

    bool[string] typesBeingGenerated;

    // for resolving references when inlining
    Type[][string] schemas;

    string renderObject(string key, const Type value, const SchemaConfig config, string description)
    {
        const name = key.keyToTypeName;

        if (auto objectType = cast(ObjectType) value)
        {
            return renderStruct(name, objectType, config, description);
        }
        if (auto allOf = cast(AllOf) value)
        {
            Type loadSchema(string target)
            {
                const string relPath = target.until("#/").array.toUTF8;
                const string schemaName = target.find("#/").drop("#/".length);
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
            Type[] flattenAllOf(AllOf allOf)
            {
                Type[] result = null;
                foreach (child; allOf.children)
                {
                    if (auto nextAllOf = cast(AllOf) child)
                    {
                        result ~= flattenAllOf(nextAllOf);
                        continue;
                    }
                    if (auto refChild = cast(Reference) child)
                    {
                        auto schema = loadSchema(refChild.target);
                        if (auto nextAllOf = cast(AllOf) schema) {
                            result ~= flattenAllOf(nextAllOf);
                            continue;
                        }
                    }
                    result ~= child;
                }
                return result;
            }
            auto children = flattenAllOf(allOf);
            auto refChildren = children.map!(a => cast(Reference) a).filter!"a".array;
            auto objChildren = children.map!(a => cast(ObjectType) a).filter!"a".array;

            if (children.length == refChildren.length + objChildren.length)
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

                foreach (ref child; children)
                {
                    auto refChild = cast(Reference) child;
                    if (!refChild)
                        continue;
                    auto schema = loadSchema(refChild.target);
                    if (refChild.target.startsWith("#/"))
                    {
                        if (auto nextRef = cast(Reference) schema)
                        {
                            /**
                             * Reference in the same file that points at another reference?
                             * This must be the workaround for https://github.com/APIDevTools/swagger-cli/issues/59
                             * Bypass the first reference entirely.
                             */
                            child = nextRef;
                            refChild = nextRef;
                            schema = loadSchema(nextRef.target);
                        }
                    }
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

                foreach (child; children)
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
                return renderStruct(name, substitute, config, description, extra);
            }
        }
        stderr.writefln!"ERR: not renderable %s; %s"(key, value.classinfo.name);
        assert(false);
    }

    string renderStruct(string name, ObjectType objectType, const SchemaConfig config, string description,
        string extra = null)
    {
        const(string)[] invariants = config.invariant_;
        string result;

        if (!description.empty)
        {
            result ~= description.renderComment(0, objectType.source);
        }
        result ~= format!"immutable struct %s\n{\n"(name);
        string extraTypes, members;
        foreach (tableEntry; objectType.properties)
        {
            const fieldName = tableEntry.key.fixReservedIdentifiers;

            if (!config.properties.empty && !config.properties.canFind(fieldName))
                continue;

            const required = objectType.required.canFind(tableEntry.key);
            const optional = !required;
            const allowNull = true;

            members ~= renderMember(fieldName, tableEntry.value,
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
        if (!objectType.required.filter!(a => config.properties.empty || config.properties.canFind(a)).empty)
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
            result ~= "    " ~ member.screamingSnakeToCamelCase.fixReservedIdentifiers ~ ",\n";
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
        result ~= "    import util.IdType : IdType;\n\n";
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
        string renderDType(string dType)
        {
            if (optional)
            {
                const nullableDType = nullableType(dType, modifier, allowNull);

                return format!"    @(This.Default)\n    %s %s;\n"(nullableDType, name);
            }
            return format!"    %s%s %s;\n"(dType, modifier, name);
        }
        if (auto numberType = cast(NumberType) type)
        {
            return renderDType("double");
        }
        if (auto integerType = cast(IntegerType) type)
        {
            return renderDType(integerType.toDType);
        }
        if (auto stringType = cast(StringType) type)
        {
            string udaPrefix = "";
            if (!stringType.minLength.isNull && stringType.minLength.get == 1)
            {
                udaPrefix = "    @NonEmpty\n";
            }

            auto result = resolveSimpleStringType(stringType);

            string actualType = "string";
            if (!result.isNull)
            {
                actualType = result.get.typeName;
                imports ~= result.get.imports;
            }
            else if (!stringType.enum_.empty)
            {
                actualType = name.capitalize;
                extraTypes ~= format!"    enum %s\n    {\n"(actualType);
                foreach (member; stringType.enum_)
                {
                    extraTypes ~= "        " ~ member.screamingSnakeToCamelCase.fixReservedIdentifiers ~ ",\n";
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
            string tryInline()
            {
                if (!reference.target.canFind("#/")) return null;

                const targetSchema = reference.target.find("#/").drop("#/".length);

                if (targetSchema !in this.schemas) return null;

                const typeName = reference.target.keyToTypeName;

                if (!matchingImports(typeName).empty)
                {
                    return null;
                }

                auto schema = this.schemas[targetSchema].pickBestType;
                string inlineModifier = modifier;
                // TODO factor out into helper (compare app.d toplevel simple-schema resolution)
                while (auto arrayType = cast(ArrayType) schema)
                {
                    schema = arrayType.items;
                    inlineModifier ~= "[]";
                }
                if (auto stringType = cast(StringType) schema)
                {
                    if (!stringType.enum_.empty || typeName.endsWith("Id")) return null;
                }
                else if (cast(BooleanType) schema || cast(NumberType) schema || cast(IntegerType) schema)
                {
                    // inline alias
                }
                else
                {
                    return null;
                }

                // inline alias
                return renderMember(name, schema, optional, allowNull, extraTypes, inlineModifier);
            }

            if (auto result = tryInline)
            {
                return result;
            }

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

        extraTypes ~= renderObject(typeName, type, SchemaConfig(), null).indent ~ "\n";
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

            void addDParameter(const Type type, const string name, bool required = true)
            {
                if (!required)
                {
                    imports ~= "std.typecons";
                }
                if (auto refType = cast(Reference) type)
                {
                    const result = resolveReference(refType);
                    const typeName = required ? result.typeName : format!"Nullable!%s"(result.typeName);

                    if (!result.import_.isNull)
                    {
                        imports ~= result.import_.get(null);
                    }
                    dParameters ~= format!"const %s %s"(typeName, name);
                }
                else if (auto strType = cast(StringType) type)
                {
                    auto stringType = "string";
                    const result = resolveSimpleStringType(strType);
                    if (!result.isNull)
                    {
                        stringType = result.get.typeName;
                        imports ~= result.get.imports;
                    }
                    dParameters ~= format!"const %s%s %s"(required ? "" : "Nullable!", stringType, name);
                }
                else
                {
                    assert(false, format!"Type currently unsupported for URL parameters: %s"(type));
                }
            }

            foreach (urlParameter; urlParameters)
            {
                addDParameter(urlParameter.schema, urlParameter.name);
            }

            string typeToString(Type type)
            {
                if (type is null) return "void";
                if (auto refType = cast(Reference) type)
                {
                    const result = resolveReference(refType);

                    if (!result.import_.isNull)
                    {
                        imports ~= result.import_.get;
                    }
                    return result.typeName;
                }
                if (auto integerType = cast(IntegerType) type)
                {
                    return integerType.toDType;
                }
                if (auto stringType = cast(StringType) type)
                {
                    if (stringType.enum_.empty && stringType.format_.isNull)
                    {
                        return "string";
                    }
                }
                if (auto arrayType = cast(ArrayType) type)
                {
                    return typeToString(arrayType.items) ~ "[]";
                }
                const bodyType = route.operationId.capitalizeFirst;

                extraTypes ~= "\n" ~ renderObject(bodyType, type, SchemaConfig(), null);
                return bodyType;
            }

            const string bodyType = typeToString(cast() route.schema);

            if (bodyType != "void")
            {
                dParameters ~= "const " ~ bodyType;
            }

            const queryParameters = route.parameters
                .map!(a => cast(ValueParameter) a)
                .filter!"a !is null"
                .filter!(a => a.in_ == "query")
                .array;

            foreach (queryParameter; queryParameters)
            {
                addDParameter(queryParameter.schema, queryParameter.name, queryParameter.required.get(false));
            }

            string urlWithQueryParams = route.url;

            if (!queryParameters.empty)
            {
                urlWithQueryParams ~= "?" ~ queryParameters.map!(a => format!"%s={%s}"(a.name, a.name)).join("&");
            }

            if (i > 0) lines ~= "";
            lines ~= route.description.strip.split("\n").strip!(a => a.empty).renderComment(4);
            lines ~= linebreak((4).spaces, (12).spaces, [
                format!"@(Method.%s!("(route.method.capitalizeFirst),
                "JsonFormat, ",
                format!"%s, "(route.schema ? bodyType : "void"),
                format!"\"%s\"))"(urlWithQueryParams),
            ]);
            Type responseType = null;
            foreach (response; route.responses)
            {
                if (response.code.startsWith("2")) {
                    assert(responseType is null);
                    responseType = cast() response.schema;
                    continue;
                }
                // produced by the networking lib
                if (response.code == "422") continue;

                enforce(response.schema is null, "Error response cannot return body");

                const member = codeToMember(response.code);
                const exception = pickException(response.code);

                lines ~= format!"    @(Throws!(%s, ResponseCode.%s.expand))"(exception, member);
            }
            const string returnType = typeToString(responseType);

            lines ~= linebreak((4).spaces, (8).spaces, [
                format!"public %s %s("(returnType, route.operationId),
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
            case "422": return from("util.IllegalArgumentException", "IllegalArgumentException");
            case "503": return from("util.ServiceUnavailableException", "ServiceUnavailableException");
            case "512": return from("util.ConcurrentModificationException", "ConcurrentModificationException");
            default: return from("std.exception", "Exception");
        }
    }

    Tuple!(string, "typeName", Nullable!string, "import_") resolveReference(const Reference reference)
    {
        const typeName = reference.target.keyToTypeName;
        if (typeName in this.redirected)
        {
            return typeof(return)(typeName, this.redirected[typeName].nullable);
        }
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

Nullable!(Tuple!(string, "typeName", string[], "imports")) resolveSimpleStringType(const StringType type)
{
    if (!type.enum_.empty)
    {
        return typeof(return)();
    }
    if (type.format_ == "date-time")
    {
        return tuple!("typeName", "imports")("SysTime", ["std.datetime"]).nullable;
    }
    if (type.format_ == "date")
    {
        return tuple!("typeName", "imports")("Date", ["std.datetime"]).nullable;
    }
    if (type.format_ == "duration")
    {
        return tuple!("typeName", "imports")("Duration", ["std.datetime"]).nullable;
    }
    return typeof(return)();
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

alias Resolution = Tuple!(string, "typeName", Nullable!string, "import_");

__gshared const(string)[] allFiles;
__gshared const(string)[][string] moduleCache;
__gshared Object cacheLock;

shared static this()
{
    cacheLock = new Object;
    allFiles = dirEntries("src", "*.d", SpanMode.depth)
        .chain(dirEntries("include", "*.d", SpanMode.depth))
        .filter!(file => !file.name.endsWith("Test.d"))
        .map!(a => a.readText)
        .array;
}

private Resolution resolveReference(const Reference reference)
{
    const typeName = reference.target.keyToTypeName;
    const matchingImports = .matchingImports(typeName);

    if (matchingImports.empty)
    {
        stderr.writefln!"WARN: no import found for type %s"(reference.target);
    }

    if (matchingImports.length > 1)
    {
        stderr.writefln!"WARN: multiple module sources for %s: %s, using %s"(
            reference.target, matchingImports, matchingImports.front);
    }

    return Resolution(typeName, matchingImports.empty ? Nullable!string() : matchingImports.front.nullable);
}

private const(string)[] matchingImports(const string typeName)
{
    synchronized (cacheLock)
    {
        if (auto ptr = typeName in moduleCache)
        {
            return *ptr;
        }

        const matches = allFiles
            .filter!(a => a.canFind(format!"struct %s\n"(typeName))
                || a.canFind(format!"enum %s\n"(typeName)))
            .map!(a => a.find("module ").drop("module ".length).until(";").toUTF8)
            .array;

        moduleCache[typeName] = matches;
        return matches;
    }
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
