//! This build belongs to Smoosh: the `native` CLI generates no build graph
//! for this tree and drives this file through `zig build` instead, so it
//! will never rewrite it. `native eject` is one-shot and refuses if this
//! file exists — there is no re-ejecting to pick up CLI changes.
//!
//! `addAppArtifacts` wires the complete standard app build — executable,
//! `zig build run`, `zig build test`, and the
//! -Dplatform/-Dweb-engine/-Dautomation/-Doptimize flags — from the
//! framework's build/app.zig, so a framework upgrade still upgrades the
//! build, while handing back the artifacts so we can link our own archives
//! into them. `addApp` does the same wiring but returns nothing, and
//! `AppOptions` has no link passthrough, so owning the build is the only
//! route to a vendored encoder.
//!
//! Read the comments below before adding a library. Each records why a
//! line is there, and each names a failure mode that hides until the
//! OTHER artifact is built.

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

/// Frameworks `src/imageio.zig` rides in on, plus the two
/// `src/workspace.zig` needs for "Show in Finder". The SDK adds the
/// ImageIO set to the exe itself via its private `linkPlatform`, but not
/// to the test artifact — stating them here is what lets
/// `src/imageio_tests.zig` run under `native test` at all.
///
/// AppKit is `NSWorkspace`, Foundation is the `NSString`/`NSURL`/`NSArray`
/// the reveal call is built out of. AppKit re-exports Foundation, so the
/// link would succeed without it; it is named anyway because the code
/// calls into it directly and a framework you use is a framework you
/// state.
const frameworks = [_][]const u8{ "ImageIO", "CoreGraphics", "CoreFoundation", "AppKit", "Foundation" };

/// The C shim over the struct-heavy libavif / libwebp encode APIs
/// (`src/encoders.zig`'s header explains why it is C and not Zig
/// `extern struct`s). It `#include`s `avif/avif.h` and `webp/encode.h`, so
/// both vendored header roots go on the include path — of BOTH modules,
/// same reason the archives do.
const encode_shim = "src/encode.c";

/// Repo-root files the tests `@embedFile` to check the app against its own
/// manifest and changelog. The string is both the path and the name
/// `@embedFile` uses.
const embedded_files = [_][]const u8{ "app.zon", "CHANGELOG.md" };
const header_paths = [_][]const u8{
    "third_party/libavif/include",
    "third_party/libwebp/include",
};

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
    //
    // But when `app_optimize == optimize` — the ReleaseFast `native build`
    // — the SDK hands back the SAME module for both, so the list must be
    // de-duplicated: adding a compiled `src/encode.c` twice is a fatal
    // `duplicate symbol`. (Linking an `.a` twice is merely wasteful, so
    // this only bites once there is a `.c` in the loop.)
    const exe_mod = artifacts.exe.root_module;
    const test_mod = artifacts.tests.root_module;
    const mods: []const *std.Build.Module = if (exe_mod == test_mod)
        &.{exe_mod}
    else
        &.{ exe_mod, test_mod };
    for (mods) |mod| {
        for (vendor_archives) |archive| mod.addObjectFile(b.path(archive));

        // `app.zon` and `CHANGELOG.md` reachable to `@embedFile`, for the
        // tests that pin the app's identity and version against them.
        // Both live at the REPO ROOT while the module root is `src/`, and
        // `@embedFile("../app.zon")` is refused outright ("embed of file
        // outside package path"). An anonymous import is the supported way
        // to hand a module a file it could not otherwise reach; the name
        // given here is the string `@embedFile` takes.
        //
        // Only `src/tests.zig` references them, and it compiles into the
        // test artifact alone, so the exe carries no changelog. They are
        // wired on both modules for the same reason everything else in
        // this loop is (see above) — a test-artifact-only import would
        // still have to survive the de-duplicated single-module case.
        for (embedded_files) |file| {
            mod.addAnonymousImport(file, .{ .root_source_file = b.path(file) });
        }

        // The encode shim and the headers it needs. `addCSourceFile` pulls
        // in the C compiler and libc for this module; the archives above
        // supply every symbol the shim references.
        for (header_paths) |header_path| mod.addIncludePath(b.path(header_path));
        mod.addCSourceFile(.{ .file = b.path(encode_shim), .flags = &.{"-std=c11"} });
        // The shim calls malloc/memcpy and libwebp/libavif expect libc; the
        // SDK does not link it for us on either module.
        mod.link_libc = true;

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
