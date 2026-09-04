# Smoosh — Project Context

## Product
**Smoosh** is a tiny native macOS utility that compresses images into modern web formats (AVIF
and/or WebP) with a drag-and-drop interface.

Goal: replace the "upload to TinyPNG / Squoosh / browser tab" workflow with a zero-friction local
tool that feels instantaneous.

**`PLAN.md` is the source of truth** for what is done and what is next. `CHANGELOG.md` is the
history. This file holds working context that neither of those covers: the traps, the seams, and
the reasons the tree is shaped the way it is.

## Stack
- **Framework**: [Native SDK](https://native-sdk.dev)
  - Declarative markup views (`.native`)
  - **Zig core** (`src/main.zig`) — `Model` struct, `Msg` union, `update` fn, run through
    `native_sdk.UiApp(Model, Msg)`. **Not TypeScript** — see "Why Zig, not TS-core" below.
  - Pure `Model` / `Msg` / `update` architecture + effects channel (`fx`)
- **Platform**: macOS only (for now)
- **Image handling** — all native, and the app spawns no subprocess:
  - Decode/preview: Apple ImageIO, called from Zig (`src/imageio.zig`).
  - Encode: vendored static libavif/libaom/libwebp, via a C shim (`src/encode.c`) that
    `src/encoders.zig` declares. Runs in the `image.encode` worker (`main.zig`'s `HostBridge`),
    which decodes → encodes → writes the output atomically, off the loop thread.

## Why Zig, not TS-core
This was planned as a TS-core app ("no JS runtime in binary") and reversed before M1. Native
open/save dialogs (`native-sdk.dialog.openFile`/`saveFile`) and file drops are gated behind
`RunOptions.bridge`/`.builtin_bridge`, fields that only exist on a hand-authored `main.zig`.
Verified from source: `addApp`'s `AppOptions` has no passthrough for them, the CLI-generated
TS-core `main.zig` hardcodes them off with no override, and the build hard-panics if a tree carries
both `src/core.ts` and `src/main.zig` ("an app has exactly one core"). **There is no
partial-adoption path** — TS-core categorically cannot reach these.

## File acquisition, honestly
A markup button dispatches `pick_file` → `update_fx` calls
`fx.hostRequest(.{ .name = "dialog.openFile", .on_result = Effects.hostMsg(.dialog_result) })` → a
`HostCallBinding.request_fn` bound by hand (closing over a hand-constructed `*Runtime`) calls
`runtime.showOpenDialog(...)` synchronously and answers through
`effects.feedHostResult(key, ok, bytes)` → the result lands back in `Model` as an ordinary `Msg`
and renders in the view.

Two non-obvious things about the hand-authored root this requires:

1. `runner.runWithOptions`'s per-platform bring-up (`runMacos` and its helpers in the CLI's
   `app_runner/root.zig`) is all non-`pub` — a hand-authored `main.zig` can't call into it, only
   replicate the relevant parts with public APIs (`platform.macos.MacPlatform.createWithOptions` +
   `native_sdk.Runtime.initAt`). In practice this is fine: only the platform handle and the Runtime
   are actually needed. `runWithOptions`' extras (trace-sink fanout, session recording,
   window-state persistence) are skipped and can be added back deliberately.
2. The `build_options` module (the `-Dautomation` comptime flag) is wired into the CLI's internal
   `runner` module only, not into a hand-authored root module — so this tree can't gate
   `RuntimeOptions.automation` on `build_options.automation` the way the scaffold does.
   `src/main.zig` gates on `builtin.mode == .Debug` instead.

Real window-wide file drops work through a different seam: `UiApp.Options.on_drop`, a
`fn(platform.FileDropEvent) ?Msg` field beside `update_fx`/`init_fx` in `App.create`'s options
(SDK 0.8.2+), dispatched from `handleRuntimeEvent`'s `.files_dropped` arm. A dropped path re-enters
the exact same load chain a picked one does. Three constraints, all read out of the CLI's source:
the drop is WINDOW-wide (a real drag carries no `view_label` or `point`, so the copy must not
promise a targeted zone), the widget-level `canvas_widget_file_drop` channel is a dead end that no
real drag ever reaches, and a drag-over highlight is impossible — the AppKit host emits nothing on
`draggingEntered:`.

## Core Principles for this project
1. **Extremely simple UX** — drop zone is the entire product. Minimal chrome.
2. **Predictable Native SDK patterns** — keep `update` pure, all I/O via the effects channel (`fx`),
   explicit messages.
3. **Beautiful by default** — the palette is app-owned through `tokens_fn`, but every widget is a
   stock component; nothing here is a hand-drawn imitation of one.
4. **Fast feedback** — preview + size delta should appear quickly.
5. **Honest about constraints** — Native SDK has no built-in encoder; Smoosh vendors its own.
6. **macOS-first** — optimize for Apple Silicon and ImageIO.

## Working in this repo

**Read the `native-ui` skill before writing any `.native` markup or `UiApp` Zig**, and the
`native-sdk` skill for scaffolding, `app.zon`, and packaging questions. They are the authoritative
authoring guides; this file only records project-specific decisions.

### Toolchain
- `native` CLI **0.10.1**, installed globally (`~/.npm-global/bin/native`) — not a devDependency.
- Zig **0.16.0** (`/usr/local/bin/zig-aarch64-macos-0.16.0/zig`).
- **This app owns its build** (`build.zig` + `build.zig.zon`) — `native eject` has run and the CLI
  drives `zig build` instead of generating a graph. It will never rewrite those files. `build.zig`
  calls `addAppArtifacts` rather than `addApp` so the vendored archives and the ImageIO frameworks
  can be stated on the artifacts; a framework upgrade still upgrades the wiring, because everything
  else still comes from the SDK's `build/app.zig`. **`native eject` is one-shot and refuses if
  either file exists** — there is no re-ejecting to pick up CLI changes.
- No pinned SDK version: `build.zig.zon` depends on the global CLI by relative path, so
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

### The linking trap, for anything you link next
`artifacts.exe.root_module` and `artifacts.tests.root_module` are **separate modules** and both
must be wired — the SDK builds its test artifact from a fresh Debug module that its private
`linkPlatform` never runs over. Wire only the exe and the failure appears solely in the test
artifact, as an `undefined symbol` at link time. `linkFramework` also needs an explicit
`addFrameworkPath`, or the link fails with `searched paths:  none`. And when
`app_optimize == optimize` (the ReleaseFast `native build`) the SDK hands back the SAME module for
both, so the list must be de-duplicated — adding a compiled `.c` twice is a fatal
`duplicate symbol`.

All three are commented in `build.zig`. **Read it before adding a library**; each has a failure mode
that hides until the other artifact is built.

### Repo layout
- `src/main.zig` — the app. Hand-authored root: builds its own platform + Runtime.
- `src/app.native` — markup view. Its header comment carries the widget-identity rule (every root
  child is keyed) and the reasons for the shapes the SDK forced; PLAN.md's "UI and style polish"
  carries the palette and geometry decisions.
- `src/imageio.zig` — the whole ImageIO C-ABI seam (`extern fn`, not `@cImport`): `probe`,
  `thumbnail` and `decode`, all callable from a worker thread and all returning straight-alpha
  8-bit sRGB. `probe` and `thumbnail` are host commands; **`decode` deliberately is not** — a
  full-resolution buffer cannot ride the 256 KiB host result, and its one caller (the
  `image.encode` worker) is already off the loop thread. `decode` applies the EXIF orientation BY
  HAND, through three scalar CTM calls rather than `CGContextConcatCTM`; the header says why.
- `src/chroma.zig` — the source-container chroma table plus the hand-rolled JPEG SOF parser, which
  is how `avifenc --yuv auto`'s behaviour survives decoding everything to RGBA. Pure over bytes.
- `src/encoders.zig` — the Zig-to-encoder seam, the mirror of `imageio.zig`. `encodeAvif`/
  `encodeWebp` plus the three version probes that pin the archive versions. Unlike `imageio.zig` it
  does NOT hand-roll the C ABI — the libavif/libwebp encode APIs are struct-heavy, so
  `src/encode.c` does the struct work and exposes a flat scalar ABI this file declares in three
  lines.
- `src/encode.c` — that shim. The only C in the tree. Reproduces `avifenc -q 58 --speed 6` /
  `cwebp -q 80` through the C APIs; tags sRGB explicitly since the decode drops the ICC profile.
- `src/tests.zig` — unit tests, pulled in by a `test {}` block at the bottom of `main.zig`.
- `src/imageio_tests.zig` — the ImageIO seam's own tests, likewise imported by `main.zig`'s `test`
  block. Its fixtures are PNGs embedded as byte literals, because `test-images/` is gitignored; the
  orientation tests build their own tagged PNGs in-process (ImageIO reads the PNG `eXIf` chunk).
- `build.zig` / `build.zig.zon` — ours (see "Toolchain"). Links the vendored archives + ImageIO
  frameworks and compiles `src/encode.c` into the exe and the test artifact; its comments record
  why each line is there.
- `third_party/` — vendored encode-only static archives (libavif, libaom, libwebp + libsharpyuv)
  and the headers for the two APIs we call. `third_party/README.md` records versions, provenance
  and the two traps the build cannot state.
- `docs/phase-b-baseline.md` — the pre-vendoring measurement of the shipping app (size, PSNR, AVIF
  `yuvFormat`, metadata) plus the fixture-set inventory and how to regenerate it. **Append-only:**
  it is the parity gate and cannot be re-measured now that the encoders have changed.
- `CHANGELOG.md` — user-facing release notes. Not an engineering record; PLAN.md and
  `docs/phase-b-baseline.md` are.

There is no npm/bun surface in this tree at all (`src/core.ts`, `package.json`, `tsconfig.json`,
`bun.lock` and `node_modules/` were the abandoned TS-core editor surface and are gone).

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

**The layout floor is a test, not a comment.** `tests.zig` lays the tallest state out at
`window_min_width` x `window_min_height` and fails naming the overflow in points. Anything that
grows a fixed-height row — the preview frame above all — has to be paid for somewhere; the test
says how much you are over.

## Native SDK surfaces this app uses
- Native dialogs (`runtime.showOpenDialog`/`showSaveDialog`, wired through a custom
  `HostCallBinding` — see "File acquisition, honestly")
- `fx.registerImage` + `<image>` for previews — **of an ImageIO thumbnail, never the source image.**
  Registered images cap at 1 MiB of *decoded* RGBA (512x512), so no real photo can be registered
  directly. `max_effect_host_result_bytes` (256 KiB) — which the preview pixels ride — binds
  tighter still, and `main.zig` asserts that fit at comptime. What actually SETS the 140px cap is
  neither: it is the fixed 144x144 frame the markup draws the preview inside.
- Three host commands of our own answered OFF the loop thread through `HostCallBinding`'s
  worker-carrier trio (`poll_fn`/`pending_fn`/`bind_services_fn`) plus `shutdown_fn`:
  `image.probe`, `image.thumbnail`, and `image.encode` (one request per output format — decode +
  encode + atomic write, replies the output size). `feedHostResult` is loop-thread-only — a
  worker parks its answer in its own slot and calls `services.wake()`. The dialogs and the two
  file commands answer synchronously from `request_fn`, which is equally supported and right for
  them.
- A host command bound by hand, `file.stat` — `update` can never hold an `Io`, the bridge can.
  Feeds `original_size`.
- Another, `file.copy` (`std.Io.Dir.copyFileAbsolute`) — Save As copies an already-produced output,
  which `fx.writeFile`'s 1 MiB cap can't hold.
- **No `fx.spawn` anywhere** — the app runs no subprocess.
- Hot-reload on `.native` files (Debug builds, via `.markup.watch_path`)
- `on_drop` (`UiApp.Options`, SDK 0.8.2+) for real window-wide file drops.
- `Options.tokens_fn` + `Options.on_appearance` for the app-owned palette — `tokens` (static) is
  NOT used, because the colour scheme is model state the footer's toggle can also move. Claiming
  either opts out of the SDK's automatic system-appearance theming, which is why the Model carries
  the scheme itself.
- Manifest: `capabilities = .{ "native_views", "gpu_surfaces", "file_drops" }` — markup renders onto
  a gpu_surface, so `gpu_surfaces` stays; `file_drops` is a real `app_manifest.CapabilityKind`
  string, confirmed by reading the SDK source (nothing in the runtime currently reads it as a gate —
  it's honest metadata, not a switch). Permissions are just `command` + `view`.

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
- Every new test assertion gets mutation-checked — break what it pins and confirm it fails, and
  fails for the right reason. See PLAN.md's "Testing strategy".
- **The comments are the most valuable thing in this tree, and the load-bearing ones are the
  longest — never prune them by volume.** Write and keep: traps that cost a day to rediscover
  (`build.zig`'s two modules, the framework search path, the archive link order, the mandatory
  libsharpyuv), non-obvious WHY (the scalar CTM calls over `CGAffineTransform`, the fixed-width
  preview header, NUL-delimited payloads), and invariants (`.failed` is always paired with a
  message; "do not simplify JPEG to 4:2:0"). Don't write, and cut on sight: historical narration
  ("this used to be X", "the `sips -g` hop this replaces"), milestone archaeology, and anything
  restating what the code plainly says.

## Two standing rules about automation
- **Never automate a native file dialog** (open or save panel). The app runs as a bare executable
  under `native dev`/`native build`; System Events cannot bring it frontmost, so global keystrokes
  land on whatever IS frontmost instead — this already typed a stray path into a live session once.
  Have the user drive every dialog by hand; everything else (button presses, chip selection,
  status/result assertions) drives fine with `native automate widget-click`.
- **File drops cannot be automated at all** (a different constraint from dialogs, same practical
  answer): have the user drag a real file onto the window by hand.
