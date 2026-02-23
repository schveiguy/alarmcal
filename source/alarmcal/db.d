module alarmcal.db;

import sqlbuilder.uda;
import sqlbuilder.dataset;
import sqlbuilder.dialect.sqlite;
import sqlbuilder.types;

import std.datetime;
import std.digest.md;
import std.logger;
import std.format;
static import std.file;

import d2sqlite3;

public import d2sqlite3 : Database;

import serverino;

import alarmcal.formudas;

enum databaseName = "caldata.sqlite";

enum MemberType {
    student,
    parent,
    mentor
}

struct Person
{
    @primaryKey @autoIncrement int id = -1;
    MemberType membertype;
    string name;
    string email;
    @password string password_hash;

    static @mapping("person_id") @refersTo!PersonEvent Relation events;
}

struct Location
{
    @primaryKey @autoIncrement int id;
    string name;
    string address;
}

enum EventType {
    shop,
    outreach,
    competition,
    offseasonCompetition,
    recreation
}

struct Event
{
    @primaryKey @autoIncrement int id;
    string title;
    DateTime start;
    DateTime end;
    @refersTo!Location("location") @dbenum!Location int location_id;
    EventType type;
    int maxStudents; // limit to how many students can attend, 0 = no limit.
    int minStudents; // minimum students required to hold the event.
    int minAdults; // minimum adults required to hold the event (at least one mentor)
    static @mapping("event_id") @refersTo!PersonEvent Relation people;
}

import std.traits;
static assert(hasUDA!(Event.location_id, dbenum));

struct PersonEvent
{
    @primaryKey @autoIncrement int id; // needed for updating.
    @mustReferTo!Person("person") int person_id;
    @mustReferTo!Event("event") int event_id;
    bool attendanceRecorded;
}

struct MigrationRecord
{
    @primaryKey @autoIncrement long migrationid = -1;
    DateTime appliedDate;
    string md5hash; // hash of the migration, all applied migrations MUST MATCH
}

// set to true if newly created sqlite database, all migrations are
// assumed to be applied.
bool assumeAllMigrations;

Database openDB()
{
    auto db = Database(databaseName);
    if(db.execute("SELECT COUNT(*) FROM sqlite_master").oneValue!long == 0)
    {
        info("Empty database, creating tables...");
        db.execute(createTableSql!(Person, true));
        db.execute(createTableSql!(Location, true));
        db.execute(createTableSql!(Event, true));
        db.execute(createTableSql!(PersonEvent, true));
        db.execute(createTableSql!(MigrationRecord, true));
        assumeAllMigrations = true;
    }
    return db;
}

struct MigrationComponent
{
    void delegate(Database) operation;
    string statement;

    this(void delegate(Database) operation)
    {
        this.operation = operation;
    }

    this(string statement)
    {
        this.statement = statement;
    }


    void apply(Database db)
    {
        if(operation is null)
            db.execute(statement);
        else
            operation(db);
    }

    void doMD5(ref MD5 md5) @safe
    {
        if(operation !is null)
        {
            // put something in there to denote a delegate is present here.
            ubyte[2] data = [0xaa, 0x55];
            md5.put(data[]);
        }
        else
        {
            md5.put(cast(const(ubyte[]))statement);
        }
    }
}

struct Migration
{
    string name;
    MigrationComponent[] items;
    bool applied;

    void add(void delegate(Database) operation)
    {
        items ~= MigrationComponent(operation);
    }

    void add(string statement)
    {
        items ~= MigrationComponent(statement);
    }


    string getMD5() @safe
    {
        MD5 md5;
        foreach(ref it; items)
            it.doMD5(md5);
        md5.put(cast(const(ubyte)[])name);
        auto result = md5.finish;
        return format("%(%02x%)", result[]);
    }
}

void applyMigrations()
{
    Migration[] migrations = [
    ];

    auto db = openDB();

    // first, ensure the migration table itself exists
    db.execute(createTableSql!(MigrationRecord, true, true));

    DataSet!MigrationRecord mds;

    bool unapplied = false;
    foreach(idx, ref m; migrations)
    {
        auto existing = db.fetchUsingKey(MigrationRecord.init, idx + 1);
        if(existing.migrationid != -1)
        {
            auto md5hash = m.getMD5;
            if(existing.md5hash != md5hash)
            {
                throw new Exception(format("MD5 hash of migration id %d does not match, expected `%s`, got `%s`", idx + 1, md5hash, existing.md5hash));
            }
            if(unapplied)
            {
                throw new Exception(format("migration id %d has been applied, but a prior migration has not been!", idx + 1));
            }
            m.applied = true;
        }
        else
        {
            unapplied = true;
        }
    }

    // all existing migrations are valid. Now apply any migrations that need to be added.
    if(!unapplied)
        // no unapplied migrations.
        return;
    // there are some unapplied migrations. First, copy the database file as a backup.
    db.close();
    auto appliedDate = cast(DateTime)Clock.currTime;
    string backupDBName = format("migration_backup_%s_%s", appliedDate.toISOString, databaseName);
    std.file.copy(databaseName, backupDBName);
    db = Database(databaseName);
    scope(failure)
    {
        db.close();
        info("Reverting database migrations...");
        std.file.copy(backupDBName, databaseName);
    }
    foreach(idx, ref m; migrations)
    {
        if(m.applied)
            continue;
        if(assumeAllMigrations)
        {
            info("Assuming migration %s - %s is applied", idx + 1, m.name);
        }
        else
        {
            info("Applying migration %s - %s", idx + 1, m.name);
            foreach(ref it; m.items)
                it.apply(db);
        }

        // the migration was applied, add it to the database
        MigrationRecord mr;
        mr.migrationid = idx + 1;
        mr.appliedDate = appliedDate;
        mr.md5hash = m.getMD5;
        db.create(mr);
    }
}

// helper function to get all values by name as if it were a database enum type.
T[] getDBEnumValues(T)() {
    auto db = openDB();
    DataSet!T ds;
    import std.array;
    return db.fetch(select(ds).orderBy(ds.name)).array;
}
