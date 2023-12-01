module types;

import boilerplate;
import std.algorithm;
import std.array;
import std.format;
import std.json;
import std.range;
import std.typecons;
import text.json.Decode;
import ToJson;

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
    if (value.hasKey("oneOf"))
    {
        const description = value.hasKey("description") ? value.getEntry("description").str : null;

        return new OneOf(value.getEntry("oneOf").decodeJson!(Type[], .decode), description);
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
    if (value.hasKey("enum"))
    {
        return new EnumType(value.getEntry("enum").decodeJson!(string[]));
    }
    if (type == "array")
    {
        return value.toObject.decodeJson!(ArrayType, .decode);
    }
    if (type == "bool" || type == "boolean")
    {
        return value.toObject.decodeJson!(BooleanType, .decode);
    }
    if (type == "number")
    {
        return value.toObject.decodeJson!(NumberType, .decode);
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

private alias frontOrNull = range => range.empty ? Nullable!(ElementType!(typeof(range)))() : range.front.nullable;

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

class EnumType : Type
{
    string[] entries;

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

class NumberType : Type
{
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

class OneOf : Type
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
        auto transformed = new OneOf(this.children.map!(a => dg(a)).array, this.description);
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
