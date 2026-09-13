module alarmcal.mail;
import alarmcal.db;
import alarmcal.dietutils;
import alarmcal.formudas : fieldNameToCapitals;
import alarmcal.notifications : dispatchEmail;

import std.conv;
import std.concurrency;
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

private ref const(EmailConfig) config() {
    import alarmcal.app : appconfig = config;
    return *cast(const(EmailConfig)*)&appconfig.email;
}

private Email makeEmail(string subject) {
    Email result = new Email();
    return result
        .setFrom("event@alarmcal.info", "Alarm Events")
        .setSubject(subject);
}

void sendEventEmail(Event event, string message, bool isAttending) {
    import alarmcal.app : db;
    // find all the target users
    DataSet!PersonEvent peds;
    Person[] recipients = db.fetch(select(peds.person).where(peds.event_id, " = ", event.id.param)).array;

    sendEventEmail(event, message, isAttending, recipients);
}

void sendEventEmail(Event event, string message, bool isAttending, Person[] recipients...) {
    foreach(r; recipients) {
        auto email = makeEmail(i"Event $(event.title) Notification".text)
            .setPlainTextBody(
i`$(message)

$(fieldNameToCapitals(event.type.to!string)) Event: $(event.title)
Start: $(event.start)
End:   $(event.end)

You have signed up for this event. You can manage your participation in the event here: https://alarmcal.info

$(isAttending ? "Check in when you are the event by using the QR code at the location, or\n" ~ 
i"this link: https://alarmcal.info/checkIn?event_id=$(event.id)\n".text : "")
$(emailDisclaimer)`.text)
            .setHtmlBody(renderDiet!("mailEventReminder.dt", message, event, emailDisclaimer, isAttending))
            .addTo(r.email, r.name);
        dispatchEmail(email);
    }
}

void sendInviteEmail(Person person) {
    auto email = makeEmail("You are invited to join Alarm calendar!")
        .setPlainTextBody(
i`Hello $(person.name.length > 0 ? person.name : person.email)!

You have been invited to join 4H Alarm Calendar. To finish creating your user,
please click on the link below. Once you have created your user, this link will
no longer work. If you find the link does not work, please contact the 4H Alarm
mentor team to get your user reset.

https://alarmcal.info/invite?id=$(person.invitation_id)

$(emailDisclaimer)`.text)
        .setHtmlBody(renderDiet!("mailInvite.dt", person, emailDisclaimer))
        .addTo(person.email, person.name);
    dispatchEmail(email);
}

void sendPasswordResetEmail(Person person) {
    auto email = makeEmail("Reset your Alarm calendar password")
        .setPlainTextBody(
i`Hello $(person.name.length > 0 ? person.name : person.email)!

A password reset was requested for your 4H Alarm Calendar account. If you did
not request this, you can safely ignore this email and your password will
remain unchanged.

This link will expire 20 minutes after this email was sent:

https://alarmcal.info/forgotpassword?id=$(person.reset_password_id)

$(emailDisclaimer)`.text)
        .setHtmlBody(renderDiet!("mailPasswordReset.dt", person, emailDisclaimer))
        .addTo(person.email, person.name);
    dispatchEmail(email);
}

void sendEmail(Email email) {
    email.send(config.smtpUrl, config.username, config.password);
}
