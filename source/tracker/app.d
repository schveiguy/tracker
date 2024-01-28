module tracker.app;

import tracker.db;

import handy_httpd;
import handy_httpd.components.multivalue_map;

import schlib.lookup;
import schlib.getopt2;
import std.getopt;

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

alias LookupById(T) = typeof(fieldLookup!"id"(T[].init));

struct IndexViewModel
{
    TimeTask currentTask;
    TimeTask[] allTasks;
    Client[] allClients;
    LookupById!Client clientLookup;
    Project[] allProjects;
    LookupById!Project projectLookup;

    // filtering
    string period;
    string forDate;
    int client_id;
    int project_id;
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
    auto querydata = ctx.request.queryParams;
    StringMultiValueMap postdata;
    auto contentType = ctx.request.headers.getFirst("Content-Type").orElse("");
    if(ctx.request.method == Method.POST &&
        contentType == "application/x-www-form-urlencoded")
    {
        postdata = ctx.request.readBodyAsFormUrlEncoded;
    }

	debugF!"Processing a new request, url: %s, parameters: %s, method: %s, Content-Type: %s"(ctx.request.url, ctx.request.queryParams[], ctx.request.method, contentType);

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
            auto taskQuery = select(ds).where(ds.stop, " IS NOT NULL").orderBy(ds.id.descend);

            // get any filtering
            string forDate = "now";
            if(auto forDateAlt = ctx.request.queryParams.getFirst("forDate"))
            {
                if(forDateAlt.value != "")
                {
                    model.forDate = forDateAlt.value;
                    forDate = forDateAlt.value;
                }
            }

            if(auto timePeriod = ctx.request.queryParams.getFirst("period"))
            {
                model.period = timePeriod.value;
                switch(timePeriod.value)
                {
                    case "month":
                        taskQuery = taskQuery.where(ds.start, " >= DATE(", forDate.param, ", 'start of month') AND ",
                                ds.start, " < DATE(", forDate.param, ", 'start of month', '+1 months')");
                        break;
                    case "week":
                        taskQuery = taskQuery.where(ds.start, " >= DATE(", forDate.param, ", '-6 days', 'weekday 1') AND ",
                                ds.start, " < DATE(", forDate.param, ", '+1 days', 'weekday 1')");
                        break;
                    case "day":
                        taskQuery = taskQuery.where(ds.start, " >= DATE(", forDate.param, ", 'start of day') AND ",
                                ds.start, " < DATE(", forDate.param, ", 'start of day', '+1 days')");
                        break;
                    default:
                        break;
                }
            }

            if(auto client_id = ctx.request.queryParams.getFirst("client_id"))
            {
                if(client_id.value.length != 0)
                {
                    model.client_id = client_id.value.to!int;
                    taskQuery = taskQuery.where(ds.client_id, " = ", model.client_id.param);
                }
            }

            if(auto project_id = ctx.request.queryParams.getFirst("project_id"))
            {
                if(project_id.value.length != 0)
                {
                    model.project_id = project_id.value.to!int;
                    taskQuery = taskQuery.where(ds.project_id, " = ", model.project_id.param);
                }
            }

            model.allTasks = db.fetch(taskQuery).array;
            model.currentTask = getUnfinishedTask(db);
            model.allClients = db.fetch(select(cds).orderBy(cds.name)).array;
            model.clientLookup = model.allClients.fieldLookup!"id";
            model.allProjects = db.fetch(select(pds).orderBy(pds.name)).array;
            model.projectLookup = model.allProjects.fieldLookup!"id";
            ctx.response.renderDiet!("index.dt", model);
            break;
        case "/timing-event":
            // ensure there is no task currently running
            auto taskid = postdata["taskid"].to!int;
            if(taskid != -1)
            {
                auto currentTask = db.fetchUsingKey!TimeTask(taskid);
                if(currentTask.stop.isNull) // if stop is null, this task was
                                            // stopped elsewhere.
                {
                    switch(postdata["action"])
                    {
                    case "stop":
                        currentTask.stop = cast(DateTime)Clock.currTime;
                        goto case "update";
                    case "update":
                        currentTask.comment = postdata["comment"];
                        currentTask.client_id = postdata["client_id"].to!int;
                        currentTask.project_id = postdata["project_id"].to!int;
                        currentTask.rate = Rate.parse(postdata["rate"]);
                        currentTask.start = parseDate(postdata["start"]);
                        enforce(currentTask.start < cast(DateTime)Clock.currTime(), "Cannot set start time to later than current time");
                        db.save(currentTask);
                        break;
                    case "cancel":
                        db.erase(currentTask);
                        break;
                    default:
                        break;
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
                    currentTask.comment = postdata["comment"];
                    currentTask.client_id = postdata["client_id"].to!int;
                    currentTask.project_id = postdata["project_id"].to!int;
                    currentTask.start = cast(DateTime)Clock.currTime;
                    currentTask.rate = Rate.parse(postdata["rate"]);
                    db.create(currentTask);
                }
            }
            ctx.response.redirect("/");
            break;
        case "/delete-task":
            auto task = db.fetchUsingKey!TimeTask(querydata["taskid"].to!int);
            db.erase(task);
            ctx.response.redirect("/");
            break;
        case "/edit-task":
            TaskEditViewModel model;
            model.currentTask = db.fetchUsingKey!TimeTask(querydata["taskid"].to!int);
            model.allClients = db.fetch(select(cds).orderBy(cds.name)).array;
            model.allProjects = db.fetch(select(pds).orderBy(pds.name)).array;
            ctx.response.renderDiet!("editor.dt", model);
            break;
        case "/process-edit-task":
            auto task = db.fetchUsingKey!TimeTask(postdata["taskid"].to!int);
            task.start = parseDate(postdata["start"]);
            task.stop = parseDate(postdata["stop"]);
            enforce(task.stop.get > task.start, "Duration must be positive");
            task.comment = postdata["comment"];
            task.client_id = postdata["client_id"].to!int;
            task.project_id = postdata["project_id"].to!int;
            task.rate = Rate.parse(postdata["rate"]);
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
            if(auto clidstr = querydata.getFirst("clientId"))
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
            newClient.name = postdata["name"];
            newClient.defaultRate = Rate.parse(postdata["rate"]);
            db.create(newClient);
            ctx.response.redirect("/clients");
            break;
        case "/add-project":
            Project newProject;
            newProject.name = postdata["name"];
            newProject.client_id = postdata["client_id"].to!int;
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
    static struct Opts
    {
        @description("Set the slf4d log level of the application (default: INFO)")
            Levels logLevel = Levels.INFO;

        @description("Bind to this IP address (default: 17.0.0.1)")
            string ipAddress = "127.0.0.1";

        @description("Bind to this port (default: 8080)")
            ushort port = 8080;
    }

    Opts opts;
    auto helpInformation = args.getopt2(opts);
    if(helpInformation.helpWanted)
    {
        defaultGetoptPrinter("Time tracker", helpInformation.options);
        return;
    }

    auto provider = new shared DefaultProvider(true, opts.logLevel);
    configureLoggingProvider(provider);

    // apply any migrations
    applyMigrations();

    auto server = new HttpServer(&runServer,
            ServerConfig(
                hostname: opts.ipAddress,
                port: opts.port
            ));
    server.start();
}
