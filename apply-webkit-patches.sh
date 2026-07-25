#!/bin/bash
# Extract WPE WebKit 2.52.4 and apply the Atlas patch series, in order.
#
#   WK_SRC=~/Projects/webkit-build ./apply-webkit-patches.sh          # extract + patch
#   ./apply-webkit-patches.sh --verify                                # patch a throwaway tree, report, delete
#
# ORDER MATTERS. Several patches touch the same files and were authored on top of each other:
#   - mediastream-camera depends on mdpdetile-videosink (same block in MediaPlayerPrivateGStreamer.cpp)
#   - webrtc-mono-opus  depends on webrtc-receive-av    (same block in GStreamerMediaEndpoint.cpp)
# Applying them in tarball/alphabetical order fails. The list below is the working order.
#
# Overridable: WK_SRC (build root), TARBALL, REPOS.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOS="${REPOS:-$(dirname "$SCRIPT_DIR")}"
WK_SRC="${WK_SRC:-$REPOS/webkit-build}"
V=2.52.4
TARBALL="${TARBALL:-$HOME/webos/wpe/build/wpewebkit-$V.tar.xz}"
BK="$REPOS/atlas-wpe-backend/patches"

SERIES="
$BK/wpewebkit-$V-softfp-jit.patch
$BK/wpewebkit-$V-memorypressuremonitor-2.6.35.patch
$BK/wpewebkit-$V-audio-autoplay-toggle.patch
$BK/wpewebkit-$V-mdpdetile-videosink.patch
$BK/wpewebkit-$V-webrtc-receive-av.patch
$BK/wpewebkit-$V-wma-wmv-canplaytype.patch
$SCRIPT_DIR/wpe-$V-atlas-flite-speech-fixes.patch
$SCRIPT_DIR/wpe-$V-atlas-fullscreen-fixes.patch
$SCRIPT_DIR/wpe-$V-atlas-webgl-angle-fixes.patch
$SCRIPT_DIR/wpe-$V-atlas-webrtc-getstats-fix.patch
$SCRIPT_DIR/wpe-$V-atlas-webrtc-sendpath-ssrc.patch
$SCRIPT_DIR/wpe-$V-atlas-webrtc-mono-opus.patch
$SCRIPT_DIR/wpe-$V-atlas-mediastream-camera.patch
$SCRIPT_DIR/wpe-$V-atlas-sysprof-oldkernel-fcntl.patch
$SCRIPT_DIR/wpe-$V-atlas-glibc223-roundeven.patch
$SCRIPT_DIR/wpe-$V-atlas-webrtc-ssrc-accessor.patch
$SCRIPT_DIR/wpe-$V-atlas-paymentrequest-gcc12.patch
$SCRIPT_DIR/wpe-$V-atlas-icb-height-cap.patch
"

die(){ echo "apply-webkit-patches: $*" >&2; exit 1; }
[ -f "$TARBALL" ] || die "source tarball not found: $TARBALL (set TARBALL=)"

if [ "${1:-}" = "--verify" ]; then
  WK_SRC=$(mktemp -d); trap 'rm -rf "$WK_SRC"' EXIT
  echo "== verify mode: patching a throwaway tree in $WK_SRC =="
fi

mkdir -p "$WK_SRC"
TREE="$WK_SRC/wpewebkit-$V"
if [ ! -d "$TREE/Source" ]; then
  echo "== extracting $(basename "$TARBALL") =="
  tar xJf "$TARBALL" -C "$WK_SRC"
else
  echo "== tree already extracted at $TREE (delete it to start clean) =="
fi

echo "== applying the Atlas patch series =="
fail=0
cd "$TREE"
for p in $SERIES; do
  n=$(basename "$p")
  [ -f "$p" ] || { echo "   MISSING  $n"; fail=1; continue; }
  # --forward makes re-runs idempotent: an already-applied patch is skipped, not reversed.
  out=$(patch -p1 --forward < "$p" 2>&1) || true
  if echo "$out" | grep -q "FAILED"; then
    echo "   FAILED   $n"; echo "$out" | grep -E "FAILED|Hunk" | sed 's/^/            /'; fail=1
  elif echo "$out" | grep -q "previously applied\|Skipping patch"; then
    echo "   already  $n"
  else
    echo "   applied  $n"
  fi
done

[ "$fail" = 0 ] || die "patch series did not apply cleanly"
find "$TREE" -name '*.rej' -delete 2>/dev/null || true
find "$TREE" -name '*.orig' -delete 2>/dev/null || true
echo "== patch series applied cleanly -> $TREE =="
