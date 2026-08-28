//! The Zig-to-ImageIO seam: everything Smoosh knows about reading an
//! image file. Nothing in here touches the SDK, `Model`, or the effects
//! channel — these are plain functions over a path, called from a WORKER
//! THREAD by `main.zig`'s `HostBridge` (see its "worker carrier" section).
//!
//! Transplanted from `docs/spikes/imageio-decode-spike.zig`, which proved
//! every claim below against the whole fixture set. Read that file's
//! header before changing anything here.
//!
//! `extern fn` rather than `@cImport`: `@cImport` would need framework
//! include paths threaded through a build we do not own yet (`native
//! build` links whatever the global CLI carries), and every type here is
//! an opaque pointer or a plain scalar, so declaring them by hand costs
//! less than wiring the header search. ImageIO, CoreGraphics and
//! CoreFoundation are already in the binary's load commands — AppKit
//! pulls them in, confirmed with `otool -L zig-out/bin/smoosh`, not
//! assumed. M14 owns `build.zig` and should add an explicit
//! `linkFramework("ImageIO")` rather than keep relying on that.
//!
//! TWO commands live here, deliberately separate because they have
//! opposite cost profiles:
//!
//!   `probe`     — properties only. Allocates no bitmap anywhere, so the
//!                 megapixel guard can run BEFORE anything is decoded.
//!   `thumbnail` — <=160px preview, orientation baked by ImageIO itself.
//!
//! THIS FILE'S TESTS LIVE IN `src/imageio_tests.zig`, AND `native test`
//! DOES NOT RUN THEM. Its test artifact is a separate Debug module
//! (`build/app.zig`'s `test_app_mod`, which diverges from the app module
//! because `app_optimize` is ReleaseFast) and `linkPlatform` never runs on
//! it, so the test binary links no frameworks — any test reaching the
//! declarations below fails at LINK time with
//! `undefined symbol: _CFRelease`. That is also why the tests are a file
//! nothing imports rather than a `test` block down here: everything
//! reachable from `main.zig` is compiled into the test artifact, tests
//! included. Run them by hand, from the repo root:
//!
//!     zig test src/imageio_tests.zig -lc \
//!       -framework ImageIO -framework CoreGraphics -framework CoreFoundation
//!
//! They need no fixtures — the PNGs are embedded there — so they work on a
//! fresh clone. Fold them into `src/tests.zig` once M14 owns `build.zig`
//! and can link the test module.
//!
//! The third command, a full-resolution decode for the encoders, lands with M14:
//! it has no consumer until the vendored encoders exist, and unlike the
//! two above it needs the EXIF transform applied by hand (the full-decode
//! path does not rotate — measured in the spike, where the same 4000x3000
//! Orientation=6 source came back 120x160 as a thumbnail and 4000x3000
//! unrotated as a full decode).

const std = @import("std");

// ---------------------------------------------------------------- C ABI

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
/// RGBA layout `CGBitmapContextCreate` accepts on this platform, which
/// is why `unpremultiply` below exists.
const kCGImageAlphaPremultipliedLast: u32 = 1;

extern fn CFRelease(cf: CFTypeRef) void;
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
extern fn CGImageSourceCreateThumbnailAtIndex(isrc: CGImageSourceRef, index: usize, options: CFDictionaryRef) CGImageRef;

extern const kCGImagePropertyPixelWidth: CFStringRef;
extern const kCGImagePropertyPixelHeight: CFStringRef;
extern const kCGImagePropertyOrientation: CFStringRef;
extern const kCGImageSourceThumbnailMaxPixelSize: CFStringRef;
extern const kCGImageSourceCreateThumbnailFromImageAlways: CFStringRef;
extern const kCGImageSourceCreateThumbnailWithTransform: CFStringRef;

extern fn CGImageGetWidth(image: CGImageRef) usize;
extern fn CGImageGetHeight(image: CGImageRef) usize;
extern fn CGImageRelease(image: CGImageRef) void;

extern const kCGColorSpaceSRGB: CFStringRef;
extern fn CGColorSpaceCreateWithName(name: CFStringRef) CGColorSpaceRef;
extern fn CGColorSpaceRelease(space: CGColorSpaceRef) void;

extern fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bitsPerComponent: usize, bytesPerRow: usize, space: CGColorSpaceRef, bitmapInfo: u32) CGContextRef;
extern fn CGContextDrawImage(c: CGContextRef, rect: CGRect, image: CGImageRef) void;
extern fn CGContextRelease(c: CGContextRef) void;

// -------------------------------------------------------------- errors

pub const Error = error{
    /// The path could not be turned into a `CFURL` — a path with an
    /// interior NUL, or one long enough to defeat the conversion.
    BadPath,
    /// `CGImageSourceCreateWithURL` returned null: the file could not be
    /// opened at all.
    Unreadable,
    /// The source opened but holds no images. THIS, not a null source, is
    /// how a non-image is detected: `CGImageSourceCreateWithURL` SUCCEEDS
    /// on 49 bytes of text named `.jpg` and returns a non-null source
    /// (measured in the spike). Testing the pointer would fall through
    /// and report the wrong thing two hops later.
    NotAnImage,
    /// The primary frame's property dictionary is missing, or has no
    /// pixel dimensions in it.
    NoProperties,
    /// ImageIO declined to produce a thumbnail from a source it otherwise
    /// opened.
    NoThumbnail,
    /// A CoreGraphics object could not be created (color space, bitmap
    /// context) — allocation failure, effectively.
    DrawFailed,
    /// The caller's pixel buffer is too small for the result. Callers size
    /// their buffers from `max_thumbnail_edge`, so this is a bug guard,
    /// not a runtime condition.
    BufferTooSmall,
};

// ------------------------------------------------------------- helpers

/// Longest edge of the preview, in pixels. The binding constraint is the
/// 256 KiB host-result cap, not the 1 MiB registered-image budget — see
/// `main.zig`'s `thumbnail_result` arm, which asserts the fit at comptime.
pub const max_thumbnail_edge: u32 = 160;

/// Widest UTI we will carry back ("public.heic", "org.webmproject.webp",
/// "com.microsoft.bmp"): 64 is roomy for every type ImageIO names.
pub const max_uti_bytes: usize = 64;

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

/// True for the four EXIF orientations that transpose the image, and so
/// swap the DISPLAY dimensions against the stored ones. Values outside
/// 1-8 are treated as upright, matching what ImageIO does with a bogus
/// tag.
pub fn swapsAxes(orientation: u8) bool {
    return orientation >= 5 and orientation <= 8;
}

/// `CGBitmapContextCreate`'s only 8-bit RGBA layout is
/// `kCGImageAlphaPremultipliedLast`, but `fx.registerImage` documents its
/// input as STRAIGHT alpha and every encoder M14 will vendor wants the
/// same. Undo the multiply in place, rounding to nearest so a round trip
/// through 255 does not drift downward.
///
/// Fully opaque and fully transparent pixels are the whole fixture set
/// bar one (`alpha16.png`), and both are already correct, so the loop
/// pays for itself only on the file that needs it.
pub fn unpremultiply(pixels: []u8) void {
    var index: usize = 0;
    while (index + 4 <= pixels.len) : (index += 4) {
        const alpha = pixels[index + 3];
        if (alpha == 0 or alpha == 255) continue;
        const a: u32 = alpha;
        for (pixels[index..][0..3]) |*channel| {
            const scaled = (@as(u32, channel.*) * 255 + a / 2) / a;
            channel.* = @intCast(@min(scaled, 255));
        }
    }
}

/// A `CFURL` for `path`, or `error.BadPath`. Caller releases.
fn urlForPath(path: []const u8) Error!CFURLRef {
    if (path.len == 0) return Error.BadPath;
    return CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), false) orelse
        Error.BadPath;
}

/// Draw `image` into `buffer` as 8-BIT sRGB RGBA at its own pixel size.
///
/// Pinning depth here is load-bearing, not defensive: `small.png` in our
/// own fixture set reports Depth 16 and `tiny.png` reports Depth 1, and
/// carrying either into an encoder buys nothing (it is also what triggers
/// the ImageIO alpha bug recorded in PLAN.md). The context normalizes
/// depth, and drawing into an sRGB context performs the P3->sRGB
/// conversion by itself — no ColorSync call of our own, verified
/// pixel-wise in the spike.
///
/// Row 0 of the backing store is the image's TOP row (also verified), so
/// no vertical flip is needed by anything downstream.
fn drawToRgba8(image: CGImageRef, buffer: []u8) Error![]u8 {
    const width = CGImageGetWidth(image);
    const height = CGImageGetHeight(image);
    const stride = width * 4;
    const needed = stride * height;
    if (needed > buffer.len) return Error.BufferTooSmall;
    const pixels = buffer[0..needed];
    @memset(pixels, 0);

    const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse return Error.DrawFailed;
    defer CGColorSpaceRelease(space);

    const ctx = CGBitmapContextCreate(
        pixels.ptr,
        width,
        height,
        8,
        stride,
        space,
        kCGImageAlphaPremultipliedLast,
    ) orelse return Error.DrawFailed;
    defer CGContextRelease(ctx);

    CGContextDrawImage(ctx, .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    }, image);

    unpremultiply(pixels);
    return pixels;
}

// --------------------------------------------------------------- probe

/// Everything `update` needs before deciding whether to go on: the
/// primary frame's DISPLAY dimensions (orientation already applied), and
/// the source's UTI.
pub const Probe = struct {
    /// Post-orientation, so this is what the megapixel guard measures and
    /// what the card reports — not the stored dimensions.
    width: u32,
    height: u32,
    /// The raw EXIF tag, 1-8 (0 when the source carries none). Kept so a
    /// caller can tell an upright source from a transposed one without
    /// re-reading the file; the preview does not need it, since ImageIO
    /// bakes the rotation into the thumbnail for us.
    orientation: u8,
    uti_buffer: [max_uti_bytes]u8,
    uti_len: usize,

    pub fn uti(self: *const Probe) []const u8 {
        return self.uti_buffer[0..self.uti_len];
    }
};

/// Properties only — NO bitmap is allocated anywhere on this path, which
/// is the whole reason it is a separate command from `thumbnail`. The
/// megapixel guard runs off this, before a single pixel is decoded; the
/// `sips -g` spawn it replaces could not offer that, because the preview
/// decode it fed had already happened.
///
/// Reads the PRIMARY frame, not index 0. That is a live-bug fix, not a
/// precaution: `multi-primary.heic` has two top-level images with `pitm`
/// naming the second, and every `sips` read Smoosh does today takes
/// index 0 — so the guard measures, the card previews, and the encoder
/// compresses an image the file never called primary.
pub fn probe(path: []const u8) Error!Probe {
    const url = try urlForPath(path);
    defer CFRelease(url);

    const source = CGImageSourceCreateWithURL(url, null) orelse return Error.Unreadable;
    defer CFRelease(source);
    if (CGImageSourceGetCount(source) == 0) return Error.NotAnImage;

    const index = CGImageSourceGetPrimaryImageIndex(source);
    const props = CGImageSourceCopyPropertiesAtIndex(source, index, null) orelse
        return Error.NoProperties;
    defer CFRelease(props);

    const stored_width = dictInt(props, kCGImagePropertyPixelWidth) orelse return Error.NoProperties;
    const stored_height = dictInt(props, kCGImagePropertyPixelHeight) orelse return Error.NoProperties;
    if (stored_width <= 0 or stored_height <= 0) return Error.NoProperties;

    const tag = dictInt(props, kCGImagePropertyOrientation) orelse 0;
    const orientation: u8 = if (tag >= 1 and tag <= 8) @intCast(tag) else 0;

    var result: Probe = .{
        .width = @intCast(stored_width),
        .height = @intCast(stored_height),
        .orientation = orientation,
        .uti_buffer = undefined,
        .uti_len = 0,
    };
    if (swapsAxes(orientation)) {
        result.width = @intCast(stored_height);
        result.height = @intCast(stored_width);
    }

    const uti = cfStringToSlice(CGImageSourceGetType(source), &result.uti_buffer);
    result.uti_len = uti.len;
    return result;
}

// ----------------------------------------------------------- thumbnail

pub const Thumbnail = struct {
    width: u32,
    height: u32,
    /// A prefix of the caller's buffer.
    pixels: []u8,
};

/// The preview, and ONLY the preview: at most `max_thumbnail_edge` on its
/// longest edge, 8-bit sRGB, straight alpha, orientation already applied.
///
/// `CGImageSourceCreateThumbnailAtIndex`, not
/// `CGImageSourceCreateImageAtIndex` — Smoosh accepts sources up to 50 MP
/// and decoding all of one to draw a 160px card would be absurd.
/// `kCGImageSourceCreateThumbnailWithTransform` is what bakes the EXIF
/// rotation (measured: a 4000x3000 Orientation=6 JPEG comes back 120x160),
/// so this path needs no transform of its own — the full-resolution decode
/// M14 adds will.
///
/// `kCGImageSourceCreateThumbnailFromImageAlways` forces the thumbnail to
/// come from the image itself rather than a stale embedded one, which is
/// the difference between previewing the photo and previewing whatever
/// the camera cached.
pub fn thumbnail(path: []const u8, buffer: []u8) Error!Thumbnail {
    const url = try urlForPath(path);
    defer CFRelease(url);

    const source = CGImageSourceCreateWithURL(url, null) orelse return Error.Unreadable;
    defer CFRelease(source);
    if (CGImageSourceGetCount(source) == 0) return Error.NotAnImage;
    const index = CGImageSourceGetPrimaryImageIndex(source);

    const options = CFDictionaryCreateMutable(
        null,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    ) orelse return Error.DrawFailed;
    defer CFRelease(options);

    const max_edge: i32 = @intCast(max_thumbnail_edge);
    const max_edge_number = CFNumberCreate(null, kCFNumberIntType, &max_edge) orelse
        return Error.DrawFailed;
    defer CFRelease(max_edge_number);
    CFDictionarySetValue(options, kCGImageSourceThumbnailMaxPixelSize, max_edge_number);
    CFDictionarySetValue(options, kCGImageSourceCreateThumbnailFromImageAlways, kCFBooleanTrue);
    CFDictionarySetValue(options, kCGImageSourceCreateThumbnailWithTransform, kCFBooleanTrue);

    const image = CGImageSourceCreateThumbnailAtIndex(source, index, options) orelse
        return Error.NoThumbnail;
    defer CGImageRelease(image);

    const pixels = try drawToRgba8(image, buffer);
    return .{
        .width = @intCast(CGImageGetWidth(image)),
        .height = @intCast(CGImageGetHeight(image)),
        .pixels = pixels,
    };
}
