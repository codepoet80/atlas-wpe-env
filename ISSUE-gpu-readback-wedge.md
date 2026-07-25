# BrowserServer wedges permanently: unbounded GPU wait on the main thread

**Affects:** Atlas 0.9.6 (stock IPK) and current master. Not a regression — reproduced on an
unmodified 0.9.6 install.
**Impact:** Browser becomes a complete no-op. Engine process stays alive and healthy-looking, so it
is easy to misdiagnose as a socket or adapter problem.
**Workaround:** `stop atlas && start atlas` — a reboot is *not* required.

## Symptom

After sustained use — repeated reloads of a heavy page, plus a rotation or two — the browser stops
responding entirely. URLs resolve, the progress bar moves, but no page ever loads or paints.

What makes it confusing is that nothing looks broken:

- `BrowserServer-atlas` is alive, RSS flat, ~0% CPU
- `WPEWebProcess` alive, sleeping normally in `poll`
- yap sockets connected; the app's `openURL` arrives
- no crash: `dmesg` clean, no segfault, no OOM kill

## Root cause

`BrowserServer`'s main thread is blocked in `futex_wait_queue_me`, i.e. it is *not* in the glib main
loop. No yap command is ever serviced again.

The engine log stops dead at a fixed point:

```
[wpe-atlas] resize -> layout 1024x2304 (cap 768x3072)
[wpe-atlas] target_resize 768x3072 -> 1024x2304
[wpe-atlas] downscale: GPU pass ready
[wpe-atlas] locksurf: 27 configs w/ LOCK_SURFACE_BIT
[wpe-atlas] locksurf: cfg via rgba8 sizes
[wpe-atlas] locksurf: ready 1024x2304          <-- last line, forever
```

The statement immediately after that log line, in `wpe-atlas-backend.c` `lock_readback()`:

```c
ATLAS_LOG("locksurf: ready %ux%u", rw, rh);
...
glFinish();                              /* <-- no timeout, cannot be interrupted */
eglMakeCurrent(dpy, t->lock_surf, ...);
... blit ...
glFinish();                              /* <-- same */
p_lock(dpy, t->lock_surf, la);           /* eglLockSurfaceKHR: maps/syncs whole surface */
```

These readbacks run **on the BrowserServer main thread**. `glFinish()` blocks until the GPU retires
all pending work, with no deadline. When the Adreno 220 stops making progress, `glFinish()` never
returns and takes the entire main loop with it — hence "alive but totally mute".

The `glReadPixels` fallback path below it has the same property, so failing over does not help.

Contributing factor: this path is already slow and heavily exercised. Measured on device,
`readback+swizzle = 294473us` at 0.0 fps for a full 768x3072 surface, and a rotation forces the
lockable pbuffer to be destroyed and recreated at the new size.

## Reproduction

1. Load a JS-heavy page over https
2. Reload repeatedly (~5–10 times)
3. Rotate the device once or twice during the sequence
4. Eventually: page never paints again; engine alive, log frozen after `locksurf: ready`

Reproduced on both stock 0.9.6 and current master. Rotation appears to make it much more likely,
which fits the surface-recreate path above.

## Suggested direction (needs someone who knows this pipeline)

The driver advertises `EGL_KHR_fence_sync` (confirmed in the device's `EGLEXT` line), so the
blocking waits could be replaced with a fence plus `eglClientWaitSyncKHR` on a deadline, abandoning
the frame on timeout rather than blocking forever. `dispatch_frame_complete()` still has to run for
the dropped frame or WebKit stalls, and the `glReadPixels` fallback must be skipped in that state
since it is equally unbounded.

**This was attempted and did not work** — see the next section.

Caveat on the diagnosis: we could not capture a userspace stack inside `glFinish()` — gdbserver
attaches, but symbols will not resolve through the patchelf'd bundled loader, so every backtrace
stops at frame #1. The identification rests on the thread state (`futex_wait`, no CPU), the log
stopping at exactly that statement, and the absence of any crash — strong, but not a captured stack.

## Secondary issue: `libWPEBackend-atlas.so` is not reproducible from source

This blocks anyone from fixing the above, so it is worth addressing first.

`libWPEBackend-atlas.so` is listed in `.gitignore`, and `build-ipk-atlas.sh` packages whatever copy
happens to be sitting in the working tree:

```sh
BACKEND="${BACKEND:-$REPOS/atlas-wpe-backend/libWPEBackend-atlas.so}"
cp -f "$BACKEND" "$D/lib/libWPEBackend-atlas.so"
```

So the shipped backend is a **prebuilt binary**, not a build artifact. Two consequences:

1. Running `build.sh` silently overwrites the prebuilt with a locally-built one, and the next IPK
   ships that instead. There is no warning and no checksum.
2. The locally-built backend does **not** behave like the shipped one. Built from the same source
   with our cross toolchain (gcc 12.3, correct soft-float ABI, `_wpe_loader_interface` exported,
   identical `NEEDED`), it produced a browser that loads and parses pages but never paints, with
   **zero** rendering log output — the readback path is never entered at all. The shipped prebuilt is
   40,088 bytes; the from-source build is 46,524.

That size and behaviour gap suggests the checked-in source does not correspond to the shipped binary
(different compiler, different flags, or the tree is behind what produced the `.so`).

`build.sh` also hardcodes `/home/herrie/webos/wpe` for both the toolchain env and the source
directory, so it only runs in one person's home directory.

Suggested fixes: make `build.sh` path-relative, and either commit the backend source that actually
produces the shipped binary or document the exact toolchain and flags used to build it.

## Environment

- HP TouchPad, webOS 3.0.5, Adreno 220
- WPE WebKit 2.52.4, `BrowserServer-atlas`, `libWPEBackend-atlas.so`
- Renderer: `Adreno (TM) 220`; `EGL_KHR_fence_sync` and `EGL_KHR_lock_surface` both present
