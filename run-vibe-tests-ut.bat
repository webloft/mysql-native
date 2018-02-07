@echo off

rem GDC doesn't autocreate the dir (and git doesn't beleive in empty dirs)
mkdir bin >NUL 2>NUL

dub run -c unittest-vibe-ut -- -t %*
