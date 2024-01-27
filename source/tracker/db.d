module tracker.db;

import std.datetime;
import std.typecons;
import std.format;
static import std.file;
import std.algorithm;
import std.array;
import std.conv;
import std.digest.md;

import sqlbuilder.dialect.sqlite;
import sqlbuilder.dataset;
import sqlbuilder.uda;
import sqlbuilder.types;

import d2sqlite3;

import slf4d;

enum databaseName = "timedata.sqlite";

struct Client
{
    @primaryKey @autoIncrement int id = -1;
    string name;
    Nullable!Rate defaultRate;

    static @refersTo!TimeTask @mapping("client_id") Relation tasks;
    static @refersTo!Project @mapping("client_id") Relation projects;
}

struct Project
{
    @primaryKey @autoIncrement int id = -1;
    @mustReferTo!Client("client") int client_id;
    string name;

    static @refersTo!TimeTask @mapping("project_id") Relation tasks;
}

struct TimeTask
{
    @primaryKey @autoIncrement int id = -1;
    @mustReferTo!Client("client") int client_id;
    @refersTo!Project("project") Nullable!int project_id;
    Nullable!Rate rate;
    DateTime start;
    Nullable!DateTime stop;
    string comment;
}

struct MigrationRecord
{
    @primaryKey long migrationid = -1;
    DateTime appliedDate;
    string md5hash; // hash of the migration, all applied migrations MUST MATCH
}

struct Rate
{
    int amount;
    this(int amount) {
        this.amount = amount;
    }

    this(string rate) {
        assert(rate.length > 0);
        auto segments = rate.splitter(".");
        amount = segments.front.to!int * 100;
        segments.popFront;
        if(!segments.empty)
            amount += segments.front.to!int;
    }

    static Nullable!Rate parse(string rate)
    {
        if(rate.length == 0)
            return Nullable!Rate.init;
        auto r = Rate(rate);
        if(r.amount == 0)
            return Nullable!Rate.init;
        return r.nullable;
    }

    int dbValue() => amount;

    static Rate fromDbValue(int amount) {
        return Rate(amount);
    }

    void toString(Out)(ref Out output) {
        output.formattedWrite("%d.%02d", amount / 100, amount % 100);
    }

    void toJSON(scope void delegate(const(char)[]) w)
    {
        toString(w);
    }
}

Database openDB()
{
    auto db = Database(databaseName);
    if(db.execute("SELECT COUNT(*) FROM sqlite_master").oneValue!long == 0)
    {
        info("Empty database, creating tables...");
        db.execute(createTableSql!(TimeTask, true));
        db.execute(createTableSql!(Project, true));
        db.execute(createTableSql!(Client, true));
        db.execute(createTableSql!(MigrationRecord, true));
    }
    return db;
}

struct Migration
{
    string name;
    void delegate(Database) preStatement;
    string[] statements;
    void delegate(Database) postStatement;
    bool applied;

    string getMD5()
    {
        MD5 md5;
        // md5 a 1 if a delegate is non-null. We can't md5 the contents of
        // the function unfortunately.
        ubyte[2] delegateFlag;
        delegateFlag[0] = preStatement is null ? 0x55 : 0xaa;
        delegateFlag[1] = postStatement is null ? 0x55 : 0xaa;
        md5.put(delegateFlag[]);
        md5.put(cast(const(ubyte)[])name);
        foreach(s; statements)
            md5.put(cast(const(ubyte)[])s);
        auto result = md5.finish;
        return format("%(%02x%)", result[]);
    }
}

void applyMigrations()
{
    Migration[] migrations;

    migrations ~= dateTimeTypeMigration();

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
        std.file.copy(backupDBName, databaseName);
    }
    foreach(idx, ref m; migrations)
    {
        if(m.applied)
            continue;
        infoF!"Applying migration %s - %s"(idx + 1, m.name);
        if(m.preStatement)
            m.preStatement(db);
        foreach(s; m.statements)
            db.execute(s);
        if(m.postStatement)
            m.postStatement(db);

        // the migration was applied, add it to the database
        MigrationRecord mr;
        mr.migrationid = idx + 1;
        mr.appliedDate = appliedDate;
        mr.md5hash = m.getMD5;
        db.create(mr);
    }
}

Migration dateTimeTypeMigration()
{
    // all date time types were stored originally as simple strings (oops)
    @tableName("TimeTask")
    static struct OldTimeTask
    {
        @primaryKey int id;
        string start;
        Nullable!string stop;
    }
    Migration result;
    result.name = __FUNCTION__;
    result.preStatement = (Database db) {
        DataSet!OldTimeTask ds;
        OldTimeTask[] results = db.fetch(select(ds)).array;
        foreach(ref r; results)
        {
            r.start = DateTime.fromSimpleString(r.start).toISOExtString;
            if(!r.stop.isNull)
                r.stop = DateTime.fromSimpleString(r.stop.get).toISOExtString;
            db.save(r);
        }
    };
    return result;
}
