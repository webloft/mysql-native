/++
Internal - Low-level communications.

Consider this module the main entry point for the low-level MySQL/MariaDB
protocol code. The other modules in `mysql.protocol` are supporting tools
for this module.

Previously, the code handling low-level protocol details was scattered all
across the library. Such functionality has been factored out into this module,
to be kept in one place for better encapsulation and to facilitate further
cleanup and refactoring.

EXPECT MAJOR CHANGES to this entire `mysql.protocol` package until it
eventually settles into what will eventually become a low-level library
containing the bulk of the MySQL/MariaDB-specific code. Hang on tight...
+/
module mysql.protocol.comms;

import std.exception;
import std.range;
import std.variant;

import mysql.connection;
import mysql.exceptions;
import mysql.prepared;

import mysql.protocol.constants;
import mysql.protocol.extra_types;
import mysql.protocol.packet_helpers;
import mysql.protocol.packets;
import mysql.protocol.sockets;

/// Low-level comms code relating to prepared statements.
package struct ProtocolPrepared
{
	import std.conv;
	import std.datetime;
	import std.variant;
	import mysql.types;
	
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
					chunk.length = chunk.length - (cs-sent);     // trim the chunk
					sent += 7;        // adjust for non-payload bytes
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
}

package(mysql) struct ExecQueryImplInfo
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

Any result set can be accessed via Connection.getNextRow(), but you should really be
using the query function for such queries.

Params: ra = An out parameter to receive the number of rows affected.
Returns: true if there was a (possibly empty) result set.
+/
package(mysql) bool execQueryImpl(Connection conn, ExecQueryImplInfo info, out ulong ra)
{
	scope(failure) conn.kill();

	// Send data
	if(info.isPrepared)
		ProtocolPrepared.sendCommand(conn, info.hStmt, info.psh, info.inParams, info.psa);
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

package(mysql) void immediateReleasePrepared(Connection conn, uint statementId)
{
	scope(failure) conn.kill();

	if(conn.closed())
		return;

	ubyte[9] packet_buf;
	ubyte[] packet = packet_buf;
	packet.setPacketHeader(0/*packet number*/);
	conn.bumpPacket();
	packet[4] = CommandType.STMT_CLOSE;
	statementId.packInto(packet[5..9]);
	conn.purgeResult();
	conn.send(packet);
	// It seems that the server does not find it necessary to send a response
	// for this command.
}

// Moved here from `struct Row`
package(mysql) bool[] consumeNullBitmap(ref ubyte[] packet, uint fieldCount) pure
{
	uint bitmapLength = calcBitmapLength(fieldCount);
	enforceEx!MYXProtocol(packet.length >= bitmapLength, "Packet too small to hold null bitmap for all fields");
	auto bitmap = packet.consume(bitmapLength);
	return decodeNullBitmap(bitmap, fieldCount);
}

// Moved here from `struct Row`
private static uint calcBitmapLength(uint fieldCount) pure nothrow
{
	return (fieldCount+7+2)/8;
}

// Moved here from `struct Row`
// This is to decode the bitmap in a binary result row. First two bits are skipped
private bool[] decodeNullBitmap(ubyte[] bitmap, uint numFields) pure nothrow
in
{
	assert(bitmap.length >= calcBitmapLength(numFields),
		"bitmap not large enough to store all null fields");
}
out(result)
{
	assert(result.length == numFields);
}
body
{
	bool[] nulls;
	nulls.length = numFields;

	// the current byte we are processing for nulls
	ubyte bits = bitmap.front();
	// strip away the first two bits as they are reserved
	bits >>= 2;
	// .. and then we only have 6 bits left to process for this byte
	ubyte bitsLeftInByte = 6;
	foreach(ref isNull; nulls)
	{
		assert(bitsLeftInByte <= 8);
		// processed all bits? fetch new byte
		if (bitsLeftInByte == 0)
		{
			assert(bits == 0, "not all bits are processed!");
			assert(!bitmap.empty, "bits array too short for number of columns");
			bitmap.popFront();
			bits = bitmap.front;
			bitsLeftInByte = 8;
		}
		assert(bitsLeftInByte > 0);
		isNull = (bits & 0b0000_0001) != 0;

		// get ready to process next bit
		bits >>= 1;
		--bitsLeftInByte;
	}
	return nulls;
}

// Moved here from `struct Row.this`
package(mysql) void ctorRow(Connection con, ref ubyte[] packet, ResultSetHeaders rh, bool binary,
	out Variant[] _values, out bool[] _nulls)
in
{
	assert(rh.fieldCount <= uint.max);
}
body
{
	scope(failure) con.kill();

	uint fieldCount = cast(uint)rh.fieldCount;
	_values.length = _nulls.length = fieldCount;

	if(binary)
	{
		// There's a null byte header on a binary result sequence, followed by some bytes of bitmap
		// indicating which columns are null
		enforceEx!MYXProtocol(packet.front == 0, "Expected null header byte for binary result row");
		packet.popFront();
		_nulls = consumeNullBitmap(packet, fieldCount);
	}

	foreach(size_t i; 0..fieldCount)
	{
		if(binary && _nulls[i])
		{
			_values[i] = null;
			continue;
		}

		SQLValue sqlValue;
		do
		{
			FieldDescription fd = rh[i];
			sqlValue = packet.consumeIfComplete(fd.type, binary, fd.unsigned, fd.charSet);
			// TODO: Support chunk delegate
			if(sqlValue.isIncomplete)
				packet ~= con.getPacket();
		} while(sqlValue.isIncomplete);
		assert(!sqlValue.isIncomplete);

		if(sqlValue.isNull)
		{
			assert(!binary);
			assert(!_nulls[i]);
			_nulls[i] = true;
			_values[i] = null;
		}
		else
		{
			_values[i] = sqlValue.value;
		}
	}
}
