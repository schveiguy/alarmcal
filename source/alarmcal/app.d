module alarmcal.app;

import alarmcal.db;
import alarmcal.router;
import alarmcal.session;
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
    enforce(args.length >= 4 && args.length <= 5, "usage: cli addUser name email password memberType [admin]");
    auto p = Person(
            name: args[0],
            email: args[1],
            password_hash: getPasswordHash(args[2]),
            memberType: args[3].to!MemberType,
            admin: args.length > 4 && args[4] == "admin",
            );
    db.create(p);
    import std.stdio;
    writeln(i"Added user id $(p.id) with name '$(p.name)', email '$(p.email)', member type $(p.memberType), admin = $(p.admin)");
    return 0;
}


int main(string[] args)
{
    import std.base64 : Base64;
    import std.process : environment;
    import std.string : split;

    // always apply migrations
    applyMigrations();

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

T extract(T, string prefix="")(Request.SafeAccess!string data, string[] exceptThese = []) {
    T result;
    data.extract(result, exceptThese);
    return result;
}

void extract(string prefix="", T)(Request.SafeAccess!string data, ref T target, string[] exceptThese = []) {
    import std.traits;
    import std.conv;
    import sqlbuilder.uda;
    import std.stdio;
    import alarmcal.dietutils;
    import std.string : strip;
    import std.algorithm : canFind;

    static foreach(idx; 0 .. T.tupleof.length) {
        static if(!hasUDA!(target.tupleof[idx], autoIncrement) && !hasUDA!(target.tupleof[idx], form.noform)){
            if(!exceptThese.canFind(__traits(identifier, T.tupleof[idx]))) {
                alias FT = typeof(target.tupleof[idx]);
                enum formname = prefix ~ __traits(identifier, T.tupleof[idx]);
                static if(hasUDA!(target.tupleof[idx], form.password)) {
                    auto pw = data.read(formname).to!string;
                    if (pw.strip.length > 0) {
                        // password was provided, hash it.
                        auto hash = getPasswordHash(pw);
                        target.tupleof[idx] = hash.to!FT;
                    }
                    // else, leave the existing field.
                }
                else static if(is(FT == DateTime)) {
                    static if(hasUDA!(target.tupleof[idx], form.timeOnly)) {
                        target.tupleof[idx] = DateTime(Date.init, parseTime(data.read(formname)));
                    } else {
                        target.tupleof[idx] = DateTime(Date.fromISOExtString(data.read(formname ~ "_d")),
                                parseTime(data.read(formname ~ "_t")));
                    }
                }
                else static if(is(FT == Date)) {
                    target.tupleof[idx] = Date.fromISOExtString(data.read(formname));
                }
                else static if(is(FT == bool)) {
                    // booleans are a checkbox, and only if they are checked is the value transmitted.
                    target.tupleof[idx] = data.read(formname, "false").to!bool;
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
        }
    }
}

Event extractEvent(string prefix="")(Request.SafeAccess!string data) {
    auto event = extract!(Event, prefix)(data);
    // fix end event date to match start date
    event.end.date = event.start.date;
    return event;
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
    Session currentSession;
    AutoClosingDatabase db;
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

Location[int] getLocationMap() {
    DataSet!Location ds;
    Location[int] result;
    foreach(l; db.fetch(select(ds))) result[l.id] = l;
    return result;
}

bool isHttpsRequest(Request request)
{
    return request.header.read("x-forwarded-proto", "") == "https";
}

// Upper bound on how long the browser is allowed to retain the cookie. This is
// intentionally much longer than `sessionDuration`: the actual sliding 7-day
// inactivity timeout is enforced server-side by `validateSession`, which
// extends `Session.expires` in the database on every valid request. Because
// serverino treats any `output.setCookie` call as "this endpoint produced the
// response" (it marks Output dirty, which stops any further routing for the
// request - see worker.d's callUntilIsDirty), `checkSession` below must NOT
// reissue the cookie on every request, or it would swallow every authenticated
// page load before the real route handler ever runs. Setting a long, fixed
// client-side Max-Age once at login sidesteps that entirely: the cookie is
// just a storage cap, not the security boundary.
enum cookieMaxAge = 400.days;

void setSessionCookie(Request request, Output output, string token)
{
    output.setCookie(Cookie("session", token)
            .path("/")
            .httpOnly()
            .sameSite(Cookie.SameSite.Lax)
            .maxAge(cookieMaxAge)
            .secure(isHttpsRequest(request)));
}

@priority(10)
@endpoint
void checkSession(Request request, Output output){
    db = openDB();
    auto token = request.cookie.read("session", "");
    currentSession = validateSession(db, token);
    if(currentSession.id != -1)
    {
        currentUser = db.fetchUsingKey!Person(currentSession.person_id);
        return;
    }

    import std.algorithm : startsWith;
    if(request.path == "/login" || request.path == "/performLogin" || request.path.startsWith("/assets/"))
        return;

    output.redirect("/login");
}

@endpoint
@getRoute!"/login"
void loginForm(Request request, Output output) {
    if(currentUser.id != -1)
        return output.redirect("/");
    bool error = false;
    output.renderDiet!("login.dt", error);
}

@endpoint
@postRoute!"/performLogin"
void performLogin(Request request, Output output) {
    if(currentUser.id != -1)
        return output.redirect("/");

    auto email = request.post.read("email", "");
    auto password = request.post.read("password", "");
    DataSet!Person ds;
    auto candidate = db.fetchOne(select(ds).where(ds.email, " = ", email.param), Person.init);
    import botan.passhash.bcrypt;
    if(candidate.id == -1 || candidate.password_hash == "" || !checkBcrypt(password, candidate.password_hash)) {
        warningf("Failed login attempt for email %s", email);
        output.status = 401;
        bool error = true;
        return output.renderDiet!("login.dt", error);
    }

    auto session = startSession(db, candidate.id);
    setSessionCookie(request, output, session.token);
    infof("User %s logged in", candidate.email);
    output.redirect("/");
}

@endpoint
@getRoute!"/logout"
void logout(Request request, Output output) {
    if(currentUser.id != -1)
        endSession(db, request.cookie.read("session", ""));
    output.setCookie(Cookie("session", "").invalidate());
    output.redirect("/login");
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
    Location[int] locations;
    Nullable!CalendarDay[][][] cal;
}

void messageRedirect(Output output, string result, string message)
{
    output.renderDiet!("messageRedirect.dt", result, message);
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
    model.locations = getLocationMap();
    output.renderDiet!("index.dt", model, currentUser);
}

@endpoint
@getRoute!"/addEvent"
void addEventForm(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can add a new event");
    }
    output.renderDiet!("addEvent.dt", currentUser);
}

@endpoint
@postRoute!"/performAddEvent"
void performAddEvent(Request request, Output output) {
    import std.conv : to;
    import std.algorithm : canFind;
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can add a new event");
    }
    auto e = request.post.extractEvent();
    if (e.start > e.end) {
        output.status = 400;
        return output.messageRedirect("Error", "End time cannot be prior to start time");
    }
    static struct Repeat {
        bool sun, mon, tue, wed, thu, fri, sat;
        Date end;
        bool[7] days() => [sun, mon, tue, wed, thu, fri, sat];
    }
    bool doRepeat = request.post.read("repeat", "false").to!bool;
    Repeat repeat;

    if (doRepeat) {
        request.post.extract!"repeat_"(repeat);
        if(repeat.days[].canFind(true)) {
            auto maxEndDate = e.start.date;
            maxEndDate.add!"years"(1);
            if (repeat.end > maxEndDate) {
                output.status = 400;
                return output.messageRedirect("Error", "Repeat end date must be within 1 year of the event start date");
            }
        }
        else
            // no repeat days were selected, ignore.
            doRepeat = false;
    }

    // have everything we need, actually modify the database
    db.create(e);
    infof("Created event %s (id:%s) of type %s at location id %s, starting at %s ending at %s (min students %s, max students %s, min adults %s)",
            e.title, e.id, e.type, e.location_id, e.start, e.end, e.minStudents, e.maxStudents, e.minAdults);

    if (doRepeat) {
        // update the original event with the repeat tag id
        e.tag_id = nullable(e.id);
        db.save(e);

        auto duration = e.end - e.start;
        auto curDate = e.start.date + 1.days;
        auto repeatDays = repeat.days;
        while (curDate <= repeat.end) {
            if (repeatDays[curDate.dayOfWeek]) {
                Event repeated = e;
                repeated.id = 0;
                repeated.start = DateTime(curDate, e.start.timeOfDay);
                repeated.end = repeated.start + duration;
                db.create(repeated);
                infof("Created repeated event (id=%s) on %s", repeated.id, repeated.start);
            }
            curDate += 1.days;
        }
    }

    output.redirect("/");
}


@endpoint
@getRoute!"/addPerson"
void addPersonForm(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can add a person");
    }
    output.renderDiet!("addPerson.dt", currentUser);
}

@endpoint
@postRoute!"/performAddPerson"
void performAddPerson(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can add a person");
    }
    auto p = request.post.extract!Person();
    if(p.password_hash == null)
    {
        output.status = 400;
        return output.messageRedirect("Forbidden", "Password required for adding a person");
    }
    import std.stdio;
    db.create(p);
    infof("Created person named %s of type %s", p.name, p.memberType);
    output.redirect("/");
}

@endpoint
@getRoute!"/addLocation"
void addLocationForm(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can add a location");
    }
    output.renderDiet!("addLocation.dt", currentUser);
}

@endpoint
@postRoute!"/performAddLocation"
void performAddLocation(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can add a location");
    }
    auto l = request.post.extract!Location();
    db.create(l);
    infof("Created location %s at address %s", l.name, l.address);
    output.redirect("/");
}

@endpoint
@getRoute!"/persons"
void listPersonsRoute(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can view the person list");
    }
    import std.array;
    DataSet!Person ds;
    auto persons = db.fetch(select(ds)).array;
    output.renderDiet!("listPersons.dt", currentUser, persons);
}

@endpoint
@getRoute!"/editPerson"
void editPersonForm(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can edit a person");
    }
    static struct params { int id; }
    auto p = request.get.extract!params;
    auto item = db.fetchUsingKey!Person(p.id);
    output.renderDiet!("editPerson.dt", currentUser, item);
}

@endpoint
@postRoute!"/performEditPerson"
void performEditPerson(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can edit a person");
    }
    import std.conv : to;
    auto p = db.fetchUsingKey!Person(request.post.read("id").to!int);
    auto origPW = p.password_hash;
    request.post.extract(p);
    auto pwChanged = origPW != p.password_hash;
    db.save(p);
    if(pwChanged) {
        endAllSessions(db, p.id);
        infof("Password changed for person id:%s '%s' by %s, all sessions invalidated", p.id, p.name, currentUser.name);
    }
    infof("Updated person id:%s '%s' type=%s admin=%s by %s", p.id, p.name, p.memberType, p.admin, currentUser.name);
    output.redirect("/persons");
}

@endpoint
@getRoute!"/editProfile"
void editProfileForm(Request request, Output output) {
    output.renderDiet!("editProfile.dt", currentUser);
}

@endpoint
@postRoute!"/performEditProfile"
void performEditProfile(Request request, Output output) {
    import std.conv : to;
    auto p = currentUser;
    request.post.extract(p, exceptThese: ["admin", "memberType"]);
    auto pwChanged = currentUser.password_hash != p.password_hash;
    db.save(p);
    if(pwChanged) {
        endAllSessions(db, p.id);
        infof("Person id:%d '%s' changed their password, all other sessions invalidated", p.id, p.name);
    }
    infof("Person id:%s '%s' changed their profile, email=%s", p.id, p.name, p.email);
    output.redirect("/");
}

@endpoint
@getRoute!"/locations"
void listLocationsRoute(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can view the location list");
    }
    import std.array;
    DataSet!Location ds;
    auto locations = db.fetch(select(ds)).array;
    output.renderDiet!("listLocations.dt", currentUser, locations);
}

@endpoint
@getRoute!"/editLocation"
void editLocationForm(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can edit a location");
    }
    static struct params { int id; }
    auto p = request.get.extract!params;
    auto item = db.fetchUsingKey!Location(p.id);
    output.renderDiet!("editLocation.dt", currentUser, item);
}

@endpoint
@postRoute!"/performEditLocation"
void performEditLocation(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can edit a location");
    }
    import std.conv : to;
    auto l = request.post.extract!Location();
    l.id = request.post.read("id").to!int;
    db.save(l);
    infof("Updated location id:%s '%s' at '%s' by %s", l.id, l.name, l.address, currentUser.name);
    output.redirect("/locations");
}

@endpoint
@getRoute!"/editEvent"
void editEventForm(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can edit an event");
    }
    static struct params { int id; }
    auto p = request.get.extract!params;
    auto item = db.fetchUsingKey!Event(p.id);
    bool isSeries = !item.tag_id.isNull;
    output.renderDiet!("editEvent.dt", currentUser, item, isSeries);
}

@endpoint
@postRoute!"/performEditEvent"
void performEditEvent(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can edit an event");
    }
    import std.conv : to;
    auto e = request.post.extractEvent();
    if (e.start > e.end) {
        output.status = 400;
        return output.messageRedirect("Error", "End time cannot be prior to start time");
    }
    e.id = request.post.read("id").to!int;
    auto existing = db.fetchUsingKey!Event(e.id);

    if (!existing.tag_id.isNull && request.post.read("apply_to", "this") == "subsequent") {
        int rootId = existing.tag_id.get;
        auto duration = e.end - e.start;
        DataSet!Event ds;
        auto subsequent = db.fetch(select(ds)
            .where(ds.tag_id, " = ", rootId.param, " AND ", ds.start, " > ", existing.start.param)).array;
        if (subsequent.length > 0) {
            // break off from the original tag id (if not this event)
            e.tag_id = nullable(e.id);
            foreach (ref ev; subsequent) {
                ev.tag_id = e.tag_id;
                ev.title = e.title;
                ev.type = e.type;
                ev.location_id = e.location_id;
                ev.maxStudents = e.maxStudents;
                ev.minStudents = e.minStudents;
                ev.minAdults = e.minAdults;
                ev.start = DateTime(ev.start.date, e.start.timeOfDay);
                ev.end = ev.start + duration;
                db.save(ev);
                infof("Updated subsequent event '%s' (id:%s) starting %s, by %s", ev.title, ev.id, ev.start, currentUser.name);
            }
        }
    }
    // save the actual event.
    db.save(e);
    infof("Updated event '%s' (id:%s) starting %s, by %s", e.title, e.id, e.start, currentUser.name);

    output.redirect("/");
}

@endpoint
@getRoute!"/deleteEvent"
void deleteEventForm(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can delete an event");
    }
    static struct params { int id; }
    auto p = request.get.extract!params;
    auto item = db.fetchUsingKey!Event(p.id);
    auto locationName = db.fetchUsingKey!Location(item.location_id).name;
    DataSet!PersonEvent pesds;
    auto rsvps = db.fetch(select(pesds).where(pesds.event_id, " = ", item.id.param)).array;
    auto personMap = getPersonMap();
    bool isSeries = !item.tag_id.isNull;
    long subsequentCount = 0;
    if (isSeries) {
        DataSet!Event evds;
        subsequentCount = db.fetchOne(select(count(evds.id))
            .where(evds.tag_id, " = ", item.tag_id.get.param, " AND ", evds.start, " > ", item.start.param));
    }
    output.renderDiet!("deleteEvent.dt", currentUser, item, locationName, rsvps, personMap, isSeries, subsequentCount);
}

@endpoint
@postRoute!"/performDeleteEvent"
void performDeleteEvent(Request request, Output output) {
    if(!currentUser.admin) {
        output.status = 403;
        return output.messageRedirect("Forbidden", "Only administrators can delete an event");
    }
    import std.conv : to;
    int id = request.post.read("id").to!int;
    auto existing = db.fetchUsingKey!Event(id);

    DataSet!PersonEvent pes;

    void eraseEvent(Event ev) {
        db.perform(removeFrom(pes.tableDef).where(pes.event_id, " = ", ev.id.param));
        db.erase(ev);
        infof("Deleted event '%s' (id:%s) starting %s, by %s", ev.title, ev.id, ev.start, currentUser.name);
    }

    if (request.post.read("delete_scope", "this") == "subsequent" && !existing.tag_id.isNull) {
        int rootId = existing.tag_id.get;
        DataSet!Event evds;
        auto toDelete = db.fetch(select(evds)
            .where(evds.tag_id, " = ", rootId.param, " AND ", evds.start, " >= ", existing.start.param)).array;
        foreach (ev; toDelete)
            eraseEvent(ev);
    } else {
        eraseEvent(existing);
    }

    output.redirect("/");
}

@endpoint
@getRoute!"/rsvp"
void rsvp(Request request, Output output) {
    static struct params {
        int event_id;
        bool attending;
        @(form.optional) string style;
    }
    auto p = request.get.extract!params;
    // check if the rsvp already exists
    DataSet!PersonEvent ds;
    auto imGoing = db.fetchOne(select(count(ds.person_id)).where(ds.person_id, " = ", currentUser.id.param, " AND ", ds.event_id, " = ", p.event_id.param));
    if(imGoing) {
        if(!p.attending) {
            // remove the rsvp
            db.perform(removeFrom(ds.tableDef).where(ds.person_id, " = ", currentUser.id.param, " AND ", ds.event_id, " = ", p.event_id.param));
            infof("Cancelled RSVP for event_id:%s by %s", p.event_id, currentUser.name);
        }
    }
    else if(p.attending) {
        // add the rsvp
        db.create(PersonEvent(
                    person_id: currentUser.id,
                    event_id: p.event_id,
                    ));
        infof("RSVP'd for event_id:%s by %s", p.event_id, currentUser.name);
    }
    output.redirect(p.style.length ? "/?style=" ~ p.style : "/");
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
            return output.messageRedirect("Invalid checkin", format("No events at location %s, please RSVP for an event here before attempting to check in.", db.fetchUsingKey!Location(p.location_id).name));
        }
        else if(eventInfo[1] == eventInfo[0]) {
            return output.messageRedirect("Already checked in", "You have already checked in for today's event(s). No need to checkin again");
        }
        db.perform(set(ds.attendanceRecorded, true.param).where(ds.person_id, " = ", currentUser.id.param, " AND ", ds.event.location_id, " = ", p.location_id.param, " AND date(", ds.event.start, ") = ", today.param));
        infof("Checked in %s to all events today at location_id:%s", currentUser.name, p.location_id);
        return output.messageRedirect("Checked in", "Thanks for checking in for today's event(s)!");
    } else if(p.event_id != -1) {
        db.perform(set(ds.attendanceRecorded, true.param).where(ds.person_id, " = ", currentUser.id.param, " AND ", ds.event_id, " = ", p.event_id.param));
        infof("Checked in %s to event_id:%s", currentUser.name, p.event_id);
        return output.redirect("/");
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

@endpoint
@getRoute!"/assets/css/alarmcal.css"
void alarmcalCss(Request request, Output output) {
    output.serveStaticFile("views/alarmcal.css", "text/css; charset=utf-8");
}

@endpoint
@getRoute!"/assets/js/eventpopup.js"
void eventPopupJs(Request request, Output output) {
    output.serveStaticFile("views/eventpopup.js", "text/javascript; charset=utf-8");
}

/* The default configuration is used if you do not implement this function.*/

@onServerInit ServerinoConfig configure()
{
    return ServerinoConfig
        .create()
        .addListener("127.0.0.1", 8080)
        .setWorkers(1);

        // You can set many other options here. For example:
        // .setMaxRequestTime(1.seconds)
        // .setMaxRequestSize(1024*1024); // 1 MB
        // .setWorkers(10); // To set a fixed number of workers.
        // Many other options are available: https://trikko.github.io/serverino/serverino/config/ServerinoConfig.html
}
