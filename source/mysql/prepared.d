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
	string _sql;

package:
	ushort _numParams; /// Number of parameters this prepared statement takes
	PreparedStmtHeaders _headers;
	Variant[] _inParams;
	ParameterSpecialization[] _psa;
	ulong _lastInsertID;

	debug(MYSQLN_TESTS)
	unittest
	{
		import mysql.connection;
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
		assertNotThrown!MYXNotPrepared(cn.exec(preparedInsert));
		assertNotThrown!MYXNotPrepared(cn.query(preparedSelect).each());
		assertNotThrown!MYXNotPrepared(cn.queryRowTuple(preparedSelect, queryTupleResult));
		
		cn.release(preparedInsert);
		assertThrown!MYXNotPrepared(cn.exec(preparedInsert));
		assertNotThrown!MYXNotPrepared(cn.query(preparedSelect).each());
		assertNotThrown!MYXNotPrepared(cn.queryRowTuple(preparedSelect, queryTupleResult));

		cn.release(preparedSelect);
		assertThrown!MYXNotPrepared(cn.exec(preparedInsert));
		assertThrown!MYXNotPrepared(cn.query(preparedSelect).each());
		assertThrown!MYXNotPrepared(cn.queryRowTuple(preparedSelect, queryTupleResult));
	}

	ExecQueryImplInfo getExecQueryImplInfo(uint statementId)
	{
		return ExecQueryImplInfo(true, null, statementId, _headers, _inParams, _psa);
	}
	
public:
	/++
	Constructor. You probably want `mysqln.connection.prepare` instead of this.
 	
	Call `mysqln.connection.prepare` instead of this, unless you are creating
	your own transport bypassing `mysql.connection.Connection` entirely.
	The prepared statement must be registered on the server BEFORE this is
	called (which `mysqln.connection.prepare` does).

	Internally, the result of a successful outcome will be a statement handle - an ID -
	for the prepared statement, a count of the parameters required for
	excution of the statement, and a count of the columns that will be present
	in any result set that the command generates.

	The server will then proceed to send prepared statement headers,
	including parameter descriptions, and result set field descriptions,
	followed by an EOF packet.
	+/
	this(string sql, PreparedStmtHeaders headers, ushort numParams)
	{
		this._sql        = sql;
		this._headers    = headers;
		this._numParams  = numParams;
		_inParams.length = numParams;
		_psa.length      = numParams;
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
		import mysql.connection;
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
		cn.exec(preparedInsert);
		rs = cn.query(selectSQL).array;
		assert(rs.length == 1);
		assert(rs[0][0] == 5);

		preparedInsert.setArg(0, null);
		cn.exec(preparedInsert);
		rs = cn.query(selectSQL).array;
		assert(rs.length == 2);
		assert(rs[0][0] == 5);
		assert(rs[1].isNull(0));
		assert(rs[1][0].type == typeid(typeof(null)));

		preparedInsert.setArg(0, Variant(null));
		cn.exec(preparedInsert);
		rs = cn.query(selectSQL).array;
		assert(rs.length == 3);
		assert(rs[0][0] == 5);
		assert(rs[1].isNull(0));
		assert(rs[2].isNull(0));
		assert(rs[1][0].type == typeid(typeof(null)));
		assert(rs[2][0].type == typeid(typeof(null)));
	}

	/// Gets the number of arguments this prepared statement expects to be passed in.
	@property ushort numArgs() pure const nothrow
	{
		return _numParams;
	}

	/// After a command that inserted a row into a table with an auto-increment
	/// ID column, this method allows you to retrieve the last insert ID generated
	/// from this prepared statement.
	@property ulong lastInsertID() pure const nothrow { return _lastInsertID; }

	debug(MYSQLN_TESTS)
	unittest
	{
		import mysql.connection;
		mixin(scopedCn);
		cn.exec("DROP TABLE IF EXISTS `testPreparedLastInsertID`");
		cn.exec("CREATE TABLE `testPreparedLastInsertID` (
			`a` INTEGER NOT NULL AUTO_INCREMENT,
			PRIMARY KEY (a)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8");
		
		auto stmt = cn.prepare("INSERT INTO `testPreparedLastInsertID` VALUES()");
		cn.exec(stmt);
		assert(stmt.lastInsertID == 1);
		cn.exec(stmt);
		assert(stmt.lastInsertID == 2);
		cn.exec(stmt);
		assert(stmt.lastInsertID == 3);
	}

	/// Gets the prepared header's field descriptions.
	@property FieldDescription[] preparedFieldDescriptions() pure { return _headers.fieldDescriptions; }

	/// Gets the prepared header's param descriptions.
	@property ParamDescription[] preparedParamDescriptions() pure { return _headers.paramDescriptions; }
}
