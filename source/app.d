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
        return Rate(rate).nullable;
    }

    int dbValue() => amount;

    static Rate fromDbValue(int amount) {
        return Rate(amount);
    }

    void toString(Out)(Out output) {
        output.formattedWrite("%d.%02d", amount / 100, amount % 100);
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
    }
    return db;
}

struct TaskModel
{
    this(TimeTask task, string clientName, Nullable!string projectName)
    {
        this.task = task;
        this.clientName = clientName;
        this.projectName = projectName.get("");
    }

    TimeTask task;
    string clientName;
    string projectName;

    alias task this;
}

alias LookupById(T) = typeof(fieldLookup!"id"(T[].init));

struct IndexViewModel
{
    TimeTask currentTask;
    TaskModel[] allTasks;
    Client[] allClients;
    LookupById!Client clientLookup;
    Project[] allProjects;
    LookupById!Project projectLookup;
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
    //auto postdata = QueryParam.toMap(formData);
    //auto querydata = QueryParam.toMap(ctx.request.queryParams);

	infoF!"Processing a new request, url: %s, parameters: %s, method: %s, Content-Type: %s"(ctx.request.url, ctx.request.queryParams, ctx.request.method, ctx.request.getHeader("Content-Type"));

    DataSet!TimeTask ds;
    DataSet!Client cds;
    DataSet!Project pds;
	switch(ctx.request.url)
    {
        case "":
        case "/":
            // fetch all the data
            auto db = openDB;
            IndexViewModel model;
            model.allTasks = db.fetch(select(ds, ds.client.name, ds.project.name).where(ds.stop, " IS NOT NULL")).map!(tup => TaskModel(tup.expand)).array;
            {
                auto currentTask = db.fetch(select(ds).where(ds.stop, " IS NULL"));
                if(!currentTask.empty)
                    model.currentTask = currentTask.front;
            }
            ctx.response.renderDiet!("index.dt", model);
            break;
        case "/timing-event":
            // ensure there is no task currently running
            auto db = openDB;
            auto taskid = postdata["taskid"].value.to!int;
            TimeTask currentTask;
            if(taskid != -1)
            {
                currentTask = db.fetchUsingKey!TimeTask(taskid);
                if(postdata["action"].value == "stop")
                {
                    if(currentTask.stop.isNull)
                    {
                        currentTask.comment = postdata["comment"].value;
                        currentTask.stop = cast(DateTime)Clock.currTime;
                        db.save(currentTask);
                    }
                }
            }
            else
            {
                // not yet a task, insert one
                currentTask.comment = postdata["comment"].value;
                currentTask.start = cast(DateTime)Clock.currTime;
                db.create(currentTask);
            }
            ctx.response.redirect("/");
            break;
        case "/clients":
            auto db = openDB;
            ClientViewModel model;
            model.allClients = db.fetch(select(cds)).array;
            ctx.response.renderDiet!("clients.dt", model);
            break;
        case "/projects":
            auto db = openDB;
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
            auto db = openDB;
            Client newClient;
            newClient.name = postdata["name"].value;
            newClient.defaultRate = Rate.parse(postdata["rate"].value);
            db.create(newClient);
            ctx.response.redirect("/clients");
            break;
        case "/add-project":
            auto db = openDB;
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
