# Building the Atlas WPE engine from scratch

Reproducible instructions for cross-building the Atlas browser engine (the WPE WebKit backend,
`libWPEBackend-atlas.so`, and the `BrowserServer-atlas` host) for the HP TouchPad (webOS 3.0.5),
from a clean Linux host.

> **Status legend:** ✅ verified on a clean host · 🚧 in progress / not yet re-verified end-to-end.
> This document is being filled in as the environment is reproduced; steps marked 🚧 are written from
> the build scripts and confirmed inputs but have not yet been run green start-to-finish here.

## Repositories

| Repo | Role |
|------|------|
| [`atlas-browser-app`](https://github.com/Herrie82/atlas-browser-app) | Enyo UI front-end (builds with the webOS SDK alone) |
| [`atlas-wpe-backend`](https://github.com/Herrie82/atlas-wpe-backend) | `wpe-atlas-backend.c` → `libWPEBackend-atlas.so`; `BrowserPageWPE.{cpp,h}` (merged into BrowserServer); WebKit `patches/` |
| [`BrowserServer`](https://github.com/Herrie82/BrowserServer) | base `Src/` + `Yap/` IPC that `BrowserPageWPE` merges into |
| `atlas-wpe-env` (this repo) | build scripts, the toolchain recipe, deploy/packaging |

Clone them as siblings, e.g. under `~/Projects` or `~/webos/wpe`.

## The target ABI (why a custom toolchain)

The device's *system* glibc is ancient (2.8, Sourcery 2008) and the kernel is 2.6.35, but the engine
ships and runs against its **own bundled runtime** (binaries `patchelf`'d to a bundled loader). Confirmed
off a running device, that runtime is:

- **glibc 2.23** (crosstool-NG), soft-float ABI, loader **`ld-linux.so.3`**
- **armv7-a / cortex-a8 / neon**, `-mfloat-abi=softfp -mthumb`
- gcc **12.x** (C++23 for WebKit 2.52.4; BrowserServer must share the libstdc++ ABI)

A stock modern cross-toolchain won't do: its glibc is far newer, so its binaries need GLIBC symbols the
device's 2.23 lacks. Hence we build a device-matched toolchain.

## 1. Host prerequisites ✅

Debian/Ubuntu host:

```sh
sudo apt-get install -y build-essential gcc g++ make bison flex gperf \
  help2man texinfo libtool-bin automake autoconf gawk \
  libncurses-dev unzip rsync bzip2 wget patch git
```

## 2. Cross-toolchain via crosstool-NG ✅

The exact toolchain is pinned as a crosstool-NG **defconfig** in this repo:
[`toolchain/atlas-arm-crosstool.defconfig`](toolchain/atlas-arm-crosstool.defconfig)
(glibc 2.23, gcc 12, binutils 2.40, linux-2.6.32 headers, cortex-a8, neon, softfp).

```sh
git clone --depth 1 --branch crosstool-ng-1.26.0 \
    https://github.com/crosstool-ng/crosstool-ng
cd crosstool-ng
./bootstrap && ./configure --enable-local && make -j"$(nproc)"

# apply the Atlas toolchain recipe
cp /path/to/atlas-wpe-env/toolchain/atlas-arm-crosstool.defconfig defconfig
./ct-ng defconfig

# build it (~1–3 h; installs to ~/x-tools/arm-cortex_a8-linux-gnueabi)
./ct-ng build
```

Result: `~/x-tools/arm-cortex_a8-linux-gnueabi/bin/arm-cortex_a8-linux-gnueabi-{gcc,g++,...}`
(gcc 12.3.0, glibc 2.23). ~20 min on a 12-core host.

**Validate it runs on the device** (recommended smoke test). A C++ binary built with the arch flags and
`patchelf`'d to the engine's bundled runtime runs on the TouchPad:

```sh
arm-cortex_a8-linux-gnueabi-g++ -march=armv7-a -mtune=cortex-a8 -mfpu=neon \
    -mfloat-abi=softfp -mthumb -O2 -pthread hello.cpp -o hello        # note: glibc 2.23 → -pthread needed
patchelf --set-interpreter /var/atlas252/lib/ld-linux.so.3 --set-rpath /var/atlas252/lib hello
novacom put file:///tmp/hello < hello && novacom run file://bin/chmod -- 755 /tmp/hello
novacom run file:///tmp/hello          # → prints, using the bundled glibc 2.23 + libstdc++
```
(`/var/atlas252` is the postinst-created symlink to the engine's `wpe-252` dir.)

**Known issue — glibc 2.23 manual vs modern texinfo.** glibc 2.23 compiles fine, but `make install`
fails at the *documentation* step on hosts with texinfo ≥ 7 (`cannot stat '.../manual/libc.info*'`) —
the new `makeinfo` won't generate glibc 2.23's old manual. The recipe works around it with
`CT_GLIBC_EXTRA_CONFIG_ARRAY="MAKEINFO=:"` (already set in the defconfig), which tells glibc to treat
`makeinfo` as absent and skip the manual entirely. No effect on the produced libraries.

## 3. Staging sysroot ✅ (libs + backend headers) / 🚧 (WebKit/Qt headers for BrowserServer)

You need the engine's **libraries** (to link against) and matching **dev headers** (to compile against).

**Libraries — pull them straight off a device that already runs Atlas** (no rebuild needed):

```sh
DR=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252
novacom run file://bin/tar -- czf /media/internal/wpe-lib.tgz -C "$DR" lib
novacom get file:///media/internal/wpe-lib.tgz > wpe-lib.tgz
mkdir -p ~/atlas-staging && tar xzf wpe-lib.tgz -C ~/atlas-staging   # → ~/atlas-staging/lib
```

This gives glibc 2.23, `ld-linux.so.3`, `libWPEWebKit-2.0.so.1`, `libwpe-1.0`, glib/gio, soup, EGL/GLES,
libstdc++ — the full link set. Then add **dev symlinks** so `-l<name>` resolves the sonames:

```sh
cd ~/atlas-staging/lib
for p in "libEGL.so:libEGL.so.1" "libGLESv2.so:libGLESv2.so.2" "libwpe-1.0.so:libwpe-1.0.so.1" \
         "libglib-2.0.so:libglib-2.0.so.0" "libgobject-2.0.so:libgobject-2.0.so.0" "libgio-2.0.so:libgio-2.0.so.0"; do
  ln -sf "${p#*:}" "${p%:*}"; done
```

**Headers for the backend `.so`** (`glib-2.0`, `libwpe-1.0`, EGL/GLESv2) — ✅ pinned:

```sh
# EGL / GLESv2 / KHR — arch-neutral Khronos headers (host mesa dev headers are fine)
cp -r /usr/include/EGL /usr/include/GLES2 /usr/include/KHR ~/atlas-staging/include/

# libwpe 1.16.0 headers (API-stable in the 1.x line)
git clone --depth 1 --branch 1.16.0 https://github.com/WebPlatformForEmbedded/libwpe
mkdir -p ~/atlas-staging/include/wpe-1.0/wpe && cp libwpe/include/wpe/*.h ~/atlas-staging/include/wpe-1.0/wpe/

# glib 2.74 headers + the 32-bit ARM glibconfig.h, extracted (not installed) from the Debian armhf .deb
curl -fsSLO https://deb.debian.org/debian/pool/main/g/glib2.0/libglib2.0-dev_2.74.6-2+deb12u9_armhf.deb
dpkg-deb -x libglib2.0-dev_*_armhf.deb /tmp/glib && \
  cp -r /tmp/glib/usr/include/glib-2.0 ~/atlas-staging/include/ && \
  mkdir -p ~/atlas-staging/lib/glib-2.0/include && \
  cp /tmp/glib/usr/lib/arm-linux-gnueabihf/glib-2.0/include/glibconfig.h ~/atlas-staging/lib/glib-2.0/include/
```

**Headers for BrowserServer — 🚧** additionally need `wpe-webkit-2.0` (from the WPE WebKit 2.52.4 install)
and QtWebKit compile-only headers. To be pinned when that build is green.

## 4. Environment ✅

Source the portable env file (a reconstruction of the original, machine-specific `env-glibc-gcc125.sh`):

```sh
source /path/to/atlas-wpe-env/env-atlas-cross.sh
# honors overrides: TOOLCHAIN=... STAGING=...
# the existing build-*.sh scripts also accept it via:  export WPE_ENV=.../env-atlas-cross.sh
```

It sets `TARGET/CC/CXX/AR/…`, the `-march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp -mthumb`
flags, `STAGING`, and points `pkg-config` at the sysroot.

## 5. Build the components

**a) `libWPEBackend-atlas.so`** — ✅ verified (builds, and renders frames in the live engine on-device):

```sh
source atlas-wpe-env/env-atlas-cross.sh
atlas-wpe-env/build-backend-atlas.sh            # → atlas-wpe-backend/libWPEBackend-atlas.so
```

This portable script encodes what works: the arch flags, the staging `-I`/`-l` paths, and a post-link
`patchelf --replace-needed libEGL.so→libEGL.so.1 / libGLESv2.so→libGLESv2.so.2` (the device deploys the
Adreno driver under the versioned names, but its own SONAME is unversioned). The result's `NEEDED` list
matches the device's shipped backend exactly and exports `_wpe_loader_interface`. Validated by swapping
it into `/var/atlas252/lib`, restarting `atlas`, and confirming `[wpe-atlas] frame_rendered` in
`/media/ram/bs-atlas.log`.

**b) BrowserServer** — ✅ builds from source (all 22 objects compile + links to an ARM executable whose
`NEEDED` matches the deployed binary) **and validated on-device**: swapped into `wpe-252/`, it renders
identically to the shipped binary (A/B on `example.com`: frames 113 vs 115, WebProcess spawns 12 vs 13,
0 crashes each). This is where the `BrowserPageWPE.cpp` engine changes (e.g. the viewport fix) live.

```sh
source atlas-wpe-env/env-atlas-cross.sh
REPOS=~/Projects atlas-wpe-env/build-browserserver-atlas.sh   # → browserserver-build/obj/BrowserServer-atlas
```

Extra source repos to clone under `$REPOS` (headers only; nothing built):
[Herrie82/BrowserServer](https://github.com/Herrie82/BrowserServer),
[openwebos/luna-service2](https://github.com/openwebos/luna-service2),
[isis-project/WebKitSupplemental](https://github.com/isis-project/WebKitSupplemental),
[isis-project/pbnjson](https://github.com/isis-project/pbnjson),
[openwebos/PmLogLib](https://github.com/openwebos/PmLogLib).

Extra staged headers (`dpkg-deb -x` the Debian **armhf** dev debs — no install — into `~/atlas-staging`;
device sonames satisfy the link):

| Header set | Source | Notes |
|-----------|--------|-------|
| `wpe-webkit-2.0` | Debian `libwpewebkit-2.0-dev` **2.52.5** | matches the engine's API |
| Qt 4.8.7 (`QtCore/QtGui/QtNetwork/QtWebKit`) | Debian `libqt4-dev` 4.8.7 + `libqtwebkit-dev` | compile-only interface types |
| `libsoup-3.0`, `openssl` (3), `libpng16`, `libpng12`, `zlib` | Debian dev debs / host | soup3 & png16 match the engine |
| `PmLogLib.h` | generated from `PmLogLib.h.in` (`@PMLOG_ENABLE_LOGGING@`→1) | |
| `InteractiveRectType.h`, `qpersistentcookiejar.h`, `webkit/webos_compat.h` | **reconstructed**, vendored in this repo (`reconstructed-headers/`) | vestigial QtWebKit types the WPE port doesn't use; documented in-file |

Link libs are **pulled off a running device** (`/usr/lib` + `/lib`, ~84 MB) into `~/atlas-staging/rootfs`
for `-rpath-link`, plus the specific `-l` libs into `~/atlas-staging/lib` (see §3). The toolchain provides
`libc`/`libm`/`libpthread`/… — those are excluded from `~/atlas-staging/linklib` so they aren't shadowed
by the device copies.

**Two repo bugs found + worked around** (candidates for upstream PRs):
1. `CodeGen/BrowserYapCommandMessages.defs` `KeyDown`/`KeyUp` were stale — declared `uint16_t key,
   uint16_t modifiers` but `BrowserServer.cpp` implements `int key, int modifiers, int chr`. Fixed the
   `.defs` to match (CodeGen only understands `int`, not `int32_t`).
2. `BrowserPageWPE.h::hitTest()` returns a `QWebHitTestResult{}` — a compile-only QtWebKit type with no
   backing lib ("QtWebKit link TBD"). Left unresolved in the test link (never reached by a page load).

## 6. Deploy + test 🚧

`patchelf` the built binaries to the bundled loader/rpath, push with `novacom`, and restart the engine:

```sh
# (patchelf --set-interpreter .../ld-linux.so.3 --set-rpath .../wpe-252/lib  <binary>)
# novacom put ... ; then on-device: stop atlas && start atlas
```

See `deploy-252.sh` / `redeploy-webkit.sh` for the current deploy flow.

---

### Not required for engine work

Rebuilding **WPE WebKit itself** (`build-webkit-252.sh`, ~40 min) is only needed when changing WebKit
source or its `patches/`. For backend/BrowserServer changes you link against the WebKit libs pulled in
step 3.
