@echo off

rem GDC doesn't autocreate the dir (and git doesn't beleive in empty dirs)
mkdir bin >NUL 2>NUL

rem Setup unit-threaded
dub fetch unit-threaded --version=0.7.37 --cache=local
cd unit-threaded-0.7.37\unit-threaded
dub build -c gen_ut_main
cd ..\..
unit-threaded-0.7.37\unit-threaded\gen_ut_main -f bin/ut.d

echo Compiling Phobos-socket tests...
rdmd --build-only -g -unittest -debug=MYSQLN_TESTS -version=MYSQLN_TESTS_NO_MAIN -version=Have_unit_threaded -ofbin/mysqln-tests-phobos-ut -Isource -Iunit-threaded-0.7.37/unit-threaded/source/ --extra-file=unit-threaded-0.7.37/unit-threaded/libunit-threaded.lib --exclude=unit_threaded bin/ut.d && echo Running Phobos-socket tests... && bin/mysqln-tests-phobos-ut -t %*
