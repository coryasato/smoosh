//! Files opened THROUGH THE APP ITSELF rather than through the window:
//! a drag onto the Dock tile, and Finder's "Open With".
//!
//! The third Objective-C runtime seam, after `workspace.zig` and
//! `pasteboard.zig`, and written to their rules — see `workspace.zig`'s
//! header for the `objc_msgSend`-cast-per-signature requirement (an
//! aarch64 ABI constraint, not a style choice).
//!
//! **This is a different channel from every other way in, and it carries
//! FILE URLS ONLY.** macOS delivers a Dock-tile drop as a `kAEOpenDocuments`
//! ("odoc") Apple Event, which NSApplication resolves to
//! `application:openURLs:` on its delegate. An Apple Event has no pixel
//! lane at all, so there is nothing here to mirror `clipboard.paste`'s
//! two-payload shape: pixels ride the pasteboard, files ride odoc, and the
//! two never overlap. A drag of an image out of a web page vends a promise
//! or a remote URL rather than a file, so the Dock tile declines it — that
//! is the channel behaving correctly, not a gap to close.
//!
//! **Two independent things must both be true for a drop to arrive**, and
//! only one of them is here:
//!
//!  - `app.zon`'s `.file_associations` must name the types, so the
//!    packaged Info.plist carries `CFBundleDocumentTypes`. Without it
//!    LaunchServices does not believe the app opens images, the Dock tile
//!    never highlights, and no event is ever sent. This also means the
//!    feature is invisible under `native dev` and `native build`, which
//!    produce a bare executable with no Info.plist — it can only be
//!    exercised from a packaged, LaunchServices-registered `.app`.
//!  - `install` must have added the delegate method. The SDK's AppKit host
//!    owns `NSApp.delegate` (`NativeSdkAppDelegate`, one method:
//!    `applicationShouldHandleReopen:`) and implements nothing
//!    document-shaped.
//!
//! **The method is added to the SDK's delegate class, not to a delegate of
//! our own.** Replacing `NSApp.delegate` is possible — the host installs
//! its own only `if (!NSApp.delegate)`, so an earlier one survives — but it
//! would silently take the Dock-reopen behaviour with it, and a future SDK
//! that puts more on that delegate would lose that too, with no error
//! anywhere. `class_addMethod` leaves the host's delegate whole and fails
//! harmlessly (returning false, changing nothing) if the SDK ever ships its
//! own `application:openURLs:`.
//!
//! **Ordering is load-bearing: `install` must run before the run loop
//! starts.** `NSApplication` snapshots which delegate methods exist when
//! `setDelegate:` is called, and the host calls that inside
//! `runWithCallback:` — i.e. inside `runtime.run`. Adding the method after
//! that snapshot would leave AppKit believing the delegate cannot open
//! URLs, and the drop would be dropped. `NSApp` itself exists by then:
//! `[NSApplication sharedApplication]` runs in the host's `init`, which is
//! inside `MacPlatform.createWithOptions`.
//!
//! Main-thread only, like every AppKit call. The delegate method is
//! delivered on the loop thread, which is what makes dispatching a `Msg`
//! straight from it legal.

const std = @import("std");

/// Called with ONE absolute path, on the loop thread, for each open
/// request. The path borrows a stack buffer that dies when the handler
/// returns — copy anything that must outlive the call (`Model.setPath`
/// already does).
pub const Handler = *const fn (context: *anyopaque, path: []const u8) void;

/// The handler is file-scope because an Objective-C IMP has no context
/// parameter: its arguments are exactly `self`, `_cmd`, and the method's
/// own. There is one NSApp and one delegate per process, so a single slot
/// is the honest shape rather than a limitation.
var handler: ?Handler = null;
var handler_context: ?*anyopaque = null;

const Id = ?*anyopaque;
const Sel = ?*anyopaque;

extern "c" fn objc_getClass(name: [*:0]const u8) Id;
extern "c" fn sel_registerName(name: [*:0]const u8) Sel;
extern "c" fn objc_msgSend() void;
extern "c" fn class_addMethod(cls: Id, name: Sel, imp: *const anyopaque, types: [*:0]const u8) bool;

/// See `workspace.zig`'s header: `objc_msgSend` is CAST to each exact
/// call signature, never called through a variadic declaration.
fn msgSend0(comptime Ret: type) *const fn (Id, Sel) callconv(.c) Ret {
    return @ptrCast(&objc_msgSend);
}

fn msgSend1(comptime Ret: type, comptime A: type) *const fn (Id, Sel, A) callconv(.c) Ret {
    return @ptrCast(&objc_msgSend);
}

/// The class the SDK's AppKit host installs as `NSApp.delegate`. Named as
/// a string because it lives in the SDK's `appkit_host.m`, which this tree
/// compiles but does not declare — `objc_getClass` is the only seam to it.
const delegate_class_name = "NativeSdkAppDelegate";

/// `- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls`
/// in Objective-C type-encoding: void return, then the two implicit
/// arguments (`self`, `_cmd`) and the two declared objects.
const open_urls_encoding = "v@:@@";

/// Adds `application:openURLs:` to the host's delegate class and records
/// where to deliver. Returns false if the delegate class is missing or the
/// method could not be added (the SDK having grown its own is the only
/// realistic cause) — in which case Dock drops simply never arrive, and
/// every other way into the app is unaffected.
///
/// Call once, after the app state the handler closes over exists and
/// BEFORE `runtime.run` — see the header on why the second half matters.
pub fn install(context: *anyopaque, on_open: Handler) bool {
    const cls = objc_getClass(delegate_class_name) orelse return false;
    const sel = sel_registerName("application:openURLs:");
    if (!class_addMethod(cls, sel, @ptrCast(&applicationOpenURLs), open_urls_encoding)) return false;
    handler = on_open;
    handler_context = context;
    return true;
}

/// The IMP. Takes the FIRST file URL and ignores the rest: Finder
/// multi-select is the natural gesture on a Dock tile, but Smoosh holds
/// one image at a time everywhere else — the window drop takes
/// `paths[0]` for the same reason. Dropping the others silently matches
/// that, and is the reason this seam never reports a count.
fn applicationOpenURLs(self: Id, cmd: Sel, app: Id, urls: Id) callconv(.c) void {
    _ = self;
    _ = cmd;
    _ = app;

    const deliver = handler orelse return;
    const context = handler_context orelse return;
    const array = urls orelse return;

    const count = msgSend0(usize)(array, sel_registerName("count"));
    if (count == 0) return;
    const url = msgSend1(Id, usize)(array, sel_registerName("objectAtIndex:"), 0) orelse return;

    // An odoc event should only ever carry file URLs, but the delegate
    // method is also how a registered URL SCHEME would arrive, and this
    // app registers none — so a non-file URL here means something other
    // than a Dock drop reached us, and the only safe answer is to ignore
    // it rather than hand `beginLoad` a path that is not one.
    //
    // `BOOL` is C's `bool` on arm64 macOS, so Zig's `bool` is the exact
    // return type; it is NOT the signed char it was on 32-bit.
    if (!msgSend0(bool)(url, sel_registerName("isFileURL"))) return;

    // `fileSystemRepresentation` is the right accessor rather than
    // `path`: it answers the file system's own bytes, already
    // percent-decoded and in the decomposed form the volume uses, which
    // is what `open`/`stat` take. `-[NSURL path]` would need a second hop
    // through NSString to reach a C string and would hand back the
    // precomposed form.
    const c_path = msgSend0(?[*:0]const u8)(url, sel_registerName("fileSystemRepresentation")) orelse return;
    const path = std.mem.span(c_path);
    // Documented as valid only for the enclosing autorelease context, so
    // it is copied before anything else runs. `max_path_bytes` is a
    // bound, not a truncation point: a longer path cannot exist on a
    // volume this event could name.
    if (path.len == 0 or path.len > std.fs.max_path_bytes) return;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(buffer[0..path.len], path);

    deliver(context, buffer[0..path.len]);
}
