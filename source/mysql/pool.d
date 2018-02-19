/++
Connect to a MySQL/MariaDB database using vibe.d's
$(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool, ConnectionPool).

You have to include vibe.d in your project to be able to use this class.
If you don't want to, refer to `mysql.connection.Connection`.

This provides various benefits over creating a new connection manually,
such as automatically reusing old connections, and automatic cleanup (no need to close
the connection when done).
+/
module mysql.pool;

import std.conv;
import mysql.connection;
import mysql.protocol.constants;
debug(MYSQLN_TESTS)
{
	import mysql.test.common;
}

version(Have_vibe_d_core) version = IncludeMySQLPool;
version(MySQLDocs)        version = IncludeMySQLPool;

version(IncludeMySQLPool)
{
	version(Have_vibe_d_core)
		import vibe.core.connectionpool;
	else version(MySQLDocs)
	{
		/++
		Vibe.d's
		$(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool, ConnectionPool)
		class.

		Not actually included in module `mysql.pool`. Only listed here for
		documentation purposes. For ConnectionPool and it's documentation, see:
		$(LINK http://vibed.org/api/vibe.core.connectionpool/ConnectionPool)
		+/
		class ConnectionPool(T)
		{
			/// See: $(LINK http://vibed.org/api/vibe.core.connectionpool/ConnectionPool.this)
			this(Connection delegate() connection_factory, uint max_concurrent = (uint).max)
			{}

			/// See: $(LINK http://vibed.org/api/vibe.core.connectionpool/ConnectionPool.lockConnection)
			LockedConnection!T lockConnection() { return LockedConnection!T(); }

			/// See: $(LINK http://vibed.org/api/vibe.core.connectionpool/ConnectionPool.maxConcurrency)
			uint maxConcurrency;
		}

		/++
		Vibe.d's
		$(LINK2 http://vibed.org/api/vibe.core.connectionpool/LockedConnection, LockedConnection)
		struct.

		Not actually included in module `mysql.pool`. Only listed here for
		documentation purposes. For LockedConnection and it's documentation, see:
		$(LINK http://vibed.org/api/vibe.core.connectionpool/LockedConnection)
		+/
		struct LockedConnection(Connection) {}
	}

	/++
	A lightweight convenience interface to a MySQL/MariaDB database using vibe.d's
	$(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool, ConnectionPool).

	You have to include vibe.d in your project to be able to use this class.
	If you don't want to, refer to `mysql.connection.Connection`.

	If, for any reason, this class doesn't suit your needs, it's easy to just
	use vibe.d's $(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool, ConnectionPool)
	directly. Simply provide it with a delegate that creates a new `mysql.connection.Connection`
	and does any other custom processing if needed.
	+/
	class MySQLPool {
		private {
			string m_host;
			string m_user;
			string m_password;
			string m_database;
			ushort m_port;
			SvrCapFlags m_capFlags;
			void delegate(Connection) m_onNewConnection;
			ConnectionPool!Connection m_pool;
		}

		/// Sets up a connection pool with the provided connection settings.
		///
		/// The optional `onNewConnection` param allows you to set a callback
		/// which will be run every time a new connection is created.
		this(string host, string user, string password, string database,
			ushort port = 3306, uint maxConcurrent = (uint).max,
			SvrCapFlags capFlags = defaultClientFlags,
			void delegate(Connection) onNewConnection = null)
		{
			m_host = host;
			m_user = user;
			m_password = password;
			m_database = database;
			m_port = port;
			m_capFlags = capFlags;
			m_onNewConnection = onNewConnection;
			m_pool = new ConnectionPool!Connection(&createConnection);
		}

		///ditto
		this(string host, string user, string password, string database,
			ushort port, SvrCapFlags capFlags, void delegate(Connection) onNewConnection = null)
		{
			this(host, user, password, database, port, (uint).max, capFlags, onNewConnection);
		}

		///ditto
		this(string host, string user, string password, string database,
			ushort port, void delegate(Connection) onNewConnection)
		{
			this(host, user, password, database, port, (uint).max, defaultClientFlags, onNewConnection);
		}

		///ditto
		this(string connStr, uint maxConcurrent = (uint).max, SvrCapFlags capFlags = defaultClientFlags,
			void delegate(Connection) onNewConnection = null)
		{
			auto parts = Connection.parseConnectionString(connStr);
			this(parts[0], parts[1], parts[2], parts[3], to!ushort(parts[4]), capFlags, onNewConnection);
		}

		///ditto
		this(string connStr, SvrCapFlags capFlags, void delegate(Connection) onNewConnection = null)
		{
			this(connStr, (uint).max, capFlags, onNewConnection);
		}

		///ditto
		this(string connStr, void delegate(Connection) onNewConnection)
		{
			this(connStr, (uint).max, defaultClientFlags, onNewConnection);
		}

		/++
		Obtain a connection. If one isn't available, a new one will be created.

		The connection returned is actually a `LockedConnection!Connection`,
		but it uses `alias this`, and so can be used just like a Connection.
		(See vibe.d's
		$(LINK2 http://vibed.org/api/vibe.core.connectionpool/LockedConnection, LockedConnection documentation).)

		No other fiber will be given this `mysql.connection.Connection` as long as your fiber still holds it.

		There is no need to close, release or unlock this connection. It is
		reference-counted and will automatically be returned to the pool once
		your fiber is done with it.
		+/
		auto lockConnection() { return m_pool.lockConnection(); }

		private Connection createConnection()
		{
			auto conn = new Connection(m_host, m_user, m_password, m_database, m_port, m_capFlags);

			if(m_onNewConnection)
				m_onNewConnection(conn);

			return conn;
		}

		
		/// Get/set a callback delegate to be run every time a new connection
		/// is created.
		@property void onNewConnection(void delegate(Connection) onNewConnection)
		{
			m_onNewConnection = onNewConnection;
		}

		///ditto
		@property void delegate(Connection) onNewConnection()
		{
			return m_onNewConnection;
		}

		@("onNewConnection")
		debug(MYSQLN_TESTS)
		unittest
		{
			auto count = 0;
			void callback(Connection conn)
			{
				count++;
			}

			// Test getting/setting
			auto poolA = new MySQLPool(testConnectionStr, &callback);
			auto poolB = new MySQLPool(testConnectionStr);
			auto poolNoCallback = new MySQLPool(testConnectionStr);
			
			assert(poolA.onNewConnection == &callback);
			assert(poolB.onNewConnection is null);
			assert(poolNoCallback.onNewConnection is null);
			
			poolB.onNewConnection = &callback;
			assert(poolB.onNewConnection == &callback);
			assert(count == 0);

			// Ensure callback is called
			{
				auto connA = poolA.lockConnection();
				assert(!connA.closed);
				assert(count == 1);
				
				auto connB = poolB.lockConnection();
				assert(!connB.closed);
				assert(count == 2);
			}

			// Ensure works with no callback
			{
				auto oldCount = count;
				auto poolC = new MySQLPool(testConnectionStr);
				auto connC = poolC.lockConnection();
				assert(!connC.closed);
				assert(count == oldCount);
			}
		}

		/++
		Forwards to vibe.d's
		$(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool.maxConcurrency, ConnectionPool.maxConcurrency)
		+/
		@property uint maxConcurrency()
		{
			return m_pool.maxConcurrency;
		}

		///ditto
		@property void maxConcurrency(uint maxConcurrent)
		{
			m_pool.maxConcurrency = maxConcurrent;
		}
	}
}
