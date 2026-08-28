//! VALIDATED SPIKE — not built as part of the app. This file IS a
//! `build.zig`: the transplant reference for the ejected build M14 needs.
//! (Kept under a `.zig` name like the other spikes; copy it to
//! `build.zig` at the app root, do not `@import` it.)
//!
//! PLAN.md's Phase B step 5: prove the link path before vendoring
//! anything. `native eject`, swap `addApp` for `addAppArtifacts`, link
//! ONE prebuilt static archive into the app executable, call a symbol
//! from it and print the answer.
//!
//! Run against a throwaway `native init --template zig-core` app
//! (`linkspike`) on 2026-08-28: CLI 0.10.1, Zig 0.16.0, macOS 26.6,
//! Xcode SDK MacOSX26.5, arm64.
//!
//! VERDICT: WORKS, and it is better than PLAN.md assumed — the same seam
//! also fixes the standing "`native test` links no frameworks" problem.
//! Four findings, in the order they bit:
//!
//! 1. `addAppArtifacts` EXISTS AND IS PUBLIC in CLI 0.10.1
//!    (`build.zig:48` re-exports `build/app.zig`'s). It returns
//!    `AppArtifacts{ exe, tests, install, run }`, so `exe.root_module`
//!    is reachable exactly as planned and the PLAN.md fallback ("hand-
//!    write a build.zig calling the same public API") is not needed.
//!    `native eject` writes a `build.zig` calling `addApp` plus a
//!    `build.zig.zon` depending on the global CLI by RELATIVE PATH; the
//!    swap to `addAppArtifacts` is a two-line edit. `eject` REFUSES if
//!    either file already exists — it is a one-way, one-shot command.
//!
//! 2. `native build`, `native test` and `native check` all still work on
//!    an ejected app. `check` still validates markup against the model
//!    contract (it warned about an unbound model field), so ejecting
//!    costs none of the CLI workflow.
//!
//! 3. THE APP MODULE IS SHARED WITH TWO HIDDEN ARTIFACTS; THE TEST
//!    MODULE IS NOT. `artifacts.exe.root_module` is the same
//!    `*std.Build.Module` the `-analysis` object and the
//!    `-model-contract` exe compile, so wiring it once covers all
//!    three. `artifacts.tests.root_module` is a SEPARATE module (the
//!    fresh Debug one `build/app.zig` makes when `app_optimize !=
//!    optimize`) and must be wired by hand — wire only the exe and a
//!    test that calls into the archive fails with
//!    `undefined symbol: _WebPGetEncoderVersion`, which is precisely
//!    CLAUDE.md's `_CFRelease` failure in a new coat.
//!
//!    Corollary worth acting on: `mod.linkFramework("ImageIO", ...)` on
//!    the TEST module makes `src/imageio_tests.zig` runnable under
//!    `native test` for the first time. Proven here with a test calling
//!    `CGImageSourceGetTypeID()`. The catch is finding 4.
//!
//! 4. `linkFramework` ALONE IS NOT ENOUGH — the framework SEARCH PATH is
//!    unset on every artifact the SDK does not run its platform wiring
//!    over, and the failure reads
//!    `unable to find framework 'ImageIO'. searched paths:  none`.
//!    `addAppArtifacts` has already resolved `b.sysroot` (its
//!    `nativeSdkTarget` shells out to `xcrun --show-sdk-path`), so the
//!    fix is one `addFrameworkPath` per module, below. This mirrors the
//!    SDK's own private `addPlatformLinkSearchPaths`.
//!
//! ALSO MEASURED:
//!
//! - libwebp.a IS NOT SELF-CONTAINED. `picture_csp_enc.c.o` pulls
//!   `SharpYuvConvert` / `SharpYuvInit` / `SharpYuvGetConversionMatrix`,
//!   so `libsharpyuv.a` must be linked beside it. PLAN.md already lists
//!   libsharpyuv; this is the proof it is mandatory, not optional. Note
//!   the ReleaseFast EXE linked clean WITHOUT it and only the Debug test
//!   artifact failed — a missing companion archive can hide until the
//!   other artifact is built.
//!
//! - Linking an archive costs only what is REFERENCED: 6,466,408 ->
//!   6,467,016 bytes (+608) for libwebp.a + libsharpyuv.a with nothing
//!   but `WebPGetEncoderVersion` called. PLAN.md's "+5 MB" budget is a
//!   claim about calling the ENCODERS — measured in step 6 at +5.20 MiB,
//!   see the STEP 6 UPDATE below.
//!
//! - No `@cImport`, no header, no include path: a hand-written
//!   `extern fn WebPGetEncoderVersion() c_int;` links against the
//!   archive, same convention as `src/imageio.zig`.
//!
//! WHAT IT DID NOT PROVE:
//!
//! - Nothing about VENDORING. The archives here are Homebrew's
//!   (`/opt/homebrew/opt/webp/lib`, libwebp 1.6.0, arm64, non-fat).
//!   Producing our own encode-only `.a` files is step 6 and is untouched
//!   by this spike; libavif and libaom were never linked here at all.
//!   The paths below are absolute Homebrew paths precisely so they do
//!   NOT read as a vendoring answer — the real build will use
//!   `b.path("third_party/...")`.
//! - Nothing about calling a real encoder. Only `WebPGetEncoderVersion`
//!   was called (it returned 1.6.0 both from `zig build test` and from
//!   the running GUI app).
//! - `native dev` and `native package` were NOT run against the ejected
//!   app. Neither is expected to care (both drive the same graph /
//!   consume the built binary), but neither was checked.
//! - x86_64 and universal binaries. arm64-macos only, non-fat archives.
//! - Whether ejecting the REAL app leaves `native check`'s model
//!   contract regeneration intact across a CLI upgrade. The tree still
//!   pins no SDK version — the ejected `build.zig.zon` points at the
//!   global CLI by path, so upgrades still flow, but that was not
//!   exercised.
//!
//! THE APP-SIDE HALF OF THE SPIKE, for the record. In `src/main.zig`:
//!
//!     extern fn WebPGetEncoderVersion() c_int;
//!
//!     /// A test build never analyzes `main`, so without a reachable
//!     /// caller the extern symbol is never emitted and the test
//!     /// artifact links clean whether or not the archive is wired in.
//!     /// That is why the wrapper exists.
//!     pub fn webpEncoderVersion() c_int {
//!         return WebPGetEncoderVersion();
//!     }
//!
//!     extern fn CGImageSourceGetTypeID() c_ulong;
//!     pub fn imageSourceTypeId() c_ulong {
//!         return CGImageSourceGetTypeID();
//!     }
//!
//! and in `src/tests.zig`:
//!
//!     test "libwebp links into the test artifact, not just the exe" {
//!         try testing.expect(main.webpEncoderVersion() > 0);
//!     }
//!     test "ImageIO links into the test artifact" {
//!         try testing.expect(main.imageSourceTypeId() != 0);
//!     }
//!
//! Both passed (7/7) once the modules below were wired.
//!
//! ============================ STEP 6 UPDATE ============================
//!
//! 2026-08-28. Step 6 closed the "nothing about VENDORING" gap above: all
//! three encode-only archives now exist, built from source for arm64-macos
//! under `~/Code/zig/smoosh-vendor`, and the body below links all three
//! instead of Homebrew's libwebp. The full recipe (configure invocations,
//! source hashes, encode-only verification) is in
//! `docs/phase-b-baseline.md` under "Phase B step 6"; only what changes
//! THIS FILE is repeated here:
//!
//! - LINK ORDER MATTERS. `libavif.a` carries its own object files only and
//!   leaves all 15 `aom_codec_*` symbols undefined, so it must be added
//!   BEFORE `libaom.a`.
//! - The size question this spike left open is answered: +1,424 bytes for
//!   all three archives with only their version symbols called, and
//!   +5,451,472 (+5.20 MiB) once the real encoder entry points are
//!   referenced. Same ReleaseFast app, three builds.
//! - `native build` and `native test` (9/9) are both green against the
//!   three archives, and `otool -L` on the exe shows no new dylibs.
//!
//! Still not proven, and inherited unchanged from above: `native dev`,
//! `native package`, x86_64/universal, and calling an encoder for real.
//! Output parity is ALSO still open — our libaom is `-O3` where
//! Homebrew's is `-Os`, so M14 must re-encode the fixture set rather than
//! assume the bitstream is unchanged.
//!
//! The paths below are still absolute and outside the repo, which is
//! still deliberate: the real build will use `b.path("third_party/...")`.

const std = @import("std");
const native_sdk = @import("native_sdk");

// Step 6's encode-only archives, built from source. libwebp.a alone does
// not link: picture_csp_enc.c.o calls into libsharpyuv.
const vendor = "/Users/coryasato/Code/zig/smoosh-vendor/out";
const libavif_a = vendor ++ "/libavif/lib/libavif.a";
const libaom_a = vendor ++ "/libaom/lib/libaom.a";
const libwebp_a = vendor ++ "/libwebp/lib/libwebp.a";
const libsharpyuv_a = vendor ++ "/libwebp/lib/libsharpyuv.a";

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{
        .name = "linkspike",
        .manifest = "app.json",
    });

    // Both modules, deliberately: the exe's module is shared with the
    // analysis object and the model-contract exe, but the test artifact
    // gets its own Debug module and inherits none of this.
    for ([_]*std.Build.Module{ artifacts.exe.root_module, artifacts.tests.root_module }) |mod| {
        // libavif before libaom: libavif.a leaves every aom_codec_*
        // symbol undefined for the archive under it to satisfy.
        mod.addObjectFile(.{ .cwd_relative = libavif_a });
        mod.addObjectFile(.{ .cwd_relative = libaom_a });
        mod.addObjectFile(.{ .cwd_relative = libwebp_a });
        mod.addObjectFile(.{ .cwd_relative = libsharpyuv_a });

        // Framework search paths are not set on artifacts the SDK does
        // not run `linkPlatform` over, and `-framework Foo` then fails
        // with "searched paths:  none". `addAppArtifacts` has already
        // resolved `b.sysroot` via xcrun.
        if (b.sysroot) |sysroot| {
            mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
        }
        mod.linkFramework("ImageIO", .{});
        mod.linkFramework("CoreGraphics", .{});
        mod.linkFramework("CoreFoundation", .{});
    }
}
