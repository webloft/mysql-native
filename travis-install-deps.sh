#!/bin/sh
if [ ! command -v rdmd ]; then
	DMD_ZIP=dmd.2.076.0.${TRAVIS_OS_NAME}.zip
	wget http://downloads.dlang.org/releases/2017/$DMD_ZIP
	unzip -d local-dmd $DMD_ZIP
fi

# Download & resolve deps now so intermittent failures are more likely
# to be correctly marked as "job error" rather than "tests failed".
dub upgrade --missing-only
cd examples/homePage
dub upgrade --missing-only
cd ../..
