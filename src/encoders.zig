//! The Zig-to-encoder seam: everything Smoosh knows about WRITING an image
//! file, against the encode-only static archives vendored under
//! `third_party/`. The mirror image of `src/imageio.zig`, which owns
//! reading.
//!
//! Unlike `imageio.zig`, this seam does NOT declare its C ABI by hand. The
//! libavif / libwebp encode APIs are struct-heavy — `avifEncoder` alone
//! has ~30 caller-mutable fields, `avifRGBImage` is a stack struct filled
//! by `avifRGBImageSetDefaults`, `WebPConfig`/`WebPPicture` are larger
//! still — and transcribing those layouts into Zig `extern struct`s is a
//! silent-miscompile risk with no upside. `src/encode.c` does that struct
//! work in C against the vendored headers and exposes a flat scalar ABI;
//! this file declares just the three functions of it.
//!
//! `pinned` and the three version probes below exist so `src/tests.zig`
//! can assert all three archive versions: a re-copied archive must not
//! change the encoder out from under `docs/phase-b-baseline.md` silently.
//!
//! The archives are stated in `build.zig` and linked into BOTH the exe and
//! the test artifact, along with `src/encode.c` and the two header roots it
//! needs. Read `build.zig`'s comments before touching that wiring — link
//! order and the mandatory libsharpyuv companion are both load-bearing and
//! both have a failure mode that hides until the other artifact is built.

const std = @import("std");
const chroma = @import("chroma.zig");

// ------------------------------------------------------------- versions

/// libwebp packs its version as (major << 16) | (minor << 8) | patch.
extern fn WebPGetEncoderVersion() c_int;

/// libavif and libaom both hand back a static NUL-terminated string.
/// libaom's carries a leading "v" (`VERSION_STRING_NOSP` in the generated
/// `aom_version.h`); libavif's does not.
extern fn avifVersion() [*:0]const u8;
extern fn aom_codec_version_str() [*:0]const u8;

/// The versions the parity baseline was measured against. An encoder
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

// -------------------------------------------------------------- encode

/// The pinned encoder settings, carried over LITERALLY from Phase A's
/// `avifenc -q 58 --speed 6` / `cwebp -q 80` — we vendor the same libaom
/// avifenc links and the same libwebp cwebp links, so the numbers mean the
/// same thing. Not user-tunable (see PLAN.md's non-goals).
pub const avif_quality: c_int = 58;
pub const avif_speed: c_int = 6;
pub const webp_quality: c_int = 80;

/// The floor `encodeThreads` clamps to, and the reason it exists.
///
/// libaom emits DIFFERENT bytes at exactly one thread than it does at two
/// or more, and identical bytes at every count from 2 upward — measured
/// over the whole fixture set, by hash and not merely by size
/// (`docs/phase-b-baseline.md`, "Round 2"). So the output is a function of
/// "threaded or not", not of "how many". Flooring at 2 is what keeps a
/// machine-derived count from making the encode machine-dependent: a
/// single-core host must still take the threaded path, or it alone would
/// produce bytes nothing else does.
pub const min_avif_threads: c_int = 2;

/// How many threads libaom may use for one AVIF encode.
///
/// Half the logical cores, floored at `min_avif_threads`. Two things pick
/// that shape, both measured on a 4P+4E M1 (`docs/phase-b-baseline.md`,
/// "Round 2"):
///
///   - **Half, not all.** The two formats of a "Both" run are two
///     concurrent workers, and WebP's encode is single-threaded with no
///     knob to change that. Handing AVIF every core makes AVIF finish
///     sooner and the RUN finish later, because it starves the WebP worker
///     — 4 threads gave a 754 ms wall against 809 ms at 8. Half the cores
///     is the measured optimum here and lands on the performance-core
///     count on every Apple Silicon part.
///   - **Cores, not a constant.** 4 is only optimal for this machine.
///
/// Safe to vary per machine ONLY because of the byte-identity above; read
/// `min_avif_threads` before changing the clamp.
pub fn encodeThreads() c_int {
    const cpus = std.Thread.getCpuCount() catch return min_avif_threads;
    const half: c_int = @intCast(cpus / 2);
    return @max(min_avif_threads, half);
}

pub const Error = error{
    /// libavif (or the RGB->YUV conversion feeding it) rejected the frame.
    AvifEncodeFailed,
    /// libwebp returned a zero-length buffer.
    WebpEncodeFailed,
};

/// The C shim (`src/encode.c`). Return 0 on success; on success `out`
/// points at a `malloc`'d buffer of `out_len` bytes to release with
/// `smoosh_encode_free`. Input is tight-packed 8-bit straight-alpha RGBA,
/// top-down — exactly `imageio.decode`'s output.
extern fn smoosh_encode_avif(
    rgba: [*]const u8,
    w: c_int,
    h: c_int,
    yuv_format: c_int,
    quality: c_int,
    speed: c_int,
    max_threads: c_int,
    out: *?[*]u8,
    out_len: *usize,
) c_int;
extern fn smoosh_encode_webp(
    rgba: [*]const u8,
    w: c_int,
    h: c_int,
    quality: c_int,
    out: *?[*]u8,
    out_len: *usize,
) c_int;
extern fn smoosh_encode_free(p: [*]u8) void;

/// A finished encode. `bytes` is owned by the C allocator; `deinit`
/// releases it. Callers write it to disk and drop it — nothing in Smoosh
/// keeps an encoded buffer around.
pub const Encoded = struct {
    bytes: []u8,

    pub fn deinit(self: *Encoded) void {
        smoosh_encode_free(self.bytes.ptr);
        self.* = undefined;
    }
};

/// Encode `pixels` (straight-alpha 8-bit RGBA, `width * height * 4` bytes,
/// top-down) as AVIF, reproducing `avifenc -q 58 --speed 6 --jobs N` --
/// see `encodeThreads` for the N and for why it does not perturb the
/// recorded baseline. `subsampling`
/// is what `chroma.forSource` decided the source container would have
/// yielded — the one `avifenc --yuv auto` behaviour decoding to RGBA
/// destroys.
pub fn encodeAvif(
    pixels: []const u8,
    width: u32,
    height: u32,
    subsampling: chroma.Subsampling,
) Error!Encoded {
    std.debug.assert(pixels.len == @as(usize, width) * height * 4);
    var out: ?[*]u8 = null;
    var out_len: usize = 0;
    const rc = smoosh_encode_avif(
        pixels.ptr,
        @intCast(width),
        @intCast(height),
        @intFromEnum(subsampling),
        avif_quality,
        avif_speed,
        encodeThreads(),
        &out,
        &out_len,
    );
    if (rc != 0 or out == null or out_len == 0) return Error.AvifEncodeFailed;
    return .{ .bytes = out.?[0..out_len] };
}

/// Encode `pixels` (same layout as `encodeAvif`) as WebP, reproducing
/// `cwebp -q 80`.
pub fn encodeWebp(pixels: []const u8, width: u32, height: u32) Error!Encoded {
    std.debug.assert(pixels.len == @as(usize, width) * height * 4);
    var out: ?[*]u8 = null;
    var out_len: usize = 0;
    const rc = smoosh_encode_webp(
        pixels.ptr,
        @intCast(width),
        @intCast(height),
        webp_quality,
        &out,
        &out_len,
    );
    if (rc != 0 or out == null or out_len == 0) return Error.WebpEncodeFailed;
    return .{ .bytes = out.?[0..out_len] };
}
