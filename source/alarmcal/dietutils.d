module alarmcal.dietutils;
import std.datetime;

auto datePrinter(Date d)
{
    static struct DP {
        Date d;
        void toString(Out)(Out output) {
            import std.format;
            output.formattedWrite("%04d-%02d-%02d", d.year, d.month, d.day);
        }
    }
    return DP(d);
}

auto timePrinter(TimeOfDay tod)
{
    static immutable hourLookup = [12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
    static immutable ampmLookup = ["AM", "PM"];
    static struct TP {
        TimeOfDay tod;
        void toString(Out)(Out output) {
            import std.format;
            if(tod.minute == 0 && tod.second == 0) {
                output.formattedWrite("%d%s", hourLookup[tod.hour], ampmLookup[tod.hour / 12]);
            }
            else {
                output.formattedWrite("%d:%02d%s", hourLookup[tod.hour], tod.minute, ampmLookup[tod.hour / 12]);
            }
        }
    }

    return TP(tod);
}

TimeOfDay parseTime(string input)
{
    // split on colons
    import std.algorithm;
    import std.range;
    import std.conv;
    auto items = input.splitter(':').map!(to!int).chain(only(0));
    auto h = items.front;
    items.popFront;
    auto m = items.front;
    items.popFront;
    auto s = items.front;
    return TimeOfDay(h, m, s);
}
