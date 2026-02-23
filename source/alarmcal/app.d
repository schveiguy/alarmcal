module alarmcal.app;

import alarmcal.db;
import alarmcal.router;
import form = alarmcal.formudas;

import std.array;
import std.datetime;
import core.time;
import std.typecons;
import std.logger;
import std.exception;

import diet.html;

import sqlbuilder.dialect.sqlite;
import sqlbuilder.dataset;

import serverino;

mixin ServerinoLoop;

int cliAddUser(string[] args) {
    auto db = openDB();
    import std.conv : to;
    // args: name email password membertype
    enforce(args.length == 4, "usage: cli addUser name email password membertype");
    auto p = Person(
            name: args[0],
            email: args[1],
            password_hash: getPasswordHash(args[2]),
            membertype: args[3].to!MemberType,
            );
    db.create(p);
    import std.stdio;
    writeln(i"Added user id $(p.id) with name '$(p.name)', email '$(p.email)', member type $(p.membertype)");
    return 0;
}


int main(string[] args)
{
    import std.base64 : Base64;
    import std.process : environment;
    import std.string : split;

    // intercept the "cli" subcommand
    if (args.length > 1 && args[1] == "cli")
    {
        enforce(args.length > 2, "cli subcommand must be provided");
        switch(args[2]) {
            case "addUser":
                return cliAddUser(args[3 .. $]);
            default:
                throw new Exception("Unknown cli command: " ~ args[2]);
        }
        return 0;
    }

    if (environment.get("SERVERINO_ARGS") !is null)
        args = (cast(string)Base64.decode(environment.get("SERVERINO_ARGS"))).split("\0");
    return mainServerinoLoop!OnMainThread(args);
}

void renderDiet(Args...)(ref Output output)
{
    auto text = appender!string;
    text.compileHTMLDietFile!(Args);
    output.addHeader("content-type", "text/html");
    output.write(text[]);
}

void redirect(ref Output output, string location)
{
    output.addHeader("Location", location);
    output.status = 303;
}

void serveStaticFile(ref Output output, string filename, string contentType)
{
    output.addHeader("content-type", contentType);
    static import std.file;
    output.write(std.file.read(filename));
}

string getPasswordHash(string input) {
    import botan.passhash.bcrypt;
    import botan.rng.rng;
    import botan.rng.auto_rng;
    scope AutoSeededRNG rng = new AutoSeededRNG;
    return generateBcrypt(input, rng, 10);
}

T extract(T, string prefix="")(Request.SafeAccess!string data) {
    T result;
    data.extract(result);
    return result;
}

void extract(T, string prefix="")(Request.SafeAccess!string data, ref T target) {
    import std.traits;
    import std.conv;
    import sqlbuilder.uda;
    import std.stdio;
    import alarmcal.dietutils;

    static foreach(idx; 0 .. T.tupleof.length) {{
        static if(!hasUDA!(target.tupleof[idx], autoIncrement) && !hasUDA!(target.tupleof[idx], form.noform)){
            alias FT = typeof(target.tupleof[idx]);
            enum formname = prefix ~ __traits(identifier, T.tupleof[idx]);
            static if(hasUDA!(target.tupleof[idx], form.password)) {{
                auto hash = getPasswordHash(data.read(formname).to!string);
                target.tupleof[idx] = hash.to!FT;
            }}
            else static if(is(FT == DateTime)) {
                target.tupleof[idx] = DateTime(Date.fromISOExtString(data.read(formname ~ "_d")),
                        parseTime(data.read(formname ~ "_t")));
            }
            else {
                auto val = data.read(formname);
                if(val.length == 0)
                {
                    static if (!(hasUDA!(target.tupleof[idx], form.optional)))
                        throw new Exception("Need required field " ~ formname);
                }
                else
                    target.tupleof[idx] = val.to!FT;
            }
        }
    }}
}

struct EventInfo
{
    Event event;
    PersonEvent[] attendees;
}

struct CalendarDay
{
    Date date;
    EventInfo[] events; // sorted by start time
}

@requestScope
{
    Person currentUser;
    Database db;
}

Nullable!CalendarDay[][] getMonth(Date date, Event[][Date] events)
{
    Nullable!CalendarDay[][] cal;
    date.day = 1;
    auto curmon = date.month;
    if(date.dayOfWeek != DayOfWeek.sun) {
        cal.length += 1;
        foreach(d; DayOfWeek.sun .. date.dayOfWeek)
            cal[$-1] ~= Nullable!CalendarDay();
    }
    while(curmon == date.month) {
        if(date.dayOfWeek == DayOfWeek.sun) {
            // start a new week.
            cal.length += 1;
        }
        auto cd = CalendarDay(date);
        if(auto evs = date in events) {
            foreach(ev; *evs) {
                auto evi = EventInfo(ev);
                DataSet!PersonEvent ds;
                evi.attendees = db.fetch(select(ds).where(ds.event_id, " = ", ev.id.param)).array;
                cd.events ~= evi;
            }
        }
        cal[$-1] ~= nullable(cd);
        date += 1.days;
    }
    foreach(d; cal[$-1][$-1].get.date.dayOfWeek + 1 .. DayOfWeek.sat + 1)
        cal[$-1].length += 1;

    return cal;
}

Person[int] getPersonMap() {
    DataSet!Person ds;
    Person[int] result;
    foreach(p; db.fetch(select(ds))) result[p.id] = p;
    return result;
}

// TODO: use sessions instead of basic auth?
@priority(10)
@endpoint
void checkAuth(Request request, Output output){

    // validate the user is logged in.
    auto username = request.user;
    auto password = request.password;
    db = openDB();
    DataSet!Person ds;
    currentUser = db.fetchOne(select(ds).where(ds.email, " = ", request.user.param), Person.init);
    import botan.passhash.bcrypt;
    if(currentUser.password_hash == "" || !checkBcrypt(request.password, currentUser.password_hash)) {
        output.status = 401;
		output.addHeader("www-authenticate",`Basic realm="4H alarm calendar"`);
        if(currentUser.id == -1)
        {
            // invalid user
            if(request.user != "")
                warningf("Invalid user: %s", request.user);
        }
        else
            // invalid password
            warningf("Failed login attempt for user %s", request.user);
    }
}

struct IndexViewModel {
    enum DisplayStyle {
        calendar,
        list,
    }
    struct Params {
        @(form.optional) bool my_events;
        @(form.optional) DisplayStyle style;
    }
    Params params;
    Person[int] people;
    Nullable!CalendarDay[][][] cal;
}

@endpoint
@getRoute!"/"
void index(Request request, Output output)
{
    IndexViewModel model;
    request.get.extract(model.params);

    // figure out the days we need to pay attention to, up to one month before the current month
    Date minDate = cast(Date)Clock.currTime;
    minDate.day = 1;
    minDate.add!"months"(-1);
    DataSet!Event ds;
    Event[][Date] events;
    Date maxDate = minDate;
    auto query = select(ds).where(ds.start, " >= ", DateTime(minDate, TimeOfDay(0, 0, 0)).param);
    if (model.params.my_events) {
        query = query.where(ds.people.person_id, " = ", currentUser.id.param);
    }
    foreach(ev; db.fetch(query))
    {
        if(ev.start.date > maxDate) maxDate = ev.start.date;
        events.require(ev.start.date) ~= ev;
    }
    import std.stdio;
    while(minDate <= maxDate)
    {
        model.cal ~= getMonth(minDate, events);
        minDate.add!"months"(1);
    }
    model.people = getPersonMap();
    output.renderDiet!("index.dt", model, currentUser);
}

@endpoint
@getRoute!"/addEvent"
void addEventForm(Request request, Output output) {
    output.renderDiet!("addEvent.dt");
}

@endpoint
@postRoute!"/performAddEvent"
void performAddEvent(Request request, Output output) {
    auto e = request.post.extract!Event();
    db.create(e);
    infof("Created event %s of type %s at location id %s, starting at %s ending at %s (min students %s, max students %s, min adults %s)",
            e.title, e.type, e.location_id, e.start, e.end, e.minStudents, e.maxStudents, e.minAdults);
    output.redirect("/");
}


@endpoint
@getRoute!"/addPerson"
void addPersonForm(Request request, Output output) {
    output.renderDiet!("addPerson.dt");
}

@endpoint
@postRoute!"/performAddPerson"
void performAddPerson(Request request, Output output) {
    auto p = request.post.extract!Person();
    import std.stdio;
    db.create(p);
    infof("Created person named %s of type %s", p.name, p.membertype);
    output.redirect("/");
}

@endpoint
@getRoute!"/addLocation"
void addLocationForm(Request request, Output output) {
    output.renderDiet!("addLocation.dt");
}

@endpoint
@postRoute!"/performAddLocation"
void performAddLocation(Request request, Output output) {
    auto l = request.post.extract!Location();
    db.create(l);
    infof("Created location %s at address %s", l.name, l.address);
    output.redirect("/");
}

@endpoint
@getRoute!"/rsvp"
void rsvp(Request request, Output output) {
    static struct params {
        int event_id;
        bool attending;
    }
    auto p = request.get.extract!params;
    // check if the rsvp already exists
    DataSet!PersonEvent ds;
    auto imGoing = db.fetchOne(select(count(ds.person_id)).where(ds.person_id, " = ", currentUser.id.param, " AND ", ds.event_id, " = ", p.event_id.param));
    if(imGoing) {
        if(!p.attending)
            // remove the rsvp
            db.perform(removeFrom(ds.tableDef).where(ds.person_id, " = ", currentUser.id.param, " AND ", ds.event_id, " = ", p.event_id.param));
    }
    else if(p.attending) {
        // add the rsvp
        db.create(PersonEvent(
                    person_id: currentUser.id,
                    event_id: p.event_id,
                    ));
    }
    output.redirect("/");
}

@endpoint
@getRoute!"/checkIn"
void checkIn(Request request, Output output) {
    static struct params {
        @(form.optional) int location_id = -1;
        @(form.optional) int event_id = -1;
    }
    DataSet!PersonEvent ds;
    auto p = request.get.extract!params;
    if(p.location_id != -1) {
        // The person is checking in to all events today at this location
        auto today = cast(Date)Clock.currTime;
        auto eventInfo = db.fetchOne(select(count(ds.id), exprCol!(Nullable!long)("SUM(", ds.attendanceRecorded, ")")).where(ds.person_id, " = ", currentUser.id.param, " AND ", ds.event.location_id, " = ", p.location_id.param, " AND date(", ds.event.start, ") = ", today.param));
        if(eventInfo[0] == 0) {
            import std.format;
            enum result = "Invalid checkin";
            auto message = format("No events at location %s, please RSVP for an event here before attempting to check in.", db.fetchUsingKey!Location(p.location_id).name);
            output.renderDiet!("messageRedirect.dt", result, message);
        }
        else if(eventInfo[1] == eventInfo[0]) {
            enum result = "Already checked in";
            auto message = "You have already checked in for today's event(s). No need to checkin again";
            output.renderDiet!("messageRedirect.dt", result, message);
        }
        else {
            db.perform(set(ds.attendanceRecorded, true.param).where(ds.person_id, " = ", currentUser.id.param, " AND ", ds.event.location_id, " = ", p.location_id.param, " AND date(", ds.event.start, ") = ", today.param));
            enum result = "Checked in";
            auto message = "Thanks for checking in for today's event(s)!";
            output.renderDiet!("messageRedirect.dt", result, message);
        }
    } else if(p.event_id != -1) {
        db.perform(set(ds.attendanceRecorded, true.param).where(ds.person_id, " = ", currentUser.id.param, " AND ", ds.event_id, " = ", p.event_id.param));
    } else {
        output.status = 400;
        output.write("You must supply either an event id or a location id to checkin");
    }
}

@endpoint
@getRoute!"/assets/css/index.css"
void indexCss(Request request, Output output) {
    output.serveStaticFile("views/index.css", "text/css; charset=utf-8");
}


/* The default configuration is used if you do not implement this function.*/

@onServerInit ServerinoConfig configure()
{
	return ServerinoConfig
		.create()
		.addListener("127.0.0.1", 8080);

		// You can set many other options here. For example:
		// .setMaxRequestTime(1.seconds)
		// .setMaxRequestSize(1024*1024); // 1 MB
		// .setWorkers(10); // To set a fixed number of workers.
		// Many other options are available: https://trikko.github.io/serverino/serverino/config/ServerinoConfig.html
}
