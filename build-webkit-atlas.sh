#!/bin/bash
# Cross-build WPE WebKit 2.52.4 for the Atlas engine.
#
#   source env-atlas-cross.sh
#   source hosttools-env.sh                  # ruby + unifdef (see stage-hosttools-atlas.sh)
#   ./apply-webkit-patches.sh                # extract + patch the tree first
#   ./build-webkit-atlas.sh configure
#   ./build-webkit-atlas.sh build            # long: ~1-2 h on 12 cores
#
# The feature set below is NOT guesswork and NOT the old build-webkit-252.sh (which disables video,
# GStreamer, WebRTC and WebGL - that was an experiment, not what shipped). It is derived from the
# SHIPPED libWPEWebKit-2.0.so.1: its 65 NEEDED libraries include the full GStreamer stack, flite,
# libepoxy, avif/jxl/webp, woff2 and cairo, and its symbol table shows DFG JIT (343 refs, zero CLoop),
# WebGL/WebGL2, MediaStream, RTCPeerConnection, SpeechSynthesis, WebAssembly, Gamepad and
# PaymentRequest - but no ServiceWorker, WebDriver or EncryptedMedia.
#
# Overridable: WK_SRC, STAGING, PREFIX, JOBS.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOS="${REPOS:-$(dirname "$SCRIPT_DIR")}"
WK_SRC="${WK_SRC:-$REPOS/webkit-build}"
V=2.52.4
TREE="$WK_SRC/wpewebkit-$V"
BUILD="$TREE/_b"
STAGING="${STAGING:-$HOME/atlas-staging}"
JOBS="${JOBS:-$(nproc)}"
LOGDIR="${LOGDIR:-$WK_SRC/logs}"; mkdir -p "$LOGDIR"

# Install prefix is the DEVICE path, so WebKit bakes correct PKGLIBEXECDIR/PKGLIBDIR at build time and
# no binary prefix-patching is needed afterwards. /var/atlas252 is the short symlink that ipk-postinst.sh
# creates pointing at the cryptofs deviceroot (the real cryptofs path is too long to patch in place).
PREFIX="${PREFIX:-/var/atlas252}"
DESTROOT="${DESTROOT:-$WK_SRC/destroot}"

die(){ echo "build-webkit-atlas: $*" >&2; exit 1; }
[ -d "$TREE/Source" ] || die "no patched tree at $TREE — run apply-webkit-patches.sh first"
command -v ruby    >/dev/null || die "ruby not on PATH — source hosttools-env.sh"
command -v unifdef >/dev/null || die "unifdef not on PATH — source hosttools-env.sh"
[ -d "$STAGING/webkitdeps/usr/include" ] || die "no $STAGING/webkitdeps — run stage-sysroot-atlas.sh webkit-deps"

# env-atlas-cross.sh exports CFLAGS/CXXFLAGS/LDFLAGS aimed at the BrowserServer build. CMake would
# append them to every compile and link, and -L$STAGING/lib is actively harmful here: that directory
# holds the DEVICE's libc.so, which shadows the toolchain's own and leaves __libc_csu_init/__libc_csu_fini
# undefined, so even CMake's "can the compiler build a trivial program" test fails. The toolchain file
# supplies the arch flags and the correct link paths (linklib, which excludes libc and friends).
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS

case "${1:-configure}" in
configure)
  rm -rf "$BUILD"; mkdir -p "$BUILD"; cd "$BUILD"
  set +e
  cmake .. -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$SCRIPT_DIR/cmake/atlas-arm-toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DPORT=WPE \
    -DUSE_SKIA=OFF \
    -DENABLE_WPE_LEGACY_API=ON -DUSE_LIBWPE=ON \
    -DUSE_GBM=OFF -DUSE_LIBDRM=OFF -DENABLE_GPU_PROCESS=OFF \
    -DENABLE_C_LOOP=OFF -DENABLE_JIT=ON -DENABLE_DFG_JIT=ON -DENABLE_FTL_JIT=OFF \
    -DENABLE_WEBASSEMBLY=ON -DENABLE_SAMPLING_PROFILER=OFF \
    -DENABLE_VIDEO=ON -DENABLE_WEB_AUDIO=ON -DENABLE_MEDIA_SOURCE=ON \
    -DENABLE_MEDIA_STREAM=ON -DENABLE_WEB_RTC=ON -DUSE_GSTREAMER_WEBRTC=ON \
    -DUSE_GSTREAMER=ON -DUSE_GSTREAMER_GL=OFF \
    -DENABLE_WEBGL=ON -DENABLE_WEBGL2=ON \
    -DENABLE_SPEECH_SYNTHESIS=ON \
    -DUSE_WOFF2=ON -DUSE_AVIF=ON -DUSE_JPEGXL=ON -DUSE_LCMS=OFF -DUSE_OPENJPEG=OFF \
    -DENABLE_GAMEPAD=ON -DENABLE_PAYMENT_REQUEST=ON -DENABLE_OFFSCREEN_CANVAS=ON \
    -DENABLE_SERVICE_WORKER=OFF -DENABLE_WEBDRIVER=OFF -DENABLE_ENCRYPTED_MEDIA=OFF \
    -DENABLE_THUNDER=OFF -DENABLE_WEBXR=OFF -DENABLE_MINIBROWSER=OFF \
    -DENABLE_INTROSPECTION=OFF -DENABLE_DOCUMENTATION=OFF -DENABLE_API_TESTS=OFF \
    -DENABLE_BUBBLEWRAP_SANDBOX=OFF -DENABLE_JOURNALD_LOG=OFF -DUSE_SYSTEMD=OFF \
    -DENABLE_SPELLCHECK=OFF -DUSE_ATK=OFF -DENABLE_ACCESSIBILITY=OFF \
    -DUSE_LIBHYPHEN=OFF -DUSE_LIBBACKTRACE=OFF -DUSE_SYSTEM_SYSPROF_CAPTURE=OFF \
    -DENABLE_WEB_CRYPTO=ON \
    > "$LOGDIR/configure.log" 2>&1
  rc=$?
  set -e
  echo "== cmake configure rc=$rc  (log: $LOGDIR/configure.log) =="
  [ "$rc" = 0 ] || { grep -E "CMake Error|Could NOT find|error:" "$LOGDIR/configure.log" | head -30; exit $rc; }
  grep -E "Could NOT find|-- Performing" "$LOGDIR/configure.log" | grep -i "could not" | head -20 || true
  ;;
build)
  [ -d "$BUILD" ] || die "not configured — run '$0 configure' first"
  # Refuse to start on top of a running build. Two ninjas sharing one log interleave their writes at
  # independent file offsets, which produces a log full of NUL padding where the errors should be and
  # makes a live build look like a mysterious failure.
  if pgrep -x ninja >/dev/null 2>&1; then
    die "a ninja is already running — wait for it, or stop it first (pgrep -x ninja)"
  fi
  cd "$BUILD"
  LOG="$LOGDIR/build.log"
  [ -e "$LOG" ] && mv -f "$LOG" "$LOG.prev"     # keep the previous run instead of clobbering it
  echo "== ninja -j$JOBS  (log: $LOG) =="
  set +e
  nice -n 10 ninja -j"$JOBS" > "$LOG" 2>&1
  rc=$?
  set -e
  echo "== ninja rc=$rc =="
  [ "$rc" = 0 ] || { grep -E "error:|FAILED" "$LOG" | head -30; exit $rc; }
  rm -rf "$DESTROOT"
  DESTDIR="$DESTROOT" ninja install >> "$LOG" 2>&1
  echo "== installed into $DESTROOT$PREFIX =="
  ls -la "$DESTROOT$PREFIX/lib/" 2>/dev/null | head
  ;;
*) die "usage: $(basename "$0") [configure|build]";;
esac
