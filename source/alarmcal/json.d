module alarmcal.json;

import iopipe.json.dom;
import iopipe.json.serialize;

import std.traits : isFloatingPoint, isIntegral;

// implement niceties around the json type to make things easy to use while typeless.
public struct JsonVal {
    private alias JV = JSONValue!string;
    enum Type : int {
        Integer = JSONType.Integer,
        Floating = JSONType.Floating,
        String = JSONType.String,
        Obj = JSONType.Obj,
        Array = JSONType.Array,
        Null = JSONType.Null,
        Bool = JSONType.Bool,
        // adds this one
        Undefined
    }

    private JV _value;

    enum undefinedValue = JsonVal(JV(type: cast(JSONType)Type.Undefined));
    enum emptyObject = JsonVal(JV(type: JSONType.Obj, object: null));
    enum emptyArray = JsonVal(JV(type: JSONType.Array, array: []));

    Type type() const => cast(Type)_value.type;

    inout(JsonVal) opIndex(size_t idx) inout{
        if(type == Type.Array && _value.array.length > idx)
            return inout(JsonVal)(_value.array[idx]);
        return undefinedValue;
    }

    inout(JsonVal) opIndex(string key) inout {
        if(type == Type.Obj)
            if(auto v = key in _value.object)
                return inout(JsonVal)(*v);
        return undefinedValue;
    }

    size_t length() const {
        switch(type) {
            case Type.Array:
                return _value.array.length;
            case Type.Obj:
                return _value.object.length;
            default:
                return 0;
        }
    }

    // Get the internal value as a T. If the type is not compatible, returns
    // the default value.
    @property inout(T) get(T)(T defaultValue) inout {
        static if (is(immutable T == immutable string))
        {
            if(type == Type.String)
                return _value.str;
            return defaultValue;
        }
        else static if (is(immutable T == immutable bool))
        {
            if(type == Type.Bool)
                return _value.boolean;
            return defaultValue;
        }
        else static if (isFloatingPoint!T)
        {
            switch (type)
            {
            case Type.Floating:
                return cast(T) _value.floating;
            case Type.Integer:
                return cast(T) _value.integer;
            default:
                return defaultValue;
            }
        }
        else static if (isIntegral!T)
        {
            switch (type)
            {
            case Type.Floating:
                return cast(T)_value.floating;
            case Type.Integer:
                return cast(T)_value.integer;
            default:
                return defaultValue;
            }
        }
        else
        {
            return defaultValue;
        }
    }

    static JsonVal fromJSON(JT, Policy)(ref JT tokenizer, ref Policy policy) {
        // deserialize directly using the JSONValue
        JV value;
        policy.deserializeImpl(tokenizer, value);
        return JsonVal(value);
    }

    void toJSON(Policy, Writer)(ref Policy policy, ref Writer w) {
        policy.serializeImpl(w, _value);
    }

    int opApply(scope int delegate(size_t index, ref JsonVal) dg) @system
    {
        int result;
        if(type == Type.Array) {
            foreach(size_t index, ref value; _value.array) {
                result = dg(index, *cast(JsonVal*)&value);
                if(result)
                    break;
            }
        }
        return result;
    }

    int opApply(scope int delegate(string key, ref JsonVal) dg) @system {
        int result;
        if(type == Type.Obj) {
            foreach(key, ref value; _value.object) {
                result = dg(key, *cast(JsonVal*)&value);
                if(result)
                    break;
            }
        }
        return result;
    }

    int opApply(scope int delegate(ref JsonVal) dg) @system {
        int result;
        if(type == Type.Obj) {
            foreach(ref value; _value.object) {
                result = dg(*cast(JsonVal*)&value);
                if(result)
                    break;
            }
        }
        else if(type == Type.Array) {
            foreach(ref value; _value.array) {
                result = dg(*cast(JsonVal*)&value);
                if(result)
                    break;
            }
        }
        return result;
    }

    inout(JsonVal)* opBinaryRight(string op: "in")(string k) inout {
        if(type != Type.Obj)
            return null;
        return cast(inout(JsonVal)*) (k in _value.object);
    }

    // use opcast to bool to check if the value is valid
    bool opCast(T: bool)() => type != Type.Undefined;

    // Convenience function to get a string with a default value. Since strings
    // are very common, we give it a dedicated function.
    auto str(string defaultValue = "") inout => get!string(defaultValue);
}

unittest {
    static JsonVal parse(string json) => deserialize!JsonVal(json);

    auto v = parse(`{
        "s": "text", "i": 42, "f": 1.5, "t": true, "n": null,
        "arr": [10, "x", {"deep": "val"}],
        "obj": {"a": 1, "b": {"c": "d"}},
        "emptyArr": [], "emptyObj": {}
    }`);

    // types
    assert(v.type == JsonVal.Type.Obj);
    assert(v["s"].type == JsonVal.Type.String);
    assert(v["i"].type == JsonVal.Type.Integer);
    assert(v["f"].type == JsonVal.Type.Floating);
    assert(v["t"].type == JsonVal.Type.Bool);
    assert(v["n"].type == JsonVal.Type.Null);
    assert(v["arr"].type == JsonVal.Type.Array);
    assert(v["obj"].type == JsonVal.Type.Obj);

    // typed access, with defaults on a type mismatch
    assert(v["s"].str == "text");
    assert(v["s"].get("dflt") == "text");
    assert(v["i"].str == "");
    assert(v["i"].str("dflt") == "dflt");
    assert(v["i"].get!int(0) == 42);
    assert(v["i"].get!long(0) == 42);
    assert(v["i"].get!double(0) == 42.0);
    assert(v["f"].get!double(0) == 1.5);
    assert(v["f"].get!int(0) == 1);
    assert(v["s"].get!int(7) == 7);
    assert(v["t"].get(false) == true);
    assert(v["s"].get(true) == true);
    assert(v["n"].str("dflt") == "dflt");

    // indexing nested values
    assert(v["obj"]["b"]["c"].str == "d");
    assert(v["arr"][0].get!int(0) == 10);
    assert(v["arr"][1].str == "x");
    assert(v["arr"][2]["deep"].str == "val");

    // anything missing or of the wrong kind is Undefined, and Undefined swallows
    // further accesses without throwing
    assert(v["missing"].type == JsonVal.Type.Undefined);
    assert(v["arr"][3].type == JsonVal.Type.Undefined);
    assert(v["arr"][size_t.max].type == JsonVal.Type.Undefined);
    assert(v["emptyArr"][0].type == JsonVal.Type.Undefined);
    assert(v["s"]["key"].type == JsonVal.Type.Undefined); // string is not an object
    assert(v["s"][0].type == JsonVal.Type.Undefined); // string is not an array
    assert(v["obj"][0].type == JsonVal.Type.Undefined); // object is not an array
    assert(v["arr"]["key"].type == JsonVal.Type.Undefined); // array is not an object
    assert(v["missing"]["a"][3]["b"].type == JsonVal.Type.Undefined);
    assert(v["missing"]["a"][3]["b"].str("dflt") == "dflt");
    assert(v["missing"].get!int(5) == 5);
    assert(v["missing"].length == 0);
    assert(JsonVal.undefinedValue.type == JsonVal.Type.Undefined);

    // truthiness: anything but Undefined, including null and false
    assert(cast(bool)v);
    assert(cast(bool)v["n"]);
    assert(cast(bool)v["t"]);
    assert(!cast(bool)v["missing"]);
    assert(!cast(bool)v["arr"][99]);

    // length
    assert(v.length == 9);
    assert(v["arr"].length == 3);
    assert(v["obj"].length == 2);
    assert(v["emptyArr"].length == 0);
    assert(v["emptyObj"].length == 0);
    assert(v["s"].length == 0);
    assert(v["i"].length == 0);

    // the `in` operator only applies to objects
    assert(("s" in v) !is null);
    assert(("s" in v).str == "text");
    assert(("missing" in v) is null);
    assert(("a" in v["obj"]) !is null);
    assert(("a" in v["arr"]) is null);
    assert(("a" in v["s"]) is null);
    assert(("a" in JsonVal.undefinedValue) is null);

    // the canned constants
    assert(JsonVal.emptyObject.type == JsonVal.Type.Obj);
    assert(JsonVal.emptyObject.length == 0);
    assert(JsonVal.emptyObject["a"].type == JsonVal.Type.Undefined);
    assert(JsonVal.emptyArray.type == JsonVal.Type.Array);
    assert(JsonVal.emptyArray.length == 0);
    assert(JsonVal.emptyArray[0].type == JsonVal.Type.Undefined);

    // iteration
    {
        long total;
        string[] strs;
        foreach(size_t i, ref el; v["arr"]) {
            if(el.type == JsonVal.Type.Integer)
                total += el.get!long(0);
            else if(el.type == JsonVal.Type.String)
                strs ~= el.str;
        }
        assert(total == 10 && strs == ["x"]);

        size_t count;
        foreach(ref el; v["arr"])
            ++count;
        assert(count == 3);

        int[string] seen;
        foreach(string key, ref el; v["obj"]) {
            if(el.type == JsonVal.Type.Integer)
                seen[key] = el.get!int(0);
        }
        assert(seen == ["a": 1]);

        count = 0;
        foreach(ref el; v["obj"])
            ++count;
        assert(count == 2);

        // iterating over things that aren't containers does nothing
        count = 0;
        foreach(ref el; v["s"])
            ++count;
        foreach(size_t i, ref el; v["missing"])
            ++count;
        foreach(string k, ref el; v["arr"])
            ++count;
        assert(count == 0);

        // early exit from iteration
        count = 0;
        foreach(size_t i, ref el; v["arr"]) {
            ++count;
            break;
        }
        assert(count == 1);
    }

    // top-level values that aren't objects
    assert(parse(`"hello"`).str == "hello");
    assert(parse(`[1, 2]`)[1].get!int(0) == 2);
    assert(parse(`null`).type == JsonVal.Type.Null);
    assert(parse(`12`)["a"].type == JsonVal.Type.Undefined);

    // works as a member of a deserialized struct
    static struct Wrapper {
        string name;
        JsonVal payload;
    }
    auto w = deserialize!Wrapper(`{"name": "n", "payload": {"k": [1, 2, 3]}}`);
    assert(w.name == "n");
    assert(w.payload["k"].length == 3);
    assert(w.payload["k"][2].get!int(0) == 3);

    // serialization round trip
    {
        auto json = `{"s":"text","n":null,"arr":[1,"x",{"k":true}],"obj":{"a":1.5}}`;
        auto orig = parse(json);
        auto again = parse(serialize(orig));
        assert(again["s"].str == "text");
        assert(again["n"].type == JsonVal.Type.Null);
        assert(again["arr"].length == 3);
        assert(again["arr"][0].get!int(0) == 1);
        assert(again["arr"][2]["k"].get(false) == true);
        assert(again["obj"]["a"].get!double(0) == 1.5);

        // and as a member of a struct
        static struct Wrapper2 {
            string name;
            JsonVal payload;
        }
        auto w2 = deserialize!Wrapper2(serialize(Wrapper2("n", orig)));
        assert(w2.name == "n");
        assert(w2.payload["arr"][1].str == "x");
    }
}
