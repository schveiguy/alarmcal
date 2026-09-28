module alarmcal.notifications;
import alarmcal.db;
import alarmcal.app : db, getTime;
import alarmcal.mail;

import postino : Email;
import std.concurrency;
import std.logger;
import std.datetime;
import std.array;
import core.time;

import serverino;

import iopipe.json.serialize : optional;

import sqlbuilder.dataset;
import sqlbuilder.dialect.sqlite;

struct NotificationConfig {
    string alarmcalSecret;
    @optional int periodSeconds = 60;
}

struct Shutdown { }

struct SendEmail {
    Email email;
}

Tid notificationTid;

private ref const(NotificationConfig) config() {
    import alarmcal.app : appconfig = config;
    return *cast(const(NotificationConfig)*)&appconfig.notifications;
}

void notificationThread() {
    import core.time;
    bool exiting = false;
    // this will just init the original poke time.
    poke();
    // don't do pokes inside the worker
    auto lastPoke = MonoTime.currTime;
    Duration period = ServerinoProcess.isWorker ? Duration.max / 2 : config.periodSeconds.seconds;
    Duration sleepTime = period;
    while(!exiting) {
        receiveTimeout(sleepTime,
            (Shutdown s) { exiting = true; },
            (shared(SendEmail) sem) { handle(cast(SendEmail)sem); },
        );
        auto cur = MonoTime.currTime;
        auto elapsed = cur - lastPoke;
        if(!exiting && elapsed >= period) {
            poke();
            lastPoke = cur;
            sleepTime = period;
        }
        else {
            // adjust sleep time for next receive call
            sleepTime = period - elapsed;
        }
    }
}

void dispatchEmail(Email email) {
    if(notificationTid is Tid.init) {
        // no notification thread stored, send it right now.
        sendEmail(email);
    }
    else {
        // ask the notification thread to send it.
        notificationTid.send(cast(shared)SendEmail(email));
    }
}

private void handle(SendEmail sem) {
    sendEmail(sem.email);
}

private void poke() {
    import std.net.curl;

    auto conn = HTTP("http://127.0.0.1:8080/poke");
    conn.addRequestHeader("x-alarmcal-poke-secret", config.alarmcalSecret);
    // need this, or the output gets written by curl to stdout
    conn.onReceive = (data) => data.length;
    conn.perform();
    if(conn.statusLine.code != 200) {
        errorf("Could not send poke message: %s", conn.statusLine);
    }
}

SysTime lastHandledPoke;

public void handlePoke() {
    auto current = getTime();
    scope(exit) lastHandledPoke = current;

    // on first run, just get the time and exit.
    if(lastHandledPoke == SysTime.init)
        return;

    auto curdate = cast(Date)current;
    DataSet!Event evds;
    if(curdate != cast(Date)lastHandledPoke) {
        // at the beginning of each day, email everyone who is signed up about
        // the events that are happening that day.
        auto events = db.fetch(select(evds).where(i"date($(evds.start)) = date($(curdate))")).array;
        foreach(ev; events) {
            sendEventEmail(ev, "This event is occurring today!", true);
        }

        // at the beginning of Sunday, email students and mentors about the
        // week ahead (Monday through the following Sunday, i.e. excluding
        // today and including next Sunday).
        if(curdate.dayOfWeek == DayOfWeek.sun) {
            sendWeeklyDigest(curdate);
        }
    }
}

private void sendWeeklyDigest(Date weekStartExclusive) {
    auto weekEnd = weekStartExclusive + 7.days;

    DataSet!Event evds;
    auto weekEvents = db.fetch(select(evds)
        .where(i"date($(evds.start)) > date($(weekStartExclusive)) AND date($(evds.start)) <= date($(weekEnd))")
        .orderBy(evds.start)).array;

    DataSet!Person pds;
    auto recipients = db.fetch(select(pds)
        .where(i"$(pds.active) = 1 AND ($(pds.memberType) = $(MemberType.student) OR $(pds.memberType) = $(MemberType.mentor))")).array;

    if(weekEvents.length == 0 || recipients.length == 0)
        return;

    DataSet!PersonEvent peds;
    auto rsvps = db.fetch(select(peds)
        .where(i"$(peds.attending) = 1 AND date($(peds.event.start)) > date($(weekStartExclusive)) AND date($(peds.event.start)) <= date($(weekEnd))")).array;

    bool[int][int] signedUpEvents; // person_id -> set of event_id
    foreach(rsvp; rsvps)
        signedUpEvents[rsvp.person_id][rsvp.event_id] = true;

    foreach(recipient; recipients) {
        auto mine = recipient.id in signedUpEvents;
        WeeklyDigestEvent[] digestEvents;
        foreach(ev; weekEvents)
            digestEvents ~= WeeklyDigestEvent(ev, mine !is null && (ev.id in *mine) !is null);
        sendWeeklyDigestEmail(recipient, digestEvents);
    }
}
