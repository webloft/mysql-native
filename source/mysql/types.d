/// Structures for MySQL types not built-in to D/Phobos.
module mysql.types;

import std.datetime;
import mysql.exceptions;

/++
A simple struct to represent time difference.

D's std.datetime does not have a type that is closely compatible with the MySQL
interpretation of a time difference, so we define a struct here to hold such
values.
+/
struct TimeDiff
{
	bool negative;
	int days;
	ubyte hours, minutes, seconds;
}

/++
A D struct to stand for a TIMESTAMP

It is assumed that insertion of TIMESTAMP values will not be common, since in general,
such columns are used for recording the time of a row insertion, and are filled in
automatically by the server. If you want to force a timestamp value in a prepared insert,
set it into a timestamp struct as an unsigned long in the format YYYYMMDDHHMMSS
and use that for the appropriate parameter. When TIMESTAMPs are retrieved as part of
a result set it will be as DateTime structs.
+/
struct Timestamp
{
	ulong rep;
}

/++
In certain circumstances, MySQL permits storing invalid dates (such as the
"zero date": 0000-00-00). Phobos's Date/DateTime disallows invalid dates, so
the MySQLDate and MySQLDateTime type allow reading such dates when they occur.
+/
struct MySQLDate
{
	int year;
	int month;
	int day;
	
	private void throwInvalidDate() pure
	{
		throw new MYXInvalidatedDate(this);
	}

	@property Date getDate() pure
	{
		if(year < 1 || month < 1 || day < 1 || month > 12 || day > 31)
			throwInvalidDate();

		try
			return Date(year, month, day);
		catch(DateTimeException e)
			throwInvalidDate();
		
		assert(0);
	}

	string toString() pure
	{
		import std.format;
		return format("%04s-%02s-%02s", year, month, day);
	}

	//alias getDate this;
}

///ditto
struct MySQLDateTime
{
	int year;
	int month;
	int day;

	int hour;
	int minute;
	int second;

	@property DateTime getDateTime() pure
	{
		// Ensure date is valid
		MySQLDate(year, month, day).getDate();

		return DateTime(year, month, day, hour, minute, second);
	}

	//alias getDateTime this;
}
