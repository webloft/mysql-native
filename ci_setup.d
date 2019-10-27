import std.file;
import std.process;
import std.stdio : writeln;

bool envBool(string name)
{
	return environment.get(name, null) == "true";
}

string envGet(string name)
{
	return environment.get(name, null);
}

void copyIfExists(string from, string to)
{
	if(exists(from) && isFile(from))
		copy(from, to);
}

int main()
{
	auto haveRdmd = executeShell("rdmd --help").status == 0;
	if(!haveRdmd)
	{
		auto dmdZip = "dmd.2.076.0."~environment["TRAVIS_OS_NAME"]~".zip";
		spawnShell("wget http://downloads.dlang.org/releases/2017/"~dmdZip).wait;
		spawnShell("unzip -q -d local-dmd "~dmdZip).wait;
	}

	// MySQL is not installed by default on OSX build agents
	auto mysqlPrefix = "";
    if(environment["TRAVIS_OS_NAME"] == "osx")
	{
        if(envGet("DB") == "mysql-5.6")
        {
            spawnShell("brew update").wait;
            spawnShell("brew install mysql@5.6 && brew services start mysql56").wait;
            mysqlPrefix = "/usr/local/opt/mysql@5.6/bin/";
        }
        else if(envGet("DB") == "mysql-latest")
        {
            spawnShell("brew update").wait;
            spawnShell("brew install mysql && brew services start mysql").wait;
        }
        else
        {
            writeln("Envar 'DB' must be 'mysql-5.6' or 'mysql-latest', not '", envGet("DB"), "'");
            return 1;
        }
	}

	// If an alternate dub.selections.json was requested, use it.
    if(environment.get("DUB_SELECT") != null) {
		string dubSelections = "dub.selections."~envGet("DUB_SELECT")~".json";
		writeln("Using alternative dub dependencies file: ", dubSelections);
		copy(dubSelections, "dub.selections.json");
		copy("examples/homePage/dub.selections."~envGet("DUB_SELECT")~".json", "examples/homePage/dub.selections.json");
	}

	if(envBool("DUB_UPGRADE"))
	{
		// Update all dependencies
		//
		// As a bonus, this downloads & resolves deps now so intermittent
		// failures are more likely to be correctly marked as "job error"
		// rather than "tests failed".
		spawnShell("dub upgrade").wait;
		chdir("examples/homePage");
		spawnShell("dub upgrade").wait;
		chdir("../..");
	}
	else
	{
		// Don't upgrade dependencies.
		//
		// But download & resolve deps now so intermittent failures are more likely
		// to be correctly marked as "job error" rather than "tests failed".
		spawnShell("dub upgrade --missing-only").wait;
		chdir("examples/homePage");
		spawnShell("dub upgrade --missing-only").wait;
		chdir("../..");
	}

	// Setup DB
	spawnShell(mysqlPrefix~`mysql -u root -e 'SHOW VARIABLES LIKE "%version%";'`).wait;
	spawnShell(mysqlPrefix~`mysql -u root -e 'CREATE DATABASE mysqln_testdb;'`).wait;
	write("testConnectionStr.txt", "host=127.0.0.1;port=3306;user=root;pwd=;db=mysqln_testdb");
	
	return 0;
}
