module route;

import boilerplate;
import std.json;
import std.typecons;
import text.json.Decode;
import ToJson;
import types;

struct Route
{
    string url;

    string method;

    string description;

    string operationId;

    Type schema;

    Parameter[] parameters;

    Response[] responses;

    mixin(GenerateAll);
}

abstract class Parameter
{
    mixin(GenerateAll);
}

class UntypedValueParameter : Parameter
{
    string in_;

    @(This.Default!null)
    string description;

    string name;

    @(This.Default)
    Nullable!bool required;

    mixin(GenerateAll);
}

class ValueParameter : UntypedValueParameter
{
    Type schema;

    mixin(GenerateAll);
}

class RefParameter : Parameter
{
    string target;

    mixin(GenerateAll);
}

struct Response
{
    string code;

    @(This.Default!null)
    Type schema;

    mixin(GenerateAll);
}

Parameter decode(T : Parameter)(const JSONValue value)
in (value.type == JSONType.array)
{
    if (value.hasKey("$ref"))
    {
        return new RefParameter(value.getEntry("$ref").decodeJson!string);
    }
    // will fall back to string
    if (value.getEntry("schema") == JSONValue(JSONValue[].init))
    {
        with (value.toObject.decodeJson!(UntypedValueParameter, types.decode))
        {
            return new ValueParameter(in_, name, new StringType, description, required);
        }
    }
    return value.toObject.decodeJson!(ValueParameter, types.decode);
}

private alias _ = decode!Parameter;
