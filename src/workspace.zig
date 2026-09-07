//! "Show in Finder", and nothing else.
//!
//! The Objective-C runtime seam, the sibling of `imageio.zig`'s C-ABI
//! seam. Two constraints forced it here rather than anywhere simpler:
//!
//!  - **The app spawns no subprocess** (CLAUDE.md), so `open -R` is not
//!    available. Revealing a file is an AppKit call or it is nothing.
//!  - **The SDK exposes no workspace/open-URL API at all** — verified by
//!    grepping its whole Zig source for `NSWorkspace`, `openURL` and
//!    `activateFileViewer`: zero hits. There is no seam to reuse.
//!
//! `-[NSWorkspace activateFileViewerSelectingURLs:]` is the honest "Show
//! in Finder": it opens the containing folder AND selects the files,
//! which the plain-C `LSOpenCFURLRef` alternative cannot do (it can only
//! open a folder, leaving the user to spot the new files themselves).
//! Selecting is the entire point here — the button exists to unveil an
//! auto-write the user did not ask for a location for.
//!
//! It takes an ARRAY, so a Both run reveals both outputs in one Finder
//! window with both highlighted, rather than picking a winner.
//!
//! `objc_msgSend` is declared `extern fn` and CAST to each exact call
//! signature at the call site, never called through a variadic
//! declaration. On aarch64 the variadic and non-variadic calling
//! conventions genuinely differ (variadic arguments go on the stack), so
//! a variadic declaration would put the selector and arguments in the
//! wrong places and the call would read garbage. The casts are the
//! correct ABI, not a convenience.

const std = @import("std");

/// One reveal per output format, and there are two formats. Sized here so
/// the NSURL scratch array is a plain fixed buffer with no allocator.
pub const max_paths = 2;

const Id = ?*anyopaque;
const Sel = ?*anyopaque;

extern "c" fn objc_getClass(name: [*:0]const u8) Id;
extern "c" fn sel_registerName(name: [*:0]const u8) Sel;
extern "c" fn objc_msgSend() void;

/// `objc_msgSend` cast to a concrete signature. See the header: the cast
/// is mandatory on aarch64, not stylistic. One helper per arity, because
/// the argument list is part of the signature being cast — a single
/// helper taking a struct would pass one struct, not N arguments.
fn msgSend0(comptime Ret: type) *const fn (Id, Sel) callconv(.c) Ret {
    return @ptrCast(&objc_msgSend);
}

fn msgSend1(comptime Ret: type, comptime A: type) *const fn (Id, Sel, A) callconv(.c) Ret {
    return @ptrCast(&objc_msgSend);
}

fn msgSend2(comptime Ret: type, comptime A: type, comptime B: type) *const fn (Id, Sel, A, B) callconv(.c) Ret {
    return @ptrCast(&objc_msgSend);
}

/// Opens Finder on `paths` with every one of them selected.
///
/// Returns false only for a request this seam cannot express: no paths,
/// too many, or a path that does not fit a NUL-terminated buffer. A path
/// that no longer EXISTS is not checked here — the caller stats first,
/// because a missing file is a fact worth reporting to the user and
/// AppKit reports nothing (`activateFileViewerSelectingURLs:` returns
/// void and silently does nothing for a dead URL).
///
/// Main-thread only, like every AppKit call. Its one caller answers from
/// `request_fn`, which the SDK runs on the loop thread.
pub fn reveal(paths: []const []const u8) bool {
    if (paths.len == 0 or paths.len > max_paths) return false;

    const NSString = objc_getClass("NSString");
    const NSURL = objc_getClass("NSURL");
    const NSArray = objc_getClass("NSArray");
    const NSWorkspace = objc_getClass("NSWorkspace");

    const sel_string = sel_registerName("stringWithUTF8String:");
    const sel_file_url = sel_registerName("fileURLWithPath:");
    const sel_array = sel_registerName("arrayWithObjects:count:");
    const sel_shared = sel_registerName("sharedWorkspace");
    const sel_reveal = sel_registerName("activateFileViewerSelectingURLs:");

    var urls: [max_paths]Id = undefined;
    for (paths, 0..) |path, i| {
        // `std.fs.max_path_bytes` + the NUL. A path longer than that
        // cannot have come from the dialog or the drop in the first
        // place, so this is a bound, not a truncation point.
        var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (path.len >= buffer.len) return false;
        @memcpy(buffer[0..path.len], path);
        buffer[path.len] = 0;
        const string = msgSend1(Id, [*:0]const u8)(NSString, sel_string, @ptrCast(&buffer));
        urls[i] = msgSend1(Id, Id)(NSURL, sel_file_url, string);
    }

    const array = msgSend2(Id, [*]const Id, usize)(NSArray, sel_array, &urls, paths.len);
    const workspace = msgSend0(Id)(NSWorkspace, sel_shared);
    msgSend1(void, Id)(workspace, sel_reveal, array);
    return true;
}
