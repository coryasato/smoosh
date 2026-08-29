//! Which chroma format the AVIF encoder must use for a given source —
//! the single most consequential encoder knob, and the one piece of
//! `avifenc`'s behaviour that decoding through ImageIO would otherwise
//! destroy.
//!
//! `avifenc --yuv auto` is NOT a content detector: it never inspects the
//! image. It reads the SOURCE CONTAINER, and after M14 hands it decoded
//! RGBA the container is gone. So the table has to be carried explicitly,
//! here, or every AVIF Smoosh writes changes chroma silently. Measured
//! consequence on a UI fixture: 7.7 dB.
//!
//! The table (PLAN.md, "Correctness requirements"; measured per fixture in
//! `docs/phase-b-baseline.md`):
//!
//!   | Source                                | yuvFormat                  |
//!   |---------------------------------------|----------------------------|
//!   | JPEG                                  | whatever the JPEG's own is |
//!   | PNG / HEIC / TIFF / GIF / WebP (color)| 4:4:4                      |
//!   | grayscale JPEG                        | 4:0:0                      |
//!
//! **Do not simplify "JPEG" to 4:2:0.** Our own primary fixture is the
//! counter-example: `large.jpg` is a photograph and is 4:4:4, because the
//! JPEG itself is `1x1,1x1,1x1`. Quality >= 90 out of most encoders is
//! 4:4:4; hardcoding 420 would soften every high-quality JPEG and every
//! screenshot. And do NOT invent an "is this photographic?" heuristic —
//! that is new behaviour, and it would disagree with v0.1 on exactly the
//! files that justified vendoring libaom.
//!
//! Everything here is a pure function over bytes: no ImageIO, no
//! allocation, no I/O. Tested in `src/tests.zig`.
//!
//! The one consumer is the `image.encode` worker in `main.zig`'s
//! `HostBridge` (M14c): for a JPEG source it reads a prefix of the file
//! and calls `forSource` to pick libavif's `yuvFormat`.

const std = @import("std");

/// The four formats libavif can be asked for. Named after the AVIF
/// values rather than the JPEG ones so the M14c seam reads as a direct
/// mapping onto `avifPixelFormat`.
pub const Subsampling = enum {
    yuv444,
    yuv422,
    yuv420,
    /// Monochrome: no chroma planes at all.
    yuv400,
};

/// The UTI ImageIO reports for a JPEG. `image.probe` carries it back in
/// its reply, which is the whole reason `Model` records the UTI rather
/// than sniffing the extension: a mis-named JPEG must still be read as
/// a JPEG here.
pub const jpeg_uti = "public.jpeg";

/// How much of the source file `forSource` wants for a JPEG. The SOF
/// marker sits after every APP segment, and an EXIF APP1 carrying a
/// full-size embedded thumbnail is capped at 64 KiB by the marker's own
/// 16-bit length — several such segments can precede SOF, so read
/// generously. Handing `forSource` the WHOLE file is always correct and
/// is what a caller that already has the bytes should do.
///
/// Read a PREFIX, not a capped whole file: `Io.Dir.readFileAlloc` with a
/// `.limited(...)` returns `error.StreamTooLong` on anything bigger
/// rather than truncating, so every real photograph would fail. Open the
/// file and `readSliceShort` into a buffer of this size instead — which
/// is also why the parser must tolerate a JPEG cut off mid-segment, and
/// does (it returns null rather than guessing).
pub const jpeg_scan_bytes: usize = 1024 * 1024;

/// The chroma format `avifenc --yuv auto` would have picked for this
/// source, reproduced from the container alone.
///
/// `head` is the leading bytes of the source file (see `jpeg_scan_bytes`)
/// and is read ONLY for JPEG sources; pass an empty slice for anything
/// else. A JPEG whose SOF cannot be found falls back to 4:4:4 rather
/// than to 4:2:0 — an unparseable JPEG is a file we cannot reproduce
/// `avifenc` on either way, and of the two guesses 4:4:4 is the one that
/// cannot lose chroma detail.
pub fn forSource(uti: []const u8, head: []const u8) Subsampling {
    if (!std.mem.eql(u8, uti, jpeg_uti)) return .yuv444;
    return parseJpegSampling(head) orelse .yuv444;
}

/// Read a JPEG's own chroma sampling out of its SOF marker.
///
/// ImageIO does not expose this — verified by dumping the FULL property
/// dictionary for a 4:2:0 JPEG and a 4:4:4 one, which are identical apart
/// from dimensions. So it is parsed by hand, the same way libavif's own
/// JPEG reader does it: component count 1 means monochrome, otherwise the
/// FIRST component's sampling factors give the ratio (luma always carries
/// the maximum factors in a conforming file).
///
/// Returns null when `bytes` is not a JPEG, is truncated before SOF, or
/// reaches the scan (SOS) without one.
pub fn parseJpegSampling(bytes: []const u8) ?Subsampling {
    if (bytes.len < 4) return null;
    // SOI. A JPEG that does not start here is not one, whatever its name.
    if (bytes[0] != 0xFF or bytes[1] != 0xD8) return null;

    var index: usize = 2;
    while (index + 1 < bytes.len) {
        if (bytes[index] != 0xFF) return null; // desynced: not a marker boundary

        // Any number of 0xFF fill bytes may precede the marker code.
        var marker = bytes[index + 1];
        while (marker == 0xFF) {
            index += 1;
            if (index + 1 >= bytes.len) return null;
            marker = bytes[index + 1];
        }
        index += 2;

        switch (marker) {
            // Standalone markers: no length, no payload.
            0x01, 0xD0...0xD8 => continue,
            // End of image, or the start of entropy-coded data. Either way
            // no SOF is coming — a JPEG with no frame header at all.
            0xD9, 0xDA => return null,
            else => {},
        }

        if (index + 2 > bytes.len) return null;
        const length = std.mem.readInt(u16, bytes[index..][0..2], .big);
        // The length counts itself, so anything under 2 is corrupt.
        if (length < 2) return null;
        const payload_start = index + 2;
        const payload_len = length - 2;
        if (payload_start + payload_len > bytes.len) return null;

        if (isStartOfFrame(marker)) {
            return samplingFromFrameHeader(bytes[payload_start..][0..payload_len]);
        }
        index = payload_start + payload_len;
    }
    return null;
}

/// Every SOFn: baseline, extended, progressive, lossless, and their
/// arithmetic-coded and hierarchical variants. The three holes are not
/// frame headers at all — 0xC4 is DHT, 0xC8 is reserved (JPG), 0xCC is
/// DAC — and treating one as a frame would read a Huffman table as
/// sampling factors.
fn isStartOfFrame(marker: u8) bool {
    return switch (marker) {
        0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => true,
        else => false,
    };
}

/// SOF payload (the two length bytes already stripped): precision (1),
/// height (2), width (2), component count (1), then three bytes per
/// component — id, sampling factors packed `h << 4 | v`, quant table.
fn samplingFromFrameHeader(payload: []const u8) ?Subsampling {
    if (payload.len < 6) return null;
    const components = payload[5];
    if (components == 0) return null;
    // One component is monochrome. `gray.jpg` is the fixture, and Phase A
    // measured it as YUV400.
    if (components == 1) return .yuv400;

    if (payload.len < 9) return null;
    const factors = payload[7];
    const horizontal = factors >> 4;
    const vertical = factors & 0x0F;

    // The three ratios AVIF can express. Everything else — 4:1:1 (h=4),
    // 4:4:0 (1x2), or a nonsense factor — has no AVIF equivalent, and
    // libavif's own reader falls through to the default for exactly the
    // same cases. 4:4:4 is that default and loses nothing.
    if (horizontal == 1 and vertical == 1) return .yuv444;
    if (horizontal == 2 and vertical == 1) return .yuv422;
    if (horizontal == 2 and vertical == 2) return .yuv420;
    return .yuv444;
}
