module ToJson;

import dyaml;
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
