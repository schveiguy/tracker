module tracker.app;

import tracker.db;

import handy_httpd;
import handy_httpd.components.multivalue_map;
import handy_httpd.components.optional : hmap = map;

import schlib.lookup;
import schlib.getopt2;


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
import std.getopt;
import std.uni;

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

struct HourFraction
{
    int units;
    this(Duration d)
    {
        enum hourHundredths = (60 * 60) / 100; // how many seconds in a 100th of an hour
        // round to nearest hour hundredth.
        units = cast(int)((d.total!"seconds" + hourHundredths / 2) / hourHundredths);
    }

    void toString(Out)(ref Out output)
    {
        import std.format;
        output.formattedWrite("%d.%02d", units / 100, units % 100);
    }

    string toString()
    {
        import std.array;
        Appender!string app;
        toString(app);
        return app.data;
    }

    Rate calculateCost(Rate perHour)
    {
        return Rate((perHour.amount * units + 50) / 100);
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

    // statistics
    Duration[Rate] rateTimeSpent;
    Duration[int] clientTimeSpent;
    Duration[int] projectTimeSpent;
    Duration totalTimeSpent;
    Duration totalPaidTime;
    Rate totalAmount;

    void calculateStats()
    {
        foreach(ref task; allTasks)
        {
            auto dur = task.stop.get - task.start;
            totalTimeSpent += dur;
            auto project = projectLookup[task.project_id];
            if(project.rate.amount > 0)
                totalPaidTime += dur;
            rateTimeSpent.require(project.rate) += dur;
            clientTimeSpent.require(task.client_id) += dur;
            projectTimeSpent.require(task.project_id) += dur;
        }

        foreach(r, dur; rateTimeSpent)
        {
            totalAmount += r * dur;
        }
    }
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

struct InvoiceListViewModel
{
    Invoice[] allInvoices;
    Client[] allClients;
    LookupById!Client clientLookup;
}

struct NewInvoiceViewModel
{
    TimeTask[] tasks;
    Client[] allClients;
    LookupById!Client clientLookup;
    Project[] allProjects;
    LookupById!Project projectLookup;
}

struct ShowInvoiceViewModel
{
    Invoice invoice;
    Client client;
    Client myInfo;

    LookupById!Project projectLookup;


    bool isDelete;

    // statistics
    struct TaskSummary
    {
        string description;
        Rate rate;
        Duration duration;
        Rate cost;
    }
    TaskSummary[] taskSummaries;
    HourFraction totalHours;
    Rate totalCost;

    struct HourLog
    {
        Date date;
        Duration duration;
        int projectid;
    }

    HourLog[] hourLog;

    struct TaskDescription
    {
        int projectid;
        string description;
    }

    TaskDescription[] descriptions;

    void buildSummaryData(TimeTask[] tasks, Project[] projects)
    {
        TaskSummary[int] summariesByProject;
        projectLookup = projects.fieldLookup!"id";
        foreach(p; projects)
            if(p.rate.amount > 0)
                summariesByProject[p.id] = TaskSummary(p.name, p.rate);

        foreach(t; tasks)
        {
            if(auto ps = t.project_id in summariesByProject)
            {
                ps.duration += t.stop.get - t.start;
            }
        }

        foreach(p; projects)
        {
            if(auto ps = p.id in summariesByProject)
            {
                if(ps.duration != Duration.zero)
                {
                    auto hf = HourFraction(ps.duration);
                    ps.cost = hf.calculateCost(ps.rate);
                    taskSummaries ~= *ps;
                    totalHours.units += hf.units;
                    totalCost += ps.cost;
                }
            }
        }

        // generate the hour logs
        tasks.sort!((t1, t2) => t1.start < t2.start);
        Duration[Date][int] logMap;
        bool[TaskDescription] descMap;
        foreach(t; tasks)
        {
            logMap.require(t.project_id).require(t.start.date) += t.stop.get - t.start;
            if(t.comment.length > 0)
                descMap[TaskDescription(t.project_id, t.comment)] = true;
        }
        foreach(pid, m1; logMap)
            foreach(date, dur; m1)
                hourLog ~= HourLog(date, dur, pid);

        hourLog.sort!((h1, h2) => h1.date == h2.date ? h1.projectid < h2.projectid : h1.date < h2.date);
        descriptions = descMap.keys;
        descriptions.sort!((d1, d2) => d1.projectid < d2.projectid);
    }
}

struct ClientEditViewModel
{
    Client client;
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

    DataSet!TimeTask tds;
    DataSet!Client cds;
    DataSet!Project pds;
    DataSet!Invoice ids;

    TimeTask getUnfinishedTask(Database db) => db.fetchOne(select(tds).where(tds.stop, " IS NULL"), TimeTask.init);

    auto db = openDB;
	switch(ctx.request.url)
    {
        case "":
        case "/":
            // fetch all the data
            IndexViewModel model;
            auto taskQuery = select(tds).where(tds.stop, " IS NOT NULL").orderBy(tds.start.descend);

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
                        taskQuery = taskQuery.where(tds.start, " >= DATETIME(", forDate.param, ", 'start of month') AND ",
                                tds.start, " < DATETIME(", forDate.param, ", 'start of month', '+1 months')");
                        break;
                    case "week":
                        taskQuery = taskQuery.where(tds.start, " >= DATETIME(", forDate.param, ", '-6 days', 'weekday 1') AND ",
                                tds.start, " < DATETIME(", forDate.param, ", '+1 days', 'weekday 1')");
                        break;
                    case "day":
                        taskQuery = taskQuery.where(tds.start, " >= DATETIME(", forDate.param, ", 'start of day') AND ",
                                tds.start, " < DATETIME(", forDate.param, ", 'start of day', '+1 days')");
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
                    taskQuery = taskQuery.where(tds.client_id, " = ", model.client_id.param);
                }
            }

            if(auto project_id = ctx.request.queryParams.getFirst("project_id"))
            {
                if(project_id.value.length != 0)
                {
                    model.project_id = project_id.value.to!int;
                    taskQuery = taskQuery.where(tds.project_id, " = ", model.project_id.param);
                }
            }

            model.allTasks = db.fetch(taskQuery).array;
            model.currentTask = getUnfinishedTask(db);
            model.allClients = db.fetch(select(cds).orderBy(cds.name)).array;
            model.clientLookup = model.allClients.fieldLookup!"id";
            model.allProjects = db.fetch(select(pds).orderBy(pds.name)).array;
            model.projectLookup = model.allProjects.fieldLookup!"id";

            // record all statistics
            model.calculateStats();
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
                    db.create(currentTask);
                }
            }
            ctx.response.redirect("/");
            break;
        case "/delete-task":
            auto task = db.fetchUsingKey!TimeTask(querydata["taskid"].to!int);
            enforce(task.invoice_id.isNull, "Cannot delete already-invoiced task");
            db.erase(task);
            ctx.response.redirect("/");
            break;
        case "/edit-task":
            TaskEditViewModel model;
            model.currentTask = db.fetchUsingKey!TimeTask(querydata["taskid"].to!int);
            model.allClients = db.fetch(select(cds).orderBy(cds.name)).array;
            model.allProjects = db.fetch(select(pds).orderBy(pds.name)).array;
            ctx.response.renderDiet!("taskeditor.dt", model);
            break;
        case "/process-edit-task":
            auto task = db.fetchUsingKey!TimeTask(postdata["taskid"].to!int);
            enforce(task.invoice_id.isNull, "Cannot edit already-invoiced task");
            task.start = parseDate(postdata["start"]);
            task.stop = parseDate(postdata["stop"]);
            enforce(task.stop.get > task.start, "Duration must be positive");
            task.comment = postdata["comment"];
            task.client_id = postdata["client_id"].to!int;
            task.project_id = postdata["project_id"].to!int;
            db.save(task);
            ctx.response.redirect("/");
            break;
        case "/clients":
            ClientViewModel model;
            model.allClients = db.fetch(select(cds)).array;
            ctx.response.renderDiet!("clients.dt", model);
            break;
        case "/invoices":
            InvoiceListViewModel model;
            model.allInvoices = db.fetch(select(ids)).array;
            model.allClients = db.fetch(select(cds)).array;
            model.clientLookup = model.allClients.fieldLookup!"id";
            ctx.response.renderDiet!("invoicelist.dt", model);
            break;
        case "/add-invoice":
            NewInvoiceViewModel model;
            model.tasks = db.fetch(select(tds).where(tds.stop, " IS NOT NULL AND ", tds.invoice_id, " IS NULL AND ", tds.project.rate, " > 0").orderBy(tds.start.descend)).array;
            model.allClients = db.fetch(select(cds)).array;
            model.clientLookup = model.allClients.fieldLookup!"id";
            model.allProjects = db.fetch(select(pds)).array;
            model.projectLookup = model.allProjects.fieldLookup!"id";
            ctx.response.renderDiet!("newinvoice.dt", model);
            break;
        case "/process-add-invoice":
            // create a new invoice based on the tasks
            Invoice newInvoice;
            int[] taskids;
            taskids = postdata.getAll("tasks[]").map!(tid => tid.to!int).array;
            newInvoice.client_id = postdata["client_id"].to!int;
            newInvoice.my_client_id = db.fetchOne(select(cds.id).where(cds.myInfo, " = TRUE"));
            auto client = db.fetchUsingKey!Client(newInvoice.client_id);
            enforce(taskids.length > 0, "Need at least one task to invoice");
            enforce(db.fetchOne(select(count(tds.id)).where(format("ID IN (%(%s,%)) AND client_id = ", taskids), newInvoice.client_id.param, " AND invoice_id IS NULL")) == taskids.length,
                "Invoice inconsistency detected!");

            newInvoice.invoiceDate = cast(Date)Clock.currTime();
            if(auto idate = postdata.getFirst("invoiceDate"))
            {
                if(idate.value.length > 0)
                    newInvoice.invoiceDate = Date.fromISOExtString(idate.value);
            }
            newInvoice.invoiceNumber = format("%s%04d%02d%02d", client.name[0 .. 3].asUpperCase, newInvoice.invoiceDate.year, int(newInvoice.invoiceDate.month), newInvoice.invoiceDate.day);
            if(auto invoiceNumSpec = postdata.getFirst("invoiceNum"))
            {
                if(invoiceNumSpec.value.length > 0)
                    newInvoice.invoiceNumber = invoiceNumSpec.value;
            }

            // create the invoice
            db.create(newInvoice);
            // now assign all the tasks to the invoice
            db.perform(set(tds.invoice_id, newInvoice.id.param).where(tds.id, format(" IN (%(%s,%))", taskids)));
            ctx.response.redirect(format("/invoice?invoiceid=%s", newInvoice.id));
            break;
        case "/delete-invoice":
        case "/invoice":
            // get the invoice
            ShowInvoiceViewModel model;
            model.isDelete = ctx.request.url == "/delete-invoice";
            auto data = db.fetchOne(select(ids, ids.client, ids.myInfo).havingKey!Invoice(ctx.request.queryParams["invoiceid"].to!int));
            model.invoice = data[0];
            model.client = data[1];
            model.myInfo = data[2];

            // get the data to build the summaries
            auto tasks = db.fetch(select(tds).where(tds.invoice_id, " = ", model.invoice.id.param)).array;
            auto projects = db.fetch(select(pds).where(pds.client_id, " = ", model.client.id.param)).array;
            model.buildSummaryData(tasks, projects);
            ctx.response.renderDiet!("invoice.dt", model);
            break;
        case "/process-delete-invoice":
            auto invoice = db.fetchUsingKey!Invoice(ctx.request.queryParams["invoiceid"].to!int);
            db.perform(set(tds.invoice_id, null.param).where(tds.invoice_id, " = ", invoice.id.param));
            db.erase(invoice);
            ctx.response.redirect("/invoices");
            break;
        case "/edit-client":
            ClientEditViewModel model;
            model.client = db.fetchUsingKey!Client(querydata["clientid"].to!int);
            ctx.response.renderDiet!("clienteditor.dt", model);
            break;
        case "/process-edit-client":
            auto client = db.fetchUsingKey!Client(postdata["clientid"].to!int);
            static foreach(field; ["name", "contractEntity", "contactName", "address1", "address2", "address3", "address4", "phone", "email"])
                __traits(getMember, client, field) = postdata.getFirst(field).orElse("");
            auto wasMyInfo = client.myInfo;
            client.myInfo = postdata.getFirst("myInfo").hmap!(v => true).orElse(false);
            if(client.myInfo != wasMyInfo && client.myInfo) {
                // remove any client myInfo from the database, only
                // one can be true.
                db.perform(set(cds.myInfo, false.param));
            }
            db.save(client);
            ctx.response.redirect("/clients");
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
            static foreach(field; ["name", "contractEntity", "contactName", "address1", "address2", "address3", "address4", "phone", "email"])
                __traits(getMember, newClient, field) = postdata[field];
            newClient.myInfo = postdata.getFirst("myInfo").hmap!(v => true).orElse(false);
            if(newClient.myInfo) {
                // remove any client myInfo from the database, only
                // one can be true.
                db.perform(set(cds.myInfo, false.param));
            }
            db.create(newClient);
            ctx.response.redirect("/clients");
            break;
        case "/add-project":
            Project newProject;
            newProject.name = postdata["name"];
            newProject.client_id = postdata["client_id"].to!int;
            newProject.rate = Rate(postdata["rate"]);
            db.create(newProject);
            ctx.response.redirect("/projects");
            break;
        default:
            ctx.response.setStatus(HttpStatus.NOT_FOUND);
            break;
    }
}

void processCSVImport(bool doImport)
{
    // use the stdin as csv input. parse the csv, and add the time tasks
    import std.csv : csvReader;
    import std.stdio;
    auto db = openDB;
    DataSet!TimeTask ds;
    foreach(record; stdin.byLine.joiner("\n").csvReader!(string[string])(null))
    {
        // need to do some massaging of data. We get the duration and the start date/time, not the stop date/time.
        auto duration = "duration" in record;
        auto start = "start" in record;
        auto description = "description" in record;
        auto projectid = "project" in record;
        enforce(duration && start && description && projectid, "Missing fields");

        TimeTask newTask;
        auto project = db.fetchUsingKey!Project((*projectid).to!int);
        newTask.start = DateTime.fromISOExtString(*start);
        int hour;
        int minute;
        int second;
        formattedRead(*duration, "%s:%s:%s", hour, minute, second);
        newTask.stop = newTask.start + (hour.hours + minute.minutes + second.seconds);
        newTask.client_id = project.client_id;
        newTask.project_id = project.id;
        newTask.comment = *description;
        if(doImport)
            db.create(newTask);
        writeln("Read task: ", newTask, " (duration = ", DurationPrinter(newTask.stop.get - newTask.start), ")");
    }
}

void main(string[] args)
{
    enum CSVOption
    {
        off,
        on,
        print,
    }
    static struct Opts
    {
        @description("Instead of running the server, use the stdin as a CSV file to import into the database")
            CSVOption csv;

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

    if(opts.csv != CSVOption.off)
    {
        processCSVImport(opts.csv == CSVOption.on);
        return;
    }

    // apply any migrations
    applyMigrations();

    auto server = new HttpServer(&runServer,
            ServerConfig(
                hostname: opts.ipAddress,
                port: opts.port
            ));
    server.start();
}
