module pacahon.server;

private
{
    import core.thread, std.stdio, std.string, std.c.string, std.json, std.outbuffer, std.datetime, std.conv, std.concurrency;
    version (linux)
        import std.c.linux.linux, core.stdc.stdlib;

    import io.mq_client;
    import io.rabbitmq_client;
    import io.file_reader;

    import az.acl;
    import az.condition;
    import storage.storage_thread;

    import util.logger;
    import util.turtle_parser;
    import util.utils;
    import util.load_info;

    import pacahon.context;
    import pacahon.know_predicates;
    import pacahon.log_msg;
    import pacahon.thread_context;
    import pacahon.define;
    import pacahon.interthread_signals;

    import search.xapian_indexer;
}

logger log;
logger io_msg;

// Called upon a signal from Linux
extern (C) public void sighandler0(int sig) nothrow @system
{
    try
    {
        log.trace_log_and_console("signal %d caught...\n", sig);
        system(cast(char *)("kill -kill " ~ text(getpid()) ~ "\0"));
        //Runtime.terminate();
    }
    catch (Exception ex)
    {
    }
}

static this()
{
    log    = new logger("pacahon", "log", "server");
    io_msg = new logger("pacahon", "io", "server");
}

string props_file_path = "pacahon-properties.json";

version (executable)
{
    void main(char[][] args)
    {
        init_core();
        while (true)
            core.thread.Thread.sleep(dur!("seconds")(1000));
    }
}

void commiter(string thread_name, Tid tid, Tid tid_subject_manager, Tid tid_acl_manager)
{
    core.thread.Thread.getThis().name = thread_name;
    // SEND ready
    receive((Tid tid_response_reciever)
            {
                send(tid_response_reciever, true);
            });

    while (true)
    {
        core.thread.Thread.sleep(dur!("seconds")(10));
        send(tid, CMD.COMMIT, "");
        core.thread.Thread.sleep(dur!("seconds")(1));
        send(tid_subject_manager, CMD.COMMIT);
        core.thread.Thread.sleep(dur!("seconds")(1));
        send(tid_acl_manager, CMD.COMMIT);
    }
}

void wait_starting_thread(P_MODULE tid_idx, ref Tid[ P_MODULE ] tids)
{
    Tid tid = tids[ tid_idx ];

    if (tid == Tid.init)
        throw new Exception("wait_starting_thread: Tid=" ~ text(tid_idx) ~ " not found", __FILE__, __LINE__);

    send(tid, thisTid);
    receive((bool isReady)
            {
                if (trace_msg[ 50 ] == 1)
                    log.trace("STARTED THREAD: %s", text(tid_idx));
            });
}

void init_core()
{
    log    = new logger("pacahon", "log", "server");
    io_msg = new logger("pacahon", "io", "server");

    version (linux)
    {
        // установим обработчик сигналов прерывания процесса
        signal(SIGABRT, &sighandler0);
        signal(SIGTERM, &sighandler0);
        signal(SIGQUIT, &sighandler0);
        signal(SIGINT, &sighandler0);
    }

    try
    {
//        log.trace_log_and_console("\nPACAHON %s.%s.%s\nSOURCE: commit=%s date=%s\n", pacahon.myversion.major, pacahon.myversion.minor,
//                                  pacahon.myversion.patch, pacahon.myversion.hash, pacahon.myversion.date);
        Tid[ P_MODULE ] tids;

        tids[ P_MODULE.interthread_signals ] = spawn(&interthread_signals_thread, text(P_MODULE.interthread_signals));
        wait_starting_thread(P_MODULE.interthread_signals, tids);

        tids[ P_MODULE.subject_manager ] = spawn(&individuals_manager, text(P_MODULE.subject_manager), individuals_db_path);
        wait_starting_thread(P_MODULE.subject_manager, tids);

        tids[ P_MODULE.ticket_manager ] = spawn(&individuals_manager, text(P_MODULE.ticket_manager), tickets_db_path);
        wait_starting_thread(P_MODULE.ticket_manager, tids);

        tids[ P_MODULE.acl_manager ] = spawn(&acl_manager, text(P_MODULE.acl_manager), acl_indexes_db_path);
        wait_starting_thread(P_MODULE.acl_manager, tids);

        tids[ P_MODULE.xapian_thread_context ] = spawn(&xapian_thread_context, text(P_MODULE.xapian_thread_context));
        wait_starting_thread(P_MODULE.xapian_thread_context, tids);

        tids[ P_MODULE.fulltext_indexer ] =
            spawn(&xapian_indexer, text(P_MODULE.fulltext_indexer), tids[ P_MODULE.subject_manager ], tids[ P_MODULE.acl_manager ],
                  tids[ P_MODULE.xapian_thread_context ]);
        wait_starting_thread(P_MODULE.fulltext_indexer, tids);

        tids[ P_MODULE.commiter ] =
            spawn(&commiter, text(P_MODULE.commiter), tids[ P_MODULE.fulltext_indexer ], tids[ P_MODULE.subject_manager ],
                  tids[ P_MODULE.acl_manager ]);
        wait_starting_thread(P_MODULE.commiter, tids);

        tids[ P_MODULE.statistic_data_accumulator ] = spawn(&statistic_data_accumulator, text(P_MODULE.statistic_data_accumulator));
        wait_starting_thread(P_MODULE.statistic_data_accumulator, tids);

        tids[ P_MODULE.print_statistic ] = spawn(&print_statistic, text(
                                                                        P_MODULE.print_statistic),
                                                 tids[ P_MODULE.statistic_data_accumulator ]);
        wait_starting_thread(P_MODULE.print_statistic, tids);

        foreach (key, value; tids)
            register(text(key), value);

        tids[ P_MODULE.condition ] = spawn(&condition_thread, text(P_MODULE.condition), props_file_path);
        wait_starting_thread(P_MODULE.condition, tids);

        register(text(P_MODULE.condition), tids[ P_MODULE.condition ]);
        Tid tid_condition = locate(text(P_MODULE.condition));


        JSONValue props;

        try
        {
            props = read_props(props_file_path);
        } catch (Exception ex1)
        {
            throw new Exception("ex! parse params:" ~ ex1.msg, ex1);
        }

        /////////////////////////////////////////////////////////////////////////////////////////////////////////

        JSONValue[] _listeners;
        if (("listeners" in props.object) !is null)
        {
            _listeners = props.object[ "listeners" ].array;
            int listener_section_count = 0;
            foreach (listener; _listeners)
            {
                listener_section_count++;
                string[ string ] params;
                foreach (key; listener.object.keys)
                    params[ key ] = listener[ key ].str;

                if (params.get("transport", "") == "file_reader")
                {
                    spawn(&io.file_reader.file_reader_thread, P_MODULE.file_reader, "pacahon-properties.json");
                }
                else if (params.get("transport", "") == "zmq")
                {
                    mq_client zmq_connection = null;

                    string    zmq_connect_type = params.get("zmq_connect_type", "server");
//						log.trace_log_and_console("LISTENER: connect to zmq:" ~ text (params), "");

                    if (zmq_connect_type == "server")
                    {
                        try
                        {
                            spawn(&io.zmq_listener.zmq_thread, text(
                                                                    P_MODULE.zmq_listener), "pacahon-properties.json",
                                  listener_section_count);
                            log.trace_log_and_console("LISTENER: connect to zmq:" ~ text(params), "");

//								zmq_connection = new zmq_point_to_poin_client();
//								zmq_connection.connect_as_listener(params);
                        } catch (Exception ex)
                        {
                        }
                    }
                }
                else if (params.get("transport", "") == "rabbitmq")
                {
                    mq_client rabbitmq_connection = null;

                    // прием данных по каналу rabbitmq
                    log.trace_log_and_console("LISTENER: connect to rabbitmq");

                    try
                    {
                        rabbitmq_connection = new rabbitmq_client();
                        rabbitmq_connection.connect_as_listener(params);

                        if (rabbitmq_connection.is_success() == true)
                        {
                            //rabbitmq_connection.set_callback(&get_message);

                            ServerThread thread_listener_for_rabbitmq = new ServerThread(&rabbitmq_connection.listener, props_file_path,
                                                                                         "RABBITMQ");

//                                init_ba2pacahon(thread_listener_for_rabbitmq.resource);

                            thread_listener_for_rabbitmq.start();

//								LoadInfoThread load_info_thread1 = new LoadInfoThread(&thread_listener_for_rabbitmq.getStatistic);
//								load_info_thread1.start();
                        }
                        else
                        {
                            writeln(rabbitmq_connection.get_fail_msg);
                        }
                    } catch (Exception ex)
                    {
                    }
                }
            }
        }
    } catch (Exception ex)
    {
        writeln("Exception: ", ex.msg);
    }
}

enum format : byte
{
    TURTLE  = 0,
    JSON_LD = 1,
    UNKNOWN = -1
}

class ServerThread : core.thread.Thread
{
    PThreadContext resource;

    this(void delegate() _dd, string props_file_path, string context_name)
    {
        super(_dd);
        resource = new PThreadContext(props_file_path, context_name);

//		resource.sw.start();
    }
}
