# Atlas WPE cross-build environment — portable reconstruction of the (unpublished) env-glibc-gcc125.sh.
# Source it, or point the existing build scripts at it:   export WPE_ENV=.../env-atlas-cross.sh
#
# Sets TARGET / CC / CXX / AR / ... / CFLAGS / STAGING for the device ABI, confirmed from the running
# TouchPad engine: glibc 2.23 (crosstool-NG), soft-float ABI (ld-linux.so.3), armv7-a / cortex-a8 / neon.
# Nothing here is machine-specific — every path is derived or overridable via the environment.
#
#   TOOLCHAIN   toolchain root (default: $HOME/x-tools/<first arm* dir>).  Built by crosstool-NG.
#   STAGING     sysroot with the engine's libs + dev headers (default: $HOME/atlas-staging).
#               Its lib/ can be pulled straight off the device (deviceroot/wpe-252/lib); headers come
#               from the WPE WebKit 2.52.4 / glib / libwpe sources.

# --- toolchain ------------------------------------------------------------------------------------
: "${TOOLCHAIN:=$(ls -d "${CT_PREFIX:-$HOME/x-tools}"/arm-*linux-gnueabi* 2>/dev/null | head -1)}"
if [ -z "${TOOLCHAIN:-}" ] || [ ! -d "$TOOLCHAIN/bin" ]; then
  echo "env-atlas-cross: no toolchain found (set TOOLCHAIN=... to the crosstool-NG arm-*-linux-gnueabi dir)" >&2
fi
# Derive the target tuple from the *-gcc in the toolchain (don't hardcode the vendor).
_gcc=$(ls "$TOOLCHAIN"/bin/arm-*linux-gnueabi*-gcc 2>/dev/null | head -1)
TARGET=$(basename "${_gcc%-gcc}" 2>/dev/null)
export TARGET
export PATH="$TOOLCHAIN/bin:$PATH"

export CC="$TARGET-gcc"
export CXX="$TARGET-g++"
export CPP="$TARGET-cpp"
export AR="$TARGET-ar"
export AS="$TARGET-as"
export LD="$TARGET-ld"
export NM="$TARGET-nm"
export RANLIB="$TARGET-ranlib"
export STRIP="$TARGET-strip"
export READELF="$TARGET-readelf"
export OBJCOPY="$TARGET-objcopy"

# --- ABI / arch flags (must match the device engine exactly) --------------------------------------
ATLAS_ARCH_FLAGS="-march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp -mthumb"

# --- staging sysroot ------------------------------------------------------------------------------
: "${STAGING:=$HOME/atlas-staging}"
export STAGING
export SYSROOT="$STAGING"

export CFLAGS="$ATLAS_ARCH_FLAGS -O2 -I$STAGING/include ${CFLAGS:-}"
export CXXFLAGS="$ATLAS_ARCH_FLAGS -O2 -I$STAGING/include ${CXXFLAGS:-}"
export LDFLAGS="-L$STAGING/lib -Wl,-rpath-link,$STAGING/lib ${LDFLAGS:-}"

# pkg-config resolves against the staging sysroot only (never the host).
export PKG_CONFIG_SYSROOT_DIR="$STAGING"
export PKG_CONFIG_LIBDIR="$STAGING/lib/pkgconfig:$STAGING/share/pkgconfig"
unset PKG_CONFIG_PATH

# Convenience: crosstool-NG puts a ready sysroot under the toolchain; expose it for startfiles/libc.
if [ -n "${TARGET:-}" ] && [ -d "$TOOLCHAIN/$TARGET/sysroot" ]; then
  export TOOLCHAIN_SYSROOT="$TOOLCHAIN/$TARGET/sysroot"
fi

echo "env-atlas-cross: TARGET=$TARGET  TOOLCHAIN=$TOOLCHAIN  STAGING=$STAGING" >&2
