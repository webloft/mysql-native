#!/bin/sh
if ! [ command -v rdmd ]; then
	DMD_ZIP=dmd.2.076.0.${TRAVIS_OS_NAME}.zip
	wget http://downloads.dlang.org/releases/2017/$DMD_ZIP
	unzip -d local-dmd $DMD_ZIP
fi
