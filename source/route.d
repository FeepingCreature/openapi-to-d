module route;

import boilerplate;
import std.json;
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

class ValueParameter : Parameter
{
    string in_;

    @(This.Default!null)
    string description;

    string name;

    Type schema;

    @(This.Default!true)
    bool required;

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
    return value.toObject.decodeJson!(ValueParameter, types.decode);
}

private alias _ = decode!Parameter;
