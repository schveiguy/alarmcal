module alarmcal.formudas;
import std.traits : hasUDA, getUDAs;

// do not provide an editor for this field
enum noform;

// string is a password, and is stored as a hash.
enum password;

// field is optional on extraction
enum optional;

struct dbenum(T) {
    alias Type = T;
}

// override the display label for a form field
struct label {
    string text;
}

private string fieldNameToCapitals(string s) pure {
    if (s.length == 0) return s;
    import std.ascii : toUpper, isUpper;
    string result = [toUpper(s[0])];
    for (int i = 1; i < s.length; ++i) {
        char c = s[i];
        if (c == '_') {
            ++i;
            c = toUpper(s[i]);
        }
        if (isUpper(c))
            result ~= ' ';
        result ~= c;
    }
    return result;
}

// returns the display label for a field: @label text if present, otherwise field name converted to Capital Case
template getFieldLabel(alias field) {
    static if (hasUDA!(field, label))
        enum getFieldLabel = getUDAs!(field, label)[0].text;
    else
        enum getFieldLabel = fieldNameToCapitals(__traits(identifier, field));
}
