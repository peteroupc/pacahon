module pacahon.context;

private import std.concurrency, std.datetime, std.json;

private import util.container;
private import search.vel;
private import onto.owl;
private import onto.individual;
private import onto.sgraph;
private import pacahon.define;

private import bind.v8d_header;

enum CMD : byte
{
    STORE     = 1,
    PUT       = 1,
    FIND      = 2,
    GET       = 2,
    EXAMINE   = 4,
    AUTHORIZE = 8,
    COMMIT    = 16,
    END_DATA  = 32,
    NOP       = 64,
    RELOAD    = 65
}

enum P_MODULE : byte
{
    ticket_manager             = 0,
    subject_manager            = 1,
    acl_manager                = 2,
    xapian_thread_context      = 3,
    fulltext_indexer           = 4,
    statistic_data_accumulator = 5,
    condition                  = 6,
    commiter                   = 7,
    print_statistic            = 8,
    interthread_signals        = 9,
    file_reader				   = 10,
    zmq_listener			   = 11, 		
    nop                        = 99
}

enum ResultCode
{
    OK                    = 200,
    Created               = 201,
    No_Content            = 204,
    Bad_Request           = 400,
    Forbidden             = 403,
    Not_Found             = 404,
    Unprocessable_Entity  = 422,
    Internal_Server_Error = 500,
    Not_Implemented       = 501,
    Service_Unavailable   = 503,
    Disk_Full             = 1021,
    Duplicate_Key         = 1022
}

struct Ticket
{
    string id;
    string user_uri;

//    string[] parentUnitIds = new string[ 0 ];

    long end_time;

    immutable this(string _id, string _user_uri, long _end_time)
    {
        id       = _id;
        user_uri = _user_uri;
        end_time = _end_time;
    }

    immutable(Ticket) idup()
    {
        immutable(Ticket) result = immutable Ticket(id, user_uri, end_time);
        return result;
    }
}

interface Context
{
    string get_name();

    ScriptVM get_ScriptVM();

    Property *get_property(string ur);

    JSONValue get_props();

    Tid getTid(P_MODULE tid_name);

    @property search.vql.VQL vql();

    bool authorize(string uri, Ticket *ticket, Access request_acess);

    ref string[ string ] get_prefix_map();

    Subject get_subject(string uid);
    string get_subject_as_cbor(string uid);

    int[ string ] get_key2slot();
    long get_last_update_time();

    void store_subject(Subject ss, bool prepareEvents = true);

    /////////////////////////////////////////// <- oykumena -> ///////////////////////////////////////////////
    void push_signal(string key, long value);
    void push_signal(string key, string value);
    long look_integer_signal(string key);
    string look_string_signal(string key);

    // *************************************************** external api *********************************** //

    public string[ 2 ] execute_script(string str);

    public immutable(Class)[ string ] get_owl_classes();
    public immutable(Individual)[ string ] get_onto_as_map_individuals();
    public Class *get_class(string ur);

    //////////////////////////////////////////////////// TICKET //////////////////////////////////////////////
    public Ticket authenticate(string login, string password);
    public Ticket *get_ticket(string ticket_id);
    public bool is_ticket_valid(string ticket_id);

    ////////////////////////////////////////////// INDIVIDUALS IO ////////////////////////////////////////////
    public ResultCode store_individual(string ticket, Individual *indv, string ss_as_cbor, bool prepareEvents = true);
    public immutable(Individual)[] get_individuals_via_query(string query_str, Ticket * ticket);
    public immutable(Individual)[] get_individuals_via_query(string query_str, string sticket);

    public immutable(string)[]     get_individuals_ids_via_query(string query_str, string sticket);
    public immutable(string)[]     get_individuals_ids_via_query(string query_str, Ticket * ticket);

    public Individual get_individual(string uri, Ticket *ticket);
    public Individual get_individual(string uri, string sticket);
    public Individual[] get_individuals(string[] uris, string sticket);


    public ResultCode put_individual(string ticket, string uri, Individual individual);
    public ResultCode post_individual(string ticket, Individual individual);

    public void wait_thread(P_MODULE thread_id);
}

