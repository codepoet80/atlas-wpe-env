# CMake cross-toolchain for the Atlas engine (HP TouchPad, webOS 3.0.5).
# Portable reconstruction of the unpublished cmake-toolchain-glibc-gcc125.cmake.
#
#   cmake .. -DCMAKE_TOOLCHAIN_FILE=<this file>
#
# Reads the same environment as env-atlas-cross.sh, so source that first (or set TOOLCHAIN/STAGING).
# Nothing here is machine-specific.

set(CMAKE_SYSTEM_NAME      Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

# --- toolchain ---------------------------------------------------------------------------------
if(NOT DEFINED ATLAS_TOOLCHAIN)
  if(DEFINED ENV{TOOLCHAIN})
    set(ATLAS_TOOLCHAIN "$ENV{TOOLCHAIN}")
  else()
    file(GLOB _tc "$ENV{HOME}/x-tools/arm-*linux-gnueabi*")
    list(GET _tc 0 ATLAS_TOOLCHAIN)
  endif()
endif()
if(NOT DEFINED ATLAS_TARGET)
  if(DEFINED ENV{TARGET})
    set(ATLAS_TARGET "$ENV{TARGET}")
  else()
    set(ATLAS_TARGET "arm-cortex_a8-linux-gnueabi")
  endif()
endif()

set(CMAKE_C_COMPILER   "${ATLAS_TOOLCHAIN}/bin/${ATLAS_TARGET}-gcc")
set(CMAKE_CXX_COMPILER "${ATLAS_TOOLCHAIN}/bin/${ATLAS_TARGET}-g++")
set(CMAKE_AR           "${ATLAS_TOOLCHAIN}/bin/${ATLAS_TARGET}-ar"     CACHE FILEPATH "")
set(CMAKE_RANLIB       "${ATLAS_TOOLCHAIN}/bin/${ATLAS_TARGET}-ranlib" CACHE FILEPATH "")
set(CMAKE_STRIP        "${ATLAS_TOOLCHAIN}/bin/${ATLAS_TARGET}-strip"  CACHE FILEPATH "")

# --- ABI (must match the device engine exactly) ------------------------------------------------
# softfp, not hardfp: webOS 3.0.5's system libraries are softfp, and JavaScriptCore's JIT is patched
# to match (wpewebkit-2.52.4-softfp-jit.patch). Getting this wrong yields a browser that links but
# passes doubles in the wrong registers.
set(ATLAS_ARCH_FLAGS "-march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp -mthumb")

# Debian multiarch keeps arch-dependent headers in /usr/include/<triplet>: gpg-error.h, ffi.h,
# jconfig.h (libjpeg), openssl/, libxslt/, libunwind*. pkg-config does not emit that directory, so
# without it <gpg-error.h> and friends are simply not found. Must be set before the flags below.
if(DEFINED ENV{STAGING})
  set(_atlas_ma "$ENV{STAGING}/webkitdeps/usr/include/arm-linux-gnueabihf")
else()
  set(_atlas_ma "$ENV{HOME}/atlas-staging/webkitdeps/usr/include/arm-linux-gnueabihf")
endif()

set(CMAKE_C_FLAGS_INIT   "${ATLAS_ARCH_FLAGS} -isystem ${_atlas_ma}")
set(CMAKE_CXX_FLAGS_INIT "${ATLAS_ARCH_FLAGS} -isystem ${_atlas_ma}")

# --- sysroot / search paths --------------------------------------------------------------------
if(DEFINED ENV{STAGING})
  set(ATLAS_STAGING "$ENV{STAGING}")
else()
  set(ATLAS_STAGING "$ENV{HOME}/atlas-staging")
endif()
set(ATLAS_WEBKITDEPS "${ATLAS_STAGING}/webkitdeps")

# webkitdeps holds the extracted armhf dev debs (headers + .pc); its lib/*.so are symlinked to the
# real device libraries by stage-sysroot-atlas.sh, so -l resolves against what the device ships.
set(CMAKE_FIND_ROOT_PATH "${ATLAS_WEBKITDEPS}/usr" "${ATLAS_STAGING}")
# Deliberately NO CMAKE_SYSROOT here. --sysroot would replace the toolchain's own sysroot, so libc's
# headers (which live in the toolchain, not in webkitdeps) would stop resolving. Dependency headers
# come in as explicit -I from pkg-config, which prefixes them with PKG_CONFIG_SYSROOT_DIR below.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)   # build tools (ruby, unifdef, gperf) come from the host
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# pkg-config resolves against webkitdeps only — never the host's /usr.
set(ENV{PKG_CONFIG_SYSROOT_DIR} "${ATLAS_WEBKITDEPS}")
set(ENV{PKG_CONFIG_LIBDIR}
    "${ATLAS_WEBKITDEPS}/usr/lib/arm-linux-gnueabihf/pkgconfig:${ATLAS_WEBKITDEPS}/usr/share/pkgconfig:${ATLAS_STAGING}/lib/pkgconfig")
unset(ENV{PKG_CONFIG_PATH})

# --- link paths ---------------------------------------------------------------------------------
# linklib = the engine's own libs (deviceroot/wpe-252/lib) minus the ones the toolchain provides.
#
# NOTE: $STAGING/rootfs is deliberately NOT on the link path here, unlike the BrowserServer build.
# rootfs is the device's SYSTEM /usr/lib + /lib, i.e. the ancient glibc 2.8 tree. Because linklib
# excludes libc/libpthread (so they cannot shadow the toolchain's), ld falls through to rootfs and
# picks up the 2.8 libpthread.so.0, which references GLIBC_PRIVATE symbols that do not exist in our
# glibc 2.23 (__default_sa_restorer_v2, h_errno, ...) and the link dies. Every WebKit dependency lives
# in the bundled engine lib dir, so linklib alone is correct; let libc/libpthread come from the
# toolchain's own sysroot.
set(ATLAS_LINK_FLAGS
    "-L${ATLAS_STAGING}/linklib -L${ATLAS_WEBKITDEPS}/usr/lib/arm-linux-gnueabihf \
-Wl,-rpath-link,${ATLAS_STAGING}/linklib")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "${ATLAS_LINK_FLAGS}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${ATLAS_LINK_FLAGS}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${ATLAS_LINK_FLAGS}")
