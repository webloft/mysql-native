import mysql.test.common;
import mysql.test.integration;
import mysql.test.regression;
import mysql.maintests;

import unit_threaded;

// manual unit-threaded main function
int main(string[] args)
{
    return args.runTests!(
                          "mysql.maintests",
                          "mysql.test.common",
                          "mysql.test.integration",
                          "mysql.test.regression"
                          );
}
