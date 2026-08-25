module alarmcal.session;

import alarmcal.db;

import sqlbuilder.dialect.sqlite;
import sqlbuilder.dataset;

import d2sqlite3;

import std.datetime;
import core.time : days;

enum sessionDuration = 7.days;

struct NewSession
{
    string token; // raw token, only ever available at creation time
    DateTime expires;
}

string generateSessionToken()
{
    import botan.rng.auto_rng;
    import std.digest : toHexString, LetterCase;

    scope AutoSeededRNG rng = new AutoSeededRNG;
    ubyte[32] buf;
    rng.randomize(buf.ptr, buf.length);
    return toHexString!(LetterCase.lower)(buf).idup;
}

string hashToken(string token)
{
    import std.digest.sha : sha256Of;
    import std.digest : toHexString, LetterCase;

    return toHexString!(LetterCase.lower)(sha256Of(token)).idup;
}

// creates a new session for the given person, returning the raw token to be stored in a cookie.
NewSession startSession(Database db, int personId)
{
    auto token = generateSessionToken();
    Session s;
    s.person_id = personId;
    s.tokenHash = hashToken(token);
    s.created = cast(DateTime)Clock.currTime;
    s.expires = s.created + sessionDuration;
    db.create(s);
    return NewSession(token, s.expires);
}

// validates a raw session token, sliding its expiration forward on success.
// returns Person.init (id == -1) if the token is missing, unknown, or expired.
Session validateSession(Database db, string rawToken)
{
    if (rawToken.length == 0)
        return Session.init;

    auto hash = hashToken(rawToken);
    DataSet!Session ds;
    auto session = db.fetchOne(select(ds).where(ds.tokenHash, " = ", hash.param), Session.init);
    if (session.id == -1)
        return session;

    auto now = cast(DateTime)Clock.currTime;
    if (session.expires <= now)
    {
        db.erase(session);
        return Session.init;
    }

    session.expires = now + sessionDuration;
    db.save(session);
    return session;
}

// deletes the session identified by the given raw token (logout).
void endSession(Database db, string rawToken)
{
    if (rawToken.length == 0)
        return;
    auto hash = hashToken(rawToken);
    DataSet!Session ds;
    db.perform(removeFrom(ds.tableDef).where(ds.tokenHash, " = ", hash.param));
}

// deletes all sessions belonging to the given person (e.g. on password change).
// the current session is excepted to avoid having to log in again.
void endAllSessions(Database db, int personId)
{
    import alarmcal.app : currentSession;
    DataSet!Session ds;
    auto cmd = removeFrom(ds.tableDef).where(ds.person_id, " = ", personId.param).where(ds.id, " <> ", currentSession.id.param);
    db.perform(cmd);
}
