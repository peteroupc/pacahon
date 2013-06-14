module onto.doc_template;

private import std.stdio;
private import pacahon.graph;
private import pacahon.know_predicates;

class DocTemplate
{
	Subject main;
	GraphCluster data;

	this()
	{
		data = new GraphCluster();
	}

	Subject addTriple(string S, string P, string O, byte lang)
	{
		return data.addTriple(S, P, O, lang);
	}

	Predicate get_export_predicates()
	{
		if(main is null)
			return null;

		Predicate pp = main.getPredicate(link__exportPredicates);
		return pp;
	}

}