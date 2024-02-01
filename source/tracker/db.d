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

//@safe: // this breaks too many things...

struct Client
{
    @primaryKey @autoIncrement int id = -1;
    string name;

    bool myInfo; // is this my info
    @allowNull {
        string contractEntity; // entity to print on invoice
        string contactName; // person's name
        string address1;
        string address2;
        string address3;
        string address4;
        string phone;
        string email;
    }

    static @refersTo!TimeTask @mapping("client_id") Relation tasks;
    static @refersTo!Project @mapping("client_id") Relation projects;
}

struct Project
{
    @primaryKey @autoIncrement int id = -1;
    @mustReferTo!Client("client") int client_id;
    string name;
    Rate rate;

    static @refersTo!TimeTask @mapping("project_id") Relation tasks;
}

struct TimeTask
{
    @primaryKey @autoIncrement int id = -1;
    @mustReferTo!Client("client") int client_id;
    @refersTo!Project("project") int project_id;
    DateTime start;
    Nullable!DateTime stop;
    string comment;
    @refersTo!Invoice("invoice") Nullable!int invoice_id;
}

struct Invoice
{
    @primaryKey @autoIncrement int id = -1;
    @mustReferTo!Client("client") int client_id;
    @mustReferTo!Client("myInfo") int my_client_id;
    Date invoiceDate;
    string invoiceNumber;
    string comment;

    static @refersTo!TimeTask @mapping("invoice_id") Relation tasks;
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
        if(rate.length > 0)
        {
            auto segments = rate.splitter(".");
            amount = segments.front.to!int * 100;
            segments.popFront;
            if(!segments.empty)
                amount += segments.front.to!int;
        }
    }

    int dbValue() => amount;

    static Rate fromDbValue(int amount) {
        return Rate(amount);
    }

    void toString(Out)(ref Out output) {
        output.formattedWrite("%,d.%02d", amount / 100, amount % 100);
    }

    void toJSON(scope void delegate(const(char)[]) @safe w)
    {
        toString(w);
    }

    Rate opBinary(string s : "*")(Duration d)
    {
        int hours, seconds;
        d.split!("hours", "seconds")(hours, seconds);
        int amt = hours * amount;
        amt += cast(int)((long(seconds) * amount) / 3600);
        return Rate(amt);
    }

    void opOpAssign(string s : "+")(Rate r)
    {
        amount += r.amount;
    }
    
    Rate opBinary(string s : "+")(Rate r)
    {
        return Rate(mixin("amount ", s, "r.amount"));
    }
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
        db.execute(createTableSql!(TimeTask, true));
        db.execute(createTableSql!(Project, true));
        db.execute(createTableSql!(Client, true));
        db.execute(createTableSql!(MigrationRecord, true));
        db.execute(createTableSql!(Invoice, true));
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
    auto migrations = [
        dateTimeTypeMigration(),
        moveRateToProjectMigration(),
        addCompanyDetails(),
        addInvoiceTable(),
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
        std.file.copy(backupDBName, databaseName);
    }
    foreach(idx, ref m; migrations)
    {
        if(m.applied)
            continue;
        if(assumeAllMigrations)
        {
            infoF!"Assuming migration %s - %s is applied"(idx + 1, m.name);
        }
        else
        {
            infoF!"Applying migration %s - %s"(idx + 1, m.name);
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
    result.add((Database db) {
        DataSet!OldTimeTask ds;
        OldTimeTask[] results = db.fetch(select(ds)).array;
        foreach(ref r; results)
        {
            r.start = DateTime.fromSimpleString(r.start).toISOExtString;
            if(!r.stop.isNull)
                r.stop = DateTime.fromSimpleString(r.stop.get).toISOExtString;
            db.save(r);
        }
    });
    return result;
}

// move the default rate to the rate of each project. The project should define
// the rate, and not each task.
Migration moveRateToProjectMigration()
{
    Migration result;
    result.name = __FUNCTION__;
    result.add(`CREATE TABLE Project2 ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "client_id" INTEGER NOT NULL, "name" TEXT NOT NULL, "rate" INT NOT NULL, FOREIGN KEY ("client_id") REFERENCES "Client" ("id"))`);
    result.add(`INSERT INTO Project2 SELECT Project.*, Client.defaultRate FROM Project LEFT JOIN Client ON (Client.id = Project.client_id)`);
    result.add(`DROP TABLE Project`);
    result.add(`ALTER TABLE Project2 RENAME TO Project`);
    result.add(`ALTER TABLE Client DROP COLUMN defaultRate`);
    result.add(`ALTER TABLE TimeTask DROP COLUMN rate`);
    return result;
}

Migration addCompanyDetails()
{
    Migration result;
    result.name = __FUNCTION__;
    result.add(`ALTER TABLE Client ADD COLUMN myInfo INTEGER NOT NULL DEFAULT 0`);
    result.add(`ALTER TABLE Client ADD COLUMN contractEntity TEXT`);
    result.add(`ALTER TABLE Client ADD COLUMN contactName TEXT`);
    result.add(`ALTER TABLE Client ADD COLUMN address1 TEXT`);
    result.add(`ALTER TABLE Client ADD COLUMN address2 TEXT`);
    result.add(`ALTER TABLE Client ADD COLUMN address3 TEXT`);
    result.add(`ALTER TABLE Client ADD COLUMN address4 TEXT`);
    result.add(`ALTER TABLE Client ADD COLUMN phone TEXT`);
    result.add(`ALTER TABLE Client ADD COLUMN email TEXT`);
    return result;
}

Migration addInvoiceTable()
{
    Migration result;
    result.name = __FUNCTION__;
    // copied from original invoice table
    static struct Invoice
    {
        @primaryKey @autoIncrement int id = -1;
        @mustReferTo!Client("client") int client_id;
        @mustReferTo!Client("myInfo") int my_client_id;
        DateTime invoiceDate;
        string invoiceNumber;
        string comment;

        static @refersTo!TimeTask @mapping("invoice_id") Relation tasks;
    }

    result.add(createTableSql!(Invoice, true));
    result.add(`ALTER TABLE TimeTask ADD COLUMN invoice_id INTEGER`);
    return result;
}
