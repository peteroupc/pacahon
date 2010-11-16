module pacahon.command.multiplexor;

private import core.stdc.stdio;
private import std.c.string;
private import core.stdc.stdlib;

private import pacahon.graph;
private import pacahon.n3.parser;

Subject*[] put (Subject* message, Predicate* sender)
{
	Subject*[] res;
	printf("command put\n");
	
	Predicate* args = message.getEdge("msg:args");	
	
	for (short i; i < args.count_objects; i++)
	{	     
		char* args_text = cast (char*)args.objects[i].object;
		printf("arg [%s]\n", args_text);
		
		int arg_size = strlen (args_text);
		printf("arg_size= %d\n", arg_size);
		
		char* buff = cast(char*) alloca(arg_size*2);
		Subject*[] triples_on_put = parse_n3_string(cast(char*) args_text, arg_size, buff);
		
		return new Subject*[3];
//		print_graph(triples_on_put[0]);
//		printf(triples_on_put[0].toString());
//		triples_on_put[0].toString();
	}
	
	return res;
}

Subject*[] get (Subject* message, Predicate* sender)
{
	Subject*[] res;
	printf("command get\n");
	
	return res;
}

Subject*[] get_ticket (Subject* message, Predicate* sender)
{
	Subject*[] res;
	printf("command get-ticket\n");
	
	return res;
}