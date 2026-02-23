module alarmcal.formudas;

// do not provide an editor for this field
enum noform;

// string is a password, and is stored as a hash.
enum password;

// field is optional on extraction
enum optional;

struct dbenum(T) {
    alias Type = T;
}
