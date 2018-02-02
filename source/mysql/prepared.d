/// Use a DB via SQL prepared statements.
module mysql.prepared;

import std.algorithm;
import std.conv;
import std.datetime;
import std.exception;
import std.range;
import std.traits;
import std.typecons;
import std.variant;

import mysql.commands;
import mysql.connection;
import mysql.exceptions;
import mysql.protocol.constants;
import mysql.protocol.extra_types;
import mysql.protocol.packets;
import mysql.protocol.packet_helpers;
import mysql.protocol.sockets;
import mysql.result;
import mysql.types;
debug(MYSQLN_TESTS)
	import mysql.test.common;

/++
A struct to represent specializations of prepared statement parameters.

If you need to send large objects to the database it might be convenient to
send them in pieces. The `chunkSize` and `chunkDelegate` variables allow for this.
If both are provided then the corresponding column will be populated by calling the delegate repeatedly.
The source should fill the indicated slice with data and arrange for the delegate to
return the length of the data supplied. If that is less than the `chunkSize`
then the chunk will be assumed to be the last one.
+/
struct ParameterSpecialization
{
	import mysql.protocol.constants;
	
	size_t pIndex;    //parameter number 0 - number of params-1
	SQLType type = SQLType.INFER_FROM_D_TYPE;
	uint chunkSize;
	uint delegate(ubyte[]) chunkDelegate;
}
///ditto
alias PSN = ParameterSpecialization;

/++
Submit an SQL command to the server to be compiled into a prepared statement.

Internally, the result of a successful outcome will be a statement handle - an ID -
for the prepared statement, a count of the parameters required for
excution of the statement, and a count of the columns that will be present
in any result set that the command generates.

The server will then proceed to send prepared statement headers,
including parameter descriptions, and result set field descriptions,
followed by an EOF packet.

Throws: `mysql.exceptions.MYX` if the server has a problem.
+/
Prepared prepare(Connection conn, string sql)
{
	return Prepared(conn, sql);
}

/++
Convenience function to create a prepared statement which calls a stored function.

Be careful that your numArgs is correct. If it isn't, you may get a
`mysql.exceptions.MYX` with a very unclear error message.

Throws: `mysql.exceptions.MYX` if the server has a problem.

Params:
	name = The name of the stored function.
	numArgs = The number of arguments the stored procedure takes.
+/
Prepared prepareFunction(Connection conn, string name, int numArgs)
{
	auto sql = "select " ~ name ~ preparedPlaceholderArgs(numArgs);
	return prepare(conn, sql);
}

///
unittest
{
	debug(MYSQLN_TESTS)
	{
		import mysql.test.common;
		mixin(scopedCn);

		exec(cn, `DROP FUNCTION IF EXISTS hello`);
		exec(cn, `
			CREATE FUNCTION hello (s CHAR(20))
			RETURNS CHAR(50) DETERMINISTIC
			RETURN CONCAT('Hello ',s,'!')
		`);

		auto preparedHello = prepareFunction(cn, "hello", 1);
		preparedHello.setArgs("World");
		auto rs = preparedHello.query.array;
		assert(rs.length == 1);
		assert(rs[0][0] == "Hello World!");
	}
}

/++
Convenience function to create a prepared statement which calls a stored procedure.

OUT parameters are currently not supported. It should generally be
possible with MySQL to present them as a result set.

Be careful that your numArgs is correct. If it isn't, you may get a
`mysql.exceptions.MYX` with a very unclear error message.

Throws: `mysql.exceptions.MYX` if the server has a problem.

Params:
	name = The name of the stored procedure.
	numArgs = The number of arguments the stored procedure takes.

+/
Prepared prepareProcedure(Connection conn, string name, int numArgs)
{
	auto sql = "call " ~ name ~ preparedPlaceholderArgs(numArgs);
	return prepare(conn, sql);
}

///
unittest
{
	debug(MYSQLN_TESTS)
	{
		import mysql.test.common;
		import mysql.test.integration;
		mixin(scopedCn);
		initBaseTestTables(cn);

		exec(cn, `DROP PROCEDURE IF EXISTS insert2`);
		exec(cn, `
			CREATE PROCEDURE insert2 (IN p1 INT, IN p2 CHAR(50))
			BEGIN
				INSERT INTO basetest (intcol, stringcol) VALUES(p1, p2);
			END
		`);

		auto preparedInsert2 = prepareProcedure(cn, "insert2", 2);
		preparedInsert2.setArgs(2001, "inserted string 1");
		preparedInsert2.exec();

		auto rs = query(cn, "SELECT stringcol FROM basetest WHERE intcol=2001").array;
		assert(rs.length == 1);
		assert(rs[0][0] == "inserted string 1");
	}
}

private string preparedPlaceholderArgs(int numArgs)
{
	auto sql = "(";
	bool comma = false;
	foreach(i; 0..numArgs)
	{
		if (comma)
			sql ~= ",?";
		else
		{
			sql ~= "?";
			comma = true;
		}
	}
	sql ~= ")";

	return sql;
}

debug(MYSQLN_TESTS)
unittest
{
	assert(preparedPlaceholderArgs(3) == "(?,?,?)");
	assert(preparedPlaceholderArgs(2) == "(?,?)");
	assert(preparedPlaceholderArgs(1) == "(?)");
	assert(preparedPlaceholderArgs(0) == "()");
}

/++
Encapsulation of a prepared statement.

Create this via the function `prepare`. Set your arguments (if any) via
the functions provided, and then run the statement by passing it to
`exec`/`query`/etc in place of the sql string parameter.

Commands that are expected to return a result set - queries - have distinctive
methods that are enforced. That is it will be an error to call such a method
with an SQL command that does not produce a result set. So for commands like
SELECT, use the `PreparedImpl.query` functions. For other commands, like
INSERT/UPDATE/CREATE/etc, use `PreparedImpl.exec`.

Internally, `Prepared` simply wraps a `PreparedImpl` with
$(LINK2 https://dlang.org/phobos/std_typecons.html#.RefCounted, `RefCounted`),
and offers access to the `PreparedImpl` members via "alias this".

See the `PreparedImpl` documentation for the bulk of the `Prepared` interface.
+/
struct Prepared
{
private:
	Connection _conn;
	string _sql;

	/++
	Submit an SQL command to the server to be compiled into a prepared statement.

	Internally, the result of a successful outcome will be a statement handle - an ID -
	for the prepared statement, a count of the parameters required for
	excution of the statement, and a count of the columns that will be present
	in any result set that the command generates.

	The server will then proceed to send prepared statement headers,
	including parameter descriptions, and result set field descriptions,
	followed by an EOF packet.
	+/
	public this(Connection conn, string sql)
	{
		this._conn = conn;
		this._sql = sql;

		register();
	}

package:
	ushort _numParams; /// Number of parameters this prepared statement takes
	PreparedStmtHeaders _headers;
	Variant[] _inParams;
	ParameterSpecialization[] _psa;
	ulong _lastInsertID;

	debug(MYSQLN_TESTS)
	unittest
	{
		import mysql.prepared;
		import mysql.test.common;
		mixin(scopedCn);

		cn.exec("DROP TABLE IF EXISTS `enforceNotReleased`");
		cn.exec("CREATE TABLE `enforceNotReleased` (
			`val` INTEGER
		) ENGINE=InnoDB DEFAULT CHARSET=utf8");

		immutable insertSQL = "INSERT INTO `enforceNotReleased` VALUES (1), (2)";
		immutable selectSQL = "SELECT * FROM `enforceNotReleased`";
		Prepared preparedInsert;
		Prepared preparedSelect;
		int queryTupleResult;
		assertNotThrown!MYXNotPrepared(preparedInsert = cn.prepare(insertSQL));
		assertNotThrown!MYXNotPrepared(preparedSelect = cn.prepare(selectSQL));
		assertNotThrown!MYXNotPrepared(preparedInsert.exec());
		assertNotThrown!MYXNotPrepared(preparedSelect.query().each());
		assertNotThrown!MYXNotPrepared(preparedSelect.queryRowTuple(queryTupleResult));
		
		preparedInsert.release();
		assertThrown!MYXNotPrepared(preparedInsert.exec());
		assertNotThrown!MYXNotPrepared(preparedSelect.query().each());
		assertNotThrown!MYXNotPrepared(preparedSelect.queryRowTuple(queryTupleResult));

		preparedSelect.release();
		assertThrown!MYXNotPrepared(preparedInsert.exec());
		assertThrown!MYXNotPrepared(preparedSelect.query().each());
		assertThrown!MYXNotPrepared(preparedSelect.queryRowTuple(queryTupleResult));
	}

	static ubyte[] makeBitmap(in Variant[] inParams)
	{
		size_t bml = (inParams.length+7)/8;
		ubyte[] bma;
		bma.length = bml;
		foreach (i; 0..inParams.length)
		{
			if(inParams[i].type != typeid(typeof(null)))
				continue;
			size_t bn = i/8;
			size_t bb = i%8;
			ubyte sr = 1;
			sr <<= bb;
			bma[bn] |= sr;
		}
		return bma;
	}

	static ubyte[] makePSPrefix(uint hStmt, ubyte flags = 0) pure nothrow
	{
		ubyte[] prefix;
		prefix.length = 14;

		prefix[4] = CommandType.STMT_EXECUTE;
		hStmt.packInto(prefix[5..9]);
		prefix[9] = flags;   // flags, no cursor
		prefix[10] = 1; // iteration count - currently always 1
		prefix[11] = 0;
		prefix[12] = 0;
		prefix[13] = 0;

		return prefix;
	}

	//TODO: All low-level commms should be moved into the mysql.protocol package.
	static ubyte[] analyseParams(Variant[] inParams, ParameterSpecialization[] psa,
		out ubyte[] vals, out bool longData)
	{
		size_t pc = inParams.length;
		ubyte[] types;
		types.length = pc*2;
		size_t alloc = pc*20;
		vals.length = alloc;
		uint vcl = 0, len;
		int ct = 0;

		void reAlloc(size_t n)
		{
			if (vcl+n < alloc)
				return;
			size_t inc = (alloc*3)/2;
			if (inc <  n)
				inc = n;
			alloc += inc;
			vals.length = alloc;
		}

		foreach (size_t i; 0..pc)
		{
			enum UNSIGNED  = 0x80;
			enum SIGNED    = 0;
			if (psa[i].chunkSize)
				longData= true;
			if (inParams[i].type == typeid(typeof(null)))
			{
				types[ct++] = SQLType.NULL;
				types[ct++] = SIGNED;
				continue;
			}
			Variant v = inParams[i];
			SQLType ext = psa[i].type;
			string ts = v.type.toString();
			bool isRef;
			if (ts[$-1] == '*')
			{
				ts.length = ts.length-1;
				isRef= true;
			}

			switch (ts)
			{
				case "bool":
					if (ext == SQLType.INFER_FROM_D_TYPE)
						types[ct++] = SQLType.BIT;
					else
						types[ct++] = cast(ubyte) ext;
					types[ct++] = SIGNED;
					reAlloc(2);
					bool bv = isRef? *(v.get!(bool*)): v.get!(bool);
					vals[vcl++] = 1;
					vals[vcl++] = bv? 0x31: 0x30;
					break;
				case "byte":
					types[ct++] = SQLType.TINY;
					types[ct++] = SIGNED;
					reAlloc(1);
					vals[vcl++] = isRef? *(v.get!(byte*)): v.get!(byte);
					break;
				case "ubyte":
					types[ct++] = SQLType.TINY;
					types[ct++] = UNSIGNED;
					reAlloc(1);
					vals[vcl++] = isRef? *(v.get!(ubyte*)): v.get!(ubyte);
					break;
				case "short":
					types[ct++] = SQLType.SHORT;
					types[ct++] = SIGNED;
					reAlloc(2);
					short si = isRef? *(v.get!(short*)): v.get!(short);
					vals[vcl++] = cast(ubyte) (si & 0xff);
					vals[vcl++] = cast(ubyte) ((si >> 8) & 0xff);
					break;
				case "ushort":
					types[ct++] = SQLType.SHORT;
					types[ct++] = UNSIGNED;
					reAlloc(2);
					ushort us = isRef? *(v.get!(ushort*)): v.get!(ushort);
					vals[vcl++] = cast(ubyte) (us & 0xff);
					vals[vcl++] = cast(ubyte) ((us >> 8) & 0xff);
					break;
				case "int":
					types[ct++] = SQLType.INT;
					types[ct++] = SIGNED;
					reAlloc(4);
					int ii = isRef? *(v.get!(int*)): v.get!(int);
					vals[vcl++] = cast(ubyte) (ii & 0xff);
					vals[vcl++] = cast(ubyte) ((ii >> 8) & 0xff);
					vals[vcl++] = cast(ubyte) ((ii >> 16) & 0xff);
					vals[vcl++] = cast(ubyte) ((ii >> 24) & 0xff);
					break;
				case "uint":
					types[ct++] = SQLType.INT;
					types[ct++] = UNSIGNED;
					reAlloc(4);
					uint ui = isRef? *(v.get!(uint*)): v.get!(uint);
					vals[vcl++] = cast(ubyte) (ui & 0xff);
					vals[vcl++] = cast(ubyte) ((ui >> 8) & 0xff);
					vals[vcl++] = cast(ubyte) ((ui >> 16) & 0xff);
					vals[vcl++] = cast(ubyte) ((ui >> 24) & 0xff);
					break;
				case "long":
					types[ct++] = SQLType.LONGLONG;
					types[ct++] = SIGNED;
					reAlloc(8);
					long li = isRef? *(v.get!(long*)): v.get!(long);
					vals[vcl++] = cast(ubyte) (li & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 8) & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 16) & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 24) & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 32) & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 40) & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 48) & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 56) & 0xff);
					break;
				case "ulong":
					types[ct++] = SQLType.LONGLONG;
					types[ct++] = UNSIGNED;
					reAlloc(8);
					ulong ul = isRef? *(v.get!(ulong*)): v.get!(ulong);
					vals[vcl++] = cast(ubyte) (ul & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 8) & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 16) & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 24) & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 32) & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 40) & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 48) & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 56) & 0xff);
					break;
				case "float":
					types[ct++] = SQLType.FLOAT;
					types[ct++] = SIGNED;
					reAlloc(4);
					float f = isRef? *(v.get!(float*)): v.get!(float);
					ubyte* ubp = cast(ubyte*) &f;
					vals[vcl++] = *ubp++;
					vals[vcl++] = *ubp++;
					vals[vcl++] = *ubp++;
					vals[vcl++] = *ubp;
					break;
				case "double":
					types[ct++] = SQLType.DOUBLE;
					types[ct++] = SIGNED;
					reAlloc(8);
					double d = isRef? *(v.get!(double*)): v.get!(double);
					ubyte* ubp = cast(ubyte*) &d;
					vals[vcl++] = *ubp++;
					vals[vcl++] = *ubp++;
					vals[vcl++] = *ubp++;
					vals[vcl++] = *ubp++;
					vals[vcl++] = *ubp++;
					vals[vcl++] = *ubp++;
					vals[vcl++] = *ubp++;
					vals[vcl++] = *ubp;
					break;
				case "std.datetime.date.Date":
				case "std.datetime.Date":
					types[ct++] = SQLType.DATE;
					types[ct++] = SIGNED;
					Date date = isRef? *(v.get!(Date*)): v.get!(Date);
					ubyte[] da = pack(date);
					size_t l = da.length;
					reAlloc(l);
					vals[vcl..vcl+l] = da[];
					vcl += l;
					break;
				case "std.datetime.TimeOfDay":
				case "std.datetime.Time":
					types[ct++] = SQLType.TIME;
					types[ct++] = SIGNED;
					TimeOfDay time = isRef? *(v.get!(TimeOfDay*)): v.get!(TimeOfDay);
					ubyte[] ta = pack(time);
					size_t l = ta.length;
					reAlloc(l);
					vals[vcl..vcl+l] = ta[];
					vcl += l;
					break;
				case "std.datetime.date.DateTime":
				case "std.datetime.DateTime":
					types[ct++] = SQLType.DATETIME;
					types[ct++] = SIGNED;
					DateTime dt = isRef? *(v.get!(DateTime*)): v.get!(DateTime);
					ubyte[] da = pack(dt);
					size_t l = da.length;
					reAlloc(l);
					vals[vcl..vcl+l] = da[];
					vcl += l;
					break;
				case "mysql.types.Timestamp":
					types[ct++] = SQLType.TIMESTAMP;
					types[ct++] = SIGNED;
					Timestamp tms = isRef? *(v.get!(Timestamp*)): v.get!(Timestamp);
					DateTime dt = mysql.protocol.packet_helpers.toDateTime(tms.rep);
					ubyte[] da = pack(dt);
					size_t l = da.length;
					reAlloc(l);
					vals[vcl..vcl+l] = da[];
					vcl += l;
					break;
				case "immutable(char)[]":
					if (ext == SQLType.INFER_FROM_D_TYPE)
						types[ct++] = SQLType.VARCHAR;
					else
						types[ct++] = cast(ubyte) ext;
					types[ct++] = SIGNED;
					string s = isRef? *(v.get!(string*)): v.get!(string);
					ubyte[] packed = packLCS(cast(void[]) s);
					reAlloc(packed.length);
					vals[vcl..vcl+packed.length] = packed[];
					vcl += packed.length;
					break;
				case "char[]":
					if (ext == SQLType.INFER_FROM_D_TYPE)
						types[ct++] = SQLType.VARCHAR;
					else
						types[ct++] = cast(ubyte) ext;
					types[ct++] = SIGNED;
					char[] ca = isRef? *(v.get!(char[]*)): v.get!(char[]);
					ubyte[] packed = packLCS(cast(void[]) ca);
					reAlloc(packed.length);
					vals[vcl..vcl+packed.length] = packed[];
					vcl += packed.length;
					break;
				case "byte[]":
					if (ext == SQLType.INFER_FROM_D_TYPE)
						types[ct++] = SQLType.TINYBLOB;
					else
						types[ct++] = cast(ubyte) ext;
					types[ct++] = SIGNED;
					byte[] ba = isRef? *(v.get!(byte[]*)): v.get!(byte[]);
					ubyte[] packed = packLCS(cast(void[]) ba);
					reAlloc(packed.length);
					vals[vcl..vcl+packed.length] = packed[];
					vcl += packed.length;
					break;
				case "ubyte[]":
					if (ext == SQLType.INFER_FROM_D_TYPE)
						types[ct++] = SQLType.TINYBLOB;
					else
						types[ct++] = cast(ubyte) ext;
					types[ct++] = SIGNED;
					ubyte[] uba = isRef? *(v.get!(ubyte[]*)): v.get!(ubyte[]);
					ubyte[] packed = packLCS(cast(void[]) uba);
					reAlloc(packed.length);
					vals[vcl..vcl+packed.length] = packed[];
					vcl += packed.length;
					break;
				case "void":
					throw new MYX("Unbound parameter " ~ to!string(i), __FILE__, __LINE__);
				default:
					throw new MYX("Unsupported parameter type " ~ ts, __FILE__, __LINE__);
			}
		}
		vals.length = vcl;
		return types;
	}

	static void sendLongData(Connection conn, uint hStmt, ParameterSpecialization[] psa)
	{
		assert(psa.length <= ushort.max); // parameter number is sent as short
		foreach (ushort i, PSN psn; psa)
		{
			if (!psn.chunkSize) continue;
			uint cs = psn.chunkSize;
			uint delegate(ubyte[]) dg = psn.chunkDelegate;

			//TODO: All low-level commms should be moved into the mysql.protocol package.
			ubyte[] chunk;
			chunk.length = cs+11;
			chunk.setPacketHeader(0 /*each chunk is separate cmd*/);
			chunk[4] = CommandType.STMT_SEND_LONG_DATA;
			hStmt.packInto(chunk[5..9]); // statement handle
			packInto(i, chunk[9..11]); // parameter number

			// byte 11 on is payload
			for (;;)
			{
				uint sent = dg(chunk[11..cs+11]);
				if (sent < cs)
				{
					if (sent == 0)    // data was exact multiple of chunk size - all sent
						break;
					sent += 7;        // adjust for non-payload bytes
					chunk.length = chunk.length - (cs-sent);     // trim the chunk
					packInto!(uint, true)(cast(uint)sent, chunk[0..3]);
					conn.send(chunk);
					break;
				}
				conn.send(chunk);
			}
		}
	}

	static void sendCommand(Connection conn, uint hStmt, PreparedStmtHeaders psh,
		Variant[] inParams, ParameterSpecialization[] psa)
	{
		conn.autoPurge();
		
		//TODO: All low-level commms should be moved into the mysql.protocol package.
		ubyte[] packet;
		conn.resetPacket();

		ubyte[] prefix = makePSPrefix(hStmt, 0);
		size_t len = prefix.length;
		bool longData;

		if (psh.paramCount)
		{
			ubyte[] one = [ 1 ];
			ubyte[] vals;
			ubyte[] types = analyseParams(inParams, psa, vals, longData);
			ubyte[] nbm = makeBitmap(inParams);
			packet = prefix ~ nbm ~ one ~ types ~ vals;
		}
		else
			packet = prefix;

		if (longData)
			sendLongData(conn, hStmt, psa);

		assert(packet.length <= uint.max);
		packet.setPacketHeader(conn.pktNumber);
		conn.bumpPacket();
		conn.send(packet);
	}

	ExecQueryImplInfo getExecQueryImplInfo(uint statementId)
	{
		return ExecQueryImplInfo(true, null, statementId, _headers, _inParams, _psa);
	}
	
public:
	/++
	Execute a prepared command, such as INSERT/UPDATE/CREATE/etc.
	
	This method is intended for commands which do not produce a result set
	(otherwise, use one of the query functions instead.) If the SQL command does
	produces a result set (such as SELECT), `mysql.exceptions.MYXResultRecieved`
	will be thrown.
	
	Type_Mappings: $(TYPE_MAPPINGS)

	Returns: The number of rows affected.
	+/
	ulong exec()
	{
		import mysql.commands;
		return .exec(_conn, this);
	}

	debug(MYSQLN_TESTS)
	unittest
	{
		mixin(scopedCn);
		cn.exec("DROP TABLE IF EXISTS `testPreparedLastInsertID`");
		cn.exec("CREATE TABLE `testPreparedLastInsertID` (
			`a` INTEGER NOT NULL AUTO_INCREMENT,
			PRIMARY KEY (a)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8");
		
		auto stmt = cn.prepare("INSERT INTO `testPreparedLastInsertID` VALUES()");
		stmt.exec();
		assert(stmt.lastInsertID == 1);
		stmt.exec();
		assert(stmt.lastInsertID == 2);
		stmt.exec();
		assert(stmt.lastInsertID == 3);
	}

	/++
	Execute a prepared SQL SELECT command where you want to deal with the
	result set one row at a time.

	If you need random access to the resulting `mysql.result.Row` elements,
	simply call $(LINK2 https://dlang.org/phobos/std_array.html#array, `std.array.array()`)
	on the result.

	If the SQL command does not produce a result set (such as INSERT/CREATE/etc),
	then `mysql.exceptions.MYXNoResultRecieved` will be thrown. Use
	`exec` instead for such commands.

	If there are long data items among the expected result columns you can use
	the `csa` param to specify that they are to be subject to chunked transfer via a
	delegate.

	Type_Mappings: $(TYPE_MAPPINGS)

	Params: csa = An optional array of `mysql.commands.ColumnSpecialization` structs.
	Returns: A (possibly empty) `mysql.result.ResultRange`.

	Example:
	---
	ResultRange oneAtATime = myPrepared.query("SELECT * from myTable");
	Row[]       allAtOnce  = myPrepared.query("SELECT * from myTable").array;
	---
	+/
	ResultRange query(ColumnSpecialization[] csa = null)
	{
		import mysql.commands;
		return .query(_conn, this, csa);
	}

	/++
	Execute a prepared SQL SELECT command where you only want the first `mysql.result.Row` (if any).

	If the SQL command does not produce a result set (such as INSERT/CREATE/etc),
	then `mysql.exceptions.MYXNoResultRecieved` will be thrown. Use
	`exec` instead for such commands.

	If there are long data items among the expected result columns you can use
	the `csa` param to specify that they are to be subject to chunked transfer via a
	delegate.

	Type_Mappings: $(TYPE_MAPPINGS)

	Params: csa = An optional array of `mysql.commands.ColumnSpecialization` structs.
	Returns: `Nullable!(mysql.result.Row)`: This will be null (check via `Nullable.isNull`) if the
	query resulted in an empty result set.
	+/
	Nullable!Row queryRow(ColumnSpecialization[] csa = null)
	{
		import mysql.commands;
		return .queryRow(_conn, this, csa);
	}

	/++
	Execute a prepared SQL SELECT command where you only want the first `mysql.result.Row`,
	and place result values into a set of D variables.
	
	This method will throw if any column type is incompatible with the corresponding D variable.

	Unlike the other query functions, queryRowTuple will throw
	`mysql.exceptions.MYX` if the result set is empty
	(and thus the reference variables passed in cannot be filled).

	If the SQL command does not produce a result set (such as INSERT/CREATE/etc),
	then `mysql.exceptions.MYXNoResultRecieved` will be thrown. Use
	`exec` instead for such commands.
	
	Type_Mappings: $(TYPE_MAPPINGS)

	Params: args = A tuple of D variables to receive the results.
	+/
	void queryRowTuple(T...)(ref T args) if(T.length == 0 || !is(T[0] : Connection))
	{
		import mysql.commands;
		return .queryRowTuple(_conn, this, args);
	}

	/++
	Execute a prepared SQL SELECT command and returns a single value,
	the first column of the first row received.

	If the query did not produce any rows, OR the rows it produced have zero columns,
	this will return `Nullable!Variant()`, ie, null. Test for this with `result.isNull`.

	If the query DID produce a result, but the value actually received is NULL,
	then `result.isNull` will be FALSE, and `result.get` will produce a Variant
	which CONTAINS null. Check for this with `result.get.type == typeid(typeof(null))`.

	If the SQL command does not produce a result set (such as INSERT/CREATE/etc),
	then `mysql.exceptions.MYXNoResultRecieved` will be thrown. Use
	`exec` instead for such commands.

	If there are long data items among the expected result columns you can use
	the `csa` param to specify that they are to be subject to chunked transfer via a
	delegate.

	Type_Mappings: $(TYPE_MAPPINGS)

	Params: csa = An optional array of `mysql.commands.ColumnSpecialization` structs.
	Returns: `Nullable!(mysql.result.Row)`: This will be null (check via `Nullable.isNull`) if the
	query resulted in an empty result set.
	+/
	Nullable!Variant queryValue(ColumnSpecialization[] csa = null)
	{
		import mysql.commands;
		return .queryValue(_conn, this, csa);
	}

	/++
	Prepared statement parameter setter.

	The value may, but doesn't have to be, wrapped in a Variant. If so,
	null is handled correctly.
	
	The value may, but doesn't have to be, a pointer to the desired value.

	The value may, but doesn't have to be, wrapped in a Nullable!T. If so,
	null is handled correctly.

	The value can be null.

	Type_Mappings: $(TYPE_MAPPINGS)

	Params: index = The zero based index
	+/
	void setArg(T)(size_t index, T val, ParameterSpecialization psn = PSN(0, SQLType.INFER_FROM_D_TYPE, 0, null))
		if(!isInstanceOf!(Nullable, T))
	{
		// Now in theory we should be able to check the parameter type here, since the
		// protocol is supposed to send us type information for the parameters, but this
		// capability seems to be broken. This assertion is supported by the fact that
		// the same information is not available via the MySQL C API either. It is up
		// to the programmer to ensure that appropriate type information is embodied
		// in the variant array, or provided explicitly. This sucks, but short of
		// having a client side SQL parser I don't see what can be done.

		enforceEx!MYX(index < _numParams, "Parameter index out of range.");

		_inParams[index] = val;
		psn.pIndex = index;
		_psa[index] = psn;
	}

	///ditto
	void setArg(T)(size_t index, Nullable!T val, ParameterSpecialization psn = PSN(0, SQLType.INFER_FROM_D_TYPE, 0, null))
	{
		if(val.isNull)
			setArg(index, null, psn);
		else
			setArg(index, val.get(), psn);
	}

	/++
	Bind a tuple of D variables to the parameters of a prepared statement.
	
	You can use this method to bind a set of variables if you don't need any specialization,
	that is chunked transfer is not neccessary.
	
	The tuple must match the required number of parameters, and it is the programmer's
	responsibility to ensure that they are of appropriate types.

	Type_Mappings: $(TYPE_MAPPINGS)
	+/
	void setArgs(T...)(T args)
		if(T.length == 0 || !is(T[0] == Variant[]))
	{
		enforceEx!MYX(args.length == _numParams, "Argument list supplied does not match the number of parameters.");

		foreach (size_t i, arg; args)
			setArg(i, arg);
	}

	/++
	Bind a Variant[] as the parameters of a prepared statement.
	
	You can use this method to bind a set of variables in Variant form to
	the parameters of a prepared statement.
	
	Parameter specializations can be added if required. This method could be
	used to add records from a data entry form along the lines of
	------------
	auto stmt = conn.prepare("INSERT INTO `table42` VALUES(?, ?, ?)");
	DataRecord dr;    // Some data input facility
	ulong ra;
	do
	{
	    dr.get();
	    stmt.setArgs(dr("Name"), dr("City"), dr("Whatever"));
	    ulong rowsAffected = stmt.exec();
	} while(!dr.done);
	------------

	Type_Mappings: $(TYPE_MAPPINGS)

	Params:
	va = External list of Variants to be used as parameters
	psnList = Any required specializations
	+/
	void setArgs(Variant[] va, ParameterSpecialization[] psnList= null)
	{
		enforceEx!MYX(va.length == _numParams, "Param count supplied does not match prepared statement");
		_inParams[] = va[];
		if (psnList !is null)
		{
			foreach (PSN psn; psnList)
				_psa[psn.pIndex] = psn;
		}
	}

	/++
	Prepared statement parameter getter.

	Type_Mappings: $(TYPE_MAPPINGS)

	Params: index = The zero based index
	+/
	Variant getArg(size_t index)
	{
		enforceEx!MYX(index < _numParams, "Parameter index out of range.");
		return _inParams[index];
	}

	/++
	Sets a prepared statement parameter to NULL.
	
	This is here mainly for legacy reasons. You can set a field to null
	simply by saying `prepared.setArg(index, null);`

	Type_Mappings: $(TYPE_MAPPINGS)

	Params: index = The zero based index
	+/
	void setNullArg(size_t index)
	{
		setArg(index, null);
	}

	/// Gets the SQL command for this prepared statement.
	string sql()
	{
		return _sql;
	}

	debug(MYSQLN_TESTS)
	unittest
	{
		import mysql.prepared;
		import mysql.test.common;
		mixin(scopedCn);

		cn.exec("DROP TABLE IF EXISTS `setNullArg`");
		cn.exec("CREATE TABLE `setNullArg` (
			`val` INTEGER
		) ENGINE=InnoDB DEFAULT CHARSET=utf8");

		immutable insertSQL = "INSERT INTO `setNullArg` VALUES (?)";
		immutable selectSQL = "SELECT * FROM `setNullArg`";
		auto preparedInsert = cn.prepare(insertSQL);
		assert(preparedInsert.sql == insertSQL);
		Row[] rs;

		{
			Nullable!int nullableInt;
			nullableInt.nullify();
			preparedInsert.setArg(0, nullableInt);
			assert(preparedInsert.getArg(0).type == typeid(typeof(null)));
			nullableInt = 7;
			preparedInsert.setArg(0, nullableInt);
			assert(preparedInsert.getArg(0) == 7);

			nullableInt.nullify();
			preparedInsert.setArgs(nullableInt);
			assert(preparedInsert.getArg(0).type == typeid(typeof(null)));
			nullableInt = 7;
			preparedInsert.setArgs(nullableInt);
			assert(preparedInsert.getArg(0) == 7);
		}

		preparedInsert.setArg(0, 5);
		preparedInsert.exec();
		rs = cn.query(selectSQL).array;
		assert(rs.length == 1);
		assert(rs[0][0] == 5);

		preparedInsert.setArg(0, null);
		preparedInsert.exec();
		rs = cn.query(selectSQL).array;
		assert(rs.length == 2);
		assert(rs[0][0] == 5);
		assert(rs[1].isNull(0));
		assert(rs[1][0].type == typeid(typeof(null)));

		preparedInsert.setArg(0, Variant(null));
		preparedInsert.exec();
		rs = cn.query(selectSQL).array;
		assert(rs.length == 3);
		assert(rs[0][0] == 5);
		assert(rs[1].isNull(0));
		assert(rs[2].isNull(0));
		assert(rs[1][0].type == typeid(typeof(null)));
		assert(rs[2][0].type == typeid(typeof(null)));
	}

	/++
	Register a prepared statement.
	
	Notes:
	
	In actuality, the server might not immediately be told to register the
	statement.
	
	This is because there could be a `mysql.result.ResultRange` with results still pending
	for retreival, and the protocol doesn't allow sending commands (such as
	"register a prepared statement") to the server while data is pending.
	Therefore, this function may instead queue the statement to be registered
	when it is safe to do so: Either the next time a result set is purged or
	the next time a command (such as `query` or `exec`) is performed (because
	such commands automatically purge any pending results).
	+/
	void register()
	{
		if(_conn is null)
			return;

		Connection.immediateRegisterPrepared(_conn, _sql);
		auto info = _conn.getPreparedServerInfo(_sql);
		
		_headers         = info._psh;
		_numParams       = info._psParams;
		_inParams.length = info._psParams;
		_psa.length      = info._psParams;
	}

	/++
	Release a prepared statement.
	
	This method tells the server that it can dispose of the information it
	holds about the current prepared statement.

	Notes:
	
	In actuality, the server might not immediately be told to release the
	statement (although this instance of `Prepared` will still behave as though
	it's been released, regardless).
	
	This is because there could be a `mysql.result.ResultRange` with results still pending
	for retreival, and the protocol doesn't allow sending commands (such as
	"release a prepared statement") to the server while data is pending.
	Therefore, this function may instead queue the statement to be released
	when it is safe to do so: Either the next time a result set is purged or
	the next time a command (such as `query` or `exec`) is performed (because
	such commands automatically purge any pending results).
	+/
	void release()
	{
		if(_conn is null)
			return;

		auto info = _conn.getPreparedServerInfo(_sql);
		if(info.isNull || !info._hStmt || _conn.closed())
			return;

		_conn.statementQueue.add(_sql);
	}

	/// Gets the number of arguments this prepared statement expects to be passed in.
	@property ushort numArgs() pure nothrow
	{
		return _numParams;
	}

	/// After a command that inserted a row into a table with an auto-increment
	/// ID column, this method allows you to retrieve the last insert ID generated
	/// from this prepared statement.
	@property ulong lastInsertID() pure const nothrow { return _lastInsertID; }

	/// Gets the prepared header's field descriptions.
	@property FieldDescription[] preparedFieldDescriptions() pure { return _headers.fieldDescriptions; }

	/// Gets the prepared header's param descriptions.
	@property ParamDescription[] preparedParamDescriptions() pure { return _headers.paramDescriptions; }
}
