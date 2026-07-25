#!/bin/bash
# Build a complete, installable Atlas Web ipk from this checkout — portable reproduction of
# full-restore-atlas.sh + build-ipk.sh, without the dependency on Herrie's private tree
# ($WPE/env-glibc-gcc125.sh, staging-glibc-252, the wpewebkit _b build dir, camera-path-a).
#
#   source env-atlas-cross.sh
#   ./build-ipk-atlas.sh                 # -> $OUT/org.webosports.app.atlas_<ver>_all.ipk
#   DOSTRIP=0 ./build-ipk-atlas.sh       # keep symbols (bigger ipk, for gdb)
#
# WHAT COMES FROM WHERE  (see BUILDING.md §7):
#   built from source here .. BrowserServer-atlas, libWPEBackend-atlas.so
#   this repo ............... boot wrapper, NPAPI adapter, upstart jobs, ls2 roles, sensord, qspkd,
#                             postinst/prerm
#   atlas-browser-app ....... the Enyo front-end (appinfo/index/source/css/images/db)
#   reference deviceroot .... the WPE WebKit runtime (libWPEWebKit, WPEWebProcess/WPENetworkProcess,
#                             injected bundle), GStreamer stack, glibc-2.23 runtime, share/, webkit-data,
#                             fonts.conf/gstomx.conf, qcamd/qmicd
#
# The reference deviceroot is the engine runtime we have NOT yet rebuilt from source (WPE WebKit itself is
# a separate ~40 min build — build-webkit-252.sh). $DEVICEROOT_REF defaults to a tree pulled off a working
# device; keep that tarball, it is also your rollback artifact.
set -eu

ENV_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOS="${REPOS:-$(dirname "$ENV_DIR")}"
APPSRC="${APPSRC:-$REPOS/atlas-browser-app}"
BLD="${BLD:-$REPOS/browserserver-build}"
BACKEND="${BACKEND:-$REPOS/atlas-wpe-backend/libWPEBackend-atlas.so}"
DEVICEROOT_REF="${DEVICEROOT_REF:-$HOME/atlas-device-backup/ref/org.webosports.app.atlas/deviceroot}"
OUT="${OUT:-$HOME/atlas-ipk}"
DOSTRIP="${DOSTRIP:-1}"
APPNAME=org.webosports.app.atlas
CRYPTO_DR="/media/cryptofs/apps/usr/palm/applications/$APPNAME/deviceroot"

die(){ echo "build-ipk-atlas: $*" >&2; exit 1; }
need(){ [ -e "$1" ] || die "missing $2: $1"; }

: "${TARGET:=arm-cortex_a8-linux-gnueabi}"
STRIP_BIN="${STRIP:-$TARGET-strip}"

need "$APPSRC/appinfo.json"                  "app front-end (set APPSRC=)"
need "$BLD/obj/BrowserServer-atlas"          "BrowserServer build (run build-browserserver-atlas.sh)"
need "$BACKEND"                              "backend .so (run build-backend-atlas.sh)"
need "$DEVICEROOT_REF/wpe-252/lib"           "reference deviceroot (set DEVICEROOT_REF=)"
need "$DEVICEROOT_REF/wpe-252/libexec/wpe-webkit-2.0/WPEWebProcess" "WPEWebProcess in reference deviceroot"

VER=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$APPSRC/appinfo.json" \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
: "${VER:=0.9.0}"

WORKROOT=$(mktemp -d); trap 'rm -rf "$WORKROOT"' EXIT
APP="$WORKROOT/usr/palm/applications/$APPNAME"
D="$APP/deviceroot/wpe-252"; A="$APP/deviceroot/atlas"
mkdir -p "$APP" "$OUT"

echo "=== 1. app front-end from source ($APPSRC) ==="
for item in appinfo.json css db depends.js index.html source images \
            icon-1024x1024.png icon-256x256.png icon-48x48.png icon-64x64.png icon.png; do
  [ -e "$APPSRC/$item" ] && cp -a "$APPSRC/$item" "$APP/"
done
need "$APP/db/kinds" "db kinds (postinst registers them)"

echo "=== 2. engine deviceroot from reference ($DEVICEROOT_REF) ==="
cp -a "$DEVICEROOT_REF/." "$APP/deviceroot/"
rm -rf "$APP/faviconcache"                                    # runtime cruft, never ship it
rm -f  "$D/libexec/gstreamer-1.0/gst-plugin-scanner.pre-rpath.bak"
rm -rf "$D/libexec/wpe-webkit-1.0"                            # legacy WPE 1.0 API — engine uses 2.0

echo "=== 3. overlay the components built from source here ==="
cp -f "$BLD/obj/BrowserServer-atlas" "$D/BrowserServer-atlas"
cp -f "$BACKEND"                     "$D/lib/libWPEBackend-atlas.so"
echo "   BrowserServer-atlas  $(stat -c%s "$D/BrowserServer-atlas") bytes"
echo "   libWPEBackend-atlas.so $(stat -c%s "$D/lib/libWPEBackend-atlas.so") bytes"

echo "=== 4. overlay artifacts committed in this repo ==="
cp -f "$ENV_DIR/ipk-build/pull/wrapper-BrowserServer" "$A/BrowserServer"   # upstart execs ./BrowserServer
mkdir -p "$APP/deviceroot/BrowserPlugins" "$APP/deviceroot/event.d" "$APP/deviceroot/ls2-roles"
cp -f "$ENV_DIR/ipk-build/pull/BrowserAdapterAtlas.so" "$APP/deviceroot/BrowserPlugins/"
cp -f "$ENV_DIR/ipk-build/pull/upstart-atlas"          "$APP/deviceroot/event.d/atlas"
cp -f "$ENV_DIR/ipk-build/pull/upstart-atlas-sensord"  "$APP/deviceroot/event.d/atlas-sensord"
cp -f "$ENV_DIR/roles/org.webosports.browserserver.json" "$APP/deviceroot/ls2-roles/"
cp -f "$ENV_DIR/roles/org.webosports.qmicd.json"         "$APP/deviceroot/ls2-roles/"
[ -f "$ENV_DIR/sensord/atlas-sensord" ] && cp -f "$ENV_DIR/sensord/atlas-sensord" "$A/atlas-sensord"
[ -f "$ENV_DIR/spk/qspkd" ]             && cp -f "$ENV_DIR/spk/qspkd" "$A/qspkd"
[ -f "$ENV_DIR/spk/libgstatlasqspksink.so" ] && \
  cp -f "$ENV_DIR/spk/libgstatlasqspksink.so" "$D/lib/gstreamer-1.0/libgstatlasqspksink.so"
[ -f "$ENV_DIR/mic/msm_media_case" ]    && cp -f "$ENV_DIR/mic/msm_media_case" "$APP/deviceroot/msm_media_case"
chmod 755 "$D/BrowserServer-atlas" "$A/BrowserServer" 2>/dev/null || true
chmod 755 "$A"/qcamd "$A"/qmicd "$A"/qspkd "$A"/atlas-sensord 2>/dev/null || true

echo "=== 5. sanity guards (fail loud rather than ship a broken browser) ==="
# The engine links versioned GPU sonames; postinst copies the device's real Adreno driver over these.
for f in "$D/lib/libWPEWebKit-2.0.so.1" "$D/libexec/wpe-webkit-2.0/WPEWebProcess" \
         "$D/libexec/wpe-webkit-2.0/WPENetworkProcess" "$D/lib/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so"; do
  need "$f" "engine runtime file"
done
# Adreno-220 WebGL fix (ANGLE dlopen("libGLESv2.so") fallback). Without it every WebGL page SIGSEGVs.
strings -a "$D/lib/libWPEWebKit-2.0.so.1" 2>/dev/null | grep -qx 'libGLESv2\.so' \
  || die "libWPEWebKit LACKS the Adreno WebGL fix (wpe-2.52.4-atlas-webgl-angle-fixes.patch) — stale runtime"
# WebRTC transport+media; a gap here ships a browser stuck on "Local Preview only".
miss=""
for p in libgstwebrtc.so libgstnice.so libgstdtls.so libgstsrtp.so libgstsctp.so libgstrtpmanager.so \
         libgstrtp.so libgstvpx.so libgstopus.so libgstogg.so libgstvorbis.so; do
  [ -f "$D/lib/gstreamer-1.0/$p" ] || miss="$miss $p"
done
[ -z "$miss" ] || die "WebRTC/codec plugins missing from the reference deviceroot:$miss"
# GIO content-type db — without mime.cache WebKit DOWNLOADS local html instead of rendering it.
[ -f "$D/share/mime/mime.cache" ] || echo "   WARN: no share/mime/mime.cache — file:// html may download"
# Our BrowserServer must already carry the bundled loader + device rpath (the build script links it so).
readelf -p .interp "$D/BrowserServer-atlas" 2>/dev/null | grep -q "wpe-252/lib/ld-linux.so.3" \
  || die "BrowserServer-atlas is not linked against the bundled loader"
echo "   guards passed"

if [ "$DOSTRIP" = 1 ]; then
  echo "=== 6. strip the engine (DOSTRIP=0 to keep symbols) ==="
  # qcamd/qmicd/qspkd/atlas-sensord run under the SYSTEM glibc — leave them alone.
  find "$D/lib" "$D/libexec" -type f -name '*.so*' -exec "$STRIP_BIN" {} + 2>/dev/null || true
  "$STRIP_BIN" "$D/libexec/wpe-webkit-2.0/WPEWebProcess" \
               "$D/libexec/wpe-webkit-2.0/WPENetworkProcess" \
               "$D/BrowserServer-atlas" 2>/dev/null || true
fi

echo "=== 7. data.tar.gz ==="
INSTALLED_KB=$(du -sk "$WORKROOT/usr" | awk '{print $1}')
( cd "$WORKROOT" && tar czf "$OUT/data.tar.gz" --owner=0 --group=0 ./usr )

echo "=== 8. control.tar.gz ==="
CTRL="$WORKROOT/CONTROL"; mkdir -p "$CTRL"
cat > "$CTRL/control" <<EOF
Package: $APPNAME
Version: $VER
Section: misc
Priority: optional
Architecture: all
Installed-Size: $INSTALLED_KB
Maintainer: WebOS Ports <webos-ports@googlegroups.com>
Description: Atlas Web — WPE WebKit 2.52 browser for webOS (HP TouchPad).
webOS-Package-Format-Version: 2
webOS-Packager-Version: 3.0.5b38
EOF
cp "$ENV_DIR/ipk-postinst.sh" "$CTRL/postinst"; chmod 755 "$CTRL/postinst"
cp "$ENV_DIR/ipk-prerm.sh"    "$CTRL/prerm";    chmod 755 "$CTRL/prerm"
( cd "$CTRL" && tar czf "$OUT/control.tar.gz" --owner=0 --group=0 ./control ./postinst ./prerm )

echo "=== 9. ar the ipk ==="
IPK="$OUT/${APPNAME}_${VER}_all.ipk"
printf '2.0\n' > "$OUT/debian-binary"
rm -f "$IPK"
( cd "$OUT" && ar rc "$(basename "$IPK")" debian-binary control.tar.gz data.tar.gz )
rm -f "$OUT/debian-binary" "$OUT/control.tar.gz" "$OUT/data.tar.gz"

echo "== built: $IPK  ($(du -h "$IPK" | cut -f1), installed ~$((INSTALLED_KB/1024)) MB, v$VER) =="
echo "   install via Preware / WebOS Quick Install (postinst must run as root)."
