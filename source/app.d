module app;
import handy_httpd;
import handy_httpd.components.form_urlencoded;

import schlib.lookup;

import sqlbuilder.dialect.sqlite;
import sqlbuilder.dataset;
import sqlbuilder.uda;
import sqlbuilder.types;

import d2sqlite3;

import slf4d;
import slf4d.default_provider.factory;
import slf4d.default_provider;

import diet.html;

import std.datetime;
import std.typecons;
import std.algorithm;
import std.array;
import std.file : exists;
import std.conv;
import std.format;
import std.exception;

import iopipe.json.serialize;

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

struct DurationPrinter
{
    Duration d;
    void toString(Out)(ref Out output)
    {
        import std.format;
        auto s = d.split!("hours", "minutes", "seconds");
        output.formattedWrite("%d:%02d:%02d", s.hours, s.minutes, s.seconds);
    }

    string toString()
    {
        import std.array;
        Appender!string app;
        toString(app);
        return app.data;
    }
}

DateTime parseDate(string s)
{
    infoF!"parsing date %s"(s);
    int year;
    int month;
    int day;
    int hour;
    int minute;
    int second;
    s.formattedRead("%d-%d-%d %d:%d:%d", year, month, day, hour, minute, second);
    return DateTime(year, month, day, hour, minute, second);
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
    }
    return db;
}

alias LookupById(T) = typeof(fieldLookup!"id"(T[].init));

struct IndexViewModel
{
    TimeTask currentTask;
    TimeTask[] allTasks;
    Client[] allClients;
    LookupById!Client clientLookup;
    Project[] allProjects;
    LookupById!Project projectLookup;
}

struct TaskEditViewModel
{
    TimeTask currentTask;
    Client[] allClients;
    Project[] allProjects;
}

struct ClientViewModel
{
    Client[] allClients;
}


struct ProjectViewModel
{
    Project[] allProjects;
    Nullable!Client selectedClient;
    Client[] allClients;
    LookupById!Client clientLookup;
}

void renderDiet(Args...)(ref HttpResponse response)
{
    auto text = appender!string;
    text.compileHTMLDietFile!(Args);
    response.writeBodyString(text.data, "text/html");
}

void redirect(ref HttpResponse response, string location)
{
    response.setStatus(HttpStatus.SEE_OTHER);
    response.addHeader("Location", location);
}

void runServer(ref HttpRequestContext ctx) {
    QueryParam[] formData;
    if(ctx.request.method == Method.POST &&
        ctx.request.getHeader("Content-Type") == "application/x-www-form-urlencoded")
    {
        formData = ctx.request.readBodyAsFormUrlEncoded;
    }

    // TODO: make lookup work with this, or wait for QueryParam to become more sane
    auto postdata = formData.fieldLookup!"name";
    auto querydata = ctx.request.queryParams.fieldLookup!"name";

	debugF!"Processing a new request, url: %s, parameters: %s, method: %s, Content-Type: %s"(ctx.request.url, ctx.request.queryParams, ctx.request.method, ctx.request.getHeader("Content-Type"));

    DataSet!TimeTask ds;
    DataSet!Client cds;
    DataSet!Project pds;

    TimeTask getUnfinishedTask(Database db) => db.fetchOne(select(ds).where(ds.stop, " IS NULL"), TimeTask.init);

    auto db = openDB;
	switch(ctx.request.url)
    {
        case "":
        case "/":
            // fetch all the data
            IndexViewModel model;
            model.allTasks = db.fetch(select(ds).where(ds.stop, " IS NOT NULL")).array;
            model.currentTask = getUnfinishedTask(db);
            model.allClients = db.fetch(select(cds).orderBy(cds.name)).array;
            model.clientLookup = model.allClients.fieldLookup!"id";
            model.allProjects = db.fetch(select(pds).orderBy(pds.name)).array;
            model.projectLookup = model.allProjects.fieldLookup!"id";
            ctx.response.renderDiet!("index.dt", model);
            break;
        case "/timing-event":
            // ensure there is no task currently running
            auto taskid = postdata["taskid"].value.to!int;
            if(taskid != -1)
            {
                auto currentTask = db.fetchUsingKey!TimeTask(taskid);
                if(currentTask.stop.isNull) // if stop is null, this task was
                                            // stopped elsewhere.
                {
                    if(postdata["action"].value == "stop")
                    {
                        currentTask.comment = postdata["comment"].value;
                        currentTask.client_id = postdata["client_id"].value.to!int;
                        currentTask.project_id = postdata["project_id"].value.to!int;
                        currentTask.rate = Rate.parse(postdata["rate"].value);
                        currentTask.stop = cast(DateTime)Clock.currTime;
                        db.save(currentTask);
                    }
                    else if(postdata["action"].value == "update")
                    {
                        currentTask.comment = postdata["comment"].value;
                        currentTask.client_id = postdata["client_id"].value.to!int;
                        currentTask.project_id = postdata["project_id"].value.to!int;
                        currentTask.rate = Rate.parse(postdata["rate"].value);
                        db.save(currentTask);
                    }
                    else if(postdata["action"].value == "cancel")
                    {
                        db.erase(currentTask);
                    }
                }
            }
            else
            {
                // see if there is a current task
                auto currentTask = getUnfinishedTask(db);
                if(currentTask.id == -1) // no unfinished task yet
                {
                    // not yet a task, insert one
                    currentTask.comment = postdata["comment"].value;
                    currentTask.client_id = postdata["client_id"].value.to!int;
                    currentTask.project_id = postdata["project_id"].value.to!int;
                    currentTask.start = cast(DateTime)Clock.currTime;
                    currentTask.rate = Rate.parse(postdata["rate"].value);
                    db.create(currentTask);
                }
            }
            ctx.response.redirect("/");
            break;
        case "/delete-task":
            auto task = db.fetchUsingKey!TimeTask(querydata["taskid"].value.to!int);
            db.erase(task);
            ctx.response.redirect("/");
            break;
        case "/edit-task":
            TaskEditViewModel model;
            model.currentTask = db.fetchUsingKey!TimeTask(querydata["taskid"].value.to!int);
            model.allClients = db.fetch(select(cds).orderBy(cds.name)).array;
            model.allProjects = db.fetch(select(pds).orderBy(pds.name)).array;
            ctx.response.renderDiet!("editor.dt", model);
            break;
        case "/process-edit-task":
            auto task = db.fetchUsingKey!TimeTask(postdata["taskid"].value.to!int);
            task.start = parseDate(postdata["start"].value);
            task.stop = parseDate(postdata["stop"].value);
            enforce(task.stop.get > task.start, "Duration must be positive");
            task.comment = postdata["comment"].value;
            task.client_id = postdata["client_id"].value.to!int;
            task.project_id = postdata["project_id"].value.to!int;
            task.rate = Rate.parse(postdata["rate"].value);
            db.save(task);
            ctx.response.redirect("/");
            break;
        case "/clients":
            ClientViewModel model;
            model.allClients = db.fetch(select(cds)).array;
            ctx.response.renderDiet!("clients.dt", model);
            break;
        case "/projects":
            ProjectViewModel model;
            auto query = select(pds);
            if(auto clidstr = "clientId" in querydata)
            {
                if(clidstr.value.length > 0) {
                    auto clid = clidstr.value.to!int;
                    query = query.where(pds.client_id, " = ", clid.param);
                    model.selectedClient = db.fetchUsingKey!Client(clid);
                }
            }
            model.allProjects = db.fetch(query).array;
            model.allClients = db.fetch(select(cds)).array;
            model.clientLookup = model.allClients.fieldLookup!"id";
            ctx.response.renderDiet!("projects.dt", model);
            break;
        case "/add-client":
            Client newClient;
            newClient.name = postdata["name"].value;
            newClient.defaultRate = Rate.parse(postdata["rate"].value);
            db.create(newClient);
            ctx.response.redirect("/clients");
            break;
        case "/add-project":
            Project newProject;
            newProject.name = postdata["name"].value;
            newProject.client_id = postdata["client_id"].value.to!int;
            db.create(newProject);
            ctx.response.redirect("/projects");
            break;
        default:
            ctx.response.setStatus(HttpStatus.NOT_FOUND);
            break;
    }
}

void main(string[] args)
{
    /*auto provider = new shared DefaultProvider(false, Levels.TRACE);
    configureLoggingProvider(provider);*/
    auto server = new HttpServer(&runServer);
    server.start();
}
