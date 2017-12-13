[![Build Status](https://travis-ci.org/mysql-d/mysql-native.svg)](https://travis-ci.org/mysql-d/mysql-native)

A [Boost-licensed](http://www.boost.org/LICENSE_1_0.txt) native [D](http://dlang.org)
client driver for MySQL and MariaDB.

This package attempts to provide composite objects and methods that will
allow a wide range of common database operations, but be relatively easy to
use. It has no dependecies on GPL header files or libraries, instead communicating
directly with the server via the
[published client/server protocol](http://dev.mysql.com/doc/internals/en/client-server-protocol.html).

This package supports both [Phobos sockets](https://dlang.org/phobos/std_socket.html)
and [Vibe.d](http://vibed.org/) sockets. It will automatically use the correct
type based on whether Vibe.d is used in your project. (If you use
[DUB](http://code.dlang.org/getting_started), this is completely seamless.
Otherwise, you can use `-version=Have_vibe_d_core` to force Vibe.d sockets
instead of Phobos ones.)

See [.travis.yml](https://github.com/mysql-d/mysql-native/blob/master/.travis.yml)
for a list of officially supported D compiler versions.

In this document:
* [API](#api)
* [Basic example](#basic-example)
* [Additional notes](#additional-notes)
* [Developers - How to run the test suite](#developers---how-to-run-the-test-suite)

API
---

[API Reference](http://semitwist.com/mysql-native)

The primary interfaces:
- [Connection](http://semitwist.com/mysql-native/mysql/connection/Connection.html): Connection to the server, and querying and setting of server parameters.
- [MySQLPool](http://semitwist.com/mysql-native/mysql/pool.html): Connection pool, for Vibe.d users.
- [exec()](http://semitwist.com/mysql-native/mysql/commands/exec.html): Plain old SQL statement that does NOT return rows (like INSERT/UPDATE/CREATE/etc), returns number of rows affected
- [query()](http://semitwist.com/mysql-native/mysql/commands/query.html): Execute an SQL statement that DOES return rows (ie, SELECT) and handle the rows one at a time, as an input range.
- [queryRow()](http://semitwist.com/mysql-native/mysql/commands/queryRow.html): Execute an SQL statement and get the first row.
- [queryRowTuple()](http://semitwist.com/mysql-native/mysql/commands/queryRowTuple.html): Execute an SQL statement and get the first row into a matching tuple of D variables.
- [queryValue()](http://semitwist.com/mysql-native/mysql/commands/queryValue.html): Execute an SQL statement and get the first value in the first row.
- [prepare()](http://semitwist.com/mysql-native/mysql/prepared/prepare.html): Create a prepared statement
- [Prepared](http://semitwist.com/mysql-native/mysql/prepared/PreparedImpl.html): A prepared statement, with principal methods:
	- [exec()](http://semitwist.com/mysql-native/mysql/prepared/PreparedImpl.exec.html)/[query()](http://semitwist.com/mysql-native/mysql/prepared/PreparedImpl.query.html)/etc.: Just like above, but using a prepared statement.
	- [setArg()](http://semitwist.com/mysql-native/mysql/prepared/PreparedImpl.setArg.html): Set one argument to pass into the prepared statement.
	- [setArgs()](http://semitwist.com/mysql-native/mysql/prepared/PreparedImpl.setArgs.html): Set all arguments to pass in.
	- [getArg()](http://semitwist.com/mysql-native/mysql/prepared/PreparedImpl.getArg.html): Get an argument that's been set.
	- [release()](http://semitwist.com/mysql-native/mysql/prepared/PreparedImpl.release.html): Optional. Prepared is refcounted.
- [Row](http://semitwist.com/mysql-native/mysql/result/Row.html): One "row" of results, used much like an array of Variant.
- [ResultRange](http://semitwist.com/mysql-native/mysql/result/ResultRange.html): An input range of rows.
- [ResultSet](http://semitwist.com/mysql-native/mysql/result/ResultSet.html): A random access range of rows.

Also note the [MySQL <-> D type mappings tables](https://semitwist.com/mysql-native/mysql.html)

Basic example
-------------
```d
import std.array : array;
import std.variant;
import mysql;

void main(string[] args)
{
	// Connect
	auto connectionStr = "host=localhost;port=3306;user=yourname;pwd=pass123;db=mysqln_testdb";
	if(args.length > 1)
		connectionStr = args[1];
	Connection conn = new Connection(connectionStr);
	scope(exit) conn.close();

	// Insert
	auto rowsAffected = exec(conn,
		"INSERT INTO `tablename` (`id`, `name`) VALUES (1, 'Ann'), (2, 'Bob')");

	// Query
	ResultRange range = query(conn, "SELECT * FROM `tablename`");
	Row row = range.front;
	Variant id = row[0];
	Variant name = row[1];
	assert(id == 1);
	assert(name == "Ann");

	range.popFront();
	assert(range.front[0] == 2);
	assert(range.front[1] == "Bob");

	// Prepared statements
	Prepared prepared = prepare(conn, "SELECT * FROM `tablename` WHERE `name`=? OR `name`=?");
	prepared.setArgs("Bob", "Bobby");
	ResultRange bobs = prepared.query();
	bobs.close(); // Skip them
	
	prepared.setArgs("Bob", "Ann");
	Row[] rs = prepared.query.array;
	assert(rs.length == 2);
	assert(rs[0][0] == 1);
	assert(rs[0][1] == "Ann");
	assert(rs[1][0] == 2);
	assert(rs[1][1] == "Bob");

	// Nulls
	Prepared insert = prepare(conn, "INSERT INTO `tablename` (`id`, `name`) VALUES (?,?)");
	insert.setArgs(null, "Cam"); // Also takes Nullable!T
	insert.exec();
	range = query(conn, "SELECT * FROM `tablename` WHERE `name`='Cam'");
	assert( range.front[0].type == typeid(typeof(null)) );
}
```

Additional notes
----------------

This requires MySQL server v4.1.1 or later, or a MariaDB server. Older
versions of MySQL server are obsolete, use known-insecure authentication,
and are not supported by this package.

Normally, MySQL clients connect to a server on the same machine via a Unix
socket on *nix systems, and through a named pipe on Windows. Neither of these
conventions is currently supported. TCP is used for all connections.

For historical reference, see the [old homepage](http://britseyeview.com/software/mysqln/)
for the original release of this project. Note, however, that version has
become out-of-date.

Developers - How to run the test suite
--------------------------------------

This package contains various unittests and integration tests. To run them,
run `run-tests`.

The first time you run `run-tests`, it will automatically create a
file `testConnectionStr.txt` in project's base diretory and then exit.
This file is deliberately not contained in the source repository
because it's specific to your system.

Open the `testConnectionStr.txt` file and verify the connection settings
inside, modifying them as needed, and if necessary, creating a test user and
blank test schema in your MySQL database.

The tests will completely clobber anything inside the db schema provided,
but they will ONLY modify that one db schema. No other schema will be
modified in any way.

After you've configured the connection string, run `run-tests` again
and their tests will be compiled and run, first using Phobos sockets,
then using Vibe sockets.
