#!/bin/sh
# Builds the slicing engine PrintDeck bundles: Ultimaker CuraEngine 15.04.6 (AGPL-3.0, source in CuraEngine/,
# PrintDeck's changes in printdeck.patch, already applied) for armv7 / iOS 5 with the Theos toolchain.
# Output: build/CuraEngine (ldid-signed). The Makefile runs this before every build; it only recompiles when a
# source file is newer than the binary.
#
# Toolchain notes:
#  - -Wl,-flat_namespace: the iPhoneOS9.3 SDK says std::length_error & co. live in libc++abi, but on iOS 5 they
#    are in libc++.1, so a two-level-namespace binary dies in dyld at launch.
#  - compat.c supplies strchr, which the 9.3 SDK stubs don't export for armv7.
set -e
cd "$(dirname "$0")"
OUT=build/CuraEngine
if [ -f "$OUT" ] && [ -z "$(find CuraEngine compat.c build.sh -newer "$OUT" -type f | head -1)" ]; then exit 0; fi
THEOS=${THEOS:-$HOME/theos}
TC=$THEOS/toolchain/linux/iphone/bin
SDK=$THEOS/sdks/iPhoneOS9.3.sdk
T="-isysroot $SDK -target armv7-apple-ios5.0 -arch armv7"
echo "==> Building CuraEngine (armv7)…"
mkdir -p build/obj
rm -f build/obj/*.o
$TC/clang $T -O2 -c compat.c -o build/obj/compat.o
for s in CuraEngine/libs/clipper/clipper.cpp CuraEngine/src/*.cpp CuraEngine/src/modelFile/modelFile.cpp \
         CuraEngine/src/utils/gettime.cpp CuraEngine/src/utils/logoutput.cpp CuraEngine/src/utils/socket.cpp; do
  $TC/clang++ $T -stdlib=libc++ -std=c++11 -O2 -isystem CuraEngine/libs -DVERSION=\"15.04.6-printdeck\" -w \
    -c $s -o build/obj/$(echo $s | tr / _).o &
done
wait
$TC/clang++ $T -stdlib=libc++ -lc++abi -Xlinker -segalign -Xlinker 4000 -Wl,-flat_namespace build/obj/*.o -o $OUT 2>&1 | grep -v 'warning:' || true
$TC/ldid -S $OUT
echo "==> $OUT: $(wc -c < $OUT) bytes"
