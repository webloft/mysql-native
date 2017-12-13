Type mapping
------------

| MySQL      | D            |
| ---------- | ------------ |
| NULL       | typeof(null) |
| BIT        | bool         |
| TINY       | (u)byte      |
| SHORT      | (u)short     |
| INT24      | (u)int       |
| INT        | (u)int       |
| LONGLONG   | (u)long      |
| FLOAT      | float        |
| DOUBLE     | double       |
| ---------- | ------------ |
| TIMESTAMP  | DateTime     |
| TIME       | TimeOfDay    |
| YEAR       | ushort       |
| DATE       | Date         |
| DATETIME   | DateTime     |
| ---------- | ------------ |
| VARCHAR    | string       |
| ENUM       | string       |
| SET        | string       |
| VARSTRING  | string       |
| STRING     | string       |
| NEWDECIMAL | string       |
| ---------- | ------------ |
| TINYBLOB   | ubyte[]      |
| MEDIUMBLOB | ubyte[]      |
| BLOB       | ubyte[]      |
| LONGBLOB   | ubyte[]      |
| ---------- | ------------ |
| TINYTEXT   | string       |
| MEDIUMTEXT | string       |
| TEXT       | string       |
| LONGTEXT   | string       |
| ---------- | ------------ |
| other      | unsupported (throws) |


| MySQL      | D            |
| ---------- | ------------ |
| NULL       | typeof(null) |
| BIT        | bool         |
| TINY       | (u)byte      |
| SHORT      | (u)short     |
| INT24      | (u)int       |
| INT        | (u)int       |
| LONGLONG   | (u)long      |
| FLOAT      | float        |
| DOUBLE     | double       |
| ---------- | ------------ |
| TIMESTAMP  | DateTime     |
| TIME       | TimeOfDay    |
| YEAR       | ushort       |
| DATE       | Date         |
| DATETIME   | DateTime     |
| ---------- | ------------ |
| VARCHAR, ENUM, SET, VARSTRING, STRING, NEWDECIMAL | string       |
| TINYBLOB, MEDIUMBLOB, BLOB, LONGBLOB              | ubyte[]      |
| TINYTEXT, MEDIUMTEXT, TEXT, LONGTEXT              | string       |
| ---------- | ------------ |
| other      | unsupported (throws) |


