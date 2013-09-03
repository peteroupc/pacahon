module pacahon.server;

private
{
	import core.thread;
	import core.stdc.stdio;
	import core.stdc.stdlib;
	import core.memory;
	import std.stdio;
	import std.string;
	import std.c.string;
	import std.json;
	import std.outbuffer;
	import std.datetime;
	import std.conv;

	import mq.zmq_point_to_poin_client;
	import mq.zmq_pp_broker_client;
	import mq.mq_client;
	import mq.rabbitmq_client;

	import trioplax.mongodb.TripleStorage;

	import util.Logger;
	import util.json_ld.parser1;
	import util.utils;
	import util.oi;

	import pacahon.context;
	import pacahon.graph;
	import pacahon.command.multiplexor;
	import pacahon.know_predicates;
	import pacahon.log_msg;
	import pacahon.load_info;
	import pacahon.thread_context;
	import pacahon.command.event_filter;
	import pacahon.ba2pacahon;	
}

Logger log;
Logger io_msg;

static this()
{
	log = new Logger("pacahon", "log", "server");
	io_msg = new Logger("pacahon", "io", "server");
}


void main(char[][] args)
{
	try
	{
		log.trace_log_and_console("\nPACAHON %s.%s.%s\nSOURCE: commit=%s date=%s\n", pacahon.myversion.major, pacahon.myversion.minor,
				pacahon.myversion.patch, pacahon.myversion.hash, pacahon.myversion.date);

		{
			JSONValue props;

			try
			{
				props = get_props("pacahon-properties.json");
			} catch(Exception ex1)
			{
				throw new Exception("ex! parse params:" ~ ex1.msg, ex1);
			}

			mq_client zmq_connection = null;
			mq_client rabbitmq_connection = null;

			/////////////////////////////////////////////////////////////////////////////////////////////////////////
			string bind_to = "tcp://*:5555";
			if(("zmq_point" in props.object) !is null)
				bind_to = props.object["zmq_point"].str;

			// логгирование
			// gebug - все отладочные сообщения, внимание! при включении будут жуткие тормоза! 
			// off - выключено
			// info - краткая информация о выполненных командах 
			// info_and_io - краткая информация о выполненных командах и входящие и исходящие сообщения 
			string logging = "info_and_io";
			if(("logging" in props.object) !is null)
				logging = props.object["logging"].str;

			// поведение:
			//	all - выполняет все операции
			//  writer - только операции записи
			//  reader - только операции чтения
			//  logger - ничего не выполняет а только логгирует операции, параметры logging не учитываются 		
			string behavior = "all";
			if(("behavior" in props.object) !is null)
				behavior = props.object["behavior"].str;

			/////////////////////////////////////////////////////////////////////////////////////////////////////////
			JSONValue[] _listeners;
			if(("listeners" in props.object) !is null)
			{
				_listeners = props.object["listeners"].array;
				foreach(listener; _listeners)
				{
					string[string] params;
					foreach(key; listener.object.keys)
						params[key] = listener[key].str;

					if(params.get("transport", "") == "zmq")
					{
						string zmq_connect_type = params.get("zmq_connect_type", "server");

						if(zmq_connect_type == "server")
						{
							try
							{
								zmq_connection = new zmq_point_to_poin_client();
								zmq_connection.connect_as_listener(params);
							} catch(Exception ex)
							{
							}
						} else if(zmq_connect_type == "broker")
						{
							if(zmq_connection is null)
							{
								//								zmq_connection = new zmq_pp_broker_client(bind_to, behavior);
								//								writeln("zmq PPP broker listener started:", bind_to);
							} else
							{
							}
						}

						if(zmq_connection !is null)
						{
							zmq_connection.set_callback(&get_message);
							ServerThread thread_listener_for_zmq = new ServerThread(&zmq_connection.listener, props, "ZMQ");

							if(("IGNORE_EMPTY_TRIPLE" in props.object) !is null)
							{
								if(props.object["IGNORE_EMPTY_TRIPLE"].str == "NO")
									thread_listener_for_zmq.resource.IGNORE_EMPTY_TRIPLE = false;
								else
									thread_listener_for_zmq.resource.IGNORE_EMPTY_TRIPLE = true;
							}

							writeln("IGNORE_EMPTY_TRIPLE:", thread_listener_for_zmq.resource.IGNORE_EMPTY_TRIPLE);

							writeln("start zmq listener");
							thread_listener_for_zmq.start();

							LoadInfoThread load_info_thread = new LoadInfoThread(&thread_listener_for_zmq.getStatistic);
							load_info_thread.start();
						}

					} else if(params.get("transport", "") == "rabbitmq")
					{
						// прием данных по каналу rabbitmq
						writeln("connect to rabbitmq");

						try
						{
							rabbitmq_connection = new rabbitmq_client();
							rabbitmq_connection.connect_as_listener(params);

							if(rabbitmq_connection.is_success() == true)
							{
								rabbitmq_connection.set_callback(&get_message);

								ServerThread thread_listener_for_rabbitmq = new ServerThread(&rabbitmq_connection.listener,
										props, "RABBITMQ");

								init_ba2pacahon(thread_listener_for_rabbitmq.resource);

								thread_listener_for_rabbitmq.start();

								LoadInfoThread load_info_thread1 = new LoadInfoThread(&thread_listener_for_rabbitmq.getStatistic);
								load_info_thread1.start();

							} else
							{
								writeln(rabbitmq_connection.get_fail_msg);
							}
						} catch(Exception ex)
						{
						}

					}

				}

				while(true)
					core.thread.Thread.sleep(dur!("seconds")(1000));
			}
		}
	} catch(Exception ex)
	{
		writeln("Exception: ", ex.msg);
	}

}

enum format: byte
{
	JSON_LD = 1,
	UNKNOWN = -1
}

void get_message(byte* msg, int message_size, mq_client from_client, ref ubyte[] out_data)
{
	ServerThread server_thread = cast(ServerThread) core.thread.Thread.getThis();
	server_thread.sw.stop();
	long time_from_last_call = cast(long) server_thread.sw.peek().usecs;

	//	if(time_from_last_call < 10)
	//		printf("microseconds passed from the last call: %d\n", time_from_last_call);

	server_thread.resource.stat.idle_time += time_from_last_call;

	StopWatch sw;
	sw.start();

	byte msg_format = format.UNKNOWN;

	if(trace_msg[1] == 1)
		log.trace("get message, count:[%d], message_size:[%d]", server_thread.resource.stat.count_message, message_size);

	//	from_client.get_counts(count_message, count_command);
	TripleStorage ts = server_thread.resource.ts;

	Subject[] subjects;

	if(trace_msg[0] == 1)
		io_msg.trace_io(true, msg, message_size);
	/*	
	 {
	 sw.stop();
	 long t = cast(long) sw.peek().usecs;
	 log.trace("messages count: %d, %d [µs] next: message parser start", server_thread.stat.count_message, t);
	 sw.start();
	 }
	 */

	bool is_parse_success = true;
	string parse_error;

	if(*msg == '{' || *msg == '[')
	{
		try
		{
			if(trace_msg[66] == 1)
				log.trace("parse from json");

			bool tmp_is_ba = true;
			for(int idx = 0; idx < message_size; idx++)
			{
				if(msg[idx] == '@')
				{
					tmp_is_ba = false;
					break;
				}
			}

			if(tmp_is_ba == true)
			{
				string msg_str = util.utils.fromStringz(cast(char*) msg);
				ba2pacahon(msg_str, server_thread.resource);
				return;
			} else
			{
				msg_format = format.JSON_LD;
				subjects = parse_json_ld_string(cast(char*) msg, message_size);
			}

			if(trace_msg[67] == 1)
				log.trace("parse from json, ok");
		} catch(Exception ex)
		{
			is_parse_success = false;
			parse_error = ex.msg;
			log.trace("Exception in parse_json_ld_string:[%s]", ex.msg);

		}
	} /*
	 {
	 sw.stop();
	 long t = cast(long) sw.peek().usecs;
	 log.trace("messages count: %d, %d [µs] next: message parser stop", server_thread.stat.count_message, t);
	 sw.start();
	 }
	 */

	if(trace_msg[3] == 1)
	{
		OutBuffer outbuff = new OutBuffer();
		toJson_ld(subjects, outbuff);
		outbuff.write(0);
		ubyte[] bb = outbuff.toBytes();
		io_msg.trace_io(true, cast(byte*) bb, bb.length);
	}

	if(trace_msg[4] == 1)
		log.trace("command.length=%d", subjects.length);

	Subject[] results;

	if(is_parse_success == false)
	{
		results = new Subject[1];

		Subject res = new Subject();

		res.subject = generateMsgId();

		res.addPredicateAsURI("a", msg__Message);
		res.addPredicate(msg__sender, "pacahon");

		//			if(message !is null)
		//			{
		//				res.addPredicateAsURI(msg__in_reply_to, message.subject);								
		//			}

		res.addPredicate(msg__reason, "JSON Parsing error:" ~ parse_error);
		res.addPredicate(msg__status, "400");

		results[0] = res;
	} else
	{
		results = new Subject[subjects.length];

		// найдем в массиве triples субьекта с типом msg

		// local_ticket <- здесь может быть тикет для выполнения пакетных операций
		Ticket ticket;
		char from;

		for(int ii = 0; ii < subjects.length; ii++)
		{
			StopWatch sw_c;
			sw_c.start();

			Subject command = subjects[ii];
			
			if(trace_msg[5] == 1)
			{
				log.trace("get_message:subject.count_edges=%d", command.count_edges);
				log.trace("get_message:message.subject=%s", command.subject);
			}

			if(command.count_edges < 3)
			{
				log.trace("данная команда [%s] не является полной (command.count_edges < 3), пропустим\n", command.subject);
				continue;
			}

			//		command.reindex_predicate();

			Predicate type = command.getPredicate("a");
			if(type is null)
				type = command.getPredicate(rdf__type);

			if(trace_msg[6] == 1)
			{
				if(type !is null)
					log.trace("command type:" ~ type.toString());
				else
					log.trace("command type: unknown");
			}

			if(type !is null && (msg__Message in type.objects_of_value) !is null)
			{				
				Predicate reciever = command.getPredicate(msg__reciever);
				Predicate sender = command.getPredicate(msg__sender);

				if(trace_msg[6] == 1)
					log.trace("message accepted from:%s", sender.getFirstLiteral());

				Predicate p_ticket = command.getPredicate(msg__ticket);

				string userId;

				if(p_ticket !is null && p_ticket.getObjects() !is null)
				{
					string ticket_id = p_ticket.getObjects()[0].literal;
					
					if (ticket_id != "@local")
					{
						ticket = server_thread.foundTicket(ticket_id);

						// проверим время жизни тикета
						if(ticket !is null)
						{
							SysTime now = Clock.currTime();
							if(now.stdTime > ticket.end_time)
							{
								// тикет просрочен
								if(trace_msg[61] == 1)
									log.trace("тикет просрочен, now=%s(%d) > tt.end_time=%d", timeToString(now), now.stdTime,
											ticket.end_time);
							} else
							{
								userId = ticket.userId;
								// продляем тикет
							
								ticket.end_time = now.stdTime + 3600;
							}
						}

						if(trace_msg[62] == 1)
							if(userId !is null)
								log.trace("пользователь найден, userId=%s", userId);

					}
					
				}
				

				if(type !is null && reciever !is null && ("pacahon" in reciever.objects_of_value) !is null)
				{
					//				Predicat* sender = command.getEdge(msg__sender);
					//				Subject out_message = new Subject;
					results[ii] = new Subject;

					if(trace_msg[6] == 1)
					{
						sw.stop();
						long t = cast(long) sw.peek().usecs;

						log.trace("messages count: %d, %d [µs] start: command_preparer",
								server_thread.resource.stat.count_message, t);
						sw.start();
					}
					
					command_preparer(ticket, command, results[ii], sender, server_thread.resource, ticket, from);

					if(trace_msg[7] == 1)
					{
						sw.stop();
						long t = cast(long) sw.peek().usecs;
						log.trace("messages count: %d, %d [µs] end: command_preparer", server_thread.resource.stat.count_message,
								t);
						sw.start();
					}
					//				results[ii] = out_message;
				}

				Predicate command_name = command.getPredicate(msg__command);
				server_thread.resource.stat.count_command++;
				sw_c.stop();
				long t = cast(long) sw_c.peek().usecs;

				if(trace_msg[68] == 1)
				{
					log.trace("command [%s][%s] %s, count: %d, total time: %d [µs]", command_name.getFirstLiteral(),
							command.subject, sender.getFirstLiteral(), server_thread.resource.stat.count_command, t);
					if(t > 60_000_000)
						log.trace("command [%s][%s] %s, time > 1 min", command_name.getFirstLiteral(), command.subject,
								sender.getFirstLiteral());
					else if(t > 10_000_000)
						log.trace("command [%s][%s] %s, time > 10 s", command_name.getFirstLiteral(), command.subject,
								sender.getFirstLiteral());
					else if(t > 1_000_000)
						log.trace("command [%s][%s] %s, time > 1 s", command_name.getFirstLiteral(), command.subject,
								sender.getFirstLiteral());
					else if(t > 100_000)
						log.trace("command [%s][%s] %s, time > 100 ms", command_name.getFirstLiteral(), command.subject,
								sender.getFirstLiteral());
				}

			} else
			{
				results[ii] = new Subject;
				//command_preparer(ticket, command, results[ii], null, null, server_thread.resource, ticket, from);
			}

		}
	}

	if(trace_msg[8] == 1)
		log.trace("формируем ответ, серилизуем ответные графы в строку");

	OutBuffer outbuff = new OutBuffer();

	if(msg_format == format.JSON_LD)
		toJson_ld(results, outbuff);

	//	outbuff.write(0);

	out_data = outbuff.toBytes();

	if(trace_msg[9] == 1)
		log.trace("данные для отправки сформированны, out_data=%s", cast(char[]) out_data);

	//if(from_client !is null)
	//	{
	//		out_data = msg_out;		
	//		from_client.send(cast(char*) "".ptr, cast(char*) msg_out, msg_out.length, false);
	//	}

	if(trace_msg[10] == 1)
	{
		if(out_data !is null)
			io_msg.trace_io(false, cast(byte*) out_data, out_data.length);
	}

	server_thread.resource.stat.count_message++;
	server_thread.resource.stat.size__user_of_ticket = cast(uint) server_thread.resource.user_of_ticket.length;
	server_thread.resource.stat.size__cache__subject_creator = cast(uint) server_thread.resource.cache__subject_creator.length;

	sw.stop();
	long t = cast(long) sw.peek().usecs;

	server_thread.resource.stat.worked_time += t;

	if(trace_msg[69] == 1)
		log.trace("messages count: %d, total time: %d [µs]", server_thread.resource.stat.count_message, t);

	server_thread.sw.reset();
	server_thread.sw.start();
	/*
	 if ((server_thread.stat.count_message % 10_000) == 0)
	 {
	 writeln ("start GC");
	 GC.collect();
	 GC.minimize();
	 }
	 */
	return;
}

class ServerThread: core.thread.Thread
{
	ThreadContext resource;

	StopWatch sw;

	//	Statistic stat;

	Statistic getStatistic()
	{
		return resource.stat;
	}

	this(void delegate() _dd, JSONValue props, string context_name)
	{
		super(_dd);
		resource = new ThreadContext(props, context_name);
		sw.start();
	}

	Ticket foundTicket(string ticket_id)
	{
		Ticket tt = resource.user_of_ticket.get(ticket_id, null);

		//	trace_msg[2] = 0;

		if(tt is null)
		{
			tt = new Ticket;
			tt.id = ticket_id;

			if(trace_msg[18] == 1)
			{
				log.trace("найдем пользователя по сессионному билету ticket=%s", ticket_id);
				//			printf("T count: %d, %d [µs] start get data\n", count, cast(long) sw.peek().microseconds);
			}

			string when = null;
			int duration = 0;

			// найдем пользователя по сессионному билету и проверим просрочен билет или нет
			if(ticket_id !is null && ticket_id.length > 10)
			{
				TLIterator it = resource.ts.getTriples(ticket_id, null, null);

				if(trace_msg[19] == 1)
					if(it is null)
						log.trace("сессионный билет не найден");

				foreach(triple; it)
				{
					if(trace_msg[20] == 1)
						log.trace("foundTicket: %s %s %s", triple.S, triple.P, triple.O);

					if(triple.P == ticket__accessor)
					{
						tt.userId = triple.O;
					}
					else if(triple.P == ticket__when)
					{
						when = triple.O;
					}
					else if(triple.P == ticket__duration)
					{
						duration = parse!uint(triple.O);
					}
					else if(triple.P == ticket__parentUnitOfAccessor)
					{
						tt.parentUnitIds ~= triple.O;
					}
					
//					if(tt.userId !is null && when !is null && duration > 10)
//						break;
				}

				delete (it);
			}

			if(trace_msg[20] == 1)
				log.trace("foundTicket end");

			if(tt.userId is null)
			{
				if(trace_msg[22] == 1)
					log.trace("найденный сессионный билет не полон, пользователь не найден");
			}

			if(tt.userId !is null && (when is null || duration < 10))
			{
				if(trace_msg[23] == 1)
					log.trace("найденный сессионный билет не полон, считаем что пользователь не был найден");
				tt.userId = null;
			}

			if(when !is null)
			{
				if(trace_msg[24] == 1)
					log.trace("сессионный билет %s Ok, user=%s, when=%s, duration=%d", ticket_id, tt.userId, when, duration);

				// TODO stringToTime очень медленная операция ~ 100 микросекунд
				tt.end_time = stringToTime(when) + duration * 100_000_000_000; //? hnsecs?

				resource.user_of_ticket[ticket_id] = tt;
			}
		} else
		{
			if(trace_msg[17] == 1)
				log.trace("тикет нашли в кеше, %s", ticket_id);
		}

		return tt;
	}

}