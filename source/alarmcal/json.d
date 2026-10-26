module alarmcal.json;

import iopipe.json.dom;
import iopipe.json.serialize;

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
        if(type == Type.Array)
            return inout(JsonVal)(_value.array[idx]);
        return undefinedValue;
    }

    inout(JsonVal) opIndex(string key) inout {
        if(type == Type.Obj)
            return inout(JsonVal)(_value.object[key]);
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
            case JSONType.Floating:
                return cast(T)_value.floating;
            case JSONType.Integer:
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

    void toJSON(JT, Writer)(ref Policy policy, ref Writer w) {
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
