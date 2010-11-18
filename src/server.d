module pacahon.server;

private import myversion;

version(D1)
{
	private import std.c.stdlib;
	private import std.thread;
	private import std.stdio;
}

version(D2)
{
	private import core.thread;
	private import core.stdc.stdio;
	private import core.stdc.stdlib;
}

private import std.c.string;

private import libzmq_headers;
private import libzmq_client;

private import std.file;
private import std.json;
private import std.datetime;
private import std.outbuffer;

private import pacahon.n3.parser;
private import pacahon.graph;

private import trioplax.triple;
private import trioplax.TripleStorage;
private import trioplax.mongodb.TripleStorageMongoDB;

private import pacahon.command.multiplexor;
private import pacahon.know_predicates;

void main(char[][] args)
{
	try
	{
		JSONValue props = get_props("pacahon-properties.json");

		printf("Pacahon commit=%s date=%s\n", myversion.hash.ptr, myversion.date.ptr);

		mom_client client = null;

		char* bind_to = cast(char*) props.object["zmq_point"].str;

		client = new libzmq_client(bind_to);
		client.set_callback(&get_message);

		string mongodb_server = props.object["mongodb_server"].str;
		string mongodb_collection = props.object["mongodb_collection"].str;
		int mongodb_port = cast(int) props.object["mongodb_port"].integer;

		printf("connect to mongodb, \n");
		printf("	port: %d\n", mongodb_port);
		printf("	server: %s\n", cast(char*) mongodb_server);
		printf("	collection: %s\n", cast(char*) mongodb_collection);

		TripleStorage ts = new TripleStorageMongoDB(mongodb_server, mongodb_port, mongodb_collection);
		printf("ok, connected : %X\n", ts);

		ServerThread thread = new ServerThread(&client.listener, ts);
		thread.start();

		printf("listener of zmq started\n");

		version(D1)
		{
			thread.wait();
		}

		while(true)
			Thread.getThis().sleep(100_000_000);

	}
	catch(Exception ex)
	{
		printf("Exception: %s", ex.msg);
	}

}

class ServerThread: Thread
{
	TripleStorage ts;

	this(void delegate() _dd, TripleStorage _ts)
	{
		super(_dd);
		ts = _ts;
	}
}

int count = 0;

void get_message(byte* msg, int message_size, mom_client from_client)
{
	msg[message_size] = 0;

	ServerThread server_thread = cast(ServerThread) Thread.getThis();
	TripleStorage ts = server_thread.ts;

	count++;

	printf("[%i] get message[%d]: \n%s\n", count, message_size, cast(char*) msg);
	//	printf("[%i] \n", count);

	StopWatch sw;
	sw.start();

	Subject*[] triples = parse_n3_string(cast(char*) msg, message_size);

	printf("triples.length=%d\n", triples.length);
	Subject*[][] results = new Subject*[][triples.length];

	// найдем в массиве triples субьекта с типом msg
	for(int ii = 0; ii < triples.length; ii++)
	{
		Subject* message = triples[ii];
		printf("message.subject=%s\n", message.subject.ptr);

		set_hashed_data(message);

		Predicate* type = message.getEdge(cast(char[]) "a");
		if(type is null)
			type = message.getEdge(rdf__type);

		if((msg__Message in type.objects_of_value) !is null)
		{

			Predicate* reciever = message.getEdge(msg__reciever);

			Predicate* ticket = message.getEdge(msg__ticket);

			char[] userId = null;

			if(ticket !is null && ticket.objects !is null)
			{
				char[] ticket_str = ticket.objects[0].object;

				printf("# найдем пользователя по сессионному билету ticket=%s\n", cast(char*) ticket_str);

				// найдем пользователя по сессионному билету
				triple_list_element* iterator = ts.getTriples(null, msg__ticket, ticket_str);

				if(iterator !is null)
				{
					userId = pacahon.graph.fromStringz(iterator.triple.s);
				}
				else
				{
					printf("# пользователь не найден\n");
				}
			}

			if(type !is null && reciever !is null && ("pacahon" in reciever.objects_of_value) !is null)
			{
				Predicate* sender = message.getEdge(msg__sender);
				Subject*[] ss = command_preparer(message, sender, userId, ts);

				if(ss !is null)
				{
					results[ii] = ss;
				}
				else
				{
					results[ii] = new Subject*[1];
					Subject ssss;
					results[ii][0] = &ssss;
				}
			}
		}
	}

	OutBuffer outbuff = new OutBuffer();

	for(int ii = 0; ii < results.length; ii++)
	{
		Subject*[] qq = results[ii];

		if(qq !is null)
		{
			for(int jj = 0; jj < qq.length; jj++)
			{
				Subject* ss1 = qq[jj];
				if(ss1 !is null)
					ss1.toOutBuffer(outbuff);
			}
		}
	}

	if(from_client !is null)
		from_client.send(cast(char*) "".ptr, cast(char*) outbuff.toBytes(), false);

	sw.stop();

	printf("count: %d, total time: %d microseconds\n", count, cast(long) sw.peek().microseconds);

	return;
}

Subject*[] command_preparer(Subject* message, Predicate* sender, char[] userId, TripleStorage ts)
{
	Subject*[] res;

	//	printf("command_preparer\n");

	Predicate* command = message.getEdge(msg__command);

	if("put" in command.objects_of_value)
	{
		res = put(message, sender, userId, ts);
	}
	else if("get" in command.objects_of_value)
	{
		res = get(message, sender, userId, ts);
	}
	else if("msg:get_ticket" in command.objects_of_value)
	{
		res = get_ticket(message, sender, userId, ts);
	}

	return res;
}

JSONValue get_props(string file_name)
{
	JSONValue res;

	if(exists(file_name))
	{
		string buff = cast(string) read(file_name);

		res = parseJSON(buff);
	}
	else
	{
		res.type = JSON_TYPE.OBJECT;

		JSONValue element1;
		element1.str = "tcp://127.0.0.1:5555";
		res.object["zmq_point"] = element1;

		JSONValue element2;
		element2.str = "127.0.0.1";
		res.object["mongodb_server"] = element2;

		JSONValue element3;
		element3.type = JSON_TYPE.INTEGER;
		element3.integer = 27017;
		res.object["mongodb_port"] = element3;

		JSONValue element4;
		element4.str = "pacahon";
		res.object["mongodb_collection"] = element4;

		string buff = toJSON(&res);

		write(file_name, buff);
	}

	return res;
}