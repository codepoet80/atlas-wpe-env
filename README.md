# atlas-wpe-env

Build environment, cross-build scripts, toolchain recipe, and deploy/packaging for the **Atlas**
browser engine on the HP TouchPad (webOS 3.0.5) — the WPE WebKit backend, `BrowserServer-atlas`, and
the self-contained IPK.

- **[BUILDING.md](BUILDING.md)** — reproduce the whole engine build from a clean host (toolchain →
  sysroot → components → deploy).
- **[toolchain/atlas-arm-crosstool.defconfig](toolchain/atlas-arm-crosstool.defconfig)** — the pinned
  crosstool-NG recipe for the device-matched cross toolchain (glibc 2.23, gcc 12, cortex-a8/neon/softfp).
- **[env-atlas-cross.sh](env-atlas-cross.sh)** — portable cross-build environment (`source` it, or point
  the build scripts at it via `WPE_ENV=`).
- **[CODE-AUDIT.md](CODE-AUDIT.md)** — engine code audit notes.

Related repos: [atlas-browser-app](https://github.com/Herrie82/atlas-browser-app) (UI),
[atlas-wpe-backend](https://github.com/Herrie82/atlas-wpe-backend) (WPE backend + `BrowserPageWPE`),
[BrowserServer](https://github.com/Herrie82/BrowserServer) (IPC host base).
