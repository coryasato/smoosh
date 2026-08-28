//! This build belongs to Smoosh, written once by `native eject` and then
//! extended by hand for M14. The `native` CLI stops generating a build
//! graph and drives this file through `zig build` instead; it will never
//! rewrite it. `addAppArtifacts` wires the complete standard app build —
//! executable, `zig build run`, `zig build test`, and the
//! -Dplatform/-Dweb-engine/-Dautomation/-Doptimize flags — from the
//! framework's build/app.zig, so a framework upgrade still upgrades the
//! build, while handing back the artifacts so we can link our own
//! archives into them. `addApp` (what eject wrote) does the same wiring
//! but returns nothing, and `AppOptions` has no link passthrough, so
//! owning the build is the only route to a vendored encoder.
//!
//! Everything below is transplanted from
//! `docs/spikes/static-archive-link-spike.zig`, which proved it against a
//! throwaway app first. Read that file's header before changing any of
//! it — it records why each line is there and what is still unproven.

const std = @import("std");
const native_sdk = @import("native_sdk");

/// Encode-only static archives, built from source for arm64-macos.
/// `third_party/README.md` records the versions, hashes and the exact
/// CMake invocations; `docs/phase-b-baseline.md` ("Phase B step 6") has
/// the full derivation and the encode-only verification.
const vendor_archives = [_][]const u8{
    // libavif MUST precede libaom: libavif.a carries its own objects only
    // and leaves all 15 `aom_codec_*` symbols undefined for the archive
    // under it to satisfy.
    "third_party/libavif/lib/libavif.a",
    "third_party/libaom/lib/libaom.a",
    // libwebp.a is NOT self-contained: picture_csp_enc.c.o calls
    // SharpYuvConvert/SharpYuvInit/SharpYuvGetConversionMatrix, so
    // libsharpyuv.a is mandatory beside it, not a nicety. The ReleaseFast
    // exe links clean without it and only the Debug test artifact fails.
    "third_party/libwebp/lib/libwebp.a",
    "third_party/libwebp/lib/libsharpyuv.a",
};

/// Frameworks `src/imageio.zig` rides in on. The SDK adds these to the
/// exe itself via its private `linkPlatform`, but not to the test
/// artifact — stating them here is what lets `src/imageio_tests.zig` run
/// under `native test` at all.
const frameworks = [_][]const u8{ "ImageIO", "CoreGraphics", "CoreFoundation" };

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{
        .name = "smoosh",
        .manifest = "app.zon",
    });

    // Both modules, deliberately. `exe.root_module` is the same
    // *std.Build.Module the hidden `-analysis` object and `-model-contract`
    // exe compile, so wiring it once covers all three; `tests.root_module`
    // is a SEPARATE Debug module (build/app.zig makes a fresh one whenever
    // app_optimize != optimize) that inherits none of it. Miss the test
    // module and a test touching an archive dies at link time on
    // `undefined symbol: _WebPGetEncoderVersion`.
    for ([_]*std.Build.Module{ artifacts.exe.root_module, artifacts.tests.root_module }) |mod| {
        for (vendor_archives) |archive| mod.addObjectFile(b.path(archive));

        // `linkFramework` alone is not enough: the framework SEARCH PATH is
        // unset on every artifact the SDK does not run its platform wiring
        // over, and the link then fails with "searched paths:  none".
        // `addAppArtifacts` has already resolved b.sysroot (its
        // nativeSdkTarget shells out to `xcrun --show-sdk-path`). This
        // mirrors the SDK's own private addPlatformLinkSearchPaths.
        if (b.sysroot) |sysroot| {
            mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
        }
        for (frameworks) |framework| mod.linkFramework(framework, .{});
    }
}
