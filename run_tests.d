import std.file;
import std.getopt;
import std.process;
import std.stdio;

bool useUnitThreaded;
bool coreTestsOnly;
enum Mode { phobos, vibe, combined };
Mode mode;

int main(string[] args)
{
	try
	{
		auto argsHelp = getopt(args,
			"ut",     "Use unit-threaded",   &useUnitThreaded,
			"core",   "Only run basic core tests (Cannot be used with --mode=combined)", &coreTestsOnly,
			std.getopt.config.required,
			"m|mode", "'-m=phobos': Run Phobos tests | '-m=vibe': Run Vibe.d tests | '-m=combined': Run core-only Phobos tests and all Vibe.d tests", &mode,
		);

		if(argsHelp.helpWanted)
		{
			defaultGetoptPrinter(
				"Runs the mysql-native test suite with Phobos sockets, Vibe.d sockets, or combined.\n"~
				"\n"~
				"Usage:\n"~
				"  run_tests --mode=(phobos|vibe|all) [OPTIONS] [-- [UNIT-THREADED OPTIONS]]\n"~
				"\n"~
				"Examples:\n"~
				"  run_tests --mode=combined\n"~
				"  run_tests --ut --mode=vibe -- --help\n"~
				"  run_tests --ut --mode=vibe -- --single --random\n"~
				"\n"~
				"Options:",
				argsHelp.options
			);

			return 0;
		}
	}
	catch(Exception e)
	{
		stderr.writeln(e.msg);
		stderr.writeln("For help: run_tests --help");
		stderr.writeln("Recommended: run_tests -m=combined");
		return 1;
	}

	if(coreTestsOnly && mode==Mode.combined)
	{
		stderr.writeln("Cannot use --core and --mode=combined together.");
		stderr.writeln("Instead, use:");
		stderr.writeln("  run_tests --core --mode=phobos && run_tests --core --mode=vibe");
		stderr.writeln("For help: run_tests --help");
		return 1;
	}

	runTests();

	return 0;
}

void runTests()
{
	
}
