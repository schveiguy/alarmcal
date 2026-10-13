module alarmcal.slack;

import std.algorithm;
import std.conv : to, text;
import std.exception;
import std.logger;
import std.net.curl;
import std.string : strip, chompPrefix;
import std.uni : icmp;
import core.thread : Thread;
import core.time;

import iopipe.json.serialize : deserialize, optional, extras, JSONIopipeException;
import iopipe.json.dom : JSONValue;

import alarmcal.json;

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

struct AuthTestResult {
    bool ok;
    // Slack adds fields over time, so absorb any we don't list.
    @extras JSONValue!string _extra;

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
/// Needs the channels:read scope (and groups:read for private channels).
string resolveChannel(string name) {
    name = name.chompPrefix("#");
    if(auto id = name in channelCache)
        return *id;
    string cursor;
    do {
        string[string] params = [
            "types": "public_channel,private_channel",
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
    throw new SlackException("conversations.list", "channel_not_found: " ~ name);
}
