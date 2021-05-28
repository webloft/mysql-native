import mysql.test.common;
import mysql.test.integration;
import mysql.test.regression;
import mysql.maintests;
import mysql.protocol.packet_helpers;
import mysql.connection;
import mysql.escape;

import unit_threaded;

// manual unit-threaded main function
int main(string[] args)
{
    return args.runTests!(
                          "mysql.maintests",
                          "mysql.test.common",
                          "mysql.test.integration",
                          "mysql.test.regression",
                          "mysql.protocol.packet_helpers",
                          "mysql.connection",
                          "mysql.escape"
                          );
}
