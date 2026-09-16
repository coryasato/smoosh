//! One preference, read from another application's domain: where macOS
//! puts screenshots.
//!
//! The fourth of the hand-bound platform seams (`workspace.zig`,
//! `pasteboard.zig`, `dockopen.zig`), written to the same rules —
//! `extern "c"` declarations rather than `@cImport`, caller-owned fixed
//! buffers, and a `null` return rather than an error set.
//!
//! **Why this exists at all.** `com.apple.screencapture`'s `location` is
//! the folder a user picks in Screenshot.app, and Smoosh needs it in two
//! places: the screenshot rescue (`Destination`), and the invented home
//! for a pasted picture with no file behind it. Neither could read it:
//!
//!  - **The app spawns no subprocess** (CLAUDE.md), so
//!    `defaults read com.apple.screencapture location` is not available.
//!  - **The SDK exposes no preferences API** — grepped for
//!    `CFPreferences`, `NSUserDefaults` and `standardUserDefaults` across
//!    its Zig source: zero hits. There is no seam to reuse.
//!
//! So it is CoreFoundation directly. No `objc_msgSend` and none of
//! `workspace.zig`'s arity-cast machinery — `CFPreferencesCopyAppValue`
//! is a plain C function, and the cast rule that file states does not
//! apply to anything here.
//!
//! **This module releases, and its siblings do not.** Everything
//! `workspace.zig` and `pasteboard.zig` touch is autoreleased
//! class-factory output (`stringWithUTF8String:`, `sharedWorkspace`), so
//! they own nothing. CoreFoundation's naming rule is the opposite: a
//! function with **Create** or **Copy** in its name returns +1 and the
//! caller must `CFRelease` it. Both of those appear below, so both are
//! released — a leak here would be per load and per paste, not once.
//!
//! **The value is user-writable and is not trusted.** `defaults write`
//! accepts any plist type under that key, so the type is checked against
//! `CFStringGetTypeID` before it is read as one, and the string it
//! yields is put through `normalizeScreenshotDir` rather than used as a
//! path directly.
//!
//! Main-thread only in practice, like the other seams: its one caller
//! answers from `HostBridge.requestFn`, which the SDK runs on the loop
//! thread. Nothing here requires it — `CFPreferencesCopyAppValue` is
//! thread-safe — but the contract is stated so it stays true.

const std = @import("std");

/// The domain Screenshot.app and `screencapture` share, and the key
/// within it. A value set through the Screenshot.app UI is an absolute
/// path; one set with `defaults write … "~/Shots"` keeps the tilde
/// literally, which is why `normalizeScreenshotDir` has to expand it.
const screencapture_domain = "com.apple.screencapture";
const location_key = "location";

const CFTypeRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFPropertyListRef = ?*anyopaque;
const CFAllocatorRef = ?*anyopaque;
const CFIndex = isize;
const CFTypeID = usize;
const CFStringEncoding = u32;

/// `kCFStringEncodingUTF8`. A constant rather than an `extern` symbol:
/// the encoding values are fixed by the framework's ABI, and an
/// `extern const` would be one more symbol to link for a number that
/// cannot change.
const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

/// `kCFAllocatorDefault` is NULL, so every allocator argument here is
/// `null` rather than a looked-up symbol.
extern "c" fn CFStringCreateWithCString(
    alloc: CFAllocatorRef,
    cStr: [*:0]const u8,
    encoding: CFStringEncoding,
) CFStringRef;
extern "c" fn CFPreferencesCopyAppValue(key: CFStringRef, applicationID: CFStringRef) CFPropertyListRef;
extern "c" fn CFGetTypeID(cf: CFTypeRef) CFTypeID;
extern "c" fn CFStringGetTypeID() CFTypeID;
/// Returns CoreFoundation's `Boolean`, which is `unsigned char` — read as
/// `u8` and compared against 0, never declared as a Zig `bool`. Same rule
/// `pasteboard.zig` applies to Objective-C's `BOOL`, and for the same
/// reason: the C type is a byte, and Zig's `bool` has no defined ABI
/// width to match it with.
extern "c" fn CFStringGetCString(
    theString: CFStringRef,
    buffer: [*]u8,
    bufferSize: CFIndex,
    encoding: CFStringEncoding,
) u8;
extern "c" fn CFRelease(cf: CFTypeRef) void;

/// The raw `location` value, exactly as stored, written into `buffer`.
///
/// `null` for every way this can come back unusable — the key is unset
/// (the default, and by far the common case), the value is not a string,
/// or it does not fit. All four are the same answer to the caller: fall
/// back to the Desktop. None of them is an error worth reporting, because
/// the user did nothing wrong in any of them.
///
/// The value is NOT validated as a path here. That is
/// `normalizeScreenshotDir`'s job, and it is split out so the policy half
/// can be tested without a live preference on the machine running the
/// tests.
pub fn screenshotLocation(buffer: []u8) ?[]const u8 {
    if (buffer.len == 0) return null;

    const key = CFStringCreateWithCString(null, location_key, kCFStringEncodingUTF8) orelse return null;
    defer CFRelease(key);
    const domain = CFStringCreateWithCString(null, screencapture_domain, kCFStringEncodingUTF8) orelse return null;
    defer CFRelease(domain);

    const value = CFPreferencesCopyAppValue(key, domain) orelse return null;
    defer CFRelease(value);

    if (CFGetTypeID(value) != CFStringGetTypeID()) return null;

    // `CFStringGetCString` NUL-terminates and answers false rather than
    // truncating, so a path too long for the buffer falls back instead of
    // arriving as a plausible-looking prefix. The terminator costs one
    // byte of the caller's buffer and is never part of the slice returned.
    if (CFStringGetCString(value, buffer.ptr, @intCast(buffer.len), kCFStringEncodingUTF8) == 0) return null;
    const len = std.mem.indexOfScalar(u8, buffer, 0) orelse return null;
    if (len == 0) return null;
    return buffer[0..len];
}

/// A raw preference value turned into an absolute directory path in
/// `buffer`, or `null` when there is nothing sensible to turn it into.
///
/// Pure over its three arguments — no I/O, no `$HOME` lookup — which is
/// what makes it the tested half of this module. Whether the directory
/// it names EXISTS is deliberately not asked here; the caller stats it,
/// for the same reason `workspace.reveal` leaves existence to its caller.
///
/// The four rejections, and why each is a fallback rather than a fix-up:
///
///  - **Empty.** Nothing to expand.
///  - **`file://`.** Percent-encoded, and may carry a host component. A
///    half-decoded URL produces a path that looks plausible and is not,
///    which is worse than the Desktop.
///  - **Relative.** There is no directory this could be relative TO. The
///    process's cwd is wherever the app happened to be launched from,
///    which is never what the user meant.
///  - **A tilde with no `$HOME`.** Cannot be expanded; `~/Shots` as a
///    literal directory name is not what was asked for.
pub fn normalizeScreenshotDir(raw: []const u8, home: []const u8, buffer: []u8) ?[]const u8 {
    if (raw.len == 0) return null;
    if (std.mem.startsWith(u8, raw, "file://")) return null;

    const written = if (std.mem.eql(u8, raw, "~") or std.mem.startsWith(u8, raw, "~/")) blk: {
        if (home.len == 0) return null;
        break :blk std.fmt.bufPrint(buffer, "{s}{s}", .{ home, raw[1..] }) catch return null;
    } else if (raw[0] == '/') blk: {
        if (raw.len > buffer.len) return null;
        @memcpy(buffer[0..raw.len], raw);
        break :blk buffer[0..raw.len];
    } else return null;

    // A trailing slash is legal in the preference and would make the
    // is-it-the-Desktop comparison miss, and `outputPath` join a double
    // slash. Root is left alone: "/" trimmed to "" is not a directory.
    var end = written.len;
    while (end > 1 and written[end - 1] == '/') end -= 1;
    return written[0..end];
}
