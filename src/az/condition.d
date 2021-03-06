module az.condition;

private
{
    import std.json, std.stdio, std.string, std.array, std.datetime, std.concurrency, std.conv, std.file;
    import core.thread;

    import util.container;
    import util.utils;
    import util.logger;
    import util.cbor;
    import util.cbor8individual;

    import onto.individual;
    import pacahon.know_predicates;
    import pacahon.context;
    import pacahon.define;
    import pacahon.thread_context;
    import pacahon.log_msg;

    import search.vel;
    import search.vql;

    import bind.v8d_header;
}

enum RightType
{
    CREATE = 0,
    READ   = 1,
    WRITE  = 2,
    UPDATE = 3,
    DELETE = 4,
    ADMIN  = 5
}

logger log;

static this()
{
    log = new logger("pacahon", "log", "condition");
}

struct Mandat
{
    string id;
    string whom;
    string right;
    string condition;
    Script script;
}

int     count;
Context context;
Mandat[ string ] mandats;
VQL     vql;

public void condition_thread(string thread_name, string props_file_name)
{
    core.thread.Thread.getThis().name = thread_name;

    context   = new PThreadContext(null, thread_name);
    g_context = context;

    vql = new VQL(context);
    load();

    try
    {
        // SEND ready
        receive((Tid tid_response_receiver)
                {
                    send(tid_response_receiver, true);
                });

        while (true)
        {
            try
            {
                ScriptVM script_vm = context.get_ScriptVM();

                receive(
                        (CMD cmd, string arg, Tid to)
                        {
                            if (cmd == CMD.RELOAD)
                            {
                                Individual ss;
                                cbor2individual(&ss, arg);
                                prepare_condition(ss, script_vm);
                                send(to, true);
                            }
                            send(to, false);
                        },
                        (CMD cmd, Tid to)
                        {
                            if (cmd == CMD.NOP)
                                send(to, true);
                            else
                                send(to, false);
                        },
                        (EVENT type, string msg)
                        {
                            //writeln ("condition_thread: type:", type, ", msg=[", msg, "]");
                            if (msg !is null && msg.length > 3 && script_vm !is null)
                            {
                                //cbor2individual (&g_individual, msg);
                                g_individual.data = cast(char *)msg;
                                g_individual.length = cast(int)msg.length;

                                foreach (mandat; mandats.values)
                                {
                                    if (mandat.script !is null)
                                    {
                                        try
                                        {
                                            if (trace_msg[ 300 ] == 1)
                                                log.trace("exec script : %s ", mandat.condition);

                                            count++;
                                            script_vm.run(mandat.script);
                                        }
                                        catch (Exception ex)
                                        {
                                            log.trace_log_and_console("EX!condition.receive : %s", ex.msg);
                                        }
                                    }
                                }

//                                writeln("count:", count);

                                //clear_script_data_cache ();
                            }
                        },
                        (CMD cmd, int arg, bool arg2)
                        {
                            if (cmd == CMD.SET_TRACE)
                                set_trace(arg, arg2);
                        },
                        (Variant v) { log.trace_log_and_console(thread_name ~ "::Received some other type." ~ text(v)); });
            }
            catch (Exception ex)
            {
                writeln(thread_name, "EX!: receive");
            }
        }
    }
    catch (Exception ex)
    {
        writeln(thread_name, "EX!: main loop");
    }
    writeln("TERMINATED: ", thread_name);
}

public void load()
{
    //writeln ("@1");
    ScriptVM script_vm = context.get_ScriptVM();

    if (script_vm is null)
        return;

    if (trace_msg[ 301 ] == 1)
        log.trace("start load mandats");

    Individual[] res;
    vql.get(null,
            "return { 'veda-schema:script'}
            filter { 'rdf:type' == 'veda-schema:Mandate'}",
            res);

    int count = 0;

    foreach (ss; res)
    {
        prepare_condition(ss, script_vm);
    }

    //writeln ("@2");
    if (trace_msg[ 300 ] == 1)
        log.trace("end load mandats, count=%d ", res.length);
}

private void prepare_condition(Individual ss, ScriptVM script_vm)
{
    if (trace_msg[ 310 ] == 1)
        log.trace("prepare_condition uri=%s", ss.uri);

    JSONValue nil;
    try
    {
        string condition_text = ss.getFirstResource(veda_schema__script).literal;
        if (condition_text.length <= 0)
            return;

        //writeln("condition_text:", condition_text);

        Mandat mandat = void;
        mandat.id = ss.uri;

        if (condition_text[ 0 ] == '{')
        {
            JSONValue condition_json = parseJSON(condition_text);

            if (condition_json.type == JSON_TYPE.OBJECT)
            {
                JSONValue el = condition_json.object.get("whom", nil);
                if (el != nil)
                    mandat.whom = el.str;

                el = condition_json.object.get("right", nil);
                if (el != nil)
                    mandat.right = el.str;

                el = condition_json.object.get("condition", nil);
                if (el != nil)
                {
                    mandat.condition = el.str;
                    mandat.script    = script_vm.compile(cast(char *)(mandat.condition ~ "\0"));

                    if (trace_msg[ 310 ] == 1)
                        log.trace("#1 mandat.id=%s, text=%s", mandat.id, mandat.condition);

                    mandats[ ss.uri ] = mandat;
                }
            }
        }
        else
        {
            mandat.condition = condition_text;
            mandat.script    = script_vm.compile(cast(char *)(mandat.condition ~ "\0"));
            if (trace_msg[ 310 ] == 1)
                log.trace("#2 mandat.id=%s, text=%s", mandat.id, mandat.condition);

            mandats[ ss.uri ] = mandat;
        }

    }
    catch (Exception ex)
    {
        log.trace_log_and_console("error:load mandat :%s", ex.msg);
    }
    finally
    {
        //writeln ("@4");
    }
}
