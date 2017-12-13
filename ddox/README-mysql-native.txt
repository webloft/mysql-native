This copy of DDOX is included in the mysql-native repository for
mysql-native's convenience.

This is based on DDOX's 'v0.16.6' tag, with the following changes:

- Added this 'README-mysql-native.txt' file.

- Modified 'dub.sdl' to include the version identifier 'VibeUseOpenSSL11' so
it will succesfully link on my machine (Workaround DDOX Issue #186)

- Modified 'layout.dt' and 'ddox.layout.dt' for mysql-native's purposes.
(Workaround DDOX Issue #88)

- Hack a few lines in 'ddox/ddoc.d' and 'ddox/htmlgenerator.d' to expose the
DDOC macros to the diet templates, so mysql-native's docs can auto-detect
the current version number via gen-package-version's --ddoc output.
