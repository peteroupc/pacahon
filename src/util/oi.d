module pacahon.oi;

private import mq_client;
private import util.Logger;
private import zmq_point_to_poin_client;
private import rabbitmq_client;
private import std.json;
private import std.stdio;

Logger log;
Logger oi_msg;

static this()
{
	log = new Logger("pacahon", "log", "server");
	oi_msg = new Logger("pacahon", "oi", "server");
}

class OI
{
	private string _alias;
	private mq_client client;

	this()
	{
	}

	void connect(string[string] params)
	{
		_alias = params.get("alias", null);
		string transport = params.get("transport", "zmq");

		writeln("gateway:" ~ _alias ~ ", transport:" ~ transport ~ ", params:" ~ params.values);
		if(transport == "zmq")
			client = new zmq_point_to_poin_client();

		else if(transport == "rabbitmq")
			client = new rabbitmq_client();
		
		client.connect_as_req(params);
	}

	void send(string msg)
	{
		if(client is null)
			return;

		int length = cast(uint) msg.length;
		char* data = cast(char*) msg;

		if(*(data + length - 1) == ' ')
			*(data + length - 1) = 0;

		client.send(data, length, false);

		oi_msg.trace_io(false, cast(byte*) msg, msg.length);
	}

	void send(ubyte[] msg)
	{
		if(client is null)
			return;

		int length = cast(uint) msg.length;
		//		char* data = cast(char*) msg;

		//		if(*(data + length - 1) == ' ')
		//		{
		//			*(data + length - 1) = 0;
		//			length --;
		//		}

		int qq = 1;
		while(msg[length - qq] == 0)
		{
			qq++;
		}

		if(qq > 0)
			length = length - qq + 2;

		client.send(cast(char*) msg, length, false);

		oi_msg.trace_io(false, cast(byte*) msg, length);
	}

	string reciev()
	{
		if(client is null)
			return null;

		string msg;
		msg = client.reciev();

		oi_msg.trace_io(true, cast(byte*) msg, msg.length);

		return msg;
	}
}