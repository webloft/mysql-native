#!/bin/sh

# LDC/GDC don't include rdmd, so allow user to specify path to it in $RDMD.
# Otherwise, use "rdmd".
#
# For travis, if "rdmd" doesn't work (ie, LDC/GDC is being tested), then use
# the copy of rdmd that was downloaded by the 'travis-install-deps.sh' script.
if [ -z "$RDMD" ]; then
	RDMD=rdmd
	if [ "${TRAVIS_OS_NAME}" = 'osx' ]; then
	    command -v $RDMD >/dev/null 2>&1 || RDMD=local-dmd/dmd2/${TRAVIS_OS_NAME}/bin/rdmd
	else
	    command -v $RDMD >/dev/null 2>&1 || RDMD=local-dmd/dmd2/${TRAVIS_OS_NAME}/bin64/rdmd
	fi
fi

if [ -z "$DMD" ]; then
	DMD=dmd
fi
