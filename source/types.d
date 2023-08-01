module types;

import boilerplate;
import std.algorithm;
import std.array;
import std.range;
import std.typecons;

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
