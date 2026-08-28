//! The Zig-to-encoder seam: everything Smoosh will know about WRITING an
//! image file, against the encode-only static archives vendored under
//! `third_party/`. The mirror image of `src/imageio.zig`, which owns
//! reading.
//!
//! M14a WIRED THE BUILD; IT DID NOT WRITE THE ENCODERS. Right now this
//! file holds nothing but the three version probes below, and the app
//! still shells out to `avifenc`/`cwebp` exactly as v0.1 did. The encode
//! functions land in M14c, and this is where they go. See PLAN.md's M14
//! entry for the split and what each part owes.
//!
//! `extern fn` rather than `@cImport`, same convention and same reason as
//! `src/imageio.zig`: every type crossing this boundary is an opaque
//! pointer or a plain scalar, so declaring them by hand costs less than
//! wiring a header search — even though, unlike the frameworks, we now
//! own the build and could. The headers for the two APIs we call are
//! vendored beside the archives (`third_party/*/include`) as the ABI
//! reference these declarations are written against.
//!
//! The archives are stated in `build.zig` and linked into BOTH the exe
//! and the test artifact. Read `build.zig`'s comments before touching
//! that wiring — link order and the mandatory libsharpyuv companion are
//! both load-bearing and both have a failure mode that hides until the
//! other artifact is built.

const std = @import("std");

/// libwebp packs its version as (major << 16) | (minor << 8) | patch.
extern fn WebPGetEncoderVersion() c_int;

/// libavif and libaom both hand back a static NUL-terminated string.
/// libaom's carries a leading "v" (`VERSION_STRING_NOSP` in the generated
/// `aom_version.h`); libavif's does not.
extern fn avifVersion() [*:0]const u8;
extern fn aom_codec_version_str() [*:0]const u8;

/// The versions the Phase A baseline was measured against. An encoder
/// upgrade is allowed — but it must be a DECISION, re-measured against
/// `docs/phase-b-baseline.md`, not something that arrives silently with a
/// re-copied archive. `src/tests.zig` pins all three.
pub const pinned = struct {
    pub const libwebp: c_int = 0x01_06_00; // 1.6.0
    pub const libavif = "1.4.2";
    pub const libaom = "v3.14.1";
};

/// Encoded (major << 16) | (minor << 8) | patch. A plain `pub fn` wrapper
/// rather than a direct call at the use site, because a test build never
/// analyzes `main`: without a reachable caller the extern symbol is never
/// emitted and the test artifact links clean whether or not the archive
/// is wired in. These three wrappers are what make the link proof real.
pub fn libwebpVersion() c_int {
    return WebPGetEncoderVersion();
}

pub fn libavifVersion() []const u8 {
    return std.mem.span(avifVersion());
}

pub fn libaomVersion() []const u8 {
    return std.mem.span(aom_codec_version_str());
}
