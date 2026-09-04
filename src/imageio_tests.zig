//! Tests for `src/imageio.zig`. They run under `native test` like
//! everything else — `main.zig`'s `test` block imports this file, and
//! `build.zig` states the ImageIO frameworks on the test artifact's
//! module (the SDK's own platform wiring never reaches it).
//!
//! The pure helpers (`swapsAxes`, `unpremultiply`) are NOT here: they link
//! fine without frameworks, so they are pinned in `src/tests.zig` beside
//! the rest of the pure logic.

const std = @import("std");
const imageio = @import("imageio.zig");
const testing = std.testing;

const Error = imageio.Error;
const max_thumbnail_edge = imageio.max_thumbnail_edge;
const decode = imageio.decode;
const probe = imageio.probe;
const thumbnail = imageio.thumbnail;

// The three PNGs below are written out to a temp file per test rather
// than read from `test-images/`: those fixtures are gitignored, so a
// fresh clone would silently skip everything. Solid-colour 8-bit RGBA,
// generated once and pasted in.

const wide_png =
    "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x01\x40" ++
    "\x00\x00\x00\xa0\x08\x06\x00\x00\x00\x7d\xa3\xb5\x9c\x00\x00\x01\xaf\x49\x44\x41" ++
    "\x54\x78\xda\xed\xd4\x31\x01\x00\x00\x08\xc3\xb0\xf9\x57\x35\x67\x20\x83\x83\x1c" ++
    "\x31\xd0\xa3\x69\x3b\x00\x1f\x45\x04\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0" ++
    "\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0" ++
    "\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0" ++
    "\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\x30" ++
    "\x40\x21\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04" ++
    "\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04" ++
    "\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04" ++
    "\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\xc0\x00\x01\x0c\x10\xc0\x00\x01" ++
    "\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01" ++
    "\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01" ++
    "\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01" ++
    "\x0c\x10\x30\x40\x11\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40" ++
    "\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40" ++
    "\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40" ++
    "\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\xc0\x00\x85\x00\x0c" ++
    "\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c" ++
    "\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c" ++
    "\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x0c" ++
    "\x10\xc0\x00\x01\x0c\x10\xc0\x00\x01\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03" ++
    "\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03\x04\x30\x40\x00\x03" ++
    "\x04\x30\x40\x00\x03\x04\xb8\xb0\x38\xa6\x5e\x08\x4a\x47\xd1\x62\x00\x00\x00\x00" ++
    "\x49\x45\x4e\x44\xae\x42\x60\x82";

const tiny_png =
    "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x08" ++
    "\x00\x00\x00\x08\x08\x06\x00\x00\x00\xc4\x0f\xbe\x8b\x00\x00\x00\x12\x49\x44\x41" ++
    "\x54\x78\xda\x63\x70\x70\x70\xf8\x8f\x0f\x33\x8c\x0c\x05\x00\x5b\xbf\x6f\xc1\x98" ++
    "\xb7\x07\xe2\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

const alpha_png =
    "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x08" ++
    "\x00\x00\x00\x08\x08\x06\x00\x00\x00\xc4\x0f\xbe\x8b\x00\x00\x00\x12\x49\x44\x41" ++
    "\x54\x78\xda\x63\x38\x91\x62\xd4\x80\x0f\x33\x8c\x0c\x05\x00\xc3\xdb\x77\x81\x96" ++
    "\x11\x33\xf5\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

/// Writes `bytes` under `/tmp/smoosh-imageio-tests/` and returns the path,
/// which is valid for the life of `buffer`.
fn writeFixture(buffer: []u8, name: []const u8, bytes: []const u8) ![]const u8 {
    const dir = "/tmp/smoosh-imageio-tests";
    try std.Io.Dir.cwd().createDirPath(testing.io, dir);
    const path = try std.fmt.bufPrint(buffer, "{s}/{s}", .{ dir, name });
    var file = try std.Io.Dir.cwd().createFile(testing.io, path, .{});
    defer file.close(testing.io);
    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    return path;
}

test "probe reads a real file's dimensions and container without decoding it" {
    var path_buffer: [256]u8 = undefined;
    const path = try writeFixture(&path_buffer, "wide.png", wide_png);

    const info = try probe(path);
    try testing.expectEqual(@as(u32, 320), info.width);
    try testing.expectEqual(@as(u32, 160), info.height);
    // Sniffed from the bytes, not read off the ".png" on the end.
    try testing.expectEqualStrings("public.png", info.uti());
    // No EXIF at all, so no tag — upright.
    try testing.expectEqual(@as(u8, 0), info.orientation);
}

test "probe reports a non-image by frame count, not by a null source" {
    var path_buffer: [256]u8 = undefined;
    const path = try writeFixture(
        &path_buffer,
        "not-an-image.jpg",
        "this is not an image, whatever the extension says",
    );

    // `CGImageSourceCreateWithURL` SUCCEEDS on this and hands back a
    // non-null source; only the frame count says otherwise. Testing the
    // pointer instead would report the wrong error two hops later.
    try testing.expectError(Error.NotAnImage, probe(path));
}

test "the thumbnail caps at the max edge, keeps aspect, and never upscales" {
    var pixels: [max_thumbnail_edge * max_thumbnail_edge * 4]u8 = undefined;
    var path_buffer: [256]u8 = undefined;

    const wide_path = try writeFixture(&path_buffer, "wide.png", wide_png);
    const capped = try thumbnail(wide_path, &pixels);
    // The 320x160 fixture, capped on its long edge with aspect kept.
    try testing.expectEqual(@as(u32, 140), capped.width);
    try testing.expectEqual(@as(u32, 70), capped.height);
    try testing.expectEqual(@as(usize, 140 * 70 * 4), capped.pixels.len);

    // This is why Phase A's drawn-size clamp could go: `sips -Z` UPSCALED
    // an 8x8 source into a blurry full-size square, ImageIO leaves it 8x8.
    const tiny_path = try writeFixture(&path_buffer, "tiny.png", tiny_png);
    const small = try thumbnail(tiny_path, &pixels);
    try testing.expectEqual(@as(u32, 8), small.width);
    try testing.expectEqual(@as(u32, 8), small.height);
}

test "a decoded thumbnail comes back as straight-alpha 8-bit RGBA" {
    var pixels: [max_thumbnail_edge * max_thumbnail_edge * 4]u8 = undefined;
    var path_buffer: [256]u8 = undefined;

    // 8x8 of one half-transparent colour (200,100,50 at alpha 128), small
    // enough that ImageIO returns it unscaled — so every output pixel is
    // comparable to the input rather than to a resampling of it.
    const path = try writeFixture(&path_buffer, "alpha.png", alpha_png);
    const decoded = try thumbnail(path, &pixels);
    try testing.expectEqual(@as(usize, 8 * 8 * 4), decoded.pixels.len);
    try testing.expectEqual(@as(u8, 128), decoded.pixels[3]);
    // `CGBitmapContextCreate`'s only 8-bit RGBA layout is PREMULTIPLIED,
    // so straight-alpha values here mean `unpremultiply` really ran. The
    // round trip through 255 costs at most a unit of rounding.
    for ([_]struct { usize, u8 }{ .{ 0, 200 }, .{ 1, 100 }, .{ 2, 50 } }) |expected| {
        const index, const value = expected;
        try testing.expect(@abs(@as(i32, decoded.pixels[index]) - @as(i32, value)) <= 2);
    }
}

test "a buffer too small for the thumbnail is refused, not overrun" {
    var pixels: [16]u8 = undefined;
    var path_buffer: [256]u8 = undefined;
    const path = try writeFixture(&path_buffer, "wide.png", wide_png);
    try testing.expectError(Error.BufferTooSmall, thumbnail(path, &pixels));
}

// ================================================================ decode
//
// The orientation bake is the one Phase B requirement whose failure mode
// is a WRONG IMAGE rather than an error — a mirrored or sideways output
// still looks like a successful compression — so all eight EXIF
// orientations are exercised here, not just the two the fixture set
// happens to carry.
//
// They are exercised against a SYNTHESIZED source rather than a fixture:
// `orient_base_png` below is 4x2 with a distinct colour in every pixel,
// and `pngWithOrientation` re-emits it with an `eXIf` chunk carrying the
// tag under test. That gives every orientation an unambiguous expected
// answer that can be stated as a formula, and it needs no `test-images/`
// (which is gitignored).

/// A 4x2 8-bit truecolour PNG. Pixel (x, y) is
/// `(10 + 40x, 200 - 60y, 30 + 7(x + y))` — no two alike, and no channel
/// constant, so a transposed, mirrored or rotated result cannot coincide
/// with the right one.
const orient_base_png =
    "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x04" ++
    "\x00\x00\x00\x02\x08\x02\x00\x00\x00\xf0\xca\xea\x34\x00\x00\x00\x22\x49\x44\x41" ++
    "\x54\x78\x9c\x63\xe0\x3a\x21\x67\x74\x42\x35\xea\x84\x4e\xd3\x09\x63\x06\xae\x1e" ++
    "\x55\xa3\x1e\x9d\xa8\x1e\xe3\xa6\x1e\x2b\x00\x74\x2a\x08\xe1\xa8\x70\x30\x54\x00" ++
    "\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

const orient_width = 4;
const orient_height = 2;

fn expectedPixel(x: u32, y: u32) [3]u8 {
    return .{
        @intCast(10 + 40 * x),
        @intCast(200 - 60 * y),
        @intCast(30 + 7 * (x + y)),
    };
}

/// `orient_base_png` with an `eXIf` chunk carrying EXIF Orientation =
/// `orientation`, written into `buffer`.
///
/// PNG carries EXIF in an `eXIf` chunk holding a bare TIFF stream, and
/// ImageIO reads it — verified, which is what lets these tests stay PNG
/// like the rest of the file instead of dragging in a JPEG or TIFF
/// fixture just to have somewhere to put a tag.
fn pngWithOrientation(buffer: []u8, orientation: u8) []const u8 {
    // A minimal big-endian TIFF: header, one-entry IFD0, no next IFD.
    var tiff = [_]u8{
        'M', 'M', 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08, // byte order, magic, IFD0 offset
        0x00, 0x01, // one entry
        0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, // tag Orientation, SHORT, count 1
        0x00, 0x00, 0x00, 0x00, // value, LEFT-JUSTIFIED in the 4-byte field
        0x00, 0x00, 0x00, 0x00, // no next IFD
    };
    tiff[19] = orientation;

    // Right after the 8-byte signature and the 25-byte IHDR chunk. A PNG
    // decoder takes ancillary chunks in any order after IHDR.
    const insert_at = 8 + 25;
    var length: usize = 0;
    @memcpy(buffer[0..insert_at], orient_base_png[0..insert_at]);
    length += insert_at;

    std.mem.writeInt(u32, buffer[length..][0..4], tiff.len, .big);
    length += 4;
    const chunk_start = length;
    @memcpy(buffer[length..][0..4], "eXIf");
    length += 4;
    @memcpy(buffer[length..][0..tiff.len], &tiff);
    length += tiff.len;
    // The CRC covers the type and the data, not the length.
    std.mem.writeInt(u32, buffer[length..][0..4], std.hash.Crc32.hash(buffer[chunk_start..length]), .big);
    length += 4;

    const rest = orient_base_png[insert_at..];
    @memcpy(buffer[length..][0..rest.len], rest);
    return buffer[0 .. length + rest.len];
}

test "decode returns the full frame in straight-alpha 8-bit sRGB RGBA" {
    var path_buffer: [256]u8 = undefined;
    const path = try writeFixture(&path_buffer, "orient-base.png", orient_base_png);

    var decoded = try decode(testing.allocator, path);
    defer decoded.deinit(testing.allocator);

    // Full resolution, not the capped preview: `thumbnail` would have
    // returned this same 4x2, so the sizes alone cannot tell them apart —
    // what can is that nothing here is capped.
    try testing.expectEqual(@as(u32, orient_width), decoded.width);
    try testing.expectEqual(@as(u32, orient_height), decoded.height);
    try testing.expectEqual(@as(usize, orient_width * orient_height * 4), decoded.pixels.len);

    for (0..orient_height) |y| {
        for (0..orient_width) |x| {
            const expected = expectedPixel(@intCast(x), @intCast(y));
            const index = (y * orient_width + x) * 4;
            try testing.expectEqualSlices(u8, &expected, decoded.pixels[index..][0..3]);
            // The source has no alpha channel, so every pixel is opaque —
            // and opaque is the one case `unpremultiply` must leave alone.
            try testing.expectEqual(@as(u8, 255), decoded.pixels[index + 3]);
        }
    }
}

test "decode bakes in every EXIF orientation, exactly" {
    var png_buffer: [orient_base_png.len + 64]u8 = undefined;
    var path_buffer: [256]u8 = undefined;

    // Where stored pixel (x, y) must END UP, per orientation. Written out
    // from the EXIF spec rather than derived from `orientationTransform`,
    // so this really is an independent check of it: 1 upright, 2 mirror,
    // 3 half turn, 4 flip, 5 transpose, 6 quarter turn clockwise,
    // 7 transverse, 8 quarter turn anticlockwise.
    const w = orient_width - 1;
    const h = orient_height - 1;
    for (1..9) |tag| {
        const orientation: u8 = @intCast(tag);
        const transposed = imageio.swapsAxes(orientation);

        const png = pngWithOrientation(&png_buffer, orientation);
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "orient-{d}.png", .{orientation});
        const path = try writeFixture(&path_buffer, name, png);

        var decoded = try decode(testing.allocator, path);
        defer decoded.deinit(testing.allocator);

        // The DISPLAY size, which is what `probe` reports for the same
        // file — the two must not disagree, or the megapixel guard and
        // the encoder would be measuring different images.
        const info = try probe(path);
        try testing.expectEqual(info.width, decoded.width);
        try testing.expectEqual(info.height, decoded.height);
        try testing.expectEqual(
            @as(u32, if (transposed) orient_height else orient_width),
            decoded.width,
        );

        for (0..orient_height) |sy| {
            for (0..orient_width) |sx| {
                const x: u32 = @intCast(sx);
                const y: u32 = @intCast(sy);
                const target: [2]u32 = switch (orientation) {
                    1 => .{ x, y },
                    2 => .{ w - x, y },
                    3 => .{ w - x, h - y },
                    4 => .{ x, h - y },
                    5 => .{ y, x },
                    6 => .{ h - y, x },
                    7 => .{ h - y, w - x },
                    8 => .{ y, w - x },
                    else => unreachable,
                };
                const expected = expectedPixel(x, y);
                const index = (target[1] * decoded.width + target[0]) * 4;
                // EXACT, not approximate: a quarter turn is a permutation
                // of the source pixels, so any resampling on the way
                // through CoreGraphics would show up here as a near miss
                // rather than a match.
                try testing.expectEqualSlices(u8, &expected, decoded.pixels[index..][0..3]);
            }
        }
    }
}

test "decode reports an unreadable and an undecodable source distinctly" {
    var path_buffer: [256]u8 = undefined;
    const missing = "/tmp/smoosh-imageio-tests/definitely-not-here.png";
    try testing.expectError(Error.Unreadable, decode(testing.allocator, missing));

    // Same as `probe`: the source OPENS, and only the frame count says
    // this is not an image.
    const path = try writeFixture(
        &path_buffer,
        "not-an-image.jpg",
        "this is not an image, whatever the extension says",
    );
    try testing.expectError(Error.NotAnImage, decode(testing.allocator, path));
}
