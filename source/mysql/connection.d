/// Connect to a MySQL/MariaDB server.
module mysql.connection;

import std.algorithm;
import std.conv;
import std.digest.sha;
import std.exception;
import std.range;
import std.socket;
import std.string;
import std.typecons;

import mysql.commands;
import mysql.exceptions;
import mysql.prepared;
import mysql.protocol.constants;
import mysql.protocol.packets;
import mysql.protocol.sockets;
import mysql.result;
debug(MYSQLN_TESTS)
{
	import mysql.test.common;
}

version(Have_vibe_d_core)
{
	static if(__traits(compiles, (){ import vibe.core.net; } ))
		import vibe.core.net;
	else
		static assert(false, "mysql-native can't find Vibe.d's 'vibe.core.net'.");
}

/// The default `mysql.protocol.constants.SvrCapFlags` used when creating a connection.
immutable SvrCapFlags defaultClientFlags =
		SvrCapFlags.OLD_LONG_PASSWORD | SvrCapFlags.ALL_COLUMN_FLAGS |
		SvrCapFlags.WITH_DB | SvrCapFlags.PROTOCOL41 |
		SvrCapFlags.SECURE_CONNECTION;// | SvrCapFlags.MULTI_STATEMENTS |
		//SvrCapFlags.MULTI_RESULTS;

/// Per-connection info from the server about a registered prepared statement.
package struct PreparedServerInfo
{
	/// Server's identifier for this prepared statement.
	/// This is never 0 if it's been registered.
	uint _hStmt;

	ushort _psWarnings;

	/// Number of parameters this statement takes.
	/// 
	/// This will be the same on all connections, but it's returned
	/// by the server upon registration, so it's stored here.
	ushort _psParams;

	/// Prepared statement headers
	///
	/// This will be the same on all connections, but it's returned
	/// by the server upon registration, so it's stored here.
	PreparedStmtHeaders _psh;
	
	/// Not actually from the server. Connection uses this to keep track
	/// of statements that should be treated as having been released.
	bool queuedForRelease = false;
}

/++
This is a wrapper over `Prepared` which is provided ONLY as a
temporary aid in upgrading to mysql-native v2.0.0 and its
new connection-independent model of prepared statements.

In most cases, this layer shouldn't even be needed. But if you have many
lines of code making calls to exec/query the same prepared statement,
then this may be helpful.

To use this temporary compatability layer, change instances of:

---
auto stmt = conn.prepare(...);
---

to:

---
auto stmt = conn.prepareBackwardCompat(...);
---

And then your prepared statement should work as before.

BUT DO NOT LEAVE IT LIKE THIS! Ultimately, you should update
your prepared statement code to the mysql-native v2.0.0 API, by changing
instances of:

---
stmt.exec()
stmt.query()
stmt.queryRow()
stmt.queryRowTuple(outputArgs...)
stmt.queryValue()
---

to:

---
conn.exec(stmt)
conn.query(stmt)
conn.queryRow(stmt)
conn.queryRowTuple(stmt, outputArgs...)
conn.queryValue(stmt)
---

Both of the above syntaxes can be used with a `BackwardCompatPrepared`
(the `Connection` passed directly to `exec`/`query` will override the
one embedded associated with your `BackwardCompatPrepared`).

Once all of your code is updated, you can change `prepareBackwardCompat`
back to `prepare` again, and your upgrade will be complete.
+/
struct BackwardCompatPrepared
{
	import std.variant;
	
	private Connection _conn;
	package Prepared _prepared;

	/// Access underlying `Prepared`
	@property Prepared prepared() { return _prepared; }

	alias _prepared this;

	/++
	This function is provided ONLY as a temporary aid in upgrading to mysql-native v2.0.0.
	
	See `BackwardCompatPrepared` for more info.
	+/
	deprecated("Change 'preparedStmt.exec()' to 'conn.exec(preparedStmt)'")
	ulong exec()
	{
		return .exec(_conn, _prepared);
	}

	///ditto
	deprecated("Change 'preparedStmt.query()' to 'conn.query(preparedStmt)'")
	ResultRange query(ColumnSpecialization[] csa = null)
	{
		return .query(_conn, _prepared, csa);
	}

	///ditto
	deprecated("Change 'preparedStmt.queryRow()' to 'conn.queryRow(preparedStmt)'")
	Nullable!Row queryRow(ColumnSpecialization[] csa = null)
	{
		return .queryRow(_conn, _prepared, csa);
	}

	///ditto
	deprecated("Change 'preparedStmt.queryRowTuple(outArgs...)' to 'conn.queryRowTuple(preparedStmt, outArgs...)'")
	void queryRowTuple(T...)(ref T args) if(T.length == 0 || !is(T[0] : Connection))
	{
		return .queryRowTuple(_conn, _prepared, args);
	}

	///ditto
	deprecated("Change 'preparedStmt.queryValue()' to 'conn.queryValue(preparedStmt)'")
	Nullable!Variant queryValue(ColumnSpecialization[] csa = null)
	{
		return .queryValue(_conn, _prepared, csa);
	}
}

/++
A class representing a database connection.

If you are using Vibe.d, consider using `mysql.pool.MySQLPool` instead of
creating a new Connection directly. That will provide certain benefits,
such as reusing old connections and automatic cleanup (no need to close
the connection when done).

------------------
// Suggested usage:

{
	auto con = new Connection("host=localhost;port=3306;user=joe;pwd=pass123;db=myappsdb");
	scope(exit) con.close();

	// Use the connection
	...
}
------------------
+/
//TODO: All low-level commms should be moved into the mysql.protocol package.
class Connection
{
/+
The Connection is responsible for handshaking with the server to establish
authentication. It then passes client preferences to the server, and
subsequently is the channel for all command packets that are sent, and all
response packets received.

Uncompressed packets consist of a 4 byte header - 3 bytes of length, and one
byte as a packet number. Connection deals with the headers and ensures that
packet numbers are sequential.

The initial packet is sent by the server - essentially a 'hello' packet
inviting login. That packet has a sequence number of zero. That sequence
number is the incremented by client and server packets through the handshake
sequence.

After login all further sequences are initialized by the client sending a
command packet with a zero sequence number, to which the server replies with
zero or more packets with sequential sequence numbers.
+/
package:
	enum OpenState
	{
		/// We have not yet connected to the server, or have sent QUIT to the
		/// server and closed the connection
		notConnected,
		/// We have connected to the server and parsed the greeting, but not
		/// yet authenticated
		connected,
		/// We have successfully authenticated against the server, and need to
		/// send QUIT to the server when closing the connection
		authenticated
	}
	OpenState   _open;
	MySQLSocket _socket;

	SvrCapFlags _sCaps, _cCaps;
	uint    _sThread;
	ushort  _serverStatus;
	ubyte   _sCharSet, _protocol;
	string  _serverVersion;

	string _host, _user, _pwd, _db;
	ushort _port;

	MySQLSocketType _socketType;

	OpenSocketCallbackPhobos _openSocketPhobos;
	OpenSocketCallbackVibeD  _openSocketVibeD;

	ulong _insertID;

	// This gets incremented every time a command is issued or results are purged,
	// so a ResultRange can tell whether it's been invalidated.
	ulong _lastCommandID;

	// Whether there are rows, headers or bimary data waiting to be retreived.
	// MySQL protocol doesn't permit performing any other action until all
	// such data is read.
	bool _rowsPending, _headersPending, _binaryPending;

	// Field count of last performed command.
	//TODO: Does Connection need to store this?
	ushort _fieldCount;

	// ResultSetHeaders of last performed command.
	//TODO: Does Connection need to store this? Is this even used?
	ResultSetHeaders _rsh;

	// This tiny thing here is pretty critical. Pay great attention to it's maintenance, otherwise
	// you'll get the dreaded "packet out of order" message. It, and the socket connection are
	// the reason why most other objects require a connection object for their construction.
	ubyte _cpn; /// Packet Number in packet header. Serial number to ensure correct
				/// ordering. First packet should have 0
	@property ubyte pktNumber()   { return _cpn; }
	void bumpPacket()       { _cpn++; }
	void resetPacket()      { _cpn = 0; }

	version(Have_vibe_d_core) {} else
	pure const nothrow invariant()
	{
		assert(_socketType != MySQLSocketType.vibed);
	}

	ubyte[] getPacket()
	{
		scope(failure) kill();

		ubyte[4] header;
		_socket.read(header);
		// number of bytes always set as 24-bit
		uint numDataBytes = (header[2] << 16) + (header[1] << 8) + header[0];
		enforceEx!MYXProtocol(header[3] == pktNumber, "Server packet out of order");
		bumpPacket();

		ubyte[] packet = new ubyte[numDataBytes];
		_socket.read(packet);
		assert(packet.length == numDataBytes, "Wrong number of bytes read");
		return packet;
	}

	void send(const(ubyte)[] packet)
	in
	{
		assert(packet.length > 4); // at least 1 byte more than header
	}
	body
	{
		_socket.write(packet);
	}

	void send(const(ubyte)[] header, const(ubyte)[] data)
	in
	{
		assert(header.length == 4 || header.length == 5/*command type included*/);
	}
	body
	{
		_socket.write(header);
		if(data.length)
			_socket.write(data);
	}

	void sendCmd(T)(CommandType cmd, const(T)[] data)
	in
	{
		// Internal thread states. Clients shouldn't use this
		assert(cmd != CommandType.SLEEP);
		assert(cmd != CommandType.CONNECT);
		assert(cmd != CommandType.TIME);
		assert(cmd != CommandType.DELAYED_INSERT);
		assert(cmd != CommandType.CONNECT_OUT);

		// Deprecated
		assert(cmd != CommandType.CREATE_DB);
		assert(cmd != CommandType.DROP_DB);
		assert(cmd != CommandType.TABLE_DUMP);

		// cannot send more than uint.max bytes. TODO: better error message if we try?
		assert(data.length <= uint.max);
	}
	out
	{
		// at this point we should have sent a command
		assert(pktNumber == 1);
	}
	body
	{
		autoPurge();

		scope(failure) kill();

		_lastCommandID++;

		if(!_socket.connected)
		{
			if(cmd == CommandType.QUIT)
				return; // Don't bother reopening connection just to quit

			_open = OpenState.notConnected;
			connect(_clientCapabilities);
		}

		resetPacket();

		ubyte[] header;
		header.length = 4 /*header*/ + 1 /*cmd*/;
		header.setPacketHeader(pktNumber, cast(uint)data.length +1/*cmd byte*/);
		header[4] = cmd;
		bumpPacket();

		send(header, cast(const(ubyte)[])data);
	}

	OKErrorPacket getCmdResponse(bool asString = false)
	{
		auto okp = OKErrorPacket(getPacket());
		enforcePacketOK(okp);
		_serverStatus = okp.serverStatus;
		return okp;
	}

	ubyte[] buildAuthPacket(ubyte[] token)
	in
	{
		assert(token.length == 20);
	}
	body
	{
		ubyte[] packet;
		packet.reserve(4/*header*/ + 4 + 4 + 1 + 23 + _user.length+1 + token.length+1 + _db.length+1);
		packet.length = 4 + 4 + 4; // create room for the beginning headers that we set rather than append

		// NOTE: we'll set the header last when we know the size

		// Set the default capabilities required by the client
		_cCaps.packInto(packet[4..8]);

		// Request a conventional maximum packet length.
		1.packInto(packet[8..12]);

		packet ~= 33; // Set UTF-8 as default charSet

		// There's a statutory block of zero bytes here - fill them in.
		foreach(i; 0 .. 23)
			packet ~= 0;

		// Add the user name as a null terminated string
		foreach(i; 0 .. _user.length)
			packet ~= _user[i];
		packet ~= 0; // \0

		// Add our calculated authentication token as a length prefixed string.
		assert(token.length <= ubyte.max);
		if(_pwd.length == 0)  // Omit the token if the account has no password
			packet ~= 0;
		else
		{
			packet ~= cast(ubyte)token.length;
			foreach(i; 0 .. token.length)
				packet ~= token[i];
		}

		// Add the default database as a null terminated string
		foreach(i; 0 .. _db.length)
			packet ~= _db[i];
		packet ~= 0; // \0

		// The server sent us a greeting with packet number 0, so we send the auth packet
		// back with the next number.
		packet.setPacketHeader(pktNumber);
		bumpPacket();
		return packet;
	}

	void consumeServerInfo(ref ubyte[] packet)
	{
		scope(failure) kill();

		_sCaps = cast(SvrCapFlags)packet.consume!ushort(); // server_capabilities (lower bytes)
		_sCharSet = packet.consume!ubyte(); // server_language
		_serverStatus = packet.consume!ushort(); //server_status
		_sCaps += cast(SvrCapFlags)(packet.consume!ushort() << 16); // server_capabilities (upper bytes)
		_sCaps |= SvrCapFlags.OLD_LONG_PASSWORD; // Assumed to be set since v4.1.1, according to spec

		enforceEx!MYX(_sCaps & SvrCapFlags.PROTOCOL41, "Server doesn't support protocol v4.1");
		enforceEx!MYX(_sCaps & SvrCapFlags.SECURE_CONNECTION, "Server doesn't support protocol v4.1 connection");
	}

	ubyte[] parseGreeting()
	{
		scope(failure) kill();

		ubyte[] packet = getPacket();

		if (packet.length > 0 && packet[0] == ResultPacketMarker.error)
		{
			auto okp = OKErrorPacket(packet);
			enforceEx!MYX(!okp.error, "Connection failure: " ~ cast(string) okp.message);
		}

		_protocol = packet.consume!ubyte();

		_serverVersion = packet.consume!string(packet.countUntil(0));
		packet.skip(1); // \0 terminated _serverVersion

		_sThread = packet.consume!uint();

		// read first part of scramble buf
		ubyte[] authBuf;
		authBuf.length = 255;
		authBuf[0..8] = packet.consume(8)[]; // scramble_buff

		enforceEx!MYXProtocol(packet.consume!ubyte() == 0, "filler should always be 0");

		consumeServerInfo(packet);

		packet.skip(1); // this byte supposed to be scramble length, but is actually zero
		packet.skip(10); // filler of \0

		// rest of the scramble
		auto len = packet.countUntil(0);
		enforceEx!MYXProtocol(len >= 12, "second part of scramble buffer should be at least 12 bytes");
		enforce(authBuf.length > 8+len);
		authBuf[8..8+len] = packet.consume(len)[];
		authBuf.length = 8+len; // cut to correct size
		enforceEx!MYXProtocol(packet.consume!ubyte() == 0, "Excepted \\0 terminating scramble buf");

		return authBuf;
	}

	static PlainPhobosSocket defaultOpenSocketPhobos(string host, ushort port)
	{
		auto s = new PlainPhobosSocket();
		s.connect(new InternetAddress(host, port));
		return s;
	}

	static PlainVibeDSocket defaultOpenSocketVibeD(string host, ushort port)
	{
		version(Have_vibe_d_core)
			return vibe.core.net.connectTCP(host, port);
		else
			assert(0);
	}

	void initConnection()
	{
		resetPacket();
		final switch(_socketType)
		{
			case MySQLSocketType.phobos:
				_socket = new MySQLSocketPhobos(_openSocketPhobos(_host, _port));
				break;

			case MySQLSocketType.vibed:
				version(Have_vibe_d_core) {
					_socket = new MySQLSocketVibeD(_openSocketVibeD(_host, _port));
					break;
				} else assert(0, "Unsupported socket type. Need version Have_vibe_d_core.");
		}
	}

	ubyte[] makeToken(ubyte[] authBuf)
	{
		auto pass1 = sha1Of(cast(const(ubyte)[])_pwd);
		auto pass2 = sha1Of(pass1);

		SHA1 sha1;
		sha1.start();
		sha1.put(authBuf);
		sha1.put(pass2);
		auto result = sha1.finish();
		foreach (size_t i; 0..20)
			result[i] = result[i] ^ pass1[i];
		return result.dup;
	}

	SvrCapFlags getCommonCapabilities(SvrCapFlags server, SvrCapFlags client) pure
	{
		SvrCapFlags common;
		uint filter = 1;
		foreach (size_t i; 0..uint.sizeof)
		{
			bool serverSupport = (server & filter) != 0; // can the server do this capability?
			bool clientSupport = (client & filter) != 0; // can we support it?
			if(serverSupport && clientSupport)
				common |= filter;
			filter <<= 1; // check next flag
		}
		return common;
	}

	void setClientFlags(SvrCapFlags capFlags)
	{
		_cCaps = getCommonCapabilities(_sCaps, capFlags);

		// We cannot operate in <4.1 protocol, so we'll force it even if the user
		// didn't supply it
		_cCaps |= SvrCapFlags.PROTOCOL41;
		_cCaps |= SvrCapFlags.SECURE_CONNECTION;
	}

	void authenticate(ubyte[] greeting)
	in
	{
		assert(_open == OpenState.connected);
	}
	out
	{
		assert(_open == OpenState.authenticated);
	}
	body
	{
		auto token = makeToken(greeting);
		auto authPacket = buildAuthPacket(token);
		send(authPacket);

		auto packet = getPacket();
		auto okp = OKErrorPacket(packet);
		enforceEx!MYX(!okp.error, "Authentication failure: " ~ cast(string) okp.message);
		_open = OpenState.authenticated;
	}

	SvrCapFlags _clientCapabilities;

	void connect(SvrCapFlags clientCapabilities)
	in
	{
		assert(closed);
	}
	out
	{
		assert(_open == OpenState.authenticated);
	}
	body
	{
		initConnection();
		auto greeting = parseGreeting();
		_open = OpenState.connected;

		_clientCapabilities = clientCapabilities;
		setClientFlags(clientCapabilities);
		authenticate(greeting);
	}
	
	/// Forcefully close the socket without sending the quit command.
	/// Needed in case an error leaves communatations in an undefined or non-recoverable state.
	void kill()
	{
		if(_socket.connected)
			_socket.close();
		_open = OpenState.notConnected;
		// any pending data is gone. Any statements to release will be released
		// on the server automatically.
		_headersPending = _rowsPending = _binaryPending = false;
		statementQueue.clear();
		preparedLookup.clear();
	}
	
	/// Called whenever mysql-native needs to send a command to the server
	/// and be sure there aren't any pending results (which would prevent
	/// a new command from being sent).
	void autoPurge()
	{
		// This is called every time a command is sent,
		// so detect & prevent infinite recursion.
		static bool isAutoPurging = false;

		if(isAutoPurging)
			return;
			
		isAutoPurging = true;
		scope(exit) isAutoPurging = false;

		try
		{
			purgeResult();
			statementQueue.releaseAll();
		}
		catch(Exception e)
		{
			// likely the connection was closed, so reset any state.
			// Don't treat this as a real error, because everything will be reset when we
			// reconnect.
			kill();
		}
	}

	/// Lookup per-connection prepared statement info by SQL
	PreparedServerInfo[string] preparedLookup;
	
	/// Returns null if not found
	Nullable!PreparedServerInfo getPreparedServerInfo(const string sql) pure nothrow
	{
		Nullable!PreparedServerInfo result;
		
		auto pInfo = sql in preparedLookup;
		if(pInfo)
			result = *pInfo;
		
		return result;
	}
	
	/// Returns 0 if not found
	uint getPreparedId(const string sql) pure const nothrow
	{
		auto pInfo = sql in preparedLookup;
		return pInfo? pInfo._hStmt : 0;
	}
	
	void enforceNotReleased(Nullable!PreparedServerInfo info)
	{
		enforceEx!MYXNotPrepared( isPreparedRegistered(info) );
	}

	package static void immediateRegisterPrepared(Connection conn, string sql)
	{
		if(sql in conn.preparedLookup)
			return;

		auto info = immediateRegisterPreparedImpl(conn, sql);
		conn.preparedLookup[sql] = info;
	}

	package static PreparedServerInfo immediateRegisterPreparedImpl(Connection conn, string sql)
	{
		scope(failure) conn.kill();

		PreparedServerInfo info;
		
		conn.sendCmd(CommandType.STMT_PREPARE, sql);
		conn._fieldCount = 0;

		//TODO: All packet handling should be moved into the mysql.protocol package.
		ubyte[] packet = conn.getPacket();
		if(packet.front == ResultPacketMarker.ok)
		{
			packet.popFront();
			info._hStmt         = packet.consume!int();
			conn._fieldCount    = packet.consume!short();
			info._psParams      = packet.consume!short();

			packet.popFront(); // one byte filler
			info._psWarnings    = packet.consume!short();

			// At this point the server also sends field specs for parameters
			// and columns if there were any of each
			info._psh = PreparedStmtHeaders(conn, conn._fieldCount, info._psParams);
		}
		else if(packet.front == ResultPacketMarker.error)
		{
			auto error = OKErrorPacket(packet);
			enforcePacketOK(error);
			assert(0); // FIXME: what now?
		}
		else
			assert(0); // FIXME: what now?
		
		
		return info;
	}

	private static void immediateReleasePrepared(Connection conn, string sql)
	{
		auto statementId = conn.getPreparedId(sql);
		if(statementId)
		{
			immediateReleasePreparedImpl(conn, statementId);
			conn.preparedLookup.remove(sql);
		}
	}

	package static void immediateReleasePreparedImpl(Connection conn, uint statementId)
	{
		if(!statementId)
			return;

		scope(failure) conn.kill();

		if(conn.closed())
			return;

		//TODO: All low-level commms should be moved into the mysql.protocol package.
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

	/++
	Keeps track of prepared statements queued to be released on the server.

	Prepared statements aren't released immediately, because that
	involves sending a command to the server even though there might be
	results pending. (Can't send a command while results are pending.)
	+/
	static struct StatementReleaseQueue(alias release)
	{
		private Connection conn;

		/// List of sql statements to be released.
		/// This uses assumeSafeAppend. Do not save copies of it.
		string[] sqlList;
		
		void add(string sql)
		{
			setQueuedForRelease(sql, true);
			sqlList ~= sql;
		}

		/// Removes a task from the list of statements
		/// to be released from the server.
		/// Does nothing if the task isn't on the list.
		void remove(string sql)
		{
			foreach(ref currSql; sqlList)
			if(sql == currSql)
			{
				currSql = null;
				setQueuedForRelease(sql, false);
			}
		}

		/// Releases all queued statemnts, and clears the queue.
		void releaseAll()
		{
			foreach(sql; sqlList)
			if(sql !is null)
				release(conn, sql);

			clear();
		}

		/// Clear all queued statements, and reset for using again.
		private void clear()
		{
			foreach(sql; sqlList)
				setQueuedForRelease(sql, false);

			if(sqlList.length)
			{
				sqlList.length = 0;
				assumeSafeAppend(sqlList);
			}
		}

		/// Set `queuedForRelease` flag for a statement in `preparedLookup`.
		/// Does nothing if statement not in `preparedLookup`.
		private void setQueuedForRelease(string sql, bool value)
		{
			if(sql in conn.preparedLookup)
			{
				auto info = conn.preparedLookup[sql];
				info.queuedForRelease = value;
				conn.preparedLookup[sql] = info;
			}
		}
	}
	StatementReleaseQueue!(immediateReleasePrepared) statementQueue;
	
	debug(MYSQLN_TESTS) string[] fakeRelease_result;
	unittest
	{
		debug(MYSQLN_TESTS)
		{
			static void fakeRelease(Connection conn, string sql)
			{
				conn.fakeRelease_result ~= sql;
			}
			
			mixin(scopedCn);
			
			StatementReleaseQueue!(fakeRelease) list;
			list.conn = cn;
			assert(list.sqlList == []);
			assert(cn.fakeRelease_result == []);

			list.add("1");
			assert(list.sqlList == ["1"]);
			assert(cn.fakeRelease_result == []);

			list.add("7");
			assert(list.sqlList == ["1", "7"]);
			assert(cn.fakeRelease_result == []);

			list.add("9");
			assert(list.sqlList == ["1", "7", "9"]);
			assert(cn.fakeRelease_result == []);

			list.remove("5");
			assert(list.sqlList == ["1", "7", "9"]);
			assert(cn.fakeRelease_result == []);
			
			list.remove("7");
			assert(list.sqlList == ["1", null, "9"]);
			assert(cn.fakeRelease_result == []);

			list.releaseAll();
			assert(list.sqlList == []);
			assert(cn.fakeRelease_result == ["1", "9"]);
		}
	}

public:

	/++
	Construct opened connection.

	Throws `mysql.exceptions.MYX` upon failure to connect.
	
	If you are using Vibe.d, consider using `mysql.pool.MySQLPool` instead of
	creating a new Connection directly. That will provide certain benefits,
	such as reusing old connections and automatic cleanup (no need to close
	the connection when done).

	------------------
	// Suggested usage:

	{
	    auto con = new Connection("host=localhost;port=3306;user=joe;pwd=pass123;db=myappsdb");
	    scope(exit) con.close();

	    // Use the connection
	    ...
	}
	------------------

	Params:
		cs = A connection string of the form "host=localhost;user=user;pwd=password;db=mysqld"
			(TODO: The connection string needs work to allow for semicolons in its parts!)
		socketType = Whether to use a Phobos or Vibe.d socket. Default is Phobos,
			unless compiled with `-version=Have_vibe_d_core` (set automatically
			if using $(LINK2 http://code.dlang.org/getting_started, DUB)).
		openSocket = Optional callback which should return a newly-opened Phobos
			or Vibe.d TCP socket. This allows custom sockets to be used,
			subclassed from Phobos's or Vibe.d's sockets.
		host = An IP address in numeric dotted form, or as a host  name.
		user = The user name to authenticate.
		password = User's password.
		db = Desired initial database.
		capFlags = The set of flag bits from the server's capabilities that the client requires
	+/
	//After the connection is created, and the initial invitation is received from the server
	//client preferences can be set, and authentication can then be attempted.
	this(string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
	{
		version(Have_vibe_d_core)
			enum defaultSocketType = MySQLSocketType.vibed;
		else
			enum defaultSocketType = MySQLSocketType.phobos;

		this(defaultSocketType, host, user, pwd, db, port, capFlags);
	}

	///ditto
	this(MySQLSocketType socketType, string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
	{
		version(Have_vibe_d_core) {} else
			enforceEx!MYX(socketType != MySQLSocketType.vibed, "Cannot use Vibe.d sockets without -version=Have_vibe_d_core");

		this(socketType, &defaultOpenSocketPhobos, &defaultOpenSocketVibeD,
			host, user, pwd, db, port, capFlags);
	}

	///ditto
	this(OpenSocketCallbackPhobos openSocket,
		string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
	{
		this(MySQLSocketType.phobos, openSocket, null, host, user, pwd, db, port, capFlags);
	}

	version(Have_vibe_d_core)
	///ditto
	this(OpenSocketCallbackVibeD openSocket,
		string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
	{
		this(MySQLSocketType.vibed, null, openSocket, host, user, pwd, db, port, capFlags);
	}

	///ditto
	private this(MySQLSocketType socketType,
		OpenSocketCallbackPhobos openSocketPhobos, OpenSocketCallbackVibeD openSocketVibeD,
		string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
	in
	{
		final switch(socketType)
		{
			case MySQLSocketType.phobos: assert(openSocketPhobos !is null); break;
			case MySQLSocketType.vibed:  assert(openSocketVibeD  !is null); break;
		}
	}
	body
	{
		enforceEx!MYX(capFlags & SvrCapFlags.PROTOCOL41, "This client only supports protocol v4.1");
		enforceEx!MYX(capFlags & SvrCapFlags.SECURE_CONNECTION, "This client only supports protocol v4.1 connection");
		version(Have_vibe_d_core) {} else
			enforceEx!MYX(socketType != MySQLSocketType.vibed, "Cannot use Vibe.d sockets without -version=Have_vibe_d_core");

		statementQueue.conn = this;

		_socketType = socketType;
		_host = host;
		_user = user;
		_pwd = pwd;
		_db = db;
		_port = port;

		_openSocketPhobos = openSocketPhobos;
		_openSocketVibeD  = openSocketVibeD;

		connect(capFlags);
	}

	///ditto
	//After the connection is created, and the initial invitation is received from the server
	//client preferences can be set, and authentication can then be attempted.
	this(string cs, SvrCapFlags capFlags = defaultClientFlags)
	{
		string[] a = parseConnectionString(cs);
		this(a[0], a[1], a[2], a[3], to!ushort(a[4]), capFlags);
	}

	///ditto
	this(MySQLSocketType socketType, string cs, SvrCapFlags capFlags = defaultClientFlags)
	{
		string[] a = parseConnectionString(cs);
		this(socketType, a[0], a[1], a[2], a[3], to!ushort(a[4]), capFlags);
	}

	///ditto
	this(OpenSocketCallbackPhobos openSocket, string cs, SvrCapFlags capFlags = defaultClientFlags)
	{
		string[] a = parseConnectionString(cs);
		this(openSocket, a[0], a[1], a[2], a[3], to!ushort(a[4]), capFlags);
	}

	version(Have_vibe_d_core)
	///ditto
	this(OpenSocketCallbackVibeD openSocket, string cs, SvrCapFlags capFlags = defaultClientFlags)
	{
		string[] a = parseConnectionString(cs);
		this(openSocket, a[0], a[1], a[2], a[3], to!ushort(a[4]), capFlags);
	}

	/++
	Check whether this `Connection` is still connected to the server, or if
	the connection has been closed.
	+/
	@property bool closed()
	{
		return _open == OpenState.notConnected || !_socket.connected;
	}

	version(Have_vibe_d_core)
	{
		/// Used by Vibe.d's ConnectionPool, ignore this.
		void acquire() { if( _socket ) _socket.acquire(); }
		///ditto
		void release() { if( _socket ) _socket.release(); }
		///ditto
		bool isOwner() { return _socket ? _socket.isOwner() : false; }
		///ditto
		bool amOwner() { return _socket ? _socket.isOwner() : false; }
	}
	else
	{
		/// Used by Vibe.d's ConnectionPool, ignore this.
		void acquire() { /+ Do nothing +/ }
		///ditto
		void release() { /+ Do nothing +/ }
		///ditto
		bool isOwner() { return !!_socket; }
		///ditto
		bool amOwner() { return !!_socket; }
	}

	/++
	Explicitly close the connection.
	
	This is a two-stage process. First tell the server we are quitting this
	connection, and then close the socket.
	
	Idiomatic use as follows is suggested:
	------------------
	{
	    auto con = new Connection("localhost:user:password:mysqld");
	    scope(exit) con.close();
	    // Use the connection
	    ...
	}
	------------------
	+/
	void close()
	{
		if (_open == OpenState.authenticated && _socket.connected)
			quit();

		if (_open == OpenState.connected)
			kill();
		resetPacket();
	}

	/++
	Reconnects to the server using the same connection settings originally
	used to create the `Connection`.

	Optionally takes a `mysql.protocol.constants.SvrCapFlags`, allowing you to
	reconnect using a different set of server capability flags.

	Normally, if the connection is already open, this will do nothing. However,
	if you request a different set of `mysql.protocol.constants.SvrCapFlags`
	then was originally used to create the `Connection`, the connection will
	be closed and then reconnected using the new `mysql.protocol.constants.SvrCapFlags`.
	+/
	void reconnect()
	{
		reconnect(_clientCapabilities);
	}

	///ditto
	void reconnect(SvrCapFlags clientCapabilities)
	{
		bool sameCaps = clientCapabilities == _clientCapabilities;
		if(!closed)
		{
			// Same caps as before?
			if(clientCapabilities == _clientCapabilities)
				return; // Nothing to do, just keep current connection

			close();
		}

		connect(clientCapabilities);
	}

	private void quit()
	in
	{
		assert(_open == OpenState.authenticated);
	}
	body
	{
		sendCmd(CommandType.QUIT, []);
		// No response is sent for a quit packet
		_open = OpenState.connected;
	}

	/++
	Parses a connection string of the form
	`"host=localhost;port=3306;user=joe;pwd=pass123;db=myappsdb"`

	Port is optional and defaults to 3306.

	Whitespace surrounding any name or value is automatically stripped.

	Returns a five-element array of strings in this order:
	$(UL
	$(LI [0]: host)
	$(LI [1]: user)
	$(LI [2]: pwd)
	$(LI [3]: db)
	$(LI [4]: port)
	)
	
	(TODO: The connection string needs work to allow for semicolons in its parts!)
	+/
	//TODO: Replace the return value with a proper struct.
	static string[] parseConnectionString(string cs)
	{
		string[] rv;
		rv.length = 5;
		rv[4] = "3306"; // Default port
		string[] a = split(cs, ";");
		foreach (s; a)
		{
			string[] a2 = split(s, "=");
			enforceEx!MYX(a2.length == 2, "Bad connection string: " ~ cs);
			string name = strip(a2[0]);
			string val = strip(a2[1]);
			switch (name)
			{
				case "host":
					rv[0] = val;
					break;
				case "user":
					rv[1] = val;
					break;
				case "pwd":
					rv[2] = val;
					break;
				case "db":
					rv[3] = val;
					break;
				case "port":
					rv[4] = val;
					break;
				default:
					throw new MYX("Bad connection string: " ~ cs, __FILE__, __LINE__);
			}
		}
		return rv;
	}

	/++
	Select a current database.
	
	Throws `mysql.exceptions.MYX` upon failure.

	Params: dbName = Name of the requested database
	+/
	void selectDB(string dbName)
	{
		sendCmd(CommandType.INIT_DB, dbName);
		getCmdResponse();
		_db = dbName;
	}

	/++
	Check the server status.
	
	Throws `mysql.exceptions.MYX` upon failure.

	Returns: An `mysql.protocol.packets.OKErrorPacket` from which server status can be determined
	+/
	OKErrorPacket pingServer()
	{
		sendCmd(CommandType.PING, []);
		return getCmdResponse();
	}

	/++
	Refresh some feature(s) of the server.
	
	Throws `mysql.exceptions.MYX` upon failure.

	Returns: An `mysql.protocol.packets.OKErrorPacket` from which server status can be determined
	+/
	OKErrorPacket refreshServer(RefreshFlags flags)
	{
		sendCmd(CommandType.REFRESH, [flags]);
		return getCmdResponse();
	}

	/++
	Internal - Get the next `mysql.result.Row` of a pending result set.
	
	This is intended to be internal, you should not use it directly.
	It will not likely remain public in the future.
	
	Returns: A `mysql.result.Row` object.
	+/
	Row getNextRow()
	{
		scope(failure) kill();

		if (_headersPending)
		{
			_rsh = ResultSetHeaders(this, _fieldCount);
			_headersPending = false;
		}
		ubyte[] packet;
		Row rr;
		packet = getPacket();
		if (packet.isEOFPacket())
		{
			_rowsPending = _binaryPending = false;
			return rr;
		}
		if (_binaryPending)
			rr = Row(this, packet, _rsh, true);
		else
			rr = Row(this, packet, _rsh, false);
		//rr._valid = true;
		return rr;
	}

	/++
	Flush any outstanding result set elements.
	
	When the server responds to a command that produces a result set, it
	queues the whole set of corresponding packets over the current connection.
	Before that `Connection` can embark on any new command, it must receive
	all of those packets and junk them.
	
	As of v1.1.4, this is done automatically as needed. But you can still
	call this manually to force a purge to occur when you want.

	See_Also: $(LINK http://www.mysqlperformanceblog.com/2007/07/08/mysql-net_write_timeout-vs-wait_timeout-and-protocol-notes/)
	+/
	ulong purgeResult()
	{
		scope(failure) kill();

		_lastCommandID++;

		ulong rows = 0;
		if (_headersPending)
		{
			for (size_t i = 0;; i++)
			{
				if (getPacket().isEOFPacket())
				{
					_headersPending = false;
					break;
				}
				enforceEx!MYXProtocol(i < _fieldCount,
					text("Field header count (", _fieldCount, ") exceeded but no EOF packet found."));
			}
		}
		if (_rowsPending)
		{
			for (;;  rows++)
			{
				if (getPacket().isEOFPacket())
				{
					_rowsPending = _binaryPending = false;
					break;
				}
			}
		}
		resetPacket();
		return rows;
	}

	/++
	Get a textual report on the server status.
	
	(COM_STATISTICS)
	+/
	string serverStats()
	{
		sendCmd(CommandType.STATISTICS, []);
		return cast(string) getPacket();
	}

	/++
	Enable multiple statement commands.
	
	This can be used later if this feature was not requested in the client capability flags.
	
	Params: on = Boolean value to turn the capability on or off.
	+/
	void enableMultiStatements(bool on)
	{
		scope(failure) kill();

		ubyte[] t;
		t.length = 2;
		t[0] = on ? 0 : 1;
		t[1] = 0;
		sendCmd(CommandType.STMT_OPTION, t);

		// For some reason this command gets an EOF packet as response
		auto packet = getPacket();
		enforceEx!MYXProtocol(packet[0] == 254 && packet.length == 5, "Unexpected response to SET_OPTION command");
	}

	/// Return the in-force protocol number.
	@property ubyte protocol() pure const nothrow { return _protocol; }
	/// Server version
	@property string serverVersion() pure const nothrow { return _serverVersion; }
	/// Server capability flags
	@property uint serverCapabilities() pure const nothrow { return _sCaps; }
	/// Server status
	@property ushort serverStatus() pure const nothrow { return _serverStatus; }
	/// Current character set
	@property ubyte charSet() pure const nothrow { return _sCharSet; }
	/// Current database
	@property string currentDB() pure const nothrow { return _db; }
	/// Socket type being used, Phobos or Vibe.d
	@property MySQLSocketType socketType() pure const nothrow { return _socketType; }

	/// After a command that inserted a row into a table with an auto-increment
	/// ID column, this method allows you to retrieve the last insert ID.
	@property ulong lastInsertID() pure const nothrow { return _insertID; }

	/// This gets incremented every time a command is issued or results are purged,
	/// so a `mysql.result.ResultRange` can tell whether it's been invalidated.
	@property ulong lastCommandID() pure const nothrow { return _lastCommandID; }

	/// Gets whether rows are pending.
	///
	/// Note, you may want `hasPending` instead.
	@property bool rowsPending() pure const nothrow { return _rowsPending; }

	/// Gets whether anything (rows, headers or binary) is pending.
	/// New commands cannot be sent on a conncection while anything is pending
	/// (the pending data will automatically be purged.)
	@property bool hasPending() pure const nothrow
	{
		return _rowsPending || _headersPending || _binaryPending;
	}

	/// Gets the result header's field descriptions.
	@property FieldDescription[] resultFieldDescriptions() pure { return _rsh.fieldDescriptions; }

	/// Is the given SQL registered on this connection as a prepared statement?
	bool isPreparedRegistered(string sql)
	{
		return isPreparedRegistered( getPreparedServerInfo(sql) );
	}

	///ditto
	package bool isPreparedRegistered(Nullable!PreparedServerInfo info)
	{
		return !info.isNull && info._hStmt && !info.queuedForRelease;
	}
}

// An attempt to reproduce issue #81: Using mysql-native driver with no default database
// I'm unable to actually reproduce the error, though.
debug(MYSQLN_TESTS)
unittest
{
	import mysql.escape;
	mixin(scopedCn);
	
	cn.exec("DROP TABLE IF EXISTS `issue81`");
	cn.exec("CREATE TABLE `issue81` (a INTEGER) ENGINE=InnoDB DEFAULT CHARSET=utf8");
	cn.exec("INSERT INTO `issue81` (a) VALUES (1)");

	auto cn2 = new Connection(text("host=", cn._host, ";port=", cn._port, ";user=", cn._user, ";pwd=", cn._pwd));
	scope(exit) cn2.close();
	
	cn2.query("SELECT * FROM `"~mysqlEscape(cn._db).text~"`.`issue81`");
}

// unittest for issue 154, when the socket is disconnected from the mysql server.
// This simulates a disconnect by closing the socket underneath the Connection
// object itself.
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);

	cn.exec("DROP TABLE IF EXISTS `dropConnection`");
	cn.exec("CREATE TABLE `dropConnection` (
		`val` INTEGER
	) ENGINE=InnoDB DEFAULT CHARSET=utf8");
	cn.exec("INSERT INTO `dropConnection` VALUES (1), (2), (3)");
	import mysql.prepared;
	{
		auto prep = cn.prepare("SELECT * FROM `dropConnection`");
		prep.query();
	}
	// close the socket forcibly
	cn._socket.close();
	// this should still work (it should reconnect).
	cn.exec("DROP TABLE `dropConnection`");
}

