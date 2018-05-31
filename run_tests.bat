@echo off

rem Compile using $DMD if it exists, otherwise use dmd
if not "%DMD%" == "" set DMD=dmd

%DMD% -ofbin\run_tests run_tests.d && bin\run_tests %*
