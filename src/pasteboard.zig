//! The macOS general pasteboard, read for an image and nothing else.
//!
//! The sibling of `workspace.zig`: same Objective-C runtime seam, same
//! `objc_msgSend`-cast-per-signature rule (see that file's header — the
//! cast is an aarch64 ABI requirement, not a style choice).
//!
//! **The SDK's own clipboard seam cannot do this.** `PlatformServices`
//! carries `readClipboardData(mime_type, buffer)`, which looks like the
//! right call and is not, for two independent reasons:
//!
//!  - Its macOS mime map (`NativeSdkPasteboardTypeForMime` in the CLI's
//!    `appkit_host.m`) resolves `text/plain`, `text/html` and `text/rtf`
//!    and returns nil for everything else. An `image/png` read is not
//!    slow or lossy — it is unrepresentable, and answers zero bytes.
//!  - Even if it mapped, `max_clipboard_data_bytes` is 64 KiB. No
//!    screenshot fits.
//!
//! So the read happens here, and the bytes never enter the app's address
//! space at all: `writeImage` hands `-[NSData writeToFile:atomically:]`
//! a destination and lets AppKit do the copy. That is what keeps this
//! module free of a multi-megabyte static buffer, and it is atomic for
//! free — the same temp-then-rename discipline the encoder outputs use.
//!
//! Main-thread only, like every AppKit call. Its one caller answers from
//! `HostBridge.requestFn`, which the SDK runs on the loop thread.

const std = @import("std");

const Id = ?*anyopaque;
const Sel = ?*anyopaque;

extern "c" fn objc_getClass(name: [*:0]const u8) Id;
extern "c" fn sel_registerName(name: [*:0]const u8) Sel;
extern "c" fn objc_msgSend() void;

/// See `workspace.zig`'s header: `objc_msgSend` is CAST to each exact
/// call signature, never called through a variadic declaration.
fn msgSend0(comptime Ret: type) *const fn (Id, Sel) callconv(.c) Ret {
    return @ptrCast(&objc_msgSend);
}

fn msgSend1(comptime Ret: type, comptime A: type) *const fn (Id, Sel, A) callconv(.c) Ret {
    return @ptrCast(&objc_msgSend);
}

fn msgSend2(comptime Ret: type, comptime A: type, comptime B: type) *const fn (Id, Sel, A, B) callconv(.c) Ret {
    return @ptrCast(&objc_msgSend);
}

/// The image flavours worth taking off a pasteboard, in the order
/// `imageKind` prefers them.
///
/// PNG first because it is what `screencapture` and every browser's
/// "Copy Image" of a PNG put there: lossless and already compact.
///
/// **JPEG before TIFF, deliberately.** A browser copying a JPEG offers
/// both, and taking the JPEG keeps the ORIGINAL entropy-coded bytes —
/// which is what `chroma.zig`'s SOF parser reads to decide whether the
/// AVIF encode may use 4:2:0. Through TIFF that fact is gone (the
/// pasteboard has already decoded to RGB), and every pasted photo would
/// silently encode at the conservative subsampling. TIFF is also
/// uncompressed, so it is the largest possible way to move the same
/// picture across the seam.
pub const Kind = enum {
    png,
    jpeg,
    tiff,

    /// The pasteboard UTI, which is also what `dataForType:` keys on.
    fn uti(self: Kind) [*:0]const u8 {
        return switch (self) {
            .png => "public.png",
            .jpeg => "public.jpeg",
            .tiff => "public.tiff",
        };
    }

    /// The extension the written file gets. It is NOT what any later
    /// read keys on — `image.probe` sniffs the container out of the
    /// bytes — but a stray file in the cache should still say what it
    /// is, and the name is what the file card shows the user.
    pub fn extension(self: Kind) []const u8 {
        return switch (self) {
            .png => "png",
            .jpeg => "jpg",
            .tiff => "tiff",
        };
    }
};

const uti_file_url = "public.file-url";

fn generalPasteboard() Id {
    const NSPasteboard = objc_getClass("NSPasteboard");
    return msgSend0(Id)(NSPasteboard, sel_registerName("generalPasteboard"));
}

fn nsString(text: [*:0]const u8) Id {
    const NSString = objc_getClass("NSString");
    return msgSend1(Id, [*:0]const u8)(NSString, sel_registerName("stringWithUTF8String:"), text);
}

/// The path of a FILE copied in Finder, if that is what the pasteboard
/// holds. Checked before `imageKind` by the caller and worth the
/// ordering: a real path keeps the file's name and puts the outputs
/// beside the original, where a raw-bytes paste can only invent both.
///
/// Nothing here asserts the file is an image, or even that it exists —
/// `image.probe` is the gate for the first and the stat for the second,
/// both of which already have a named failure. A copied `.txt` therefore
/// reaches the ordinary "that isn't an image" message rather than a
/// paste-specific one.
///
/// The value on the pasteboard is a URL STRING (`file:///Users/.../a%20b.png`),
/// so it goes back through `NSURL` to be percent-decoded rather than
/// being unescaped by hand.
pub fn filePath(buffer: []u8) ?[]const u8 {
    const pasteboard = generalPasteboard() orelse return null;
    const text = msgSend1(Id, Id)(
        pasteboard,
        sel_registerName("stringForType:"),
        nsString(uti_file_url),
    ) orelse return null;

    const NSURL = objc_getClass("NSURL");
    const url = msgSend1(Id, Id)(NSURL, sel_registerName("URLWithString:"), text) orelse return null;
    // A non-file URL (a link dragged from a browser can land on
    // `public.file-url`'s neighbours) has no filesystem path to give.
    if (msgSend0(u8)(url, sel_registerName("isFileURL")) == 0) return null;
    const path = msgSend0(Id)(url, sel_registerName("path")) orelse return null;

    const utf8 = msgSend0(?[*:0]const u8)(path, sel_registerName("UTF8String")) orelse return null;
    const slice = std.mem.span(utf8);
    if (slice.len == 0 or slice.len > buffer.len) return null;
    @memcpy(buffer[0..slice.len], slice);
    return buffer[0..slice.len];
}

/// Which image flavour the pasteboard offers, best first, or null when it
/// holds no image at all (text, a URL, an empty pasteboard).
pub fn imageKind() ?Kind {
    const pasteboard = generalPasteboard() orelse return null;
    const sel_data = sel_registerName("dataForType:");
    for (std.enums.values(Kind)) |kind| {
        const data = msgSend1(Id, Id)(pasteboard, sel_data, nsString(kind.uti()));
        if (data == null) continue;
        // A declared-but-empty flavour is not an image. `dataForType:`
        // answers non-nil for a promise the producer never filled.
        if (msgSend0(usize)(data, sel_registerName("length")) == 0) continue;
        return kind;
    }
    return null;
}

/// Writes the pasteboard's `kind` bytes to `path`, atomically. False for
/// anything that did not land: the flavour vanished between `imageKind`
/// and here (a copy in another app), the directory does not exist, or the
/// write failed.
///
/// The bytes are never copied into this process — `writeToFile:` reads
/// the pasteboard and writes the file inside AppKit. See the header.
pub fn writeImage(kind: Kind, path: []const u8) bool {
    // `std.fs.max_path_bytes` + the NUL, the bound `workspace.reveal`
    // uses for the same reason: this path was built from a directory the
    // bridge resolved, so it is a bound, not a truncation point.
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buffer.len) return false;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;

    const pasteboard = generalPasteboard() orelse return false;
    const data = msgSend1(Id, Id)(
        pasteboard,
        sel_registerName("dataForType:"),
        nsString(kind.uti()),
    ) orelse return false;

    const destination = nsString(@ptrCast(&buffer));
    // ObjC `BOOL` is a signed char on aarch64, so the return is read as a
    // byte and YES is passed as 1 — not as a Zig `bool`, whose ABI here
    // is not the one the method was compiled against.
    return msgSend2(u8, Id, u8)(
        data,
        sel_registerName("writeToFile:atomically:"),
        destination,
        1,
    ) != 0;
}
