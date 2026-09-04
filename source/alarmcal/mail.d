module alarmcal.mail;
import alarmcal.db;
import alarmcal.dietutils;
import alarmcal.formudas : fieldNameToCapitals;
import std.conv : to;

import std.conv;
import std.array;

import sqlbuilder.dataset;
import sqlbuilder.dialect.sqlite;

import postino;

enum emailDisclaimer = `NOTE: This email is generated from an automated system, replying to it will not reach a real person. If you have questions, please contact a mentor on slack`;

// configured from config file
struct EmailConfig {
    string smtpUrl;
    string username;
    string password;
}

ref EmailConfig config() {
    import alarmcal.app : appconfig = config;
    return appconfig.email;
}

void sendEventEmail(Event event, string message) {
    // open the database 
    auto db = openDB();
    // find all people who are attending
    DataSet!PersonEvent peds;
    Person[] recipients = db.fetch(select(peds.person).where(peds.event_id, " = ", event.id.param)).array;

    foreach(r; recipients) {
        auto email = new Email();
        email.setFrom("event@alarmcal.info", "Alarm Events")
            .setSubject(i"Event $(event.title) Notification".text)
            .setPlainTextBody(
i`$(message)

Event: $(event.title) ($(fieldNameToCapitals(event.type.to!string)))
Start: $(event.start)
End:   $(event.end)

You have signed up for this event. You can manage your participation in the event here: https://alarmcal.info

Check in when you are the event by using the QR code at the location, or 
$("https://alarmcal.info/checkIn?event_id=")$(event.id)

$(emailDisclaimer)`.text)
            .setHtmlBody(renderDiet!("mailEventReminder.dt", message, event, emailDisclaimer))
            .addTo(r.email, r.name)
            .send(config.smtpUrl, config.username, config.password);
    }
}
