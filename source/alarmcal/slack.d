module alarmcal.slack;

import std.algorithm;
import std.conv : to, text;
import std.exception;
import std.logger;
import std.net.curl;
import std.array : appender;
import std.string : strip, chompPrefix, indexOf, splitLines;
import std.uni : toLower, icmp;
import core.thread : Thread;
import core.time;
import std.datetime : Clock;

import iopipe.json.serialize : deserialize, optional, extras, JSONIopipeException, ignoreExtras;
import iopipe.json.dom : JSONValue;

import alarmcal.db;
import alarmcal.json;
import alarmcal.notifications : dispatchSlack;

import sqlbuilder.dataset;
import sqlbuilder.dialect.sqlite;

// Both fields are optional so that a missing "slack" block (or a partial one)
// simply leaves Slack disabled. Never log these values.
struct SlackConfig {
    @optional string botToken;
    @optional string signingSecret;
}

enum slackApiBase = "https://slack.com/api/";

class SlackException : Exception {
    // The error string from Slack's response (e.g. "channel_not_found"), or
    // "http_<code>" if no usable JSON came back.
    string slackError;
    this(string method, string slackError, string file = __FILE__, size_t line = __LINE__) {
        super("Slack API call " ~ method ~ " failed: " ~ slackError, file, line);
        this.slackError = slackError;
    }
}

private ref const(SlackConfig) config() {
    import alarmcal.app : appconfig = config;
    return *cast(const(SlackConfig)*)&appconfig.slack;
}

bool slackEnabled() {
    return config.botToken.length > 0;
}

struct SlackResponse {
    bool ok;
    @optional string error;
    @extras JSONValue!string _message;
    JsonVal message() => JsonVal(_message);
}

/**
 * Call a Slack Web API method. Parameters are sent form-encoded, which every
 * Web API method accepts (not all accept a JSON body). Returns the parsed
 * response;
 *
 * Retries a couple of times if Slack rate-limits us (HTTP 429).
 */
T slackCall(T = SlackResponse)(string method, string[string] params = null) {
    enforce(slackEnabled, "Slack is not configured (missing slack.botToken)");
    enum maxAttempts = 3;
    foreach(attempt; 0 .. maxAttempts) {
        auto conn = HTTP();
        conn.addRequestHeader("Authorization", "Bearer " ~ config.botToken);
        int retryAfter = 1;
        conn.onReceiveHeader = (in char[] key, in char[] value) {
            if(key.icmp("retry-after") == 0)
                retryAfter = value.strip.to!int.ifThrown(1);
        };
        auto body = post(slackApiBase ~ method, params, conn);
        if(conn.statusLine.code == 429 && attempt + 1 < maxAttempts) {
            warningf("Slack rate limited %s, retrying in %s seconds", method, retryAfter);
            Thread.sleep(clamp(retryAfter, 1, 30).seconds);
            continue;
        }
        T result;
        try
            result = deserialize!T(body);
        catch(JSONIopipeException ex)
            throw new SlackException(method, text("http_", conn.statusLine.code, ": ", ex.msg));
        if(!result.ok)
            throw new SlackException(method, result.error);
        return result;
    }
    assert(0); // the last attempt always returns or throws
}

@ignoreExtras
struct AuthTestResult {
    bool ok;

    @optional:
    string error;
    string url;
    string team;
    string user;
    string team_id;
    string user_id;
    string bot_id;
}

/// Verify the token works. Returns the auth.test response (team, user, etc.)
AuthTestResult authTest() {
    return slackCall!AuthTestResult("auth.test");
}

/**
 * Post a message. `channel` is a channel ID (C...), or a user ID (U...) to
 * send a DM. `blocks`, if given, is a Block Kit JSON array as a string, and
 * `text` is then the notification/fallback text. Returns the message `ts`.
 */
string postMessage(string channel, string text, string blocks = null) {
    string[string] params = ["channel": channel, "text": text];
    if(blocks.length)
        params["blocks"] = blocks;
    return slackCall("chat.postMessage", params).message["ts"].str;
}

/// Find a Slack user ID by email. Throws SlackException("users_not_found") if none.
string lookupUserByEmail(string email) {
    return slackCall("users.lookupByEmail", ["email": email]).message["user"]["id"].str;
}

/// Open (or fetch) the DM conversation with a user. Returns the channel ID.
string openDM(string userId) {
    return slackCall("conversations.open", ["users": userId]).message["channel"]["id"].str;
}

// Per-thread cache, which is fine: channel lookups are rare.
private string[string] channelCache;

/// Resolve a channel name (with or without a leading '#') to its ID.
/// Needs the channels:read scope; private channels also need groups:read, and
/// are skipped if that scope is missing.
string resolveChannel(string name) {
    name = name.chompPrefix("#");
    if(auto id = name in channelCache)
        return *id;
    // Query each type separately: asking for private_channel without
    // groups:read fails the whole call, even if the channel is public.
    foreach(type; ["public_channel", "private_channel"]) {
        try {
            if(auto id = findChannel(type, name))
                return id;
        }
        catch(SlackException e) {
            if(type == "private_channel" && e.slackError == "missing_scope")
                continue;
            throw e;
        }
    }
    throw new SlackException("conversations.list", "channel_not_found: " ~ name);
}

// Page through channels of one type, caching them all. Returns the ID of
// `name`, or null if it isn't of this type.
private string findChannel(string type, string name) {
    string cursor;
    do {
        string[string] params = [
            "types": type,
            "exclude_archived": "true",
            "limit": "200",
        ];
        if(cursor.length)
            params["cursor"] = cursor;
        auto r = slackCall("conversations.list", params);
        foreach(ref ch; r.message["channels"])
            channelCache[ch["name"].str] = ch["id"].str;
        if(auto id = name in channelCache)
            return *id;
        cursor = null;
        if(auto md = "response_metadata" in r.message)
            if(auto nc = "next_cursor" in *md)
                cursor = nc.str;
    } while(cursor.length);
    return null;
}

/// Get the email address from a Slack user's profile. Needs the users:read.email scope.
/// Returns an empty string if the profile has no email.
string lookupEmailByUser(string userId) {
    auto user = slackCall("users.info", ["user": userId]).message["user"];
    return user["profile"]["email"].str;
}

/**
 * Check that a request to our events endpoint really came from Slack, using
 * the signing secret (https://api.slack.com/authentication/verifying-requests-from-slack).
 * Fails closed if no signing secret is configured, and rejects stale
 * timestamps to prevent replays.
 */
bool verifySlackRequest(const(char)[] timestamp, const(char)[] signature, const(char)[] body,
        long now = Clock.currTime.toUnixTime) {
    import std.digest : toHexString, LetterCase, secureEqual;
    import std.digest.hmac : HMAC;
    import std.digest.sha : SHA256;
    import std.string : representation;

    if(config.signingSecret.length == 0)
        return false;
    long ts;
    try
        ts = timestamp.to!long;
    catch(Exception)
        return false;
    enum maxSkew = 5 * 60;
    auto diff = now - ts;
    if(diff > maxSkew || diff < -maxSkew)
        return false;

    auto hmac = HMAC!SHA256(config.signingSecret.representation);
    hmac.put("v0:".representation)
        .put(timestamp.representation)
        .put(":".representation)
        .put(body.representation);
    auto expected = hmac.finish.toHexString!(LetterCase.lower);
    return expected.length + 3 == signature.length &&
        signature[0 .. 3] == "v0=" && // standard equal ok here, it should always pass and is not related to the signature
        secureEqual(expected[], signature[3 .. $]);
}

unittest {
    import alarmcal.app : appconfig = config;
    (cast()appconfig).slack.signingSecret = "testsecret";
    scope(exit) (cast()appconfig).slack.signingSecret = null;

    enum body = `{"type":"url_verification","challenge":"abc123"}`;
    enum ts = "1700000000";
    // generated independently with openssl: HMAC-SHA256 of "v0:<ts>:<body>"
    enum sig = "v0=1158d46067d687bac21e6a5e6a6be0a85c085481afe2b88931e62ea63a664e9d";
    enum now = 1_700_000_000L;

    assert(verifySlackRequest(ts, sig, body, now));
    // still fine within the allowed clock skew, rejected beyond it
    assert(verifySlackRequest(ts, sig, body, now + 299));
    assert(verifySlackRequest(ts, sig, body, now - 299));
    assert(!verifySlackRequest(ts, sig, body, now + 301));
    assert(!verifySlackRequest(ts, sig, body, now - 301));
    // tampering with any signed part, or the signature itself
    assert(!verifySlackRequest(ts, sig, body ~ " ", now));
    assert(!verifySlackRequest("1700000001", sig, body, now));
    assert(!verifySlackRequest(ts, sig[0 .. $ - 1] ~ "0", body, now));
    assert(!verifySlackRequest(ts, sig ~ "0", body, now));
    assert(!verifySlackRequest(ts, sig[0 .. $ - 1], body, now));
    assert(!verifySlackRequest(ts, sig[3 .. $], body, now)); // missing "v0="
    assert(!verifySlackRequest(ts, "v1" ~ sig[2 .. $], body, now));
    assert(!verifySlackRequest(ts, "", body, now));
    // garbage timestamps
    assert(!verifySlackRequest("", sig, body, now));
    assert(!verifySlackRequest("abc", sig, body, now));
    // no configured secret fails closed
    (cast()appconfig).slack.signingSecret = null;
    assert(!verifySlackRequest(ts, sig, body, now));
}

// The outer wrapper of an Events API delivery. Everything else (e.g. "event")
// lands in the extras.
struct SlackEnvelope {
    @optional string type;
    @optional string challenge; // only for url_verification
    @extras JSONValue!string _rest;
    JsonVal rest() => JsonVal(_rest);
}

/**
 * Process a (signature-verified) Events API payload. Returns the text to send
 * back in the response, which is only non-empty for Slack's url_verification
 * handshake. Never throws; errors are logged.
 */
string handleSlackPayload(string payload) {
    SlackEnvelope env;
    try
        env = deserialize!SlackEnvelope(payload);
    catch(JSONIopipeException ex) {
        warningf("Ignoring malformed Slack payload: %s", ex.msg);
        return null;
    }
    if(env.type == "url_verification")
        return env.challenge;
    if(env.type == "event_callback") {
        if(auto ev = env.rest["event"]) {
            try
                handleSlackEvent(ev);
            catch(Exception e)
                errorf("Error handling Slack event: %s", e.msg);
        }
    }
    return null;
}

// Remove <@U123> user mentions from message text.
private string stripMentions(string text) {
    auto result = appender!string;
    while(text.length) {
        auto start = text.indexOf("<@");
        auto end = start < 0 ? -1 : text[start .. $].indexOf('>');
        if(end < 0) {
            result ~= text;
            break;
        }
        result ~= text[0 .. start];
        text = text[start + end + 1 .. $];
    }
    return result.data;
}

/**
 * Extract the command from a message: the first word once user mentions are
 * removed, lowercased, without an optional leading slash (Slack won't let
 * people send a channel message that starts with "/", so they write
 * "@alarmcal /link"). Returns an empty string if there is no command.
 */
private string parseCommand(string text) {
    auto words = stripMentions(text).strip.chompPrefix("/").splitter;
    return words.empty ? "" : words.front.toLower;
}

unittest {
    assert(parseCommand("link") == "link");
    assert(parseCommand("/link") == "link");
    assert(parseCommand("<@U0123ABC> /link") == "link");
    assert(parseCommand("<@U0123ABC> link") == "link");
    assert(parseCommand("<@U0123ABC>/link") == "link");
    assert(parseCommand("  <@U0123ABC>   /Unlink  ") == "unlink");
    assert(parseCommand("LINK please") == "link");
    assert(parseCommand("/link\nextra") == "link");
    assert(parseCommand("<@U0123ABC> hello there") == "hello");
    // mentions anywhere are removed, and an unterminated one is left alone
    assert(parseCommand("link <@U0123ABC>") == "link");
    assert(parseCommand("<@U0123ABC> <@U0456DEF> link") == "link");
    assert(parseCommand("<@U0123ABC link") == "<@u0123abc");
    // nothing to parse
    assert(parseCommand("") == "");
    assert(parseCommand("   ") == "");
    assert(parseCommand("<@U0123ABC>") == "");
    assert(parseCommand("/") == "");
}

private void handleSlackEvent(ref JsonVal ev) {
    switch(ev["type"].str) {
        case "app_mention":
            break;
        case "message":
            // only direct messages to us, and never anything a bot (including
            // ourselves) or an edit/delete/etc. produced.
            if(ev["channel_type"].str != "im" || (ev["subtype"]) || (ev["bot_id"]))
                return;
            break;
        default:
            return;
    }
    auto user = ev["user"].str;
    if(user.length == 0)
        return;

    switch(parseCommand(ev["text"].str)) {
        case "link":
            return linkSlackUser(user);
        case "unlink":
            return unlinkSlackUser(user);
        default:
            return dispatchSlack(user, "Sorry, I didn't understand that. I know these commands:\n" ~
                    "• `/link` - link your Slack account to your alarmcal account\n" ~
                    "• `/unlink` - remove that link");
    }
}

private void linkSlackUser(string slackUser) {
    import alarmcal.app : db;
    DataSet!Person ds;

    auto existing = db.fetchOne(select(ds).where(i"$(ds.slack_id) = $(slackUser)"), Person.init);
    if(existing.id != -1) {
        return dispatchSlack(slackUser, "You are already linked to the alarmcal account for " ~ existing.name ~
                ". Use `/unlink` first if you want to change that.");
    }

    string email;
    try
        email = lookupEmailByUser(slackUser);
    catch(SlackException e) {
        errorf("Could not get the email for Slack user %s: %s", slackUser, e.msg);
        return dispatchSlack(slackUser, "Sorry, I couldn't look up your Slack email address. Please ask a mentor for help.");
    }

    auto person = email.length ? db.fetchOne(select(ds).where(i"$(ds.email) = $(email) AND $(ds.active) = 1"), Person.init) : Person.init;
    if(person.id == -1) {
        return dispatchSlack(slackUser, "I couldn't find an alarmcal account that matches your Slack email address" ~
                (email.length ? " (" ~ email ~ ")" : "") ~
                ". Please make sure your Slack email matches your alarmcal email, then try `/link` again.");
    }
    if(!person.slack_id.isNull) {
        // this alarmcal account is linked to a different Slack account; relinking is allowed
        // because the Slack email vouches for the person.
        infof("Person id:%d '%s' is being relinked from Slack user %s to %s", person.id, person.name, person.slack_id.get, slackUser);
    }
    person.slack_id = slackUser;
    db.save(person);
    infof("Person id:%d '%s' linked Slack user %s", person.id, person.name, slackUser);
    dispatchSlack(slackUser, "You are now linked to the alarmcal account for " ~ person.name ~
            ". I will send you a DM when you change your RSVP for an event; you can turn that off in your alarmcal profile. " ~
            "Use `/unlink` to remove the link.");
}

private void unlinkSlackUser(string slackUser) {
    import alarmcal.app : db;
    DataSet!Person ds;

    auto person = db.fetchOne(select(ds).where(i"$(ds.slack_id) = $(slackUser)"), Person.init);
    if(person.id == -1)
        return dispatchSlack(slackUser, "Your Slack account isn't linked to an alarmcal account. Use `/link` to link it.");
    person.slack_id.nullify();
    db.save(person);
    infof("Person id:%d '%s' unlinked Slack user %s", person.id, person.name, slackUser);
    dispatchSlack(slackUser, "Your Slack account is no longer linked to alarmcal. I won't send you any more notifications.");
}
