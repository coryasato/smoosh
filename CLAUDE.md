# Smoosh — Project Context

## Product
**Smoosh** is a tiny native macOS utility that compresses images into modern web formats (AVIF and/or WebP) with a drag-and-drop interface.

Goal: replace the "upload to TinyPNG / Squoosh / browser tab" workflow with a zero-friction local tool that feels instantaneous.

## Stack
- **Framework**: [Native SDK](https://native-sdk.dev)
  - Declarative markup views (`.native`)
  - **Zig core** (`src/main.zig`) — `Model` struct, `Msg` union, `update` fn, run through `native_sdk.UiApp(Model, Msg)`. **Not TypeScript** — see "Why Zig, not TS-core" below.
  - Pure `Model` / `Msg` / `update` architecture + effects channel (`fx`)
- **Platform**: macOS only (for now)
- **Image handling**:
  - Decode/preview: Apple ImageIO, called from Zig (`src/imageio.zig`) — landed in M13, and the
    full-resolution encoder-input decode landed in M14b.
  - Encode: still system tools via `fx.spawn` (`avifenc`, `cwebp`). The vendored libavif/libaom/
    libwebp archives are already linked in (M14a) but nothing calls them yet; M14c swaps the seam.

## Why Zig, not TS-core
Originally planned as a TS-core app (`src/core.ts`, "no JS runtime in binary" — see git history). Reversed after spiking file acquisition: native open/save dialogs (`native-sdk.dialog.openFile`/`saveFile`) and file drops are gated behind `RunOptions.bridge`/`.builtin_bridge`, fields that only exist on hand-authored `main.zig`. Verified from source (`@native-sdk/cli@0.8.0`'s `build/app.zig`): `addApp`'s `AppOptions` has no passthrough for them, the CLI-generated TS-core `main.zig` hardcodes them off with no override, and the build hard-panics if a tree carries both `src/core.ts` and `src/main.zig` ("an app has exactly one core"). There is no partial-adoption path — TS-core categorically cannot reach these. Confirmed by building and `native check`-validating a throwaway spike app, not by reading docs alone.

## File acquisition, honestly
This is how file acquisition actually works, proven end to end and now shipping: a markup button dispatches `pick_file` -> `update_fx` calls `fx.hostRequest(.{ .name = "dialog.openFile", .on_result = Effects.hostMsg(.dialog_result) })` -> a `HostCallBinding.request_fn` bound by hand (closing over a hand-constructed `*Runtime`) calls `runtime.showOpenDialog(...)` synchronously and answers through `effects.feedHostResult(key, ok, bytes)` -> the result lands back in `Model` as an ordinary `Msg` and renders in the view. Originally proven with a throwaway spike app against a real macOS `NSOpenPanel` (reference implementation, trimmed of scaffold cruft: `docs/spikes/dialog-open-file-spike.zig`), then transplanted into the real app.

Two non-obvious things the spike surfaced, still true of the real app:
1. `runner.runWithOptions`'s per-platform bring-up (`runMacos` and its helpers in the CLI's `app_runner/root.zig`) is all non-`pub` — a hand-authored `main.zig` can't call into it, only replicate the relevant parts with public APIs (`platform.macos.MacPlatform.createWithOptions` + `native_sdk.Runtime.initAt`). In practice this is fine: only the platform handle and the Runtime are actually needed; `runWithOptions` extras (trace-sink fanout, session recording, window-state persistence) can be skipped or added back deliberately later.
2. The `build_options` module (the `-Dautomation` comptime flag) is wired into the CLI's internal `runner` module only, not into a hand-authored root module — a hand-rolled `main.zig` can't gate `RuntimeOptions.automation` on `build_options.automation` the way the scaffold does. `src/main.zig` gates on `builtin.mode == .Debug` instead.

Real window-wide file drops work the same way but through a different seam: `UiApp.Options.on_drop`,
a `fn(platform.FileDropEvent) ?Msg` field beside `update_fx`/`init_fx` in `App.create`'s options
(added in SDK 0.8.2), dispatched from `handleRuntimeEvent`'s `.files_dropped` arm. A dropped path
re-enters the exact same load chain a picked one does. Full spec and source citations in
`docs/plan-v0.1-archive.md`'s M11 entry.

## Core Principles for this project
1. **Extremely simple UX** — drop zone is the entire product. Minimal chrome.
2. **Predictable Native SDK patterns** — keep `update` pure, all I/O via the effects channel (`fx`), explicit messages.
3. **Beautiful by default** — lean on Native SDK design tokens and built-in components.
4. **Fast feedback** — preview + size delta should appear quickly.
5. **Honest about constraints** — Native SDK has no built-in encoder. We start with system tools, then move to a fully native Zig pipeline.
6. **macOS-first** — optimize for Apple Silicon and ImageIO. No Linux/Windows scope in v0.1.

## Working in this repo

**Read the `native-ui` skill before writing any `.native` markup or `UiApp` Zig**, and the
`native-sdk` skill for scaffolding, `app.zon`, and packaging questions. They are the authoritative
authoring guides; this file only records project-specific decisions.

### Toolchain
- `native` CLI **0.10.1**, installed globally (`~/.npm-global/bin/native`) — not a devDependency.
- Zig **0.16.0** (`/usr/local/bin/zig-aarch64-macos-0.16.0/zig`).
- `node_modules/` + `package.json` + `tsconfig.json` are an **editor-only** surface for the
  abandoned TS-core path. Builds never read them. Do not run installs to "fix" a build.
- **This app owns its build** (`build.zig` + `build.zig.zon`), as of M14a — `native eject` ran and
  the CLI now drives `zig build` instead of generating a graph. It will never rewrite those files.
  `build.zig` calls `addAppArtifacts` rather than `addApp` so the vendored archives and the ImageIO
  frameworks can be stated on the artifacts; a framework upgrade still upgrades the wiring, because
  everything else still comes from the SDK's `build/app.zig`. **`native eject` is one-shot and
  refuses if either file exists** — there is no re-ejecting to pick up CLI changes.
- Still no pinned SDK VERSION: `build.zig.zon` depends on the global CLI by relative path, so
  `native build` links whatever the installed CLI carries. Run `native test` before `native check`
  after any CLI upgrade — `check` degrades to grammar-only with a loud note until `test`
  regenerates the model contract.

### Commands
```sh
native dev      # Debug build + run, markup hot reload
native build    # ReleaseFast binary into zig-out/bin/
native check    # validate markup + app.zon
native test     # app test suite
native package --target macos [--signing ...]
native automate snapshot                       # widget ids (bare numbers, printed as #id)
native automate widget-click <view-label> <id> # drive the running app
native automate screenshot <view-label>        # gpu_surface views only
```
`native dev --core` is TS-core only and does not apply here.
Widget clicks take a **numeric id from `snapshot`**, not a label — snapshot first.

**`native test` links frameworks now — since M14a.** It did not before, and the reason is worth
keeping: `build/app.zig` builds its test artifact from a fresh Debug module whenever
`app_optimize != optimize` (and `app_optimize` defaults to ReleaseFast), so the SDK's private
`linkPlatform` never runs on it. Anything reaching ImageIO from any file reachable from `main.zig`,
tests included, died at link time on `undefined symbol: _CFRelease`. `src/imageio_tests.zig` was
therefore imported by nothing and run by hand.

Owning `build.zig` fixed it: it states the frameworks on `artifacts.tests.root_module` directly.
`src/imageio_tests.zig` is now imported by `main.zig`'s `test` block and runs like everything else.

**The shape of that trap still applies to anything new you link.** `artifacts.exe.root_module` and
`artifacts.tests.root_module` are SEPARATE modules and both must be wired; wire only the exe and
the failure appears solely in the test artifact. `linkFramework` also needs an explicit
`addFrameworkPath`, or the link fails with `searched paths:  none`. Both are commented in
`build.zig` — read it before adding a library.

### Repo layout
- `src/main.zig` — the app. Hand-authored root: builds its own platform + Runtime.
- `src/app.native` — markup view.
- `src/imageio.zig` — the whole ImageIO C-ABI seam (`extern fn`, not `@cImport`): `probe`,
  `thumbnail` and `decode`, all callable from a worker thread and all returning straight-alpha
  8-bit sRGB. `probe` and `thumbnail` are host commands; **`decode` deliberately is not** — a
  full-resolution buffer cannot ride the 256 KiB host result, and M14c's encode worker (its only
  caller) is already off the loop thread. `decode` applies the EXIF orientation BY HAND, through
  three scalar CTM calls rather than `CGContextConcatCTM`; the header says why.
- `src/chroma.zig` — the source-container chroma table plus the hand-rolled JPEG SOF parser, which
  is how `avifenc --yuv auto`'s behaviour survives decoding everything to RGBA. Pure over bytes.
  **Nothing calls it yet** — M14c's libavif seam is its only consumer.
- `src/imageio_tests.zig` — its tests. Imported by `main.zig`'s `test` block and run by
  `native test` like everything else, since M14a. (It used to be a file nothing imported, run by
  hand — see "Commands" for why, and do not reintroduce that pattern.) Its fixtures are PNGs
  embedded as byte literals, because `test-images/` is gitignored; the orientation tests build
  their own tagged PNGs in-process (ImageIO reads the PNG `eXIf` chunk).
- `src/encoders.zig` — the Zig-to-encoder seam, the mirror of `imageio.zig`. **M14a wired the
  build but wrote no encoders**: right now this holds only the three version probes that prove the
  vendored archives link, and the app still spawns `avifenc`/`cwebp`. The encode functions land in
  M14c.
- `build.zig` / `build.zig.zon` — ours since M14a (see "Toolchain"). `build.zig` links the vendored
  archives and the ImageIO frameworks into both the exe and the test artifact; its comments record
  why each line is there.
- `third_party/` — vendored encode-only static archives (libavif, libaom, libwebp + libsharpyuv)
  and the headers for the two APIs we call. `third_party/README.md` records versions, provenance
  and the two traps the build cannot state.
- `src/tests.zig` — unit tests, pulled in by a `test {}` block at the bottom of `main.zig` (the
  scaffold's convention). Run with `native test`. See PLAN.md's "Testing strategy" for the two
  tiers and what belongs in each.
- `README.md` — rewritten for Smoosh; keep the Status section honest as the app evolves.
- `docs/spikes/` — validated reference implementations, not built as part of the app. Each
  file's header records what it proved AND what it did not; read that before transplanting.
  `dialog-open-file-spike.zig` (file acquisition), `threaded-host-call-spike.zig` (long work off
  the loop thread), `imageio-decode-spike.zig` (the ImageIO C-ABI seam; builds standalone with
  `zig build-exe … -framework ImageIO -framework CoreGraphics -framework CoreFoundation`),
  `static-archive-link-spike.zig` (M14's ejected `build.zig` — this one IS a build.zig: copy it,
  do not `@import` it).
- `docs/plan-v0.1-archive.md` — full v0.1 development history (see PLAN.md's header).
- `docs/phase-b-baseline.md` — the pre-Phase-B measurement of the shipping app (size, PSNR, AVIF
  `yuvFormat`, metadata) plus the fixture-set inventory and how to regenerate it. Append-only: it
  is the gate M13/M14 are judged against and cannot be re-measured once the encoders change.

(`src/core.ts`, `package.json`, `tsconfig.json`, `bun.lock`, and `node_modules/` were the abandoned
TS-core editor surface and were deleted early on. There is no npm/bun surface in this tree at all.)

### Gotcha: window config exists in THREE places
For a hand-authored root, window geometry is stated three times and all three must move together
(see the block comment in `src/main.zig`):

1. **`platform.AppInfo.main_window.default_frame`** — the host creates the real NSWindow from this,
   *before* the scene loads, and it defaults to **720x480**. The size passed to
   `MacPlatform.createWithOptions` only sizes the *surface*, not the window. Omit `main_window` and
   you get a 720x480 window no matter what the scene or `app.zon` says. The CLI runner derives these
   `WindowOptions` from `app.zon` at comptime; a hand-authored root has no such path, so it must
   state them in Zig.
2. **`native_sdk.ShellConfig`** passed to `App.create(.{ .scene = ... })` — what the runtime lays
   views out against (`ShellWindow` label/title/size, the view's `gpu_*` fields).
3. **`app.zon`'s `.shell.windows`** — identity, `native check`, and packaging.

## Native SDK surfaces this app uses
- Native dialogs (`runtime.showOpenDialog`/`showSaveDialog`, wired through a custom `HostCallBinding` — see "File acquisition, honestly")
- `fx.registerImage` + `<image>` for previews — **of an ImageIO thumbnail, never the source image.**
  Registered images cap at 1 MiB of *decoded* RGBA (512x512), so no real photo can be registered
  directly. The 160px cap is set tighter still by `max_effect_host_result_bytes` (256 KiB), which
  the preview pixels ride; `main.zig` asserts that fit at comptime.
- Two host commands of our own for ImageIO, `image.probe` and `image.thumbnail`, answered OFF the
  loop thread through `HostCallBinding`'s worker-carrier trio (`poll_fn`/`pending_fn`/
  `bind_services_fn`) plus `shutdown_fn`. `feedHostResult` is loop-thread-only — a worker parks its
  answer in its own slot and calls `services.wake()`. The dialogs and the two file commands still
  answer synchronously from `request_fn`, which is equally supported and right for them.
- A second host command bound by hand, `file.stat` — `update` can never hold an `Io`, the bridge can.
  Reused for output sizes rather than adding a stat spawn.
- A third, `file.copy` (`std.Io.Dir.copyFileAbsolute`) — Save As copies an already-produced output,
  which `fx.writeFile`'s 1 MiB cap can't hold.
- `fx.spawn` (system tools: `sips` for HEIC staging only, `avifenc`, `cwebp`, `which`)
- Hot-reload on `.native` files (Debug builds, via `.markup.watch_path`)
- `on_drop` (`UiApp.Options`, SDK 0.8.2+) for real window-wide file drops.
- Manifest: `capabilities = .{ "native_views", "gpu_surfaces", "file_drops" }` — markup renders onto a
  gpu_surface, so `gpu_surfaces` stays; `file_drops` is a real `app_manifest.CapabilityKind` string,
  confirmed by reading the SDK source (nothing in the runtime currently reads it as a gate — it's
  honest metadata, not a switch). Permissions are just `command` + `view`.

## Conventions
- Zig core (`src/main.zig`) — no TypeScript in this tree.
- Messages are narrow and explicit.
- Keep `update`/`update_fx` pure and small. Heavy work lives in effects (`fx`).
- `Model` is a plain struct heap-allocated by `UiApp.create`: fixed-size buffers, not slices or
  `ArrayList`. Derive display strings via `pub fn` methods rather than storing them.
- `error` is a Zig keyword — enum states use `failed`, not `error`.
- UI should work well at small window sizes (the app is meant to live in a corner of the desktop).
- Verify against the *running* app via `native automate`. A clean `native build` proves nothing
  about behavior.

## Current status
v0.1 shipped (M1-M12; full history in `docs/plan-v0.1-archive.md`): pick or drop an image, choose
AVIF/WebP/Both, Smoosh auto-saves next to the source, optionally Save As to another location,
packaged as an ad-hoc-signed `.app`.

Phase B M13 (v0.2) is DONE: the load chain runs on ImageIO, both `sips` reads and `fx.loadImage`
are gone, and the preview now shows the file's primary frame, upright and in sRGB.

**M14b is DONE**: `imageio.decode` and `src/chroma.zig` exist and are tested against the whole
fixture set, but **neither has a caller** — that is what M14b is. No output byte has moved.

**M14a is DONE too**: the build is ejected and ours, the encode-only archives are vendored under
`third_party/` and link into both the exe and the test artifact, and `src/imageio_tests.zig` runs
under `native test` for the first time. **No encoder is called yet** — the app still spawns
`avifenc`/`cwebp` with the pinned argv, so no output byte has moved and the Homebrew dependency is
still there. M14c (the encode seams + parity) is all that is left of M14, and is what removes it.
`native build`/`check`/`test`/`dev`/`package` all clean, zero `check` warnings.
**PLAN.md is the source of truth** for what is done and what is next.

Two standing rules from that round, still load-bearing for any future work:
- **Never automate a native file dialog** (open or save panel). The app runs as a bare executable
  under `native dev`/`native build`; System Events cannot bring it frontmost, so global keystrokes
  land on whatever IS frontmost instead — this already typed a stray path into a live session once.
  Have the user drive every dialog by hand; everything else (button presses, chip selection,
  status/result assertions) drives fine with `native automate widget-click`.
- **File drops cannot be automated at all** (a different constraint from dialogs, same practical
  answer): have the user drag a real file onto the window by hand.

**`PLAN.md` is the source of truth** for what's current and what's next. Do not restate its
contents here — link to it.
