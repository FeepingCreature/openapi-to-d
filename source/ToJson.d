module ToJson;

import dyaml;
import std.algorithm;
import std.format;
import std.json;
import std.typecons;

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
