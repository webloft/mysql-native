#!/bin/sh
if ! [ $(which rdmd) ]; then
	DMD_ZIP=dmd.2.076.0.${TRAVIS_OS_NAME}.zip
	wget http://downloads.dlang.org/releases/2017/$DMD_ZIP
	unzip -d local-dmd $DMD_ZIP
fi

# If there's a special dub.selections.json for this compiler version, then use it.
. ./find-rdmd.sh
echo "RDMD=$RDMD"
D_VER=$($RDMD --compiler=$DMD '--eval=writef("%s.%03s", version_major, version_minor)')
echo "D_VER=${D_VER}"
cp "dub.selections.${D_VER}.json" dub.selections.json 2>/dev/null
cp "examples/homePage/dub.selections.${D_VER}.json" examples/homePage/dub.selections.json 2>/dev/null

# Download & resolve deps now so intermittent failures are more likely
# to be correctly marked as "job error" rather than "tests failed".
dub upgrade --missing-only
cd examples/homePage
dub upgrade --missing-only
cd ../..
