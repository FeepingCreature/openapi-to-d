module config;

import boilerplate;
import dyaml;
import std.json;
import std.typecons;
import text.json.Decode;
import ToJson;

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
