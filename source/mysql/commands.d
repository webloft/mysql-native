/++
Use a DB via plain SQL statements.

Commands that are expected to return a result set - queries - have distinctive
methods that are enforced. That is it will be an error to call such a method
with an SQL command that does not produce a result set. So for commands like
SELECT, use the `query` functions. For other commands, like
INSERT/UPDATE/CREATE/etc, use `exec`.
+/

module mysql.commands;

import std.conv;
import std.exception;
import std.range;
import std.typecons;
import std.variant;

import mysql.connection;
import mysql.exceptions;
import mysql.prepared;
import mysql.protocol.constants;
import mysql.protocol.extra_types;
import mysql.protocol.packets;
import mysql.protocol.packet_helpers;
import mysql.protocol.sockets;
import mysql.result;

/++
A struct to represent specializations of prepared statement parameters.

If you are executing a query that will include result columns that are large objects
it may be expedient to deal with the data as it is received rather than first buffering
it to some sort of byte array. These two variables allow for this. If both are provided
then the corresponding column will be fed to the stipulated delegate in chunks of
chunkSize, with the possible exception of the last chunk, which may be smaller.
The 'finished' argument will be set to true when the last chunk is set.

Be aware when specifying types for column specializations that for some reason the
field descriptions returned for a resultset have all of the types TINYTEXT, MEDIUMTEXT,
TEXT, LONGTEXT, TINYBLOB, MEDIUMBLOB, BLOB, and LONGBLOB lumped as type 0xfc
contrary to what it says in the protocol documentation.
+/
struct ColumnSpecialization
{
	size_t  cIndex;    // parameter number 0 - number of params-1
	ushort  type;
	uint    chunkSize;
	void delegate(const(ubyte)[] chunk, bool finished) chunkDelegate;
}
///ditto
alias CSN = ColumnSpecialization;

package struct ExecQueryImplInfo
{
	bool isPrepared;

	// For non-prepared statements:
	string sql;

	// For prepared statements:
	uint hStmt;
	PreparedStmtHeaders psh;
	Variant[] inParams;
	ParameterSpecialization[] psa;
}

/++
Internal implementation for the exec and query functions.

Execute a one-off SQL command.

Use this method when you are not going to be using the same command repeatedly.
It can be used with commands that don't produce a result set, or those that
do. If there is a result set its existence will be indicated by the return value.

Any result set can be accessed via Connection.getNextRow(), but you should really be
using the query function for such queries.

Params: ra = An out parameter to receive the number of rows affected.
Returns: true if there was a (possibly empty) result set.
+/
//TODO: All low-level commms should be moved into the mysql.protocol package.
package bool execQueryImpl(Connection conn, ExecQueryImplInfo info, out ulong ra)
{
	scope(failure) conn.kill();

	// Send data
	if(info.isPrepared)
		Prepared.sendCommand(conn, info.hStmt, info.psh, info.inParams, info.psa);
	else
	{
		conn.sendCmd(CommandType.QUERY, info.sql);
		conn._fieldCount = 0;
	}

	// Handle response
	ubyte[] packet = conn.getPacket();
	bool rv;
	if (packet.front == ResultPacketMarker.ok || packet.front == ResultPacketMarker.error)
	{
		conn.resetPacket();
		auto okp = OKErrorPacket(packet);
		enforcePacketOK(okp);
		ra = okp.affected;
		conn._serverStatus = okp.serverStatus;
		conn._insertID = okp.insertID;
		rv = false;
	}
	else
	{
		// There was presumably a result set
		assert(packet.front >= 1 && packet.front <= 250); // Result set packet header should have this value
		conn._headersPending = conn._rowsPending = true;
		conn._binaryPending = info.isPrepared;
		auto lcb = packet.consumeIfComplete!LCB();
		assert(!lcb.isNull);
		assert(!lcb.isIncomplete);
		conn._fieldCount = cast(ushort)lcb.value;
		assert(conn._fieldCount == lcb.value);
		rv = true;
		ra = 0;
	}
	return rv;
}

///ditto
package bool execQueryImpl(Connection conn, ExecQueryImplInfo info)
{
	ulong rowsAffected;
	return execQueryImpl(conn, info, rowsAffected);
}

/++
Execute a one-off SQL command, such as INSERT/UPDATE/CREATE/etc.

This method is intended for commands such as which do not produce a result set
(otherwise, use one of the query functions instead.) If the SQL command does
produces a result set (such as SELECT), `mysql.exceptions.MYXResultRecieved`
will be thrown.

Use this method when you are not going to be using the same command
repeatedly and you are CERTAIN all the data you're sending is properly
escaped. Otherwise consider using `mysql.prepared.Prepared`.

Params:
conn = An open Connection to the database.
sql = The SQL command to be run.

Returns: The number of rows affected.
+/
ulong exec(Connection conn, string sql)
{
	return execImpl(conn, ExecQueryImplInfo(false, sql));
}

/// Common implementation for mysql.commands.exec and Prepared.exec
package ulong execImpl(Connection conn, ExecQueryImplInfo info)
{
	ulong rowsAffected;
	bool receivedResultSet = execQueryImpl(conn, info, rowsAffected);
	if(receivedResultSet)
	{
		conn.purgeResult();
		throw new MYXResultRecieved();
	}

	return rowsAffected;
}

/++
Execute a one-off SQL SELECT command where you expect the entire
result set all at once.

This is deprecated because the same thing can be achieved via `query`().
$(LINK2 https://dlang.org/phobos/std_array.html#array, `array()`).

If the SQL command does not produce a result set (such as INSERT/CREATE/etc),
then `mysql.exceptions.MYXNoResultRecieved` will be thrown. Use
`exec` instead for such commands.

Use this method when you are not going to be using the same command
repeatedly and you are CERTAIN all the data you're sending is properly
escaped. Otherwise consider using `mysql.prepared.Prepared`.

If there are long data items among the expected result columns you can use
the csa param to specify that they are to be subject to chunked transfer via a
delegate.

Params:
conn = An open Connection to the database.
sql = The SQL command to be run.
csa = An optional array of ColumnSpecialization structs.

Returns: A (possibly empty) ResultSet.

Example:
---
// Do this instead of using querySet:
Row[] allAtOnce = myConnection.query("SELECT * from myTable").array;
---
+/
deprecated("Import std.array and use 'query(...).array' to receive 'Row[]' instead of a ResultSet")
ResultSet querySet(Connection conn, string sql, ColumnSpecialization[] csa = null)
{
	return querySetImpl(csa, false, conn, ExecQueryImplInfo(false, sql));
}

/// Common implementation for mysql.commands.querySet and Prepared.querySet
//TODO: All low-level commms should be moved into the mysql.protocol package.
package ResultSet querySetImpl(ColumnSpecialization[] csa, bool binary,
	Connection conn, ExecQueryImplInfo info)
{
	ulong ra;
	enforceEx!MYXNoResultRecieved(execQueryImpl(conn, info, ra));

	conn._rsh = ResultSetHeaders(conn, conn._fieldCount);
	if (csa !is null)
		conn._rsh.addSpecializations(csa);
	conn._headersPending = false;

	Row[] rows;
	while(true)
	{
		scope(failure) conn.kill();

		auto packet = conn.getPacket();
		if(packet.isEOFPacket())
			break;
		rows ~= Row(conn, packet, conn._rsh, binary);
		// As the row fetches more data while incomplete, it might already have
		// fetched the EOF marker, so we have to check it again
		if(!packet.empty && packet.isEOFPacket())
			break;
	}
	conn._rowsPending = conn._binaryPending = false;

	return ResultSet(rows, conn._rsh.fieldNames);
}

/++
Execute a one-off SQL SELECT command where you want to deal with the
result set one row at a time.

If you need random access to the resulting Row elements,
simply call $(LINK2 https://dlang.org/phobos/std_array.html#array, `std.array.array()`)
on the result.

If the SQL command does not produce a result set (such as INSERT/CREATE/etc),
then `mysql.exceptions.MYXNoResultRecieved` will be thrown. Use
`exec` instead for such commands.

Use this method when you are not going to be using the same command
repeatedly and you are CERTAIN all the data you're sending is properly
escaped. Otherwise consider using `mysql.prepared.Prepared`.

If there are long data items among the expected result columns you can use
the csa param to specify that they are to be subject to chunked transfer via a
delegate.

Params:
conn = An open Connection to the database.
sql = The SQL command to be run.
csa = An optional array of ColumnSpecialization structs.

Returns: A (possibly empty) ResultRange.

Example:
---
ResultRange oneAtATime = myConnection.query("SELECT * from myTable");
Row[]       allAtOnce  = myConnection.query("SELECT * from myTable").array;
---
+/
ResultRange query(Connection conn, string sql, ColumnSpecialization[] csa = null)
{
	return queryImpl(csa, conn, ExecQueryImplInfo(false, sql));
}

/// Common implementation for mysql.commands.query and Prepared.query
package ResultRange queryImpl(ColumnSpecialization[] csa,
	Connection conn, ExecQueryImplInfo info)
{
	ulong ra;
	enforceEx!MYXNoResultRecieved(execQueryImpl(conn, info, ra));

	conn._rsh = ResultSetHeaders(conn, conn._fieldCount);
	if (csa !is null)
		conn._rsh.addSpecializations(csa);

	conn._headersPending = false;
	return ResultRange(conn, conn._rsh, conn._rsh.fieldNames);
}

/++
Execute a one-off SQL SELECT command where you only want the first Row (if any).

If the SQL command does not produce a result set (such as INSERT/CREATE/etc),
then `mysql.exceptions.MYXNoResultRecieved` will be thrown. Use
`exec` instead for such commands.

Use this method when you are not going to be using the same command
repeatedly and you are CERTAIN all the data you're sending is properly
escaped. Otherwise consider using `mysql.prepared.Prepared`.

If there are long data items among the expected result columns you can use
the csa param to specify that they are to be subject to chunked transfer via a
delegate.

Params:
conn = An open Connection to the database.
sql = The SQL command to be run.
csa = An optional array of ColumnSpecialization structs.

Returns: Nullable!Row: This will be null (check via Nullable.isNull) if the
query resulted in an empty result set.
+/
Nullable!Row queryRow(Connection conn, string sql, ColumnSpecialization[] csa = null)
{
	return queryRowImpl(csa, conn, ExecQueryImplInfo(false, sql));
}

/// Common implementation for mysql.commands.querySet and Prepared.querySet
package Nullable!Row queryRowImpl(ColumnSpecialization[] csa, Connection conn,
	ExecQueryImplInfo info)
{
	auto results = queryImpl(csa, conn, info);
	if(results.empty)
		return Nullable!Row();
	else
	{
		auto row = results.front;
		results.close();
		return Nullable!Row(row);
	}
}

/++
Execute a one-off SQL SELECT command where you only want the first Row, and
place result values into a set of D variables.

This method will throw if any column type is incompatible with the corresponding D variable.

Unlike the other query functions, queryRowTuple will throw
`mysql.exceptions.MYX` if the result set is empty
(and thus the reference variables passed in cannot be filled).

If the SQL command does not produce a result set (such as INSERT/CREATE/etc),
then `mysql.exceptions.MYXNoResultRecieved` will be thrown. Use
`exec` instead for such commands.

Use this method when you are not going to be using the same command
repeatedly and you are CERTAIN all the data you're sending is properly
escaped. Otherwise consider using `mysql.prepared.Prepared`.

Params:
conn = An open Connection to the database.
sql = The SQL command to be run.
args = The variables, taken by reference, to receive the values.

Params: args = A tuple of D variables to receive the results.
+/
void queryRowTuple(T...)(Connection conn, string sql, ref T args)
{
	return queryRowTupleImpl(conn, ExecQueryImplInfo(false, sql), args);
}

/// Common implementation for mysql.commands.queryRowTuple and Prepared.queryRowTuple
package void queryRowTupleImpl(T...)(Connection conn, ExecQueryImplInfo info, ref T args)
{
	ulong ra;
	enforceEx!MYXNoResultRecieved(execQueryImpl(conn, info, ra));

	Row rr = conn.getNextRow();
	/+if (!rr._valid)   // The result set was empty - not a crime.
		return;+/
	enforceEx!MYX(rr._values.length == args.length, "Result column count does not match the target tuple.");
	foreach (size_t i, dummy; args)
	{
		enforceEx!MYX(typeid(args[i]).toString() == rr._values[i].type.toString(),
			"Tuple "~to!string(i)~" type and column type are not compatible.");
		args[i] = rr._values[i].get!(typeof(args[i]));
	}
	// If there were more rows, flush them away
	// Question: Should I check in purgeResult and throw if there were - it's very inefficient to
	// allow sloppy SQL that does not ensure just one row!
	conn.purgeResult();
}

// Test what happends when queryRowTuple receives no rows
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	import mysql.prepared;
	import mysql.test.common : scopedCn, createCn;
	mixin(scopedCn);

	cn.exec("DROP TABLE IF EXISTS `queryRowTuple`");
	cn.exec("CREATE TABLE `queryRowTuple` (
		`val` INTEGER
	) ENGINE=InnoDB DEFAULT CHARSET=utf8");

	immutable selectSQL = "SELECT * FROM `queryRowTuple`";
	int queryTupleResult;
	assertThrown!MYX(cn.queryRowTuple(selectSQL, queryTupleResult));
}

/++
Execute a one-off SQL SELECT command and returns a single value,
the first column of the first row received.

If the query did not produce any rows, or the rows it produced have zero columns,
this will return `Nullable!Variant()`, ie, null. Test for this with `result.isNull`.

If the query DID produce a result, but the value actually received is NULL,
then `result.isNull` will be FALSE, and `result.get` will produce a Variant
which CONTAINS null. Check for this with `result.get.type == typeid(typeof(null))`.

If the SQL command does not produce a result set (such as INSERT/CREATE/etc),
then `mysql.exceptions.MYXNoResultRecieved` will be thrown. Use
`exec` instead for such commands.

Use this method when you are not going to be using the same command
repeatedly and you are CERTAIN all the data you're sending is properly
escaped. Otherwise consider using `mysql.prepared.Prepared`.

If there are long data items among the expected result columns you can use
the csa param to specify that they are to be subject to chunked transfer via a
delegate.

Params:
conn = An open Connection to the database.
sql = The SQL command to be run.
csa = An optional array of ColumnSpecialization structs.

Returns: Nullable!Variant: This will be null (check via Nullable.isNull) if the
query resulted in an empty result set.
+/
Nullable!Variant queryValue(Connection conn, string sql, ColumnSpecialization[] csa = null)
{
	return queryValueImpl(csa, conn, ExecQueryImplInfo(false, sql));
}

/// Common implementation for mysql.commands.querySet and Prepared.querySet
package Nullable!Variant queryValueImpl(ColumnSpecialization[] csa, Connection conn,
	ExecQueryImplInfo info)
{
	auto results = queryImpl(csa, conn, info);
	if(results.empty)
		return Nullable!Variant();
	else
	{
		auto row = results.front;
		results.close();
		
		if(row.length == 0)
			return Nullable!Variant();
		else
			return Nullable!Variant(row[0]);
	}
}
