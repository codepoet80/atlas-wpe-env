#!/bin/bash
# Build BrowserServer-atlas (the WPE BrowserServer, with BrowserPageWPE merged in) from source.
# Portable reproduction of the original build-browserserver.sh + link-bs-252.sh, de-hardcoded.
#
#   source env-atlas-cross.sh           # sets CC/CXX, arch flags, STAGING
#   REPOS=~/Projects ./build-browserserver-atlas.sh
#
# Prerequisites (see BUILDING.md §5b for exact provenance):
#   $REPOS/BrowserServer      (Herrie82/BrowserServer)  — Src/ + Yap/ + CodeGen/
#   $REPOS/atlas-wpe-backend  — BrowserPageWPE.{cpp,h}  (the viewport fix lives here)
#   $REPOS/{luna-service2,WebKitSupplemental,pbnjson,PmLogLib}  — webOS headers
#   $STAGING/include/{wpe-webkit-2.0,wpe-1.0,glib-2.0,qt4,libpng16,openssl,libsoup,EGL,GLES2,KHR,reconstructed}
#   $STAGING/lib (device-pulled sonames + dev symlinks), $STAGING/linklib, $STAGING/rootfs (device /usr/lib+/lib)
set -eu
: "${STAGING:?source env-atlas-cross.sh first}"
: "${CXX:=arm-cortex_a8-linux-gnueabi-g++}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)   # this repo — vendors reconstructed-headers/
REPOS="${REPOS:-$HOME/Projects}"
BS="$REPOS/BrowserServer"; BK="$REPOS/atlas-wpe-backend"
BLD="${BLD:-$REPOS/browserserver-build}"; SRC="$BLD/src"; OBJ="$BLD/obj"
S="$STAGING/include"; LL="$STAGING/linklib"; RL="$STAGING/rootfs"
DR="${DEVICEROOT:-/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot}"
ARCH="-march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp -mthumb"
DEF="-DQT_NO_KEYWORDS -DNDEBUG -D_GLIBCXX_USE_CXX11_ABI=0 -Demit= -DUSE_LUNA_SERVICE -DATLAS_LUNA"
STD="-std=c++11 -fPIC -fpermissive -Wno-deprecated"
INC="-I$SRC -I$BS/Yap -I$BK \
 -I$S/wpe-webkit-2.0 -I$S/wpe-1.0 -I$S/glib-2.0 -I$STAGING/lib/glib-2.0/include -I$S \
 -I$S/qt4 -I$S/qt4/QtCore -I$S/qt4/QtGui -I$S/qt4/QtNetwork -I$S/qt4/QtWebKit \
 -I$REPOS/luna-service2/include/public -I$REPOS/luna-service2/include/public/luna-service2 \
 -I$REPOS/WebKitSupplemental/misc -I$REPOS/WebKitSupplemental/qbsplugin \
 -I$REPOS/WebKitSupplemental/qtwebkitplugin -I$REPOS/WebKitSupplemental/widgets \
 -I$REPOS/pbnjson/include/public -I$REPOS/pbnjson/src/api -I$SCRIPT_DIR/reconstructed-headers -I$REPOS/PmLogLib/include/public"

echo "== 1. stage BrowserServer/Src + merge BrowserPageWPE -> BrowserPage =="
rm -rf "$BLD"; mkdir -p "$SRC" "$OBJ"; cp -r "$BS/Src/." "$SRC/"
python3 - "$BS" "$BK" "$SRC" <<'PY'
import sys
BS,BK,SRC=sys.argv[1:4]
def block(t,n):
    i=t.index('class '+n); j=t.index('{',i); d=0; k=j
    while k<len(t):
        c=t[k]
        if c=='{': d+=1
        elif c=='}':
            d-=1
            if d==0: return i,t.index(';',k)+1
        k+=1
B='/* GENERATED from atlas-wpe-backend/BrowserPageWPE.* — edit the canonical file. */\n\n'
o=open(f'{BS}/Src/BrowserPage.h').read(); w=open(f'{BK}/BrowserPageWPE.h').read()
o0,o1=block(o,'BrowserPage'); w0,w1=block(w,'BrowserPageWPE')
wc=w[w0:w1].replace('BrowserPageWPE','BrowserPage')
open(f'{SRC}/BrowserPage.h','w').write(B+o[:o0]+'#include <wpe/webkit.h>\n#include <semaphore.h>\n#include <lunaservice.h>\n\n'+wc+o[o1:])
open(f'{SRC}/BrowserPage.cpp','w').write(B+open(f'{BK}/BrowserPageWPE.cpp').read().replace('BrowserPageWPE','BrowserPage'))
PY

echo "== 2. CodeGen the yap interface (host tool) =="
# CodeGen is a HOST tool (host g++ + host Qt5). env-atlas-cross.sh points pkg-config at the ARM
# cross-sysroot, so query host Qt5 with those overrides cleared.
HOSTPC="env -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_SYSROOT_DIR -u PKG_CONFIG_PATH pkg-config"
QT5_CFLAGS=$($HOSTPC --cflags Qt5Core); QT5_LIBS=$($HOSTPC --libs Qt5Core)
( cd "$BS/CodeGen"
  [ -x ./CodeGen ] || g++ -O2 -fPIC $QT5_CFLAGS -o CodeGen YapCodeGen.cpp $QT5_LIBS
  ./CodeGen server Browser BrowserYapCommandMessages.defs >/dev/null
  ./CodeGen client Browser BrowserYapCommandMessages.defs >/dev/null
  cp Browser{Server,Client}Base.{h,cpp} "$SRC/" )

echo "== 3. compile Src/*.cpp (QtWebKit-only units excluded) + Yap/*.cpp =="
EXCLUDE="BackupManager BrowserComboBox WebKitEventListener WebOSPlatformPlugin qwebkitplatformplugin"
for cpp in "$SRC"/*.cpp; do
  n=$(basename "$cpp" .cpp)
  case " $EXCLUDE " in *" $n "*) continue;; esac
  case "$n" in *.moc) continue;; esac
  "$CXX" $ARCH $STD $DEF $INC -c "$cpp" -o "$OBJ/$n.o"
done
for cpp in "$BS"/Yap/*.cpp; do
  n=$(basename "$cpp" .cpp)
  extra=""; [ "$n" = OffscreenBuffer ] && extra="-I$S/libpng16"    # OffscreenBuffer uses libpng
  "$CXX" $ARCH $STD $DEF $INC $extra -c "$cpp" -o "$OBJ/yap_$n.o"
done
echo "   compiled $(ls "$OBJ"/*.o | wc -l) objects"

echo "== 4. link BrowserServer-atlas (bundled ld-linux + rpath; toolchain provides libc via linklib) =="
# NOTE: --unresolved-symbols=ignore-in-object-files tolerates the still-unfinished QtWebKit hit-test/
# settings stubs (BrowserPageWPE.h hitTest() returns {} — "QtWebKit link TBD" upstream). Those symbols
# are never reached by a page load. Drop this flag once the de-QtWebKit work upstream is complete.
"$CXX" -o "$OBJ/BrowserServer-atlas" "$OBJ"/*.o \
  -Wl,--dynamic-linker="$DR/wpe-252/lib/ld-linux.so.3" \
  -Wl,-rpath="$DR/wpe-252/lib:$DR/atlas:/usr/lib:/lib" \
  -L"$LL" -lWPEWebKit-2.0 -lwpe-1.0 -lWPEBackend-atlas \
  -lglib-2.0 -lgobject-2.0 -lgio-2.0 -lgthread-2.0 -lpng16 \
  -lQtCore -lQtGui -lQtNetwork \
  -lssl -lcrypto -llunaservice -lpbnjson_cpp -lpbnjson_c -lyajl -luriparser \
  -lcjson -lmjson -laffinity -lmemchute -lPmCertificateMgr -leventreporter -lpthread -lrt -ldl \
  -Wl,-rpath-link,"$LL" -Wl,-rpath-link,"$RL/usr/lib" -Wl,-rpath-link,"$RL/lib" -Wl,-rpath-link,"$RL/usr/lib/ssl11" \
  -Wl,--unresolved-symbols=ignore-in-object-files
echo "== built: $OBJ/BrowserServer-atlas  ($(du -h "$OBJ/BrowserServer-atlas"|cut -f1)) =="
