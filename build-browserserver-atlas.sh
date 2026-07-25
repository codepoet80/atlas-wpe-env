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
# WebKitSupplemental/misc: Settings.cpp calls webOS::WebSettings::initSettings()/initWebSettings()/
# stringToBytes(). Upstream builds these from WebKitSupplemental (misc.pro) and links them in. They are
# NOT part of BrowserServer/Src, so they must be compiled here explicitly — otherwise InitSettings()
# calls a NULL address and BrowserServer SIGSEGVs on startup before writing a single log line.
# These need two deviations from $DEF/$INC:
#   - NO -DQT_NO_KEYWORDS: upstream uses Qt's `foreach` keyword.
#   - wpe-shims FIRST on the include path: it supplies a no-op QtWebKit <qwebsettings.h> so the
#     QtWebKit-only initWebSettings() compiles without stock QtWebKit (which lacks Palm's
#     setPluginSupplementalPath/FullScreenEnabled) and without linking libQtWebKit. See that header.
WKS_DEF="-DNDEBUG -D_GLIBCXX_USE_CXX11_ABI=0 -DUSE_LUNA_SERVICE -DATLAS_LUNA"
for n in weboswebsettings webosmisc; do
  cpp="$REPOS/WebKitSupplemental/misc/$n.cpp"
  [ -f "$cpp" ] || { echo "   MISSING $cpp (clone isis-project/WebKitSupplemental)" >&2; exit 1; }
  "$CXX" $ARCH $STD $WKS_DEF -I"$SCRIPT_DIR/wpe-shims" $INC -c "$cpp" -o "$OBJ/wks_$n.o"
done
echo "   compiled $(ls "$OBJ"/*.o | wc -l) objects"

echo "== 4. link BrowserServer-atlas (bundled ld-linux + rpath; toolchain provides libc via linklib) =="
# DANGER: --unresolved-symbols=ignore-in-object-files makes every unresolved call link to ADDRESS 0.
# It does not fail the build — it produces a binary that SIGSEGVs (`blx 0`) the moment such a call is
# reached. It is here only to tolerate the still-unfinished QtWebKit hit-test stubs (BrowserPageWPE.h
# hitTest() returns {} — "QtWebKit link TBD" upstream), which no page load reaches. Step 5 below
# enforces that nothing ELSE picks up a null call. Drop the flag once upstream finishes de-QtWebKit'ing.
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
echo "== 5. null-call guard =="
# Every `blx 0` is an unresolved symbol that will SIGSEGV when reached, so NONE are tolerated. This exact class of bug shipped once: Settings.cpp calls
# webOS::WebSettings::initSettings(), WebKitSupplemental/misc was never compiled in, and BrowserServer
# SIGSEGV'd inside InitSettings() on startup with an empty log.
# Was four QtWebKit hit-test/cache stubs; all now have real WPE implementations or fail safe, so the
# allowlist is EMPTY and any null call at all fails the build.
ALLOWED_NULLCALL=''
BAD=$("${OBJDUMP:-$TARGET-objdump}" -d "$OBJ/BrowserServer-atlas" 2>/dev/null | awk '
  /^[0-9a-f]+ </ { fn=$2; gsub(/[<>:]/,"",fn) }
  /blx?\t0 </    { print fn }' | sort -u | grep -vxF "$ALLOWED_NULLCALL" || true)
if [ -n "$BAD" ]; then
  echo "   !! FATAL: calls to address 0 (unresolved symbols) in unexpected functions:" >&2
  echo "$BAD" | sed 's/^/      /' >&2
  echo "   !! These WILL SIGSEGV at runtime. A source file or -l library is missing from this script." >&2
  exit 1
fi
echo "   OK — no calls to address 0"

echo "== built: $OBJ/BrowserServer-atlas  ($(du -h "$OBJ/BrowserServer-atlas"|cut -f1)) =="
