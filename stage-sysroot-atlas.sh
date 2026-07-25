#!/bin/bash
# Assemble the Atlas cross-build staging sysroot from scratch.
#
# The sysroot ($STAGING, default ~/atlas-staging) is what env-atlas-cross.sh points the compiler at.
# It has four parts, each built by a subcommand below:
#
#   include/   dev headers   <- pinned Debian armhf dev debs (extracted, never installed) + host
#                               Khronos/zlib headers + libwpe git + this repo's reconstructed-headers
#   lib/       link libs     <- pulled off a running device (deviceroot/wpe-252/lib) + dev symlinks
#   rootfs/    -rpath-link   <- pulled off a running device (/usr/lib + /lib)
#   linklib/   link path     <- symlinks to lib/, MINUS the libs the toolchain provides (see `linklib`)
#
# Usage:
#   ./stage-sysroot-atlas.sh headers    # network only, no device needed
#   ./stage-sysroot-atlas.sh device     # needs a TouchPad running Atlas, over novacom
#   ./stage-sysroot-atlas.sh linklib    # derives linklib/ + dev symlinks from lib/ (run after `device`)
#   ./stage-sysroot-atlas.sh webkit-deps # dev headers + .pc for building WebKit itself (network)
#   ./stage-sysroot-atlas.sh all        # headers + device + linklib
#   ./stage-sysroot-atlas.sh everything # ... plus webkit-deps
#
# Overridable:
#   STAGING     sysroot to build            (default $HOME/atlas-staging)
#   REPOS       where the source repos live (default $HOME/Projects) — used to generate PmLogLib.h
#   DEB_CACHE   downloaded .deb cache       (default $STAGING/.deb-cache)
#   CRYPTO_DR   device deviceroot path
#   LIBWPE_TAG  libwpe release to take headers from (default 1.16.0; the 1.x API is stable)
#
# Why Debian armhf debs: we need headers matching the ARM ABI and the engine's library versions, without
# polluting the host. `dpkg-deb -x` extracts without installing. Every deb is pinned by content hash and
# fetched from snapshot.debian.org, which keeps every version forever (the regular pool 404s as sid moves).
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STAGING="${STAGING:-$HOME/atlas-staging}"
REPOS="${REPOS:-$HOME/Projects}"
DEB_CACHE="${DEB_CACHE:-$STAGING/.deb-cache}"
CRYPTO_DR="${CRYPTO_DR:-/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot}"
LIBWPE_TAG="${LIBWPE_TAG:-1.16.0}"
SNAPSHOT="${SNAPSHOT:-https://snapshot.debian.org/file}"

# Pinned dev debs:  <local name>|<sha1 = snapshot.debian.org id>|<sha256 = integrity check>
# sha1 doubles as the permanent URL; sha256 is verified after download.
DEBS="
libglib2.0-dev_2.74.6-2+deb12u9_armhf.deb|7cecdae21513173ee6a7fd20d8ba64045582c48b|c40d2bbff2f758a39ef2432468146b7e29af36e3cde349577e6e229a085fd752
libpng12-dev_1.2.50-2+deb8u3_armhf.deb|16285d417bb5e41ca681140468e37803df1460be|bf3465e1455f66980f102f45742066c6e391386dec52404d9d91202ca2b2712b
libpng-dev_1.6.58-1_armhf.deb|4dc2b8a0427f1d6cb6ac002b54ff171f3f16c015|f849867fc46d8be2a97346348e30e05094e04f6075d8c9becece4d35ade02261
libqt4-dev_4.8.7+dfsg-18+deb10u1_armhf.deb|860a2f70355efac55065c509da47d4af8c6ada6e|fe6f7b5f07ea5c8f1d258da7b7aa7bf63b5584758f5073072fadd143f763f8a8
libqtwebkit-dev_2.3.4.dfsg-10_armhf.deb|ba8a045e327ad1cf3783aa702998a05091e06312|5ba55b9178bcbbdaa98b7d4c34c2cb0c1f3bdbc519b28279906e3672d03558a3
libsoup-3.0-dev_3.6.6-1_armhf.deb|88f89c3558ec54c0f4e89db9a93e71c5b4ae2322|b152159896473f5a32e881fd42f2f0b697203e538e28f2e0e3047d8082d734f4
libssl-dev_3.6.3-1_armhf.deb|284c9e64d4fe8b4a45606f2415832a3a88e7c9eb|d49e30ee3ae583d5b91f3762ee691e4a922e08308d5456540e9d4cdb3b116a96
libwpewebkit-2.0-dev_2.52.5-1_armhf.deb|701c928fcd0df7a16d520d5271d8b7f3e372a0a7|39ea72ee383da0f6f2660d1e7ab50ec66cfb232cf08f315660ce0f19238a97b2
"

die(){ echo "stage-sysroot: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------------
# headers
# ---------------------------------------------------------------------------------------------------
fetch_debs(){
  mkdir -p "$DEB_CACHE"
  for row in $DEBS; do
    IFS='|' read -r name sha1 sha256 <<<"$row"
    local f="$DEB_CACHE/$name"
    if [ -f "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$sha256" ]; then
      echo "   cached  $name"; continue
    fi
    echo "   fetch   $name"
    curl -fsSL --retry 3 -o "$f.part" "$SNAPSHOT/$sha1" || die "download failed: $name"
    [ "$(sha256sum "$f.part" | cut -d' ' -f1)" = "$sha256" ] || die "sha256 MISMATCH for $name (refusing)"
    mv "$f.part" "$f"
  done
}

# extract a cached deb into $DEB_CACHE/x/<stem> (idempotent)
unpack(){
  local stem="$1" d="$DEB_CACHE/x/$1"
  [ -d "$d" ] && { echo "$d"; return; }
  mkdir -p "$d"
  dpkg-deb -x "$DEB_CACHE"/"$stem"_*.deb "$d" || die "dpkg-deb -x failed: $stem"
  echo "$d"
}

do_headers(){
  local I="$STAGING/include"
  mkdir -p "$I"
  echo "== headers: fetch pinned Debian armhf dev debs =="
  fetch_debs

  echo "== headers: extract + place =="
  local wpe qt qtwk soup ssl png16 png12 glib
  wpe=$(unpack libwpewebkit-2.0-dev); qt=$(unpack libqt4-dev); qtwk=$(unpack libqtwebkit-dev)
  soup=$(unpack libsoup-3.0-dev);     ssl=$(unpack libssl-dev)
  png16=$(unpack libpng-dev);         png12=$(unpack libpng12-dev); glib=$(unpack libglib2.0-dev)

  rm -rf "$I/wpe-webkit-2.0" "$I/qt4" "$I/libsoup" "$I/openssl" "$I/libpng16" "$I/libpng12" "$I/glib-2.0"

  # WPE WebKit 2.52.5 — matches the engine's API (device ships 2.52.4; the C API is identical)
  cp -r "$wpe/usr/include/wpe-webkit-2.0" "$I/"
  # Qt 4.8.7 + QtWebKit — compile-only interface types (no Qt is linked into the WPE port)
  cp -r "$qt/usr/include/qt4" "$I/"
  cp -r "$qtwk/usr/include/qt4/QtWebKit" "$I/qt4/"
  # libsoup 3 — flattened: the build includes <libsoup/soup.h> off $STAGING/include
  cp -r "$soup/usr/include/libsoup-3.0/libsoup" "$I/"
  # OpenSSL 3 — arch-specific opensslconf.h/configuration.h overlay the generic headers
  cp -r "$ssl/usr/include/openssl" "$I/"
  cp -f "$ssl/usr/include/arm-linux-gnueabihf/openssl/"*.h "$I/openssl/"
  cp -r "$png16/usr/include/libpng16" "$I/"
  cp -r "$png12/usr/include/libpng12" "$I/"
  # glib 2.74 + the 32-bit ARM glibconfig.h (arch-dependent — must come from the armhf deb, not the host)
  cp -r "$glib/usr/include/glib-2.0" "$I/"
  mkdir -p "$STAGING/lib/glib-2.0/include"
  cp -f "$glib/usr/lib/arm-linux-gnueabihf/glib-2.0/include/glibconfig.h" "$STAGING/lib/glib-2.0/include/"

  # Khronos + zlib headers are arch-neutral -> host copies are correct
  echo "== headers: host Khronos + zlib =="
  for d in EGL GLES2 KHR; do
    [ -d "/usr/include/$d" ] || die "missing /usr/include/$d — apt-get install libegl1-mesa-dev libgles2-mesa-dev"
    rm -rf "$I/$d"; cp -r "/usr/include/$d" "$I/"
  done
  [ -f /usr/include/zlib.h ] || die "missing /usr/include/zlib.h — apt-get install zlib1g-dev"
  cp -f /usr/include/zlib.h /usr/include/zconf.h "$I/"

  # libwpe headers straight from the release tag
  echo "== headers: libwpe $LIBWPE_TAG =="
  local lw="$DEB_CACHE/libwpe-$LIBWPE_TAG"
  [ -d "$lw" ] || git -c advice.detachedHead=false clone --depth 1 --branch "$LIBWPE_TAG" -q \
      https://github.com/WebPlatformForEmbedded/libwpe "$lw" || die "libwpe clone failed"
  mkdir -p "$I/wpe-1.0/wpe"; cp -f "$lw"/include/wpe/*.h "$I/wpe-1.0/wpe/"

  # Vestigial QtWebKit types the WPE port never uses — reconstructed, vendored in this repo
  echo "== headers: reconstructed (vendored) =="
  rm -rf "$I/reconstructed"; mkdir -p "$I/reconstructed"
  cp -r "$SCRIPT_DIR/reconstructed-headers/." "$I/reconstructed/"

  # PmLogLib.h is generated from .in by PmLogLib's build; we only need the header, so expand it here.
  echo "== headers: generate PmLogLib.h =="
  local pm="$REPOS/PmLogLib/include/public"
  if [ -f "$pm/PmLogLib.h.in" ]; then
    sed 's/@PMLOG_ENABLE_LOGGING@/1/g' "$pm/PmLogLib.h.in" > "$pm/PmLogLib.h"
    echo "   wrote $pm/PmLogLib.h"
  else
    echo "   WARNING: $pm/PmLogLib.h.in not found — clone openwebos/PmLogLib into \$REPOS" >&2
  fi
  echo "== headers: done -> $I =="
}

# ---------------------------------------------------------------------------------------------------
# device  (needs a TouchPad running Atlas, reachable over novacom)
# ---------------------------------------------------------------------------------------------------
nova_pull(){   # nova_pull <device-tar-args...> -> stdout tarball ; $1 = remote tgz, rest = tar args
  local remote="$1"; shift
  novacom run file://bin/tar -- czf "$remote" "$@" >/dev/null 2>&1 || die "device tar failed ($remote)"
  novacom get "file://$remote" || die "novacom get failed ($remote)"
  novacom run file://bin/rm -- -f "$remote" >/dev/null 2>&1 || true
}

do_device(){
  command -v novacom >/dev/null || die "novacom not found — install the webOS novacom tools"
  novacom -l 2>/dev/null | grep -q . || die "no device found (novacom -l is empty) — plug in the TouchPad"
  mkdir -p "$STAGING" "$STAGING/rootfs"

  echo "== device: pull the engine runtime libs (deviceroot/wpe-252/lib) =="
  nova_pull /media/internal/atlas-wpe-lib.tgz -C "$CRYPTO_DR/wpe-252" lib > "$STAGING/.wpe-lib.tgz"
  tar xzf "$STAGING/.wpe-lib.tgz" -C "$STAGING"      # -> $STAGING/lib
  rm -f "$STAGING/.wpe-lib.tgz"

  echo "== device: pull /usr/lib + /lib for -rpath-link (~84 MB) =="
  nova_pull /media/internal/atlas-rootfs.tgz -C / usr/lib lib > "$STAGING/.rootfs.tgz"
  tar xzf "$STAGING/.rootfs.tgz" -C "$STAGING/rootfs"
  rm -f "$STAGING/.rootfs.tgz"

  echo "== device: done -> $STAGING/{lib,rootfs} =="
}

# ---------------------------------------------------------------------------------------------------
# linklib  (pure derivation from lib/ — no network, no device)
# ---------------------------------------------------------------------------------------------------
do_linklib(){
  [ -d "$STAGING/lib" ] || die "no $STAGING/lib — run the 'device' step first"

  # 1. dev symlinks: for every REAL versioned lib, add the unversioned -l<name> name.
  #    Only REAL files are candidates (so libQtCore.so lands on libQtCore.so.4.8.0, not the .so.4
  #    symlink), and the HIGHEST version wins (sort -V). That last part matters: wpe-252/lib ships both
  #    OpenSSL 1.1 and 3, and the engine's TLS stack is OpenSSL 3 — a plain glob would pick
  #    libssl.so.1.1 and silently link BrowserServer against the wrong major.
  echo "== linklib: dev symlinks (libX.so -> highest real libX.so.N) =="
  ( cd "$STAGING/lib"
    for f in *.so.*; do [ -f "$f" ] || continue; echo "${f%%.so.*}"; done | sort -u |
    while read -r base; do
      best=$(for v in "$base".so.*; do [ -f "$v" ] && echo "$v"; done | sort -V | tail -1)
      [ -n "$best" ] || continue
      # leave a real unversioned .so alone; otherwise (re)point our managed symlink
      [ -e "$base.so" ] && [ ! -L "$base.so" ] && continue
      ln -sfn "$best" "$base.so"
    done
    echo "   $(find . -maxdepth 1 -type l -name '*.so' | wc -l) unversioned names" )

  # 2. linklib/ = everything in lib/ EXCEPT what the toolchain itself provides. The device copies are
  #    glibc 2.23 too, but linking against them shadows the toolchain's startfiles and leaves
  #    __libc_csu_init undefined — so keep libc/libm/libpthread/libstdc++/loader out of the link path.
  #    NOTE: the original hand-built sysroot also had a libpng12.so entry pointed at rootfs/usr/lib.
  #    It is deliberately NOT reproduced here: nothing links -lpng12 (the builds use -lpng16).
  echo "== linklib: symlink farm (toolchain-provided libs excluded) =="
  rm -rf "$STAGING/linklib"; mkdir -p "$STAGING/linklib"
  ( cd "$STAGING/lib"
    for f in *; do
      [ -d "$f" ] && continue
      case "$f" in
        ld-linux.so*|libc.so*|libdl.so*|libgcc_s.so*|libm.so*|libpthread.so*|\
libresolv.so*|librt.so*|libstdc++.so*) continue;;
      esac
      ln -sf "../lib/$f" "$STAGING/linklib/$f"
    done )
  echo "   linklib: $(ls "$STAGING/linklib" | wc -l) entries (lib/: $(ls "$STAGING/lib" | wc -l))"
}

# ---------------------------------------------------------------------------------------------------
# webkit-deps  — headers + .pc files for building WPE WebKit itself
# ---------------------------------------------------------------------------------------------------
# Building WebKit needs dev headers and pkg-config files for ~40 libraries. We do NOT build those
# libraries: the engine links the ones the device already ships, so the headers only have to match
# their sonames. Versions are pinned in webkitdeps.list (see the notes in that file — ICU in
# particular MUST be 70.x or nothing links).
#
# An unprivileged apt root lets us pull armhf packages from three suites at once without touching
# the host system, and without hand-constructing pool URLs for 65 packages.
do_webkit_deps(){
  local WD="$STAGING/webkitdeps"
  local APTROOT="${APTROOT:-$STAGING/.apt}"
  local LIST="$SCRIPT_DIR/webkitdeps.list"
  [ -f "$LIST" ] || die "missing $LIST"
  command -v apt-get >/dev/null || die "apt-get required (Debian/Ubuntu host)"

  echo "== webkit-deps: unprivileged apt root =="
  rm -rf "$APTROOT"
  mkdir -p "$APTROOT"/{etc/apt/apt.conf.d,etc/apt/preferences.d,var/lib/apt/lists/partial,var/lib/dpkg,var/cache/apt/archives/partial}
  : > "$APTROOT/var/lib/dpkg/status"
  cat > "$APTROOT/etc/apt/sources.list" <<'EOF'
deb [arch=armhf trusted=yes] http://deb.debian.org/debian bookworm main
deb [arch=armhf trusted=yes] http://deb.debian.org/debian trixie main
deb [arch=armhf trusted=yes] http://ports.ubuntu.com/ubuntu-ports jammy main universe
EOF
  cat > "$APTROOT/etc/apt/apt.conf" <<EOF
Dir "$APTROOT";
Dir::State "$APTROOT/var/lib/apt";
Dir::State::status "$APTROOT/var/lib/dpkg/status";
Dir::Cache "$APTROOT/var/cache/apt";
Dir::Etc "$APTROOT/etc/apt";
APT::Architecture "armhf";
APT::Architectures { "armhf"; };
Acquire::Languages "none";
EOF
  export APT_CONFIG="$APTROOT/etc/apt/apt.conf"
  ( cd "$APTROOT" && apt-get update >/dev/null 2>&1 ) || die "apt-get update failed"

  echo "== webkit-deps: fetching pinned packages =="
  mkdir -p "$APTROOT/debs"
  local n=0
  while IFS='|' read -r pkgver sha; do
    case "$pkgver" in ''|'#'*) continue;; esac
    local pkg="${pkgver%%=*}"
    # apt-get download aborts the WHOLE batch on one bad name, so fetch one at a time and report.
    if ! ( cd "$APTROOT/debs" && apt-get download "$pkgver" >/dev/null 2>&1 ); then
      die "could not fetch $pkgver (archive may have superseded it; update webkitdeps.list)"
    fi
    local f; f=$(ls "$APTROOT/debs/${pkg}"_*.deb 2>/dev/null | head -1)
    [ -n "$f" ] || die "download reported success but no .deb for $pkg"
    if [ -n "$sha" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$sha" ]; then
      die "sha256 MISMATCH for $pkg (expected $sha)"
    fi
    n=$((n+1))
  done < "$LIST"
  echo "   fetched + verified $n packages"

  echo "== webkit-deps: extracting (never installing) =="
  rm -rf "$WD"; mkdir -p "$WD"
  for d in "$APTROOT"/debs/*.deb; do dpkg-deb -x "$d" "$WD"; done

  # The -dev packages ship libX.so symlinks pointing at runtime libs that live in the (uninstalled)
  # runtime packages, so every one of them dangles. Repoint each at the real library the DEVICE ships,
  # so -l resolves against the engine's actual ABI rather than a Debian build of the same library.
  echo "== webkit-deps: repointing dev symlinks at the device libraries =="
  local L="$WD/usr/lib/arm-linux-gnueabihf" fixed=0 miss=""
  for f in "$L"/*.so; do
    [ -L "$f" ] || continue
    readlink -e "$f" >/dev/null && continue
    local tgt base alt; tgt=$(readlink "$f"); base=$(basename "$f" .so)
    if [ -e "$STAGING/lib/$tgt" ]; then ln -sfn "$STAGING/lib/$tgt" "$f"; fixed=$((fixed+1))
    else
      alt=$(ls "$STAGING/lib/$base".so.* 2>/dev/null | head -1)
      if [ -n "$alt" ]; then ln -sfn "$alt" "$f"; fixed=$((fixed+1)); else miss="$miss $base"; fi
    fi
  done
  echo "   repointed $fixed;  no device lib for:$miss"
  echo "   (gstgl/opencv/va/wayland and GL/GLESv1_CM are expected here — the engine ships none of them)"
  echo "== webkit-deps: done -> $WD =="
}

case "${1:-all}" in
  headers) do_headers;;
  device)  do_device;;
  linklib)     do_linklib;;
  webkit-deps) do_webkit_deps;;
  all)         do_headers; do_device; do_linklib;;
  everything)  do_headers; do_device; do_linklib; do_webkit_deps;;
  *)       die "usage: $(basename "$0") [headers|device|linklib|webkit-deps|all|everything]";;
esac
echo "== staging sysroot ready: $STAGING =="
