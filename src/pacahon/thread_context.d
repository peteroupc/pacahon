module pacahon.thread_context;

private
{
    import core.thread, std.json, std.stdio, std.format, std.datetime, std.concurrency, std.conv, std.outbuffer, std.string, std.uuid,
           std.file;

    import bind.xapian_d_header;
    import bind.v8d_header;

    import io.mq_client;
    import util.container;
    import util.logger;
    import util.utils;
    import util.cbor;
    import util.cbor8individual;

    import pacahon.know_predicates;
    import pacahon.define;
    import pacahon.context;
    import pacahon.bus_event;
    import pacahon.interthread_signals;
    import pacahon.log_msg;

    import onto.owl;
    import onto.individual;
    import onto.resource;
    import storage.lmdb_storage;
    import az.acl;
}

logger log;

static this()
{
    log = new logger("pacahon", "log", "API");
}

Tid    dummy_tid;

string g_str_script_result;
string g_str_script_out;

class PThreadContext : Context
{
    bool[ P_MODULE ] is_traced_module;

    /// deprecated vvv
    private Ticket *[ string ] user_of_ticket;
    private bool use_caching_of_documents = false;
    /// deprecated ^^^

    // // // authorization
    private Authorization acl_indexes;

    ScriptVM              script_vm;

    private OWL           owl;
    private JSONValue     props;

    private string        name;

    private string        old_msg_key2slot;
    private int[ string ] old_key2slot;

    private                string[ string ] prefix_map;

    private LmdbStorage    inividuals_storage;
    private LmdbStorage    tickets_storage;
    private search.vql.VQL _vql;

    private                Tid[ P_MODULE ] name_2_tids;
    private long           local_last_update_time;

    this(string property_file_path, string context_name)
    {
        inividuals_storage = new LmdbStorage(individuals_db_path, DBMode.R);
        tickets_storage    = new LmdbStorage(tickets_db_path, DBMode.R);
        acl_indexes        = new Authorization(acl_indexes_db_path, DBMode.R);

        name = context_name;

        if (trace_msg[ 21 ] == 1)
            log.trace("CREATE NEW CONTEXT:", context_name);

        foreach (id; P_MODULE.min .. P_MODULE.max)
            name_2_tids[ id ] = locate(text(id));

        is_traced_module[ P_MODULE.ticket_manager ]   = true;
        is_traced_module[ P_MODULE.subject_manager ]  = true;
        is_traced_module[ P_MODULE.acl_manager ]      = true;
        is_traced_module[ P_MODULE.fulltext_indexer ] = true;
        is_traced_module[ P_MODULE.condition ]        = true;

//        writeln("@ name_2_tids=", name_2_tids);

        if (property_file_path !is null)
        {
            try
            {
                props = read_props(property_file_path);
            } catch (Exception ex1)
            {
                throw new Exception("ex! parse params:" ~ ex1.msg, ex1);
            }

            // использование кеша документов
            if (("use_caching_of_documents" in props.object) !is null)
            {
                if (props.object[ "use_caching_of_documents" ].str == "true")
                    use_caching_of_documents = true;
            }

            _vql = new search.vql.VQL(this);

            //writeln(context_name ~ ": load events");
            //pacahon.event_filter.load_events(this);
            //writeln(context_name ~ ": load events... ok");

            owl = new OWL(this);
            owl.load();
        }
    }

    public long get_last_update_time()
    {
        long lut;

        send(getTid(P_MODULE.xapian_thread_context), CMD.GET, CNAME.LAST_UPDATE_TIME, thisTid);
        receive((long tm)
                {
                    lut = tm;
                });
        return lut;
    }

    private void reload_scripts()
    {
        Script[] scripts;
        writeln("-");

        foreach (path; [ "./public/js/server", "./public/js/common" ])
        {
            auto oFiles = dirEntries(path, "*.{js}", SpanMode.depth);

            foreach (o; oFiles)
            {
                writeln(" load script:", o);
                auto str_js        = cast(ubyte[]) read(o.name);
                auto str_js_script = script_vm.compile(cast(char *)(cast(char[])str_js ~ "\0"));
                if (str_js_script !is null)
                    scripts ~= str_js_script;
            }
        }

        foreach (script; scripts)
        {
            script_vm.run(script);
        }
    }

    ScriptVM get_ScriptVM()
    {
        if (script_vm is null)
        {
            try
            {
                script_vm = new_ScriptVM();
                g_context = this;

                string g_str_script_result = new char[ 1024 * 64 ];
                string g_str_script_out    = new char[ 1024 * 64 ];

                g_script_result.data           = cast(char *)g_str_script_result;
                g_script_result.allocated_size = cast(int)g_str_script_result.length;

                g_script_out.data           = cast(char *)g_str_script_out;
                g_script_out.allocated_size = cast(int)g_str_script_out.length;

                reload_scripts();
            }
            catch (Exception ex)
            {
                writeln("EX!get_ScriptVM ", ex.msg);
            }
        }

        return script_vm;
    }

    string[ 2 ] execute_script(string str_js)
    {
        string[ 2 ] res;
        get_ScriptVM();

        reload_scripts();

        try
        {
            auto str_js_script = script_vm.compile(cast(char *)(cast(char[])str_js ~ "\0"));
            if (str_js_script !is null)
                script_vm.run(str_js_script, &g_script_result);
            else
                writeln("Script is invalid");

            res[ 0 ] = cast(string)g_script_result.data[ 0..g_script_result.length ];
            res[ 1 ] = "NONE";
        }
        catch (Exception ex)
        {
            writeln("EX!executeScript ", ex.msg);
            res[ 0 ] = ex.msg;
            res[ 1 ] = "NONE";
        }

        return res;
    }

    bool authorize(string uri, Ticket *ticket, Access request_acess)
    {
        return acl_indexes.authorize(uri, ticket, request_acess);
    }

    public JSONValue get_props()
    {
        return props;
    }

    public string get_name()
    {
        return name;
    }

    public immutable(Class)[ string ] iget_owl_classes()
    {
        if (owl !is null)
        {
            check_for_reload("onto", &owl.load);
            return owl.iget_classes();
        }
        else
            return (immutable(Class)[ string ]).init;
    }

    public immutable(Class) * iget_class(string uri)
    {
        if (owl !is null)
        {
            check_for_reload("onto", &owl.load);
            return uri in owl.iget_classes();
        }
        else
            return null;
    }

    public Property *get_property(string uri)
    {
        if (owl !is null)
        {
            check_for_reload("onto", &owl.load);
            return owl.getProperty(uri);
        }
        else
            return null;
    }

    public immutable(Individual)[ string ] get_onto_as_map_individuals()
    {
        if (owl !is null)
        {
            check_for_reload("onto", &owl.load);
            return owl.iget_individuals;
        }
        else
            return (immutable(Individual)[ string ]).init;
    }


    public string get_individual_as_cbor(string uri)
    {
        //writeln ("@ get_individual_as_cbor, uri=", uri);
        auto res = inividuals_storage.find(uri);

        return res;
    }
///////////////////////////////////////////// oykumena ///////////////////////////////////////////////////

    public void push_signal(string key, long value)
    {
        try
        {
            Tid tid_interthread_signals = getTid(P_MODULE.interthread_signals);

            if (tid_interthread_signals != Tid.init)
            {
                send(tid_interthread_signals, CMD.PUT, key, value);
            }

            set_reload_signal_to_local_thread(key);
        }
        catch (Exception ex)
        {
            writeln(__FUNCTION__ ~ "", ex.msg);
        }
    }

    public void push_signal(string key, string value)
    {
        try
        {
            Tid tid_interthread_signals = getTid(P_MODULE.interthread_signals);

            if (tid_interthread_signals != Tid.init)
            {
                send(tid_interthread_signals, CMD.PUT, key, value);
            }
        }
        catch (Exception ex)
        {
            writeln(__FUNCTION__ ~ "", ex.msg);
        }
    }

///////////////////////////////////////////////////////////////////////////////////////////////

    public Tid getTid(P_MODULE tid_id)
    {
        Tid res = name_2_tids.get(tid_id, Tid.init);

        if (res == Tid.init)
        {
            // tid not found, attempt restore
            Tid tmp_tid = locate(text(tid_id));

            if (tmp_tid == Tid.init)
            {
                writeln("!!! NOT FOUND TID=", text(tid_id), "\n", name_2_tids, ", locate=1 ", );
                throw new Exception("!!! NOT FOUND TID=" ~ text(tid_id));
            }
            else
            {
                name_2_tids[ tid_id ] = tmp_tid;
                return tmp_tid;
            }
            //assert(false);
        }
        return res;
    }

    public int[ string ] get_key2slot()
    {
        string key2slot_str = inividuals_storage.find(xapian_metadata_doc_id);

        int[ string ] key2slot = deserialize_key2slot(key2slot_str);
        return key2slot;
    }

    ref string[ string ] get_prefix_map()
    {
        return prefix_map;
    }

    @property search.vql.VQL vql()
    {
        return _vql;
    }

    private void subject2Ticket(ref Individual ticket, Ticket *tt)
    {
        string when;
        long   duration;

        tt.id       = ticket.uri;
        tt.user_uri = ticket.getFirstLiteral(ticket__accessor);
        when        = ticket.getFirstLiteral(ticket__when);
        string dd = ticket.getFirstLiteral(ticket__duration);
        duration = parse!uint (dd);

//				writeln ("tt.userId=", tt.userId);

        if (tt.user_uri is null)
        {
            if (trace_msg[ 22 ] == 1)
                log.trace("найденный сессионный билет не полон, пользователь не найден");
        }

        if (tt.user_uri !is null && (when is null || duration < 10))
        {
            if (trace_msg[ 23 ] == 1)
                log.trace(
                          "найденный сессионный билет не полон, считаем что пользователь не был найден");
            tt.user_uri = null;
        }

        if (when !is null)
        {
            if (trace_msg[ 24 ] == 1)
                log.trace("сессионный билет %s Ok, user=%s, when=%s, duration=%d", tt.id, tt.user_uri, when,
                          duration);

            // TODO stringToTime очень медленная операция ~ 100 микросекунд
            tt.end_time = stringToTime(when) + duration * 10_000_000;                     //? hnsecs?
        }
    }

    private void stat(CMD command_type, ref StopWatch sw, string func = __FUNCTION__)
    {
        sw.stop();
        int t = cast(int)sw.peek().usecs;

        send(this.getTid(P_MODULE.statistic_data_accumulator), CMD.PUT, CNAME.WORKED_TIME, t);

//        send(this.getTid(P_MODULE.statistic_data_accumulator), CMD.PUT, CNAME.COUNT_COMMAND, 1);

        if (command_type == CMD.GET)
            send(this.getTid(P_MODULE.statistic_data_accumulator), CMD.PUT, CNAME.COUNT_GET, 1);
        else
            send(this.getTid(P_MODULE.statistic_data_accumulator), CMD.PUT, CNAME.COUNT_PUT, 1);

        if (trace_msg[ 555 ] == 1)
            log.trace(func[ (func.lastIndexOf(".") + 1)..$ ] ~ ": t=%d µs", t);
    }

    //////////////////////////////////////////////////////////////////////////////////
    struct Signal
    {
        long last_time_update = 0;
        long last_time_check  = 0;
    }

    Signal *[ string ] signals;

    public void set_reload_signal_to_local_thread(string interthread_signal_id)
    {
        Signal *signal = signals.get(interthread_signal_id, null);

        if (signal == null)
        {
            signal                           = new Signal;
            signals[ interthread_signal_id ] = signal;
        }

        long now = Clock.currStdTime() / 10000;
        signal.last_time_update = now;

        if (trace_msg[ 19 ] == 1)
            log.trace("[%s] SET RELOAD LOCAL SIGNAL [%s], signal.last_time_update=%d", name, interthread_signal_id,
                      signal.last_time_update);
    }

    public bool check_for_reload(string interthread_signal_id, void delegate() load)
    {
        Signal *signal = signals.get(interthread_signal_id, null);

        if (signal == null)
        {
            signal                           = new Signal;
            signals[ interthread_signal_id ] = signal;
        }

        long now = Clock.currStdTime() / 10000;

        if (trace_msg[ 19 ] == 1)
            log.trace("[%s] CHECK FOR RELOAD [%s], last_time_update=%d, last_time_check=%d", name, interthread_signal_id,
                      now - signal.last_time_update, now - signal.last_time_check);

        if (signal.last_time_update > signal.last_time_check)
        {
            signal.last_time_check = now;
            if (trace_msg[ 19 ] == 1)
                log.trace("[%s] RELOAD FOR [%s], last_time_update > last_time_check", name, interthread_signal_id);

            load();

            return true;
        }
        else if (now - signal.last_time_check > 10000 || now - signal.last_time_check < 0)
        {
            signal.last_time_check = now;

            long now_time_signal = look_integer_signal(interthread_signal_id);

            if (trace_msg[ 19 ] == 1)
                log.trace("[%s] RELOAD for [%s], (now_time_signal - signal.last_time_update)=%d", name, interthread_signal_id,
                          now_time_signal - signal.last_time_update);

            if (now_time_signal - signal.last_time_update > 10000 || now_time_signal - signal.last_time_update < 0 || now_time_signal == 0)
            {
                signal.last_time_update = now_time_signal;

                if (trace_msg[ 19 ] == 1)
                    log.trace("[%s] RELOAD FOR [%s]", name, interthread_signal_id);

                load();

                return true;
            }
        }
        return false;
    }

    public long look_integer_signal(string key)
    {
        Tid myTid                   = thisTid;
        Tid tid_interthread_signals = getTid(P_MODULE.interthread_signals);

        if (tid_interthread_signals !is Tid.init)
        {
            send(tid_interthread_signals, CMD.GET, key, DataType.Integer, myTid);

            long res;

            receive((long msg)
                    {
                        res = msg;
                    });

            return res;
        }
        return 0;
    }

    public string look_string_signal(string key)
    {
        Tid myTid                   = thisTid;
        Tid tid_interthread_signals = getTid(P_MODULE.interthread_signals);

        if (tid_interthread_signals !is Tid.init)
        {
            send(tid_interthread_signals, CMD.GET, key, DataType.String, myTid);

            string res;

            receive((string msg)
                    {
                        res = msg;
                    });

            return res;
        }
        return null;
    }


    // *************************************************** external api *********************************** //

    ///////////////////////////////////////////////////////// TICKET //////////////////////////////////////////////

    public bool is_ticket_valid(string ticket_id)
    {
        StopWatch sw; sw.start;

        try
        {
//        writeln("@is_ticket_valid, ", ticket_id);
            Ticket *ticket = get_ticket(ticket_id);

            if (ticket is null)
            {
                return false;
            }

            SysTime now = Clock.currTime();
            if (now.stdTime < ticket.end_time)
                return true;

            return false;
        }
        finally
        {
            stat(CMD.GET, sw);
        }
    }

    public Ticket authenticate(string login, string password)
    {
        StopWatch sw; sw.start;

        try
        {
            if (trace_msg[ 18 ] == 1)
                log.trace("authenticate, login=[%s] password=[%s]", login, password);

            Ticket ticket;
            ticket.result = ResultCode.Authentication_Failed;

            Ticket       *sys_ticket;

            Individual[] candidate_users = get_individuals_via_query(sys_ticket, "'" ~ veda_schema__login ~ "' == '" ~ login ~ "'");
            foreach (user; candidate_users)
            {
                string user_id = user.getFirstResource(veda_schema__owner).uri;
                if (user_id is null)
                    continue;

                Resources pass = user.resources.get(veda_schema__password, _empty_Resources);
                if (pass.length > 0 && pass[ 0 ] == password)
                {
                    Individual new_ticket;
                    new_ticket.resources[ rdf__type ] ~= Resource(ticket__Ticket);

                    UUID new_id = randomUUID();
                    new_ticket.uri = new_id.toString();

                    new_ticket.resources[ ticket__accessor ] ~= Resource(user_id);
                    new_ticket.resources[ ticket__when ] ~= Resource(getNowAsString());
                    new_ticket.resources[ ticket__duration ] ~= Resource("40000");

                    if (trace_msg[ 18 ] == 1)
                        log.trace("authenticate, ticket__accessor=%s", user_id);

                    // store ticket
                    string ss_as_cbor = individual2cbor(&new_ticket);

                    Tid    tid_ticket_manager = getTid(P_MODULE.ticket_manager);

                    if (tid_ticket_manager != Tid.init)
                    {
                        send(tid_ticket_manager, CMD.STORE, ss_as_cbor, thisTid);
                        receive((EVENT ev, Tid from)
                                {
                                    if (from == getTid(P_MODULE.ticket_manager))
                                    {
//                            res = msg;
                                        //writeln("context.store_subject:msg=", msg);
                                        subject2Ticket(new_ticket, &ticket);
                                        ticket.result = ResultCode.OK;
                                        user_of_ticket[ ticket.id ] = &ticket;
                                    }
                                });
                    }

                    return ticket;
                }
            }

            log.trace("fail authenticate, login=[%s] password=[%s]", login, password);

            ticket.result = ResultCode.Authentication_Failed;
            return ticket;
        }
        finally
        {
            stat(CMD.PUT, sw);
        }
    }

    public Ticket *get_ticket(string ticket_id)
    {
        StopWatch sw; sw.start;

        try
        {
            Ticket *tt = user_of_ticket.get(ticket_id, null);

            if (tt is null)
            {
                string when     = null;
                int    duration = 0;

                string ticket_str = tickets_storage.find(ticket_id);
                if (ticket_str !is null && ticket_str.length > 128)
                {
                    tt = new Ticket;
                    Individual ticket;
                    cbor2individual(&ticket, ticket_str);
                    subject2Ticket(ticket, tt);
                    tt.result               = ResultCode.OK;
                    user_of_ticket[ tt.id ] = tt;

                    if (trace_msg[ 17 ] == 1)
                        log.trace("тикет найден в базе, id=%s", ticket_id);
                }
                else
                {
                    tt        = new Ticket;
                    tt.result = ResultCode.Ticket_expired;

                    if (trace_msg[ 17 ] == 1)
                        log.trace("тикет не найден в базе, id=%s", ticket_id);
                }
            }
            else
            {
                if (trace_msg[ 17 ] == 1)
                    log.trace("тикет нашли в кеше, id=%s", ticket_id);

                SysTime now = Clock.currTime();
                if (now.stdTime >= tt.end_time)
                {
                    if (trace_msg[ 17 ] == 1)
                        log.trace("тикет просрочен, id=%s", ticket_id);
                    tt        = new Ticket;
                    tt.result = ResultCode.Ticket_expired;
                    return tt;
                }
            }
            return tt;
        }
        finally
        {
            stat(CMD.GET, sw);
        }
    }


    ////////////////////////////////////////////// INDIVIDUALS IO /////////////////////////////////////

    public immutable(string)[] get_individuals_ids_via_query(Ticket * ticket, string query_str)
    {
        StopWatch sw; sw.start;

        try
        {
            immutable(string)[] res;
            if (query_str.indexOf("==") <= 0)
                query_str = "'*' == '" ~ query_str ~ "'";

            vql.get(ticket, query_str, null, null, 10, 100000, res);
            return res;
        }
        finally
        {
            stat(CMD.GET, sw);
        }
    }

    public Individual[] get_individuals_via_query(Ticket *ticket, string query_str)
    {
        StopWatch sw; sw.start;

        if (trace_msg[ 26 ] == 1)
        {
            if (ticket !is null)
                log.trace("get_individuals_via_query: start, query_str=%s, ticket=%s", query_str, ticket.id);
            else
                log.trace("get_individuals_via_query: start, query_str=%s, ticket=null", query_str);
        }

        try
        {
            Individual[] res;
            if (query_str.indexOf("==") <= 0)
                query_str = "'*' == '" ~ query_str ~ "'";

            vql.get(ticket, query_str, null, null, 10, 10000, res);
            return res;
        }
        finally
        {
            stat(CMD.GET, sw);

            if (trace_msg[ 26 ] == 1)
                log.trace("get_individuals_via_query: end, query_str=%s", query_str);
        }
    }

    public immutable(Individual)[] iget_individuals_via_query(Ticket * ticket, string query_str)
    {
        StopWatch sw; sw.start;

        if (trace_msg[ 26 ] == 1)
        {
            if (ticket !is null)
                log.trace("iget_individuals_via_query: start, query_str=%s, ticket=%s", query_str, ticket.id);
            else
                log.trace("iget_individuals_via_query: start, query_str=%s, ticket=null", query_str);
        }

        try
        {
            immutable(Individual)[] res;
            if (query_str.indexOf("==") <= 0)
                query_str = "'*' == '" ~ query_str ~ "'";

            vql.get(ticket, query_str, null, null, 10, 10000, res);
            return res;
        }
        finally
        {
            stat(CMD.GET, sw);

            if (trace_msg[ 26 ] == 1)
                log.trace("iget_individuals_via_query: end, query_str=%s", query_str);
        }
    }


    public Individual[] get_individuals(Ticket *ticket, string[] uris)
    {
        StopWatch sw; sw.start;

        try
        {
            Individual[] res = Individual[].init;

            foreach (uri; uris)
            {
                if (acl_indexes.authorize(uri, ticket, Access.can_read) == true)
                {
                    Individual individual         = Individual.init;
                    string     individual_as_cbor = get_individual_as_cbor(uri);

                    if (individual_as_cbor !is null && individual_as_cbor.length > 1)
                        cbor2individual(&individual, individual_as_cbor);

                    res ~= individual;
                }
            }

            return res;
        }
        finally
        {
            stat(CMD.GET, sw);
        }
    }

    public Individual get_individual(Ticket *ticket, string uri)
    {
        StopWatch sw; sw.start;

        if (trace_msg[ 25 ] == 1)
        {
            if (ticket !is null)
                log.trace("get_individual, uri=%s, ticket=%s", uri, ticket.id);
            else
                log.trace("get_individual, uri=%s, ticket=null", uri);
        }

        try
        {
            Individual individual = Individual.init;

            if (acl_indexes.authorize(uri, ticket, Access.can_read) == true)
            {
                string individual_as_cbor = get_individual_as_cbor(uri);

                if (individual_as_cbor !is null && individual_as_cbor.length > 1)
                {
                    cbor2individual(&individual, individual_as_cbor);
                    individual.setStatus(ResultCode.OK);
                }
                else
                {
                    individual.setStatus(ResultCode.Unprocessable_Entity);
                }
            }
            else
            {
                if (trace_msg[ 25 ] == 1)
                    log.trace("get_individual, not authorized, uri=%s", uri);
                individual.setStatus(ResultCode.Not_Authorized);
            }

            return individual;
        }
        finally
        {
            stat(CMD.GET, sw);
            if (trace_msg[ 25 ] == 1)
                log.trace("get_individual: end, uri=%s", uri);
        }
    }

    public ResultCode store_individual(Ticket *ticket, Individual *indv, string ss_as_cbor, bool prepareEvents = true)
    {
        StopWatch sw; sw.start;

        try
        {
            Tid tid_subject_manager;
            Tid tid_acl;

            if (trace_msg[ 27 ] == 1)
                log.trace("[%s] store_individual", name);

            if (indv is null && ss_as_cbor is null)
                return ResultCode.No_Content;

            if (ss_as_cbor is null)
                ss_as_cbor = individual2cbor(indv);

            if (indv is null && ss_as_cbor !is null)
            {
                Individual tmp_indv;
                indv = &tmp_indv;
                cbor2individual(indv, ss_as_cbor);
            }

            if (indv is null && ss_as_cbor is null)
                return ResultCode.No_Content;

            if (trace_msg[ 27 ] == 1)
                log.trace("[%s] store_individual: %s", name, *indv);

            Resource[ string ] rdfType;
            setMapResources(indv.resources[ rdf__type ], rdfType);

            if (rdfType.anyExist(veda_schema__Membership) == true)
            {
                // before storing the data, expected availability acl_manager.
                wait_thread(P_MODULE.acl_manager);
                if (this.acl_indexes.isExistMemberShip(indv) == true)
                    return ResultCode.Duplicate_Key;
            }
            else if (rdfType.anyExist(veda_schema__PermissionStatement) == true)
            {
                // before storing the data, expected availability acl_manager.
                wait_thread(P_MODULE.acl_manager);
                if (this.acl_indexes.isExistPermissionStatement(indv) == true)
                    return ResultCode.Duplicate_Key;
            }

            EVENT ev = EVENT.NONE;

            tid_subject_manager = getTid(P_MODULE.subject_manager);

            if (tid_subject_manager != Tid.init)
            {
                send(tid_subject_manager, CMD.STORE, ss_as_cbor, thisTid);
                receive((EVENT _ev, Tid from)
                        {
                            if (from == getTid(P_MODULE.subject_manager))
                                ev = _ev;
                        });
            }

            if (ev == EVENT.NOT_READY)
                return ResultCode.Not_Ready;

            if (ev == EVENT.CREATE || ev == EVENT.UPDATE)
            {
                Tid tid_search_manager = getTid(P_MODULE.fulltext_indexer);

                if (tid_search_manager != Tid.init)
                {
                    push_signal("search", Clock.currStdTime() / 10000);

                    send(tid_search_manager, CMD.STORE, ss_as_cbor);
                }

                if (prepareEvents == true)
                {
                    bus_event_after(indv, rdfType, ss_as_cbor, ev, this);
                }

                return ResultCode.OK;
            }
            else
            {
                log.trace("Ex! store_subject:%s", ev);
                return ResultCode.Internal_Server_Error;
            }
        }
        finally
        {
            stat(CMD.PUT, sw);
        }
    }

    public ResultCode put_individual(Ticket *ticket, string uri, Individual individual)
    {
        individual.uri = uri;
        return store_individual(ticket, &individual, null);
    }

    public ResultCode post_individual(Ticket *ticket, Individual individual)
    {
        return store_individual(ticket, &individual, null);
    }

    public void wait_thread(P_MODULE thread_id)
    {
        StopWatch sw; sw.start;

        try
        {
            Tid tid = this.getTid(thread_id);

            if (tid != Tid.init)
            {
//            writeln("WAIT READY THREAD ", thread_id);
                send(tid, CMD.NOP, thisTid);
                receive((bool res) {});
//            writeln("OK");
            }
        }
        finally
        {
            stat(CMD.GET, sw);
        }
    }

    public void set_trace(int idx, bool state)
    {
        writeln("set trace idx=", idx, ":", state);
        foreach (mid; is_traced_module.keys)
        {
            Tid tid = getTid(mid);
            if (tid != Tid.init)
                send(tid, CMD.SET_TRACE, idx, state);
        }

        pacahon.log_msg.set_trace(idx, state);
    }

    public bool backup(int level = 0)
    {
        if (level == 0)
            freeze();

        try
        {
            bool result = false;

            Tid  tid_subject_manager = getTid(P_MODULE.subject_manager);

            send(tid_subject_manager, CMD.BACKUP, "", thisTid);
            string backup_id;
            receive((string res) { backup_id = res; });

            if (backup_id != "")
            {
                result = true;

                string res;
                Tid    tid_acl_manager = getTid(P_MODULE.acl_manager);
                send(tid_acl_manager, CMD.BACKUP, backup_id, thisTid);
                receive((string _res) { res = _res; });
                if (res == "")
                    result = false;
                else
                {
                    Tid tid_ticket_manager = getTid(P_MODULE.ticket_manager);
                    send(tid_ticket_manager, CMD.BACKUP, backup_id, thisTid);
                    receive((string _res) { res = _res; });
                    if (res == "")
                        result = false;
                    else
                    {
                        Tid tid_fulltext_indexer = getTid(P_MODULE.fulltext_indexer);
                        send(tid_fulltext_indexer, CMD.BACKUP, backup_id, thisTid);
                        receive((string _res) { res = _res; });
                        if (res == "")
                            result = false;
                    }
                }
            }

            if (result == false)
            {
                if (level < 10)
                {
                    log.trace_log_and_console("BACKUP FAIL, repeat(%d) %s", level, backup_id);

                    core.thread.Thread.sleep(dur!("msecs")(500));
                    return backup(level + 1);
                }
                else
                    log.trace_log_and_console("BACKUP FAIL, %s", backup_id);
            }
            else
                log.trace_log_and_console("BACKUP Ok, %s", backup_id);

            return result;
        }
        finally
        {
            if (level == 0)
                unfreeze();
        }
    }

    public long count_individuals()
    {
        return inividuals_storage.count_entries();
    }

    public void freeze()
    {
        writeln("FREEZE");
        Tid tid_subject_manager = getTid(P_MODULE.subject_manager);

        if (tid_subject_manager != Tid.init)
        {
            send(tid_subject_manager, CMD.FREEZE, thisTid);
            receive((bool _res) {});
        }
    }

    public void unfreeze()
    {
        writeln("UNFREEZE");
        Tid tid_subject_manager = getTid(P_MODULE.subject_manager);

        if (tid_subject_manager != Tid.init)
        {
            send(tid_subject_manager, CMD.UNFREEZE);
        }
    }
}
