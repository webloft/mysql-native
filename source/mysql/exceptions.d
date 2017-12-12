/// Exceptions defined by mysql-native.
module mysql.exceptions;

import std.algorithm;
import mysql.protocol.packets;

/++
An exception type to distinguish exceptions thrown by this package.
+/
class MYX: Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) pure
	{
		super(msg, file, line);
	}
}
deprecated("This has been renamed MYX")
alias MySQLException = MYX;

/++
The server sent back a MySQL error code and message. If the server is 4.1+,
there should also be an ANSI/ODBC-standard SQLSTATE error code.

See_Also: https://dev.mysql.com/doc/refman/5.5/en/error-messages-server.html
+/
class MYXReceived: MYX
{
	ushort errorCode;
	char[5] sqlState;

	this(OKErrorPacket okp, string file, size_t line) pure
	{
		this(okp.message, okp.serverStatus, okp.sqlState, file, line);
	}

	this(string msg, ushort errorCode, char[5] sqlState, string file, size_t line) pure
	{
		this.errorCode = errorCode;
		this.sqlState = sqlState;
		super("MySQL error: " ~ msg, file, line);
	}
}
deprecated("This has been renamed MYXReceived")
alias MySQLReceivedException = MYXReceived;

/++
This exception is no longer used by mysql-native and will be removed
in an upcoming release.

Previously, this was thrown when attempting to communicate with the server
(ex: executing SQL or creating a new prepared statement) while the server
was still sending results data. Any `mysql.result.ResultRange` was required to
be consumed or purged before anything else was allowed to be done on the
connection (as per inherent limitations of the MySQL client-server protocol).

But as of mysql-native v1.1.4 (as discussed in
$(LINK2 https://github.com/mysql-d/mysql-native/issues/117, issue #117)),
this behavior was changed. Any communication with the server now purges any
active `mysql.result.ResultRange` automatically (See also,
`mysql.result.ResultRange.isValid`). As a result, this exception is never
thrown anymore.
+/
deprecated("No longer thrown by mysql-native, as of v1.1.4. You can safely remove all MYXDataPending handling from your code.")
class MYXDataPending: MYX
{
	this(string file = __FILE__, size_t line = __LINE__) pure
	{
		super("Data is pending on the connection. Any existing ResultRange "~
			"must be consumed or purged before performing any other communication "~
			"with the server.", file, line);
	}
}
deprecated("This has been renamed MYXDataPending")
alias MySQLDataPendingException = MYXDataPending;

/++
Received invalid data from the server which violates the MySQL network protocol.
(Quite possibly mysql-native's fault. Please
$(LINK2 https://github.com/mysql-d/mysql-native/issues, file an issue)
if you receive this.)
+/
class MYXProtocol: MYX
{
	this(string msg, string file, size_t line) pure
	{
		super(msg, file, line);
	}
}
deprecated("This has been renamed MYXProtocol")
alias MySQLProtocolException = MYXProtocol;

/++
Thrown when attempting to use a prepared statement which had already been released.
+/
class MYXNotPrepared: MYX
{
	this(string file = __FILE__, size_t line = __LINE__) pure
	{
		super("The prepared statement has already been released.", file, line);
	}
}
deprecated("This has been renamed MYXNotPrepared")
alias MySQLNotPreparedException = MYXNotPrepared;

/++
Common base class of MySQLResultRecievedException and MySQLNoResultRecievedException.

Thrown when making the wrong choice between exec or query.

The query functions (query, querySet, queryRow, etc.) are for SQL statements
such as SELECT that return results (even if the result set has zero elements.)

The exec functions are for SQL statements, such as INSERT, that never return
result sets, but may return rowsAffected.

Using one of those functions, when the other should have been used instead,
results in an exception derived from this.
+/
class MYXWrongFunction: MYX
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) pure
	{
		super(msg, file, line);
	}
}
deprecated("This has been renamed MYXWrongFunction")
alias MySQLWrongFunctionException = MYXWrongFunction;

/++
Thrown when a result set was returned unexpectedly. Use the query functions
(query, querySet, queryRow, etc.), not exec for commands that return
result sets (such as SELECT), even if the result set has zero elements.
+/
class MYXResultRecieved: MYXWrongFunction
{
	this(string file = __FILE__, size_t line = __LINE__) pure
	{
		super(
			"A result set was returned. Use the query functions, not exec, "~
			"for commands that return result sets.",
			file, line
		);
	}
}
deprecated("This has been renamed MYXResultRecieved")
alias MySQLResultRecievedException = MYXResultRecieved;

/++
Thrown when the executed query, unexpectedly, did not produce a result set.
Use the exec functions, not query (query, querySet, queryRow, etc.),
for commands that don't produce result sets (such as INSERT).
+/
class MYXNoResultRecieved: MYXWrongFunction
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) pure
	{
		super(
			"The executed query did not produce a result set. Use the exec "~
			"functions, not query, for commands that don't produce result sets.",
			file, line
		);
	}
}
deprecated("This has been renamed MYXNoResultRecieved")
alias MySQLNoResultRecievedException = MYXNoResultRecieved;

/++
Thrown when attempting to use a range that's been invalidated.
In particular, when using a ResultRange after a new command
has been issued on the same connection.
+/
class MYXInvalidatedRange: MYX
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) pure
	{
		super(msg, file, line);
	}
}
deprecated("This has been renamed MYXInvalidatedRange")
alias MySQLInvalidatedRangeException = MYXInvalidatedRange;

debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	import std.exception;
	import mysql.commands;
	import mysql.prepared;
	import mysql.test.common : scopedCn, createCn;
	mixin(scopedCn);

	cn.exec("DROP TABLE IF EXISTS `wrongFunctionException`");
	cn.exec("CREATE TABLE `wrongFunctionException` (
		`val` INTEGER
	) ENGINE=InnoDB DEFAULT CHARSET=utf8");

	immutable insertSQL = "INSERT INTO `wrongFunctionException` VALUES (1), (2)";
	immutable selectSQL = "SELECT * FROM `wrongFunctionException`";
	Prepared preparedInsert;
	Prepared preparedSelect;
	int queryTupleResult;
	assertNotThrown!MYXWrongFunction(cn.exec(insertSQL));
	assertNotThrown!MYXWrongFunction(cn.querySet(selectSQL));
	assertNotThrown!MYXWrongFunction(cn.query(selectSQL).each());
	assertNotThrown!MYXWrongFunction(cn.queryRowTuple(selectSQL, queryTupleResult));
	assertNotThrown!MYXWrongFunction(preparedInsert = cn.prepare(insertSQL));
	assertNotThrown!MYXWrongFunction(preparedSelect = cn.prepare(selectSQL));
	assertNotThrown!MYXWrongFunction(preparedInsert.exec());
	assertNotThrown!MYXWrongFunction(preparedSelect.querySet());
	assertNotThrown!MYXWrongFunction(preparedSelect.query().each());
	assertNotThrown!MYXWrongFunction(preparedSelect.queryRowTuple(queryTupleResult));

	assertThrown!MYXResultRecieved(cn.exec(selectSQL));
	assertThrown!MYXNoResultRecieved(cn.querySet(insertSQL));
	assertThrown!MYXNoResultRecieved(cn.query(insertSQL).each());
	assertThrown!MYXNoResultRecieved(cn.queryRowTuple(insertSQL, queryTupleResult));
	assertThrown!MYXResultRecieved(preparedSelect.exec());
	assertThrown!MYXNoResultRecieved(preparedInsert.querySet());
	assertThrown!MYXNoResultRecieved(preparedInsert.query().each());
	assertThrown!MYXNoResultRecieved(preparedInsert.queryRowTuple(queryTupleResult));
}
