//! VALIDATED SPIKE — not built as part of the app, kept as a transplant
//! reference for `src/imageio.zig` (M13).
//!
//! PLAN.md's Phase B step 2: prove the Zig-to-C-ABI seam into ImageIO
//! standalone — `extern fn` declarations, CoreFoundation lifetime rules,
//! `CFRelease` discipline — before any of it is entangled with
//! `HostBridge`. Build and run it on its own, no SDK involved:
//!
//!     zig build-exe imageio-decode-spike.zig -lc \
//!       -framework ImageIO -framework CoreGraphics -framework CoreFoundation
//!     ./imageio-decode-spike test-images/photo.heic out [--dump]
//!
//! VERDICT: works, and it answers all three of M13's host commands with
//! about 90 lines of declarations. Run over the whole fixture set on
//! 2026-08-27 (macOS 26.6, Zig 0.16.0), including a real iPhone 13 Pro
//! HEIC and a hand-built multi-image HEIC.
//!
//! WHAT IT PROVED (each one is a PLAN.md requirement, now measured
//! rather than assumed):
//!
//! - `extern fn` over `@cImport` is right. Every type here is an opaque
//!   pointer or a plain scalar; `CGRect` is the only by-value struct and
//!   it passes correctly as an `extern struct` of four `f64`. No include
//!   paths, no build-graph change.
//!
//! - `image.probe` is genuinely free. `CGImageSourceCopyPropertiesAtIndex`
//!   returns PixelWidth/PixelHeight/Orientation/Depth/ProfileName with no
//!   bitmap allocated anywhere — the megapixel guard can run before any
//!   decode, which is not true of today's `sips` path.
//!
//! - `kCGImageSourceCreateThumbnailWithTransform` REALLY BAKES
//!   ORIENTATION, and the full decode really does not. Same file
//!   (`test-images/rotated-gps.jpg`, 4000x3000 with EXIF Orientation=6):
//!   the thumbnail comes back 120x160 (portrait, rotated for us) while
//!   `CGImageSourceCreateImageAtIndex` comes back 4000x3000 unrotated.
//!   So M13's preview needs no rotation code and M14's encoder input
//!   needs it by hand — exactly the split PLAN.md assumed, now measured.
//!
//! - DRAWING INTO AN sRGB BITMAP CONTEXT REALLY CONVERTS. Two PNGs with
//!   identical stored bytes, one tagged Display P3, decoded through
//!   `CGBitmapContextCreate(..., kCGColorSpaceSRGB)`: the untagged one
//!   returns its authored values unchanged, the P3-tagged one is
//!   remapped — #D93025 -> (237,5,14), #0A66FF -> (0,104,255),
//!   #00A35C -> (0,166,84), white unmoved. 2.78% of pixels move by more
//!   than 6/255 total. That is the "convert to sRGB" requirement
//!   satisfied by the context alone, no ColorSync call of our own.
//!
//! - 8-BIT PINNING IS LOAD-BEARING ON OUR OWN FIXTURES. PLAN.md called
//!   the whole fixture set "8-bit sRGB photographs"; it is not.
//!   `small.png` reports Depth 16 and `tiny.png` reports Depth 1. Both
//!   draw correctly into the 8-bit context, which is the point: the
//!   context normalizes depth, so the encoder never sees 16-bit input
//!   and the ImageIO alpha bug stays out of reach.
//!
//! - ImageIO STILL DOES NOT EXPOSE JPEG CHROMA SAMPLING. Dumped the full
//!   property dictionary (`--dump`) for a 4:2:0 JPEG (`ui.jpg`) and a
//!   4:4:4 JPEG (`large.jpg`): the two dictionaries are identical apart
//!   from dimensions — ColorModel, Depth, PixelWidth/Height,
//!   ProfileName, {JFIF}. No sampling key of any kind. M14's hand-rolled
//!   SOF-marker parse is not optional.
//!
//! - AN UNDECODABLE FILE DOES NOT FAIL WHERE YOU EXPECT.
//!   `CGImageSourceCreateWithURL` SUCCEEDS on `not-an-image.jpg` (49
//!   bytes of text) and returns a non-null source; it is
//!   `CGImageSourceGetCount() == 0` (and `GetType()` returning null) that
//!   says "not an image". M13's undecodable-input error must test the
//!   count, not the source pointer, or it will fall through to a null
//!   properties dictionary later and report the wrong thing.
//!
//! - The decoded buffer is TOP-DOWN. Row 0 of the `CGBitmapContext`
//!   backing store is the TOP row of the image (verified by sampling
//!   known landmarks in the UI fixture at both orientations), so no
//!   vertical flip is needed feeding an encoder that expects top-down
//!   rows. `kCGImageAlphaPremultipliedLast` is the layout — note
//!   PREMULTIPLIED: an encoder wanting straight alpha must un-premultiply,
//!   which matters for `alpha16.png` and nothing else in the set.
//!
//! CAVEATS, so nothing here is over-claimed:
//!
//! - Primary-frame selection was untested when this spike was first run,
//!   and is now PROVEN: on `test-images/multi-primary.heic` (two
//!   top-level images, 400x300 at index 0 and 640x200 at index 1, with
//!   the HEIF `pitm` box naming item 2) this prints `primary 1`,
//!   properties report 640x200, and the thumbnail comes back 160x50 —
//!   the second image's aspect. Index 0 would have given 400x300 and the
//!   wrong picture, which is exactly what `sips` does today. Worth
//!   knowing how that fixture had to be made: a REAL iPhone still does
//!   not reach this path. An HDR capture carries a gain map, but a gain
//!   map is an AUXILIARY image and `CGImageSourceGetCount` still reports
//!   `frames 1`, so no ordinary photo — Live Photo included — makes
//!   `GetPrimaryImageIndex` return non-zero.
//! - The full-resolution path allocates `w*h*4` in one shot: 8000x6400
//!   (`oversized.jpg`) is 205 MB. Fine for a spike that runs once; M13's
//!   megapixel guard must run BEFORE this, which is exactly why
//!   `image.probe` is a separate command.
//! - No `CFRelease` discipline is proven beyond "it does not crash" —
//!   this spike runs once and exits. M13's bridge holds sources across
//!   many loads and needs the `defer CFRelease` pairing below taken
//!   seriously.


const std = @import("std");

// ---------------------------------------------------------------- C ABI
//
// Plain `extern` declarations, not `@cImport`: `@cImport` would need
// framework include paths threaded through the build, and every type we
// touch here is either an opaque pointer or a plain scalar, so declaring
// them by hand costs less than wiring the header search.

const CFTypeRef = ?*anyopaque;
const CFAllocatorRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFURLRef = ?*anyopaque;
const CFDictionaryRef = ?*anyopaque;
const CFMutableDictionaryRef = ?*anyopaque;
const CFNumberRef = ?*anyopaque;
const CFBooleanRef = ?*anyopaque;
const CGImageSourceRef = ?*anyopaque;
const CGImageRef = ?*anyopaque;
const CGColorSpaceRef = ?*anyopaque;
const CGContextRef = ?*anyopaque;

const CFIndex = isize;
const CGFloat = f64;

const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };

const kCFStringEncodingUTF8: u32 = 0x08000100;
/// `CFNumberType.kCFNumberIntType`
const kCFNumberIntType: CFIndex = 9;
/// `CGImageAlphaInfo.kCGImageAlphaPremultipliedLast` — the only 8-bit
/// RGBA layout `CGBitmapContextCreate` accepts on this platform.
const kCGImageAlphaPremultipliedLast: u32 = 1;

extern fn CFRelease(cf: CFTypeRef) void;
extern fn CFGetTypeID(cf: CFTypeRef) usize;
extern fn CFStringGetCString(theString: CFStringRef, buffer: [*]u8, bufferSize: CFIndex, encoding: u32) bool;
extern fn CFDictionaryGetValue(theDict: CFDictionaryRef, key: ?*const anyopaque) ?*anyopaque;
extern fn CFDictionaryCreateMutable(allocator: CFAllocatorRef, capacity: CFIndex, keyCallBacks: ?*const anyopaque, valueCallBacks: ?*const anyopaque) CFMutableDictionaryRef;
extern fn CFDictionarySetValue(theDict: CFMutableDictionaryRef, key: ?*const anyopaque, value: ?*const anyopaque) void;
extern fn CFNumberGetValue(number: CFNumberRef, theType: CFIndex, valuePtr: *anyopaque) bool;
extern fn CFNumberCreate(allocator: CFAllocatorRef, theType: CFIndex, valuePtr: *const anyopaque) CFNumberRef;
extern fn CFURLCreateFromFileSystemRepresentation(allocator: CFAllocatorRef, buffer: [*]const u8, bufLen: CFIndex, isDirectory: bool) CFURLRef;

extern const kCFTypeDictionaryKeyCallBacks: anyopaque;
extern const kCFTypeDictionaryValueCallBacks: anyopaque;
extern const kCFBooleanTrue: CFBooleanRef;

extern fn CGImageSourceCreateWithURL(url: CFURLRef, options: CFDictionaryRef) CGImageSourceRef;
extern fn CGImageSourceGetType(isrc: CGImageSourceRef) CFStringRef;
extern fn CGImageSourceGetCount(isrc: CGImageSourceRef) usize;
extern fn CGImageSourceGetPrimaryImageIndex(isrc: CGImageSourceRef) usize;
extern fn CGImageSourceCopyPropertiesAtIndex(isrc: CGImageSourceRef, index: usize, options: CFDictionaryRef) CFDictionaryRef;
extern fn CGImageSourceCreateImageAtIndex(isrc: CGImageSourceRef, index: usize, options: CFDictionaryRef) CGImageRef;
extern fn CGImageSourceCreateThumbnailAtIndex(isrc: CGImageSourceRef, index: usize, options: CFDictionaryRef) CGImageRef;

extern fn CFShow(obj: CFTypeRef) void;

extern const kCGImagePropertyProfileName: CFStringRef;
extern const kCGImagePropertyPixelWidth: CFStringRef;
extern const kCGImagePropertyPixelHeight: CFStringRef;
extern const kCGImagePropertyOrientation: CFStringRef;
extern const kCGImagePropertyDepth: CFStringRef;
extern const kCGImagePropertyHasAlpha: CFStringRef;
extern const kCGImageSourceThumbnailMaxPixelSize: CFStringRef;
extern const kCGImageSourceCreateThumbnailFromImageAlways: CFStringRef;
extern const kCGImageSourceCreateThumbnailWithTransform: CFStringRef;

extern fn CGImageGetWidth(image: CGImageRef) usize;
extern fn CGImageGetHeight(image: CGImageRef) usize;
extern fn CGImageGetBitsPerComponent(image: CGImageRef) usize;
extern fn CGImageRelease(image: CGImageRef) void;

extern const kCGColorSpaceSRGB: CFStringRef;
extern fn CGColorSpaceCreateWithName(name: CFStringRef) CGColorSpaceRef;
extern fn CGColorSpaceRelease(space: CGColorSpaceRef) void;

extern fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bitsPerComponent: usize, bytesPerRow: usize, space: CGColorSpaceRef, bitmapInfo: u32) CGContextRef;
extern fn CGContextDrawImage(c: CGContextRef, rect: CGRect, image: CGImageRef) void;
extern fn CGContextRelease(c: CGContextRef) void;

// ------------------------------------------------------------- helpers

fn cfStringToSlice(string: CFStringRef, buffer: []u8) []const u8 {
    if (string == null) return "";
    if (!CFStringGetCString(string, buffer.ptr, @intCast(buffer.len), kCFStringEncodingUTF8)) return "";
    return std.mem.sliceTo(buffer, 0);
}

fn dictInt(dict: CFDictionaryRef, key: CFStringRef) ?i32 {
    const value = CFDictionaryGetValue(dict, key) orelse return null;
    var out: i32 = 0;
    if (!CFNumberGetValue(value, kCFNumberIntType, &out)) return null;
    return out;
}

/// Decode `image` into a freshly allocated straight-run of 8-BIT sRGB
/// RGBA at its own pixel size. Pinning depth here is deliberate: a
/// 16-bit source otherwise carries its depth into the encoder for no
/// benefit (PLAN.md, "Correctness requirements").
const Rgba = struct {
    width: usize,
    height: usize,
    pixels: []u8,

    fn deinit(self: Rgba, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }
};

fn drawToRgba8(gpa: std.mem.Allocator, image: CGImageRef) !Rgba {
    const width = CGImageGetWidth(image);
    const height = CGImageGetHeight(image);
    const stride = width * 4;
    const pixels = try gpa.alloc(u8, stride * height);
    errdefer gpa.free(pixels);
    @memset(pixels, 0);

    const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse return error.NoColorSpace;
    defer CGColorSpaceRelease(space);

    const ctx = CGBitmapContextCreate(
        pixels.ptr,
        width,
        height,
        8,
        stride,
        space,
        kCGImageAlphaPremultipliedLast,
    ) orelse return error.NoBitmapContext;
    defer CGContextRelease(ctx);

    CGContextDrawImage(ctx, .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    }, image);

    return .{ .width = width, .height = height, .pixels = pixels };
}

fn writePpm(io: std.Io, path: []const u8, rgba: Rgba) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const out = &writer.interface;
    try out.print("P6\n{d} {d}\n255\n", .{ rgba.width, rgba.height });
    var index: usize = 0;
    while (index < rgba.pixels.len) : (index += 4) {
        try out.writeAll(rgba.pixels[index .. index + 3]);
    }
    try out.flush();
}

// ---------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [8 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        try out.print("usage: imageio_spike <image> [out-prefix]\n", .{});
        return;
    }
    const path = args[1];
    const prefix: []const u8 = if (args.len > 2) args[2] else "spike";

    const url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), false) orelse
        return error.BadUrl;
    defer CFRelease(url);

    const source = CGImageSourceCreateWithURL(url, null) orelse return error.NotAnImage;
    defer CFRelease(source);

    var text_buf: [256]u8 = undefined;
    const uti = cfStringToSlice(CGImageSourceGetType(source), &text_buf);
    const count = CGImageSourceGetCount(source);
    const primary = CGImageSourceGetPrimaryImageIndex(source);
    try out.print("path      {s}\n", .{path});
    try out.print("uti       {s}\n", .{uti});
    try out.print("frames    {d}\n", .{count});
    try out.print("primary   {d}\n", .{primary});

    // ---- probe: properties only, no bitmap anywhere.
    const props = CGImageSourceCopyPropertiesAtIndex(source, primary, null) orelse
        return error.NoProperties;
    defer CFRelease(props);
    try out.print("width     {?d}\n", .{dictInt(props, kCGImagePropertyPixelWidth)});
    try out.print("height    {?d}\n", .{dictInt(props, kCGImagePropertyPixelHeight)});
    try out.print("orient    {?d}\n", .{dictInt(props, kCGImagePropertyOrientation)});
    try out.print("depth     {?d}\n", .{dictInt(props, kCGImagePropertyDepth)});
    var profile_buf: [256]u8 = undefined;
    const profile: CFStringRef = CFDictionaryGetValue(props, kCGImagePropertyProfileName);
    try out.print("profile   {s}\n", .{cfStringToSlice(profile, &profile_buf)});

    // `--dump` prints EVERY property key ImageIO exposes for this
    // source — the check behind "ImageIO does not expose JPEG chroma
    // sampling" (PLAN.md, M14 correctness requirements).
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dump")) {
            try out.flush();
            CFShow(props);
        }
    }

    // ---- thumbnail: <=160px, orientation baked by ImageIO itself.
    const options = CFDictionaryCreateMutable(null, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse
        return error.NoDictionary;
    defer CFRelease(options);
    const max_edge: i32 = 160;
    const max_edge_number = CFNumberCreate(null, kCFNumberIntType, &max_edge) orelse return error.NoNumber;
    defer CFRelease(max_edge_number);
    CFDictionarySetValue(options, kCGImageSourceThumbnailMaxPixelSize, max_edge_number);
    CFDictionarySetValue(options, kCGImageSourceCreateThumbnailFromImageAlways, kCFBooleanTrue);
    CFDictionarySetValue(options, kCGImageSourceCreateThumbnailWithTransform, kCFBooleanTrue);

    const thumb = CGImageSourceCreateThumbnailAtIndex(source, primary, options) orelse
        return error.NoThumbnail;
    defer CGImageRelease(thumb);
    const thumb_rgba = try drawToRgba8(gpa, thumb);
    defer thumb_rgba.deinit(gpa);
    try out.print("thumb     {d}x{d} ({d} bytes rgba, source bpc {d})\n", .{
        thumb_rgba.width, thumb_rgba.height, thumb_rgba.pixels.len, CGImageGetBitsPerComponent(thumb),
    });

    var name_buf: [512]u8 = undefined;
    const thumb_path = try std.fmt.bufPrint(&name_buf, "{s}-thumb.ppm", .{prefix});
    try writePpm(io, thumb_path, thumb_rgba);
    try out.print("wrote     {s}\n", .{thumb_path});

    // ---- full decode: the encoder's input.
    const full = CGImageSourceCreateImageAtIndex(source, primary, null) orelse
        return error.NoImage;
    defer CGImageRelease(full);
    try out.print("full      {d}x{d} bpc {d} (BEFORE orientation)\n", .{
        CGImageGetWidth(full), CGImageGetHeight(full), CGImageGetBitsPerComponent(full),
    });
    const full_rgba = try drawToRgba8(gpa, full);
    defer full_rgba.deinit(gpa);
    const full_path = try std.fmt.bufPrint(&name_buf, "{s}-full.ppm", .{prefix});
    try writePpm(io, full_path, full_rgba);
    try out.print("wrote     {s} ({d}x{d})\n", .{ full_path, full_rgba.width, full_rgba.height });
}
