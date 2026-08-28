//! Standalone tests for `src/imageio.zig`. NOTHING IMPORTS THIS FILE, on
//! purpose — see that file's header: everything reachable from `main.zig`
//! is compiled into `native test`'s artifact, and that artifact links no
//! frameworks, so a test touching ImageIO fails at link time. Run them by
//! hand, from the repo root:
//!
//!     zig test src/imageio_tests.zig -lc \
//!       -framework ImageIO -framework CoreGraphics -framework CoreFoundation
//!
//! The pure helpers (`swapsAxes`, `unpremultiply`) are NOT here: they link
//! fine in the app's own test artifact, so they are pinned in
//! `src/tests.zig` where `native test` actually runs them.

const std = @import("std");
const imageio = @import("imageio.zig");
const testing = std.testing;

const Error = imageio.Error;
const max_thumbnail_edge = imageio.max_thumbnail_edge;
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
    try testing.expectEqual(@as(u32, 160), capped.width);
    try testing.expectEqual(@as(u32, 80), capped.height);
    try testing.expectEqual(@as(usize, 160 * 80 * 4), capped.pixels.len);

    // This is why Phase A's drawn-size clamp could go: `sips -Z 160`
    // UPSCALED an 8x8 source into a 160x160 blur, ImageIO leaves it 8x8.
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
