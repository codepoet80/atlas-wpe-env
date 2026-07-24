#!/bin/bash
# Build libWPEBackend-atlas.so from atlas-wpe-backend/wpe-atlas-backend.c, portably.
# Reproducible companion to the upstream build.sh (which hard-codes $WPE paths + needs pkg-config).
#
#   source env-atlas-cross.sh      # sets CC / arch flags / STAGING (or export TOOLCHAIN=/STAGING=)
#   BACKEND_SRC=~/Projects/atlas-wpe-backend  ./build-backend-atlas.sh
#
# Needs in $STAGING: lib/ (device-pulled sonames + dev symlinks), include/{glib-2.0,wpe-1.0,EGL,GLES2,KHR},
# lib/glib-2.0/include/glibconfig.h.  See BUILDING.md §3.
set -eu
: "${STAGING:?source env-atlas-cross.sh first (STAGING unset)}"
: "${CC:=arm-cortex_a8-linux-gnueabi-gcc}"
BACKEND_SRC="${BACKEND_SRC:-$(cd "$(dirname "$0")/../atlas-wpe-backend" 2>/dev/null && pwd)}"
OUT="${OUT:-$BACKEND_SRC/libWPEBackend-atlas.so}"
ARCH="-march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp -mthumb"
INC="-I$STAGING/include/glib-2.0 -I$STAGING/lib/glib-2.0/include -I$STAGING/include/wpe-1.0 -I$STAGING/include"

echo "== building libWPEBackend-atlas.so =="
"$CC" $ARCH -std=gnu11 -fPIC -fvisibility=hidden -O2 -Wall $INC \
  -shared -Wl,-soname,libWPEBackend-atlas.so \
  -o "$OUT" "$BACKEND_SRC/wpe-atlas-backend.c" \
  -L"$STAGING/lib" -lwpe-1.0 -lglib-2.0 -lEGL -lGLESv2 -Wl,-rpath-link,"$STAGING/lib"

# The device deploys the Adreno driver as libEGL.so.1 / libGLESv2.so.2, but the driver's own SONAME is
# unversioned (libEGL.so) — so fix NEEDED to the versioned names the device actually provides.
patchelf --replace-needed libEGL.so    libEGL.so.1    "$OUT"
patchelf --replace-needed libGLESv2.so libGLESv2.so.2 "$OUT"

echo "== built: $OUT =="
"${TARGET:-arm-cortex_a8-linux-gnueabi}-readelf" -d "$OUT" | grep NEEDED | grep -oE '\[.*\]' | tr '\n' ' '; echo
echo "  exports _wpe_loader_interface: $(${TARGET:-arm-cortex_a8-linux-gnueabi}-nm -D "$OUT" | grep -c _wpe_loader_interface)"
