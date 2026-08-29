//! The Zig-to-ImageIO seam: everything Smoosh knows about reading an
//! image file. Nothing in here touches the SDK, `Model`, or the effects
//! channel — these are plain functions over a path, called from a WORKER
//! THREAD by `main.zig`'s `HostBridge` (see its "worker carrier" section).
//!
//! Transplanted from `docs/spikes/imageio-decode-spike.zig`, which proved
//! every claim below against the whole fixture set. Read that file's
//! header before changing anything here.
//!
//! `extern fn` rather than `@cImport`: every type here is an opaque
//! pointer or a plain scalar, so declaring them by hand costs less than
//! wiring a header search. ImageIO, CoreGraphics and CoreFoundation are
//! now linked EXPLICITLY — `build.zig` states all three on both the exe
//! and the test module, as of M14a. Before that the app relied on AppKit
//! pulling them in transitively (confirmed with `otool -L`, not assumed),
//! and the test artifact got them not at all.
//!
//! THREE reads live here, deliberately separate because their costs are
//! nothing alike:
//!
//!   `probe`     — properties only. Allocates no bitmap anywhere, so the
//!                 megapixel guard can run BEFORE anything is decoded.
//!   `thumbnail` — <=160px preview, orientation baked by ImageIO itself.
//!   `decode`    — full resolution, upright, sRGB: the ENCODERS' input.
//!                 Allocates, and can allocate 200 MB.
//!
//! The first two are host commands (`image.probe`, `image.thumbnail`).
//! `decode` is NOT, and deliberately: a full-resolution buffer cannot ride
//! a 256 KiB host result, and its only caller will be M14c's encode
//! worker, which is already off the loop thread and can call it directly.
//!
//! THIS FILE'S TESTS LIVE IN `src/imageio_tests.zig`, and **`native test`
//! RUNS THEM** — `main.zig`'s `test` block imports that file. They stay in
//! their own file rather than moving into `src/tests.zig` only because
//! they are a coherent set about one seam; nothing forces the split any
//! more.
//!
//! It used to. The SDK builds its test artifact from a separate Debug
//! module (`build/app.zig`'s `test_app_mod`, which diverges from the app
//! module because `app_optimize` is ReleaseFast) and `linkPlatform` never
//! runs over it, so the test binary linked no frameworks and any test
//! reaching the declarations below died at LINK time on
//! `undefined symbol: _CFRelease`. M14a ejected `build.zig` and states the
//! frameworks on `artifacts.tests.root_module` directly, which is what
//! closed it.
//!
//! They need no fixtures — the PNGs are embedded there — so they work on a
//! fresh clone.
//!
//! `decode` LANDED IN M14b AND HAS NO CALLER YET — M14c's libavif and
//! libwebp seams are its only consumers. That is deliberate (PLAN.md's
//! M14 split): it is pure logic and fully testable on its own, and
//! landing it separately keeps M14c to the encoder swap and the parity
//! investigation.

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
extern fn CGImageSourceCreateImageAtIndex(isrc: CGImageSourceRef, index: usize, options: CFDictionaryRef) CGImageRef;

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

// The CTM trio the orientation bake rides on. All three take PLAIN
// SCALARS, which is why `Transform` below is decomposed into
// translate/rotate/scale rather than expressed as the one
// `CGAffineTransform` it really is: a 6-double struct is neither an HFA
// nor small enough to pass in registers on arm64, so `CGContextConcatCTM`
// would put an ABI question between us and the only correctness
// requirement in Phase B that silently produces a WRONG IMAGE rather than
// a failure. Three scalar calls have no such question.
extern fn CGContextTranslateCTM(c: CGContextRef, tx: CGFloat, ty: CGFloat) void;
extern fn CGContextScaleCTM(c: CGContextRef, sx: CGFloat, sy: CGFloat) void;
extern fn CGContextRotateCTM(c: CGContextRef, angle: CGFloat) void;

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
    /// ImageIO declined to decode the primary frame of a source it
    /// otherwise opened — a truncated or corrupt image whose header still
    /// parsed, which is exactly the file `probe` cannot reject.
    NoImage,
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

/// The EXIF orientation bake, decomposed into the three CTM calls that
/// take plain scalars. Every EXIF orientation is one of the eight
/// elements of the square's symmetry group, and every one of those is
/// `translate . (quarter turn?) . scale` — so this covers all eight with
/// no matrix crossing the ABI.
///
/// Coordinates are the DESTINATION context's user space: origin at the
/// bottom-left, y up. The caller applies them in the order the fields are
/// declared and then draws the image into `(0, 0, width, height)` — its
/// STORED size, pre-rotation.
pub const Transform = struct {
    translate_x: f64,
    translate_y: f64,
    /// A +90 degree turn in the destination's y-up space. True for exactly
    /// the four transposing orientations, i.e. wherever `swapsAxes` is.
    quarter_turn: bool,
    scale_x: f64,
    scale_y: f64,
};

/// The transform that takes a frame stored at `width` x `height` and
/// draws it upright, for EXIF `orientation` (0 or anything outside 1-8
/// means "no tag", which is upright).
///
/// Derived rather than copied: with the image drawn into `(0,0,w,h)`
/// under the identity CTM, stored pixel `(u,v)` lands at user-space
/// `(u, h-v)`, and each orientation's stored-to-display mapping is one
/// affine map away from that. `src/tests.zig` re-derives the same eight
/// mappings independently and asserts this table reproduces them, so a
/// sign error here fails a test rather than shipping a mirrored photo.
///
/// **This is the only Phase B correctness requirement whose failure mode
/// is a WRONG IMAGE rather than an error.** A flipped output looks like a
/// successful compression.
pub fn orientationTransform(orientation: u8, width: usize, height: usize) Transform {
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    return switch (orientation) {
        2 => .{ .translate_x = w, .translate_y = 0, .quarter_turn = false, .scale_x = -1, .scale_y = 1 },
        3 => .{ .translate_x = w, .translate_y = h, .quarter_turn = false, .scale_x = -1, .scale_y = -1 },
        4 => .{ .translate_x = 0, .translate_y = h, .quarter_turn = false, .scale_x = 1, .scale_y = -1 },
        5 => .{ .translate_x = h, .translate_y = w, .quarter_turn = true, .scale_x = -1, .scale_y = 1 },
        6 => .{ .translate_x = 0, .translate_y = w, .quarter_turn = true, .scale_x = -1, .scale_y = -1 },
        7 => .{ .translate_x = 0, .translate_y = 0, .quarter_turn = true, .scale_x = 1, .scale_y = -1 },
        8 => .{ .translate_x = h, .translate_y = 0, .quarter_turn = true, .scale_x = 1, .scale_y = 1 },
        // 1, 0 (no tag) and anything bogus: upright, and the three CTM
        // calls below become no-ops rather than being skipped.
        else => .{ .translate_x = 0, .translate_y = 0, .quarter_turn = false, .scale_x = 1, .scale_y = 1 },
    };
}

/// Draw `image` into `buffer` as 8-BIT sRGB RGBA, applying EXIF
/// `orientation` on the way in. Pass 0 or 1 for a source that is already
/// upright — which is what the `thumbnail` path does, because
/// `kCGImageSourceCreateThumbnailWithTransform` has already rotated for
/// it.
///
/// The destination is the DISPLAY size: `width` and `height` swap for the
/// four transposing orientations.
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
fn drawToRgba8(image: CGImageRef, orientation: u8, buffer: []u8) Error![]u8 {
    const stored_width = CGImageGetWidth(image);
    const stored_height = CGImageGetHeight(image);
    const transposes = swapsAxes(orientation);
    const width = if (transposes) stored_height else stored_width;
    const height = if (transposes) stored_width else stored_height;

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

    // CTM calls compose OUTERMOST-FIRST: the point a later call produces
    // is fed to the earlier one, so this is `translate . turn . scale`.
    const transform = orientationTransform(orientation, stored_width, stored_height);
    CGContextTranslateCTM(ctx, transform.translate_x, transform.translate_y);
    if (transform.quarter_turn) CGContextRotateCTM(ctx, std.math.pi / 2.0);
    CGContextScaleCTM(ctx, transform.scale_x, transform.scale_y);

    // The rect is the image's OWN size, pre-rotation — the transform is
    // what carries it onto the (possibly transposed) destination.
    CGContextDrawImage(ctx, .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(stored_width), .height = @floatFromInt(stored_height) },
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

    // Orientation 0, not the source's tag:
    // `kCGImageSourceCreateThumbnailWithTransform` has ALREADY rotated
    // this image. Passing the tag here would rotate it a second time.
    const pixels = try drawToRgba8(image, 0, buffer);
    return .{
        .width = @intCast(CGImageGetWidth(image)),
        .height = @intCast(CGImageGetHeight(image)),
        .pixels = pixels,
    };
}

// -------------------------------------------------------------- decode

pub const Decoded = struct {
    /// DISPLAY dimensions: orientation has already been applied, so these
    /// match what `probe` reported for the same file.
    width: u32,
    height: u32,
    /// `width * height * 4`, straight-alpha 8-bit sRGB, TOP-DOWN (row 0 is
    /// the image's top row — verified in the spike, so an encoder that
    /// expects top-down rows needs no flip). Owned by the caller.
    pixels: []u8,

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// The encoders' input: the primary frame at FULL resolution, upright, in
/// sRGB, 8-bit, straight alpha, and carrying no metadata of any kind.
///
/// Four of Phase B's correctness requirements are satisfied right here,
/// and three of them are behaviour CHANGES rather than preservation —
/// each one recorded as deliberate in PLAN.md:
///
///  - **Primary frame, not index 0.** A live bug on `multi-primary.heic`,
///    where every `sips` read v0.1 does takes the wrong image.
///  - **EXIF orientation baked in, BY HAND.** Unlike `thumbnail`, this
///    path gets no help: `CGImageSourceCreateImageAtIndex` returns the
///    frame unrotated (measured — the same 4000x3000 Orientation 6 source
///    comes back 120x160 as a thumbnail and 4000x3000 unrotated here).
///    This is what stops the same source producing an upright AVIF and a
///    sideways WebP.
///  - **sRGB, converted and not merely passed through.** The bitmap
///    context does it; a Display P3 photo comes out in sRGB numbers.
///  - **No metadata.** Encoding from decoded pixels copies nothing unless
///    asked, which is how the GPS tags v0.1 leaks into every AVIF stop
///    being copied. It also drops the ICC tag, which is why the sRGB
///    conversion above is not optional — the encoder must TAG sRGB.
///
/// Allocates `width * height * 4` bytes, which is 200 MB at the 50 MP
/// guard's limit — the caller's megapixel check has already run off
/// `probe` by the time anything reaches here. Callable from a worker
/// thread, like the rest of this file.
pub fn decode(allocator: std.mem.Allocator, path: []const u8) (Error || std.mem.Allocator.Error)!Decoded {
    const url = try urlForPath(path);
    defer CFRelease(url);

    const source = CGImageSourceCreateWithURL(url, null) orelse return Error.Unreadable;
    defer CFRelease(source);
    if (CGImageSourceGetCount(source) == 0) return Error.NotAnImage;
    const index = CGImageSourceGetPrimaryImageIndex(source);

    // The orientation tag lives in the SOURCE's properties, not on the
    // decoded `CGImage` — which is the whole reason this path has to
    // transform by hand.
    const props = CGImageSourceCopyPropertiesAtIndex(source, index, null) orelse
        return Error.NoProperties;
    defer CFRelease(props);
    const tag = dictInt(props, kCGImagePropertyOrientation) orelse 0;
    const orientation: u8 = if (tag >= 1 and tag <= 8) @intCast(tag) else 0;

    const image = CGImageSourceCreateImageAtIndex(source, index, null) orelse
        return Error.NoImage;
    defer CGImageRelease(image);

    const stored_width = CGImageGetWidth(image);
    const stored_height = CGImageGetHeight(image);
    if (stored_width == 0 or stored_height == 0) return Error.NotAnImage;
    const transposes = swapsAxes(orientation);
    const width = if (transposes) stored_height else stored_width;
    const height = if (transposes) stored_width else stored_height;

    const buffer = try allocator.alloc(u8, width * height * 4);
    errdefer allocator.free(buffer);

    const pixels = try drawToRgba8(image, orientation, buffer);
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .pixels = pixels,
    };
}
