//! Smoosh — image compression for the desktop.
//!
//! M1 skeleton: platform + Runtime are stood up BY HAND (not through the
//! CLI's `runner.runWithOptions`, whose per-platform bring-up is non-`pub`)
//! so that M3 can bind a `HostCallBinding` closing over the `*Runtime` and
//! reach `showOpenDialog`. See CLAUDE.md, "File acquisition, honestly", and
//! the validated reference at `docs/spikes/dialog-open-file-spike.zig`.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const app_dirs = native_sdk.app_dirs;
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const platform = native_sdk.platform;

/// Debug builds get hot reload and the automation server. `build_options`
/// (the CLI's `-Dautomation` flag) is wired into the CLI's internal runner
/// module only and is unreachable from a hand-authored root, so build mode
/// is the gate we actually control. See CLAUDE.md note 2.
const dev = builtin.mode == .Debug;

// ------------------------------------------------------------------ shell
//
// Window config lives in THREE places for a hand-authored root, and all
// three must move together:
//   1. `AppInfo.main_window` below — the host creates the real NSWindow from
//      this, before the scene loads. Its `default_frame` defaults to 720x480;
//      the size passed to `MacPlatform.createWithOptions` only sizes the
//      surface, so omitting it silently gives a 720x480 window whatever the
//      scene says. (The CLI runner derives this from app.zon; a hand-authored
//      root has no such path and must state it in Zig.)
//   2. The `ShellConfig` below — what the runtime lays views out against.
//   3. `app.zon`'s `.shell.windows` — identity, `native check`, packaging.

pub const canvas_label = "main-canvas";
const window_title = "Smoosh";
// M9: 480x320 was M2's guess, made before any real content existed, and the
// ready/done states overflowed it (the `zero_canvas_layout` diagnostic PLAN.md
// deferred to this milestone). 480x400 is the honest floor for the tallest
// state — header, a 160px preview card, the format row, the actions row and
// the status line — and `min_*` below stops a resize from re-creating the
// overflow. All three declarations of this geometry move together
// (see the block comment above): these consts feed the `AppInfo` frame and
// the `ShellWindow`, and `app.zon` states it a third time.
pub const window_width: f32 = 540;
pub const window_height: f32 = 400;
pub const window_min_width: f32 = 420;
// Equal to the default height on purpose: every row here is fixed-height and
// the preview frame is a fixed box, so vertical shrink buys the user nothing
// and costs the layout its only slack. The width still gives.
pub const window_min_height: f32 = window_height;

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
};

const shell_views = [_]native_sdk.ShellView{
    .{
        .label = canvas_label,
        .kind = .gpu_surface,
        .fill = true,
        .role = "Smoosh canvas",
        .accessibility_label = "Smoosh",
        .gpu_backend = .metal,
        .gpu_pixel_format = .bgra8_unorm,
        .gpu_present_mode = .timer,
        .gpu_alpha_mode = .@"opaque",
        .gpu_color_space = .srgb,
        .gpu_vsync = true,
    },
};

const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = window_title,
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    .views = &shell_views,
}};

pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model
//
// Per PLAN.md's Model/Msg sketch. Buffers use `platform.max_dialog_path_bytes`
// (4096), not the sketch's literal 1024 — the spike's own dialog wiring
// (docs/spikes/dialog-open-file-spike.zig) sizes `path_buf` this way to hold
// whatever `showOpenDialog` hands back, and M3 transplants that pattern
// directly. `update` stays a no-op switch this milestone: M3-M8 fill in one
// arm each; `set_format` is M6's job specifically, so it stays empty here
// too even though it would be a one-line wire-up.

pub const Format = enum { avif, webp, both };
pub const Status = enum { idle, loading, ready, compressing, done, failed };
// NOTE: `failed`, not `error` — `error` is a Zig keyword and won't parse as
// a bare enum field.

/// Where ONE output format got to in the current smoosh run. M7's
/// partial-failure decision (PLAN.md "Open decisions") lives in this type:
/// the two formats carry their own outcome, so "Both" is two independent
/// encodes joined at the end rather than one all-or-nothing operation.
///
/// `.none` means "not part of this run" and `.pending` means "spawned,
/// still waiting" — which is what makes the join immune to the user
/// changing `Model.format` mid-encode: completion is "neither is
/// `.pending`", never a re-read of the current selection.
///
/// The failure tags are separate rather than one `.failed` because each
/// one is a different sentence to the user, and PLAN.md's "Error states"
/// names them individually.
pub const EncodeOutcome = enum {
    none,
    pending,
    ok,
    /// The encoder binary is not installed (M5's launch check said so).
    missing_encoder,
    /// The output path would BE the source path — encoding a `.webp` to
    /// WebP would have the encoder read and overwrite the same file.
    same_path,
    /// The encoder ran and exited nonzero (or was killed).
    encode_failed,
    /// The encoder claimed success but the output could not be stat'd —
    /// PLAN.md's "write to output path failed" state.
    write_failed,
    /// M12: the shared HEIC->PNG staging step (`sips`) failed or the source
    /// vanished between pick and encode, so the encoder for this format
    /// never even ran. Distinct from `encode_failed` because the encoder
    /// itself is not what failed.
    convert_failed,

    fn isFailure(outcome: EncodeOutcome) bool {
        return switch (outcome) {
            .none, .pending, .ok => false,
            .missing_encoder, .same_path, .encode_failed, .write_failed, .convert_failed => true,
        };
    }
};

pub const Model = struct {
    // file
    path_buffer: [platform.max_dialog_path_bytes]u8 = undefined,
    path_len: usize = 0,
    original_size: u64 = 0,
    // preview
    image_id: u64 = 0,
    preview_width: u32 = 0,
    preview_height: u32 = 0,
    /// The SOURCE's real pixel dimensions, from M4's `sips -g` hop (0 until
    /// it answers, and 0 forever if its output did not parse — the same
    /// tolerance the megapixel check already takes). M9 needs them because
    /// `sips -Z 160` *upscales* a source smaller than 160px: `tiny.png`
    /// (312 B) came back a blurry 160x160. The registered pixels are
    /// whatever `sips` produced; the DRAWN size clamps to the source, so a
    /// small image renders small and sharp instead of stretched.
    source_width: u32 = 0,
    source_height: u32 = 0,
    // result — per format, because the two encodes succeed or fail
    // independently (see `EncodeOutcome`). No `savings_percent` field:
    // the percentage is pure arithmetic over `original_size` and each
    // output size, so it is derived per rebuild ("Derive, don't store").
    avif_path_buffer: [platform.max_dialog_path_bytes]u8 = undefined,
    avif_path_len: usize = 0,
    avif_size: u64 = 0,
    avif_outcome: EncodeOutcome = .none,
    webp_path_buffer: [platform.max_dialog_path_bytes]u8 = undefined,
    webp_path_len: usize = 0,
    webp_size: u64 = 0,
    webp_outcome: EncodeOutcome = .none,
    // options
    format: Format = .avif,
    // encoders — M5's launch-time `which avifenc`/`which cwebp` presence
    // check. `null` until that hop answers; both land before any user
    // input is possible, so `update`'s arms below never need to guard on
    // this being unresolved.
    avifenc_present: ?bool = null,
    cwebp_present: ?bool = null,
    // ui
    status: Status = .idle,
    error_message_buffer: [256]u8 = undefined,
    error_message_len: usize = 0,
    /// A `.done` run that still lost a format. Distinct from
    /// `error_message_buffer` because the two coexist in exactly the case
    /// M7's partial-failure decision creates: AVIF landed, WebP did not,
    /// and the run is a success WITH something to say. PLAN.md's
    /// "`.failed` is always paired with an error message, and no other
    /// path sets `.failed`" survives precisely because this is its own
    /// buffer rather than a second meaning for that one.
    warning_message_buffer: [256]u8 = undefined,
    warning_message_len: usize = 0,

    // M8: Save As. `showSaveDialog` only ever returns ONE path, so "Both"
    // mode runs two dialog+copy rounds back to back rather than inventing a
    // folder-picker PLAN never mentions — `save_queue` is that round-robin.
    // `index == len` (true at rest, including 0 == 0) means "no save in
    // flight"; `save_as` rebuilds the queue fresh on every press.
    save_queue: [2]Output = undefined,
    save_queue_len: usize = 0,
    save_queue_index: usize = 0,
    /// Accumulates one short note per format that actually resolved (a
    /// cancel is silent — see `update`'s `.save_as_dialog_result` arm).
    /// Its own buffer, not `warning_message_buffer`: a save note and an
    /// encode warning are different facts, and folding them into one
    /// field would mean one silently overwriting the other.
    save_message_buffer: [256]u8 = undefined,
    save_message_len: usize = 0,

    /// One chip per format, for the toggle-group (see "Chips" in the
    /// native-ui skill) — must live inside Model for `for each` to see it.
    ///
    /// A struct rather than a bare `[_]Format` so the chip can carry its
    /// own label: the tag names are lowercase Zig identifiers ("avif",
    /// "webp"), and the UI names FILE FORMATS, which spell themselves
    /// "AVIF" and "WebP". A method on `Format` would have been tidier, but
    /// bindings resolve fields on a loop ITEM and an enum has none — the
    /// checker says so directly ("binding does not name a field on the
    /// loop item"). `{c.value}` still coerces into the `set_format`
    /// payload exactly as the bare tag did.
    pub const FormatChip = struct { value: Format, label: []const u8 };
    pub const formats = [_]FormatChip{
        .{ .value = .avif, .label = "AVIF" },
        .{ .value = .webp, .label = "WebP" },
        .{ .value = .both, .label = "Both" },
    };

    /// State `update` owns, which the markup reaches only through the
    /// derived fns below (`statusLine`, `fileSummary`, `avifResult`, ...).
    /// Declared now rather than in M2 because until M7 most of these were
    /// "not bound YET" (M2's recorded reason for leaving the warnings
    /// alone); what is left over after M7 is permanently update-side, so
    /// naming it here makes a future `native check` warning mean something
    /// again instead of arriving into a standing list of 17.
    pub const view_unbound = .{
        "path_buffer",
        "path_len",
        "original_size",
        "preview_width",
        "preview_height",
        "source_width",
        "source_height",
        "avif_path_buffer",
        "avif_path_len",
        "avif_size",
        "avif_outcome",
        "webp_path_buffer",
        "webp_path_len",
        "webp_size",
        "webp_outcome",
        "avifenc_present",
        "cwebp_present",
        "status",
        "error_message_buffer",
        "error_message_len",
        "warning_message_buffer",
        "warning_message_len",
        "save_queue",
        "save_queue_len",
        "save_queue_index",
        "save_message_buffer",
        "save_message_len",
        "path",
        "errorMessage",
        "warningMessage",
        "saveMessage",
    };

    pub fn path(model: *const Model) []const u8 {
        return model.path_buffer[0..model.path_len];
    }
    pub fn errorMessage(model: *const Model) []const u8 {
        return model.error_message_buffer[0..model.error_message_len];
    }
    pub fn warningMessage(model: *const Model) []const u8 {
        return model.warning_message_buffer[0..model.warning_message_len];
    }
    pub fn saveMessage(model: *const Model) []const u8 {
        return model.save_message_buffer[0..model.save_message_len];
    }

    /// The picked file's last path component — what the UI names, and
    /// what every error message interpolates. Empty until a pick lands.
    pub fn fileName(model: *const Model) []const u8 {
        const full = model.path();
        if (std.mem.lastIndexOfScalar(u8, full, '/')) |slash| return full[slash + 1 ..];
        return full;
    }

    /// True once `image_loaded` registered preview pixels — the `<if>`
    /// gate on the `<image>` leaf, since id 0 draws nothing anyway but
    /// the surrounding chrome shouldn't reserve space for it.
    pub fn hasPreview(model: *const Model) bool {
        return model.image_id != 0;
    }

    // ------------------------------------------------------- M9: view state
    //
    // The view swaps between two shapes — the empty drop zone and the
    // file card — and disables the two actions that have nothing to act
    // on. Every one of these is a PREDICATE, not a status comparison
    // spelled in markup: the states the UI cares about ("is something
    // running", "is there anything to save") are unions of `Status`
    // values, and naming them here keeps that mapping in Zig where it is
    // testable.

    /// A file has been picked — true from the moment the dialog answers,
    /// including while the preview is still loading and after a load that
    /// failed. The drop zone is gone at that point either way: the status
    /// bar is what explains what happened.
    pub fn hasFile(model: *const Model) bool {
        return model.path_len != 0;
    }

    /// An effect chain is running and the user should wait: the spinner
    /// beside the status line, and the reason Smoosh/Save As go quiet.
    pub fn isBusy(model: *const Model) bool {
        return model.status == .loading or model.status == .compressing;
    }

    /// The status line carries every failure message, and a failure has to
    /// look different from "Done." — this gates the alert icon beside it.
    /// A `.done` run that lost one format is deliberately NOT included: it
    /// succeeded, and its warning rides the same line (see `statusLine`).
    pub fn isFailed(model: *const Model) bool {
        return model.status == .failed;
    }

    /// Same gate `update`'s `.smoosh` arm enforces, so the button is
    /// disabled exactly when pressing it would be a no-op.
    pub fn canSmoosh(model: *const Model) bool {
        return model.hasPreview() and model.status != .compressing;
    }

    /// Same gate the `.save_as` arm enforces: at least one landed output,
    /// and no save round already in flight.
    pub fn canSave(model: *const Model) bool {
        return (model.hasAvifResult() or model.hasWebpResult()) and
            model.save_queue_index >= model.save_queue_len;
    }

    /// "2.4 MB" — the picked file's size on its own line, the sketch's
    /// "Original: 2.4 MB". Empty with no file.
    pub fn originalSize(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!model.hasFile()) return "";
        return formatBytes(arena, model.original_size);
    }

    /// The preview's DRAWN size, clamped to the source's real dimensions
    /// so `sips -Z`'s upscaling of a tiny source never renders as a blurry
    /// 160x160 (PLAN.md M3's deferred note). Falls back to the registered
    /// size when the source dimensions never parsed.
    pub fn previewWidth(model: *const Model) u32 {
        if (model.source_width == 0) return model.preview_width;
        return @min(model.preview_width, model.source_width);
    }
    pub fn previewHeight(model: *const Model) u32 {
        if (model.source_height == 0) return model.preview_height;
        return @min(model.preview_height, model.source_height);
    }

    // ------------------------------------------------------ M7: results
    //
    // One line per format, shown only for a format that actually landed
    // — the "per-format, side by side" reading of PLAN.md's "combined
    // savings" for Both mode. A summed total would describe a download
    // that never happens (no client fetches both files), so each line
    // reports what would really be served if that format were chosen.

    pub fn hasAvifResult(model: *const Model) bool {
        return model.avif_outcome == .ok;
    }
    pub fn hasWebpResult(model: *const Model) bool {
        return model.webp_outcome == .ok;
    }

    /// "AVIF  700.2 KB  −88%". Empty unless AVIF landed this run.
    pub fn avifResult(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!model.hasAvifResult()) return "";
        return model.resultLine(arena, "AVIF", model.avif_size);
    }
    /// "WebP  655.3 KB  −89%". Empty unless WebP landed this run.
    pub fn webpResult(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!model.hasWebpResult()) return "";
        return model.resultLine(arena, "WebP", model.webp_size);
    }

    fn resultLine(model: *const Model, arena: std.mem.Allocator, label: []const u8, size: u64) []const u8 {
        return std.fmt.allocPrint(arena, "{s}  {s}  {s}", .{
            label,
            formatBytes(arena, size),
            formatSavings(arena, model.original_size, size),
        }) catch "";
    }

    // ---------------------------------------------------------- mutation
    //
    // Not `pub`: these are update-side only. Bindings resolve Model's
    // pub decls, and a pub setter would show up in the model contract as
    // bindable state it is not.

    fn setPath(model: *Model, text: []const u8) void {
        const len = @min(text.len, model.path_buffer.len);
        @memcpy(model.path_buffer[0..len], text[0..len]);
        model.path_len = len;
    }

    /// Every `.failed` transition goes through here, so PLAN.md's
    /// "Status → error mapping" holds by construction: `.failed` is
    /// never set without a message beside it.
    ///
    /// M9 note on wording: these messages do NOT name the file. The
    /// `<status-bar>` is one honest line that elides what does not fit
    /// (it takes no `wrap`, by design), and a quoted filename cost ~18 of
    /// the ~65 characters that fit — enough to truncate the part that
    /// says what to do about it. The file card directly above names the
    /// file in every state that can fail, so the message explains what
    /// happened and nothing else.
    fn fail(model: *Model, comptime fmt: []const u8, args: anytype) void {
        // A path long enough to overflow 256 bytes is a real input (the
        // path buffer is 4096), so the fallback has to be a message, not
        // whatever partial bytes bufPrint left behind.
        const written = std.fmt.bufPrint(&model.error_message_buffer, fmt, args) catch blk: {
            const fallback = "Something went wrong with that file.";
            @memcpy(model.error_message_buffer[0..fallback.len], fallback);
            break :blk model.error_message_buffer[0..fallback.len];
        };
        model.error_message_len = written.len;
        model.status = .failed;
    }

    /// The partial-success counterpart to `fail`: says what was lost
    /// WITHOUT claiming the run failed. Deliberately does not touch
    /// `status` — the caller has already decided this run is `.done`.
    fn warn(model: *Model, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&model.warning_message_buffer, fmt, args) catch blk: {
            const fallback = "Some formats didn't finish.";
            @memcpy(model.warning_message_buffer[0..fallback.len], fallback);
            break :blk model.warning_message_buffer[0..fallback.len];
        };
        model.warning_message_len = written.len;
    }

    /// Drops the preview: the id the `<image>` draws and the dimensions
    /// that size it. Separate from `clearResults` because they answer to
    /// different events — outputs die when a RUN starts, the preview when
    /// a new FILE does.
    fn clearPreview(model: *Model) void {
        model.image_id = 0;
        model.preview_width = 0;
        model.preview_height = 0;
        model.source_width = 0;
        model.source_height = 0;
    }

    /// Wipes the previous run's outputs. Called when a new run starts and
    /// when a new file lands — without it, a fresh pick would keep
    /// rendering the last file's result lines. Also wipes any Save As note
    /// (M8): it names a file this call is about to invalidate, and a save
    /// can never be in flight here — dialogs block the loop, so `smoosh`/a
    /// new pick can only run between rounds, never mid-save.
    fn clearResults(model: *Model) void {
        model.avif_outcome = .none;
        model.avif_path_len = 0;
        model.avif_size = 0;
        model.webp_outcome = .none;
        model.webp_path_len = 0;
        model.webp_size = 0;
        model.warning_message_len = 0;
        model.save_queue_len = 0;
        model.save_queue_index = 0;
        model.save_message_len = 0;
    }

    /// M2 scaffold status line — just enough for the placeholder
    /// `<status-bar>` to bind to. Later milestones will likely replace this
    /// with something that also reports sizes/savings once those are real.
    pub fn statusLine(model: *const Model) []const u8 {
        // A Save As note is the freshest thing the user did, so it wins
        // over whatever `status` says — including a stale `.done` warning
        // about the run that PRODUCED the file just saved. It cannot mask
        // a genuine new `.failed`/`.done`: both `smoosh` and a new pick
        // clear it (see `clearResults`), and `.reset` clears the whole
        // model.
        if (model.save_message_len > 0) return model.saveMessage();
        return switch (model.status) {
            // M11: "drop" is back — `on_drop` makes it real again, after
            // M9 dropped the word because drops didn't work yet.
            .idle => "Drop or choose an image to get started.",
            .loading => "Loading…",
            .ready => "Ready to smoosh.",
            .compressing => "Smooshing…",
            // A partially successful run is `.done` — the result lines
            // show what landed, and the status bar is the only place the
            // format that did NOT land can be named.
            .done => if (model.warning_message_len > 0) model.warningMessage() else "Done.",
            .failed => model.errorMessage(),
        };
    }
};

pub const Msg = union(enum) {
    pick_file, // "Choose Image…" clicked
    dialog_result: native_sdk.EffectHostResult, // host open-dialog callback
    dropped_file: []const u8, // on_drop callback — a file dragged onto the window (M11)
    stat_result: native_sdk.EffectHostResult, // host file-size callback -> original_size
    dimensions_result: native_sdk.EffectExit, // `sips -g` source pixel dimensions -> megapixel limit check
    thumbnail_result: native_sdk.EffectExit, // `sips` downscale for the preview
    image_loaded: native_sdk.EffectImageResult, // fx.loadImage callback (registers the preview pixels)
    set_format: Format, // format chip pressed
    smoosh, // "Smoosh" clicked
    convert_result: native_sdk.EffectExit, // M12: `sips` HEIC->PNG staging callback, shared by both formats
    encode_result: native_sdk.EffectExit, // fx.spawn callback, one per format encoded
    encode_size_result: native_sdk.EffectHostResult, // host file-size callback -> avif_size/webp_size
    save_as, // "Save As…" clicked
    save_as_dialog_result: native_sdk.EffectHostResult, // host save-dialog callback
    // A THIRD host command we bind ourselves, `file.copy` — not
    // `fx.writeFile`. `fx.writeFile`/`fx.readFile` cap at 1 MiB
    // (`max_effect_file_bytes`), and a real encoder output can exceed
    // that (M3 hit the identical bound with the preview, for the same
    // reason: a bundled-effect ceiling sized for small payloads, not an
    // arbitrary file). `std.Io.Dir.copyFileAbsolute` has no such cap.
    save_as_result: native_sdk.EffectHostResult, // host copy-file callback
    encoder_check_result: native_sdk.EffectExit, // launch-time `which avifenc`/`which cwebp`
    reset, // clear current image, return to idle

    // Dispatched by effect/host-call result paths, never from markup —
    // same idiom the spike uses for its `dialog_result` Msg.
    pub const view_unbound = .{
        "dialog_result",
        "dropped_file",
        "stat_result",
        "dimensions_result",
        "thumbnail_result",
        "image_loaded",
        "convert_result",
        "encode_result",
        "encode_size_result",
        "save_as_dialog_result",
        "save_as_result",
        "encoder_check_result",
    };
};

/// Human-readable byte count for the UI. Formatted into the build arena
/// by the caller's fn; never stored on the model.
pub fn formatBytes(arena: std.mem.Allocator, bytes: u64) []const u8 {
    const kb = 1024;
    const mb = 1024 * 1024;
    if (bytes < kb) return std.fmt.allocPrint(arena, "{d} B", .{bytes}) catch "";
    const unit: []const u8, const divisor: f64 = if (bytes < mb)
        .{ "KB", @as(f64, kb) }
    else
        .{ "MB", @as(f64, mb) };
    return std.fmt.allocPrint(arena, "{d:.1} {s}", .{
        @as(f64, @floatFromInt(bytes)) / divisor,
        unit,
    }) catch "";
}

/// "−88%" when the output is smaller than the source, "+1% larger" when it
/// is not. The negative case is REAL, not an error: `test-images/tiny.png`
/// (312 B) encodes to a 315-byte AVIF, confirmed by running the pinned argv
/// in M5. PLAN.md asks that this "display sanely rather than as a broken
/// percentage" — so the sign flips and the word changes, rather than
/// printing "−-1%". Differences under half a percent round to nothing
/// meaningful in either direction, so they say so outright.
pub fn formatSavings(arena: std.mem.Allocator, original: u64, output: u64) []const u8 {
    if (original == 0) return "";
    const ratio = @as(f64, @floatFromInt(output)) / @as(f64, @floatFromInt(original));
    const percent = (1.0 - ratio) * 100.0;
    if (percent >= 0.5) return std.fmt.allocPrint(arena, "−{d:.0}%", .{percent}) catch "";
    if (percent <= -0.5) return std.fmt.allocPrint(arena, "+{d:.0}% larger", .{-percent}) catch "";
    return "same size";
}

pub const Effects = native_sdk.Effects(Msg);

// ------------------------------------------------------------- effect keys
//
// One key space across spawns, fetches, files, host requests, and image
// loads (`max_effects` = 16 slots). `preview_image_id` is BOTH the
// loadImage effect key and the ImageId the `<image>` leaf draws — that
// is the SDK's design, not a shortcut, so it must stay distinct from the
// others.

const dialog_key: u64 = 1;
const stat_key: u64 = 2;
const thumbnail_key: u64 = 3;
const preview_image_id: u64 = 4;
const dimensions_key: u64 = 5;
const avifenc_check_key: u64 = 6;
const cwebp_check_key: u64 = 7;
const avif_encode_key: u64 = 8;
const webp_encode_key: u64 = 9;
const avif_stat_key: u64 = 10;
const webp_stat_key: u64 = 11;
const save_dialog_key: u64 = 12;
const save_copy_key: u64 = 13;
const heic_convert_key: u64 = 14;

/// Host-call names our own `HostBridge` answers (see `main`). Not SDK
/// vocabulary — we bind the seam, so we name it.
const host_open_file = "dialog.openFile";
const host_file_size = "file.stat";
const host_save_file = "dialog.saveFile";
const host_file_copy = "file.copy";

/// Absolute so the check does not depend on the inherited PATH — but
/// `which`'s OWN job is to search that PATH for `avifenc`/`cwebp`, which is
/// exactly what a real encode spawn (M7) would do resolving argv[0] the
/// same way, so the check is honest about what it is proving.
const which_path = "/usr/bin/which";

/// Where `sips` writes the downscaled preview, resolved once in `main`
/// (see the "Preview is a thumbnail" note there). `pub var` so tests can
/// point it somewhere harmless; `update` only ever reads it.
pub var thumbnail_path: []const u8 = "";

/// M12: where `sips` stages a HEIC/HEIF source as a PNG before encoding —
/// `avifenc`/`cwebp` reject HEIC as an INPUT format outright (see
/// `isHeicSource`), even though `sips` decodes it fine for the preview
/// above. Resolved once in `main`, same as `thumbnail_path`; `pub var` for
/// the same test reason.
pub var converted_path: []const u8 = "";

/// The environment every `fx.spawn` child inherits (bound once, at launch,
/// into `Runtime.Options.environ`) — see `resolveSpawnEnviron` below for why
/// this differs from the raw process environment on a packaged app.
var spawn_environ: std.process.Environ = .empty;

/// M10: launched from `/Applications`, `avifenc`/`cwebp` presence detection
/// (M5) failed even with both installed via Homebrew. GUI-launched apps
/// (Finder/Dock double-click — every packaged `.app`) inherit launchd's
/// minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), not the interactive-shell
/// PATH `brew shellenv` adds to `.zshrc`/`.zprofile` — that file only runs
/// for a login/interactive shell, which `native dev`/`native build` (always
/// launched from a Terminal) had until now. Every spawned child, `which`
/// included, inherits this process's OWN environment (`Runtime.Options.environ`,
/// threaded straight into each child — see effects.zig), so the fix is to
/// widen THAT environment once at launch rather than touch the spawns
/// themselves. Leaves PATH untouched if Homebrew's bin is already on it
/// (the Terminal-launched case), so this changes nothing for `native dev`.
pub fn resolveSpawnEnviron(gpa: std.mem.Allocator, base: std.process.Environ) !std.process.Environ {
    const homebrew_paths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin";

    var map = try base.createMap(gpa);
    defer map.deinit();

    const current_path = map.get("PATH") orelse "";
    if (std.mem.indexOf(u8, current_path, "/opt/homebrew/bin") != null) return base;

    const augmented_path = if (current_path.len == 0)
        homebrew_paths
    else
        try std.fmt.allocPrint(gpa, "{s}:{s}", .{ current_path, homebrew_paths });
    defer if (current_path.len != 0) gpa.free(augmented_path);

    try map.put("PATH", augmented_path);
    return .{ .block = try map.createPosixBlock(gpa, .{}) };
}

/// Longest edge of the generated preview, in pixels. The registered-image
/// budget is 1 MiB of DECODED RGBA (`max_registered_canvas_image_pixel_bytes`),
/// i.e. 512x512 exactly — 160x160x4 = 100 KB leaves real headroom.
const thumbnail_max_edge = "160";

// -------------------------------------------------------- M4: input limits
//
// PLAN.md's "Input size limits": 80-100MB / 40-50 megapixels, whichever
// comes first. Picked the top of both ranges — a local tool should be more
// permissive than a web upload limit, and the failure mode we are guarding
// against (exhausting memory on decode) only bites well past either number.

const max_original_bytes: u64 = 100 * 1024 * 1024; // 100 MB
const max_source_megapixels: f64 = 50.0;

fn bytesToMb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

const Dimensions = struct { width: u32, height: u32 };

/// Parses `sips -g pixelWidth -g pixelHeight -1 <path>`'s one-line output:
/// `<path>|pixelWidth: <n>|pixelHeight: <n>|`. Returns null for anything
/// that doesn't parse — in particular `sips` prints literal `<nil>` (and
/// still exits 0) for a non-image or a missing file, which is fine: an
/// unparseable result just means "dimensions unknown," and the thumbnail
/// spawn right after is the real format gate (M3).
fn parseDimensions(output: []const u8) ?Dimensions {
    var width: ?u32 = null;
    var height: ?u32 = null;
    var it = std.mem.splitScalar(u8, output, '|');
    while (it.next()) |segment| {
        const colon = std.mem.indexOfScalar(u8, segment, ':') orelse continue;
        const key = std.mem.trim(u8, segment[0..colon], " \t\r\n");
        const value_text = std.mem.trim(u8, segment[colon + 1 ..], " \t\r\n");
        const value = std.fmt.parseInt(u32, value_text, 10) catch continue;
        if (std.mem.eql(u8, key, "pixelWidth")) width = value;
        if (std.mem.eql(u8, key, "pixelHeight")) height = value;
    }
    if (width == null or height == null) return null;
    return .{ .width = width.?, .height = height.? };
}

// ------------------------------------------------------- M5: encoder check
//
// PLAN.md: "Detect presence of avifenc/cwebp at launch. If missing, show
// which tool is absent and the exact brew install command." `init_fx` is
// the SDK's boot-command hook — it runs exactly once, on the installing
// frame, before the first view builds, so a launch that starts missing an
// encoder shows the error on the very first paint rather than a flash of
// the normal drop-zone.

/// TEA's boot command (`UiApp.Options.init_fx`). Fires the two presence
/// checks; `update`'s `.encoder_check_result` arm joins them.
pub fn initFx(model: *Model, fx: *Effects) void {
    _ = model;
    fx.spawn(.{
        .key = avifenc_check_key,
        .argv = &.{ which_path, "avifenc" },
        .output = .collect,
        .on_exit = Effects.exitMsg(.encoder_check_result),
    });
    fx.spawn(.{
        .key = cwebp_check_key,
        .argv = &.{ which_path, "cwebp" },
        .output = .collect,
        .on_exit = Effects.exitMsg(.encoder_check_result),
    });
}

// ------------------------------------------------------ M7: encode pipeline
//
// THE PARTIAL-FAILURE DECISION (PLAN.md's "Open decisions", settled here):
// in "Both" mode the two encodes are INDEPENDENT. If one succeeds and the
// other fails, the run is `.done` — the successful format's numbers are
// shown and the failed one is named in the status bar. Only when NO
// requested format landed is the run `.failed`.
//
// The deciding fact is that `avifenc`/`cwebp` write their own output files:
// by the time WebP's nonzero exit arrives, `photo.avif` is already on disk
// next to the source. Failing the whole run would mean either claiming
// failure with a good file sitting right there, or deleting a file the user
// can see. It also makes a missing encoder degrade instead of blocking — a
// machine with only `avifenc` still gets its AVIF out of a "Both" run.
//
// The floor keeps PLAN.md's "Status → error mapping" intact: a run where
// everything failed is `.failed` with a message, which in single-format mode
// is just the ordinary failure path — no special case.

/// ONE encodable output format. `Format.both` is a REQUEST for two of
/// these; every per-format path below works on this type, never on `Format`,
/// which is exactly what keeps the two encodes independent.
const Output = enum { avif, webp };

/// Pinned in M5 by running both against real fixtures (PLAN.md's "Encoder
/// invocations"). argv[0] is a bare name, not an absolute path: M5's
/// `which` check proved the PATH resolution these spawns depend on.
const avif_quality = "58";
const avif_speed = "6";
const webp_quality = "80";

/// M12: true for a `.heic`/`.heif` source (case-insensitive). `avifenc`/
/// `cwebp` reject HEIC as an INPUT format outright — confirmed in M11 by
/// running both directly against a real HEIC fixture (PLAN.md's "Known
/// limitations") — even though `sips` decodes it fine, which is what M3's
/// preview thumbnail already relies on. `smoosh` uses this to route through
/// a `sips`-to-PNG staging step first instead of handing the encoders a
/// container they cannot read. `pub`, matching `formatBytes`/`formatSavings`/
/// `resolveSpawnEnviron`'s precedent for a pure helper worth testing
/// directly rather than only through the full dispatch path.
pub fn isHeicSource(source_path: []const u8) bool {
    const name_start = if (std.mem.lastIndexOfScalar(u8, source_path, '/')) |slash| slash + 1 else 0;
    const dot = std.mem.lastIndexOfScalar(u8, source_path[name_start..], '.') orelse return false;
    const ext = source_path[name_start + dot + 1 ..];
    return std.ascii.eqlIgnoreCase(ext, "heic") or std.ascii.eqlIgnoreCase(ext, "heif");
}

fn outputLabel(output: Output) []const u8 {
    return switch (output) {
        .avif => "AVIF",
        .webp => "WebP",
    };
}

fn outcomeOf(model: *const Model, output: Output) EncodeOutcome {
    return switch (output) {
        .avif => model.avif_outcome,
        .webp => model.webp_outcome,
    };
}

fn setOutcome(model: *Model, output: Output, outcome: EncodeOutcome) void {
    switch (output) {
        .avif => model.avif_outcome = outcome,
        .webp => model.webp_outcome = outcome,
    }
}

fn outputPathOf(model: *const Model, output: Output) []const u8 {
    return switch (output) {
        .avif => model.avif_path_buffer[0..model.avif_path_len],
        .webp => model.webp_path_buffer[0..model.webp_path_len],
    };
}

/// `/a/b/photo.jpg` + `.avif` -> `/a/b/photo.avif` (PLAN.md's "Output
/// handling": next to the source). The extension search is scoped to the
/// last path component so a dot in a PARENT directory can never be mistaken
/// for one; a name with no dot of its own just gets the extension appended.
/// Returns null only when the result would not fit the buffer.
fn outputPath(buffer: []u8, source: []const u8, extension: []const u8) ?[]const u8 {
    const name_start = if (std.mem.lastIndexOfScalar(u8, source, '/')) |slash| slash + 1 else 0;
    const stem_end = blk: {
        const dot = std.mem.lastIndexOfScalar(u8, source[name_start..], '.') orelse break :blk source.len;
        // A leading dot is a hidden file (".profile"), not an extension.
        if (dot == 0) break :blk source.len;
        break :blk name_start + dot;
    };
    if (stem_end + extension.len > buffer.len) return null;
    @memcpy(buffer[0..stem_end], source[0..stem_end]);
    @memcpy(buffer[stem_end..][0..extension.len], extension);
    return buffer[0 .. stem_end + extension.len];
}

/// Starts one format, or records why it could not start. Every path out of
/// here leaves the format's outcome non-`.none`, so the join below always
/// terminates.
///
/// `input_path` is what the encoder actually reads — `model.path()` for an
/// ordinary source, or M12's `converted_path` when the source is HEIC/HEIF.
/// The DESTINATION is still always derived from `model.path()` (the real
/// source name), never from `input_path` — a HEIC `photo.heic` must become
/// `photo.avif`, not something named after the staging file.
fn beginEncode(model: *Model, fx: *Effects, output: Output, input_path: []const u8) void {
    // M5 resolves both checks before any user input is possible; `null`
    // would mean the boot check never answered, and attempting the spawn
    // is more useful than refusing on a guess.
    const encoder_present = switch (output) {
        .avif => model.avifenc_present orelse true,
        .webp => model.cwebp_present orelse true,
    };
    if (!encoder_present) return setOutcome(model, output, .missing_encoder);

    const extension = switch (output) {
        .avif => ".avif",
        .webp => ".webp",
    };
    const buffer: []u8 = switch (output) {
        .avif => &model.avif_path_buffer,
        .webp => &model.webp_path_buffer,
    };
    const destination = outputPath(buffer, model.path(), extension) orelse
        return setOutcome(model, output, .encode_failed);
    // A `.webp` source encoded to WebP would hand the encoder the same
    // path to read and write. "Overwrite silently" is about a previous
    // OUTPUT, never the user's source file.
    if (std.mem.eql(u8, destination, model.path())) {
        return setOutcome(model, output, .same_path);
    }
    switch (output) {
        .avif => model.avif_path_len = destination.len,
        .webp => model.webp_path_len = destination.len,
    }

    setOutcome(model, output, .pending);
    fx.spawn(.{
        .key = switch (output) {
            .avif => avif_encode_key,
            .webp => webp_encode_key,
        },
        .argv = switch (output) {
            .avif => &.{ "avifenc", "-q", avif_quality, "--speed", avif_speed, input_path, destination },
            .webp => &.{ "cwebp", "-q", webp_quality, input_path, "-o", destination },
        },
        // `.collect` rather than `.lines`: the encoders' progress output is
        // of no use to the UI, and collect is the mode that also delivers
        // `stderr_tail` on a nonzero exit.
        .output = .collect,
        .on_exit = Effects.exitMsg(.encode_result),
    });
}

/// One failed format's user-facing sentence. Written into `buffer` (caller
/// owned) for the cases that must name the file; the rest are static.
fn failureText(model: *const Model, output: Output, buffer: []u8) []const u8 {
    const label = outputLabel(output);
    return switch (outcomeOf(model, output)) {
        // PLAN.md error state: encoder binary missing. Same wording as
        // M5's launch-time check, scoped to the one format that needs it.
        .missing_encoder => switch (output) {
            .avif => "AVIF needs avifenc. Install with: brew install libavif",
            .webp => "WebP needs cwebp. Install with: brew install webp",
        },
        .same_path => switch (output) {
            .avif => "Skipped AVIF — the source is already an AVIF file.",
            .webp => "Skipped WebP — the source is already a WebP file.",
        },
        // PLAN.md error state: write to output path failed. Names the
        // source file, which is also where the output was headed.
        .write_failed => std.fmt.bufPrint(
            buffer,
            "Couldn't save the {s} — check the folder's permissions.",
            .{label},
        ) catch "Couldn't save the compressed file.",
        // PLAN.md error state: encode failed. Deliberately short and
        // non-technical; the encoder's stderr is not surfaced in v0.1.
        else => std.fmt.bufPrint(buffer, "{s} encoding failed.", .{label}) catch "Encoding failed.",
    };
}

/// The join. Fires once no requested format is still `.pending` — which is
/// why it never reads `Model.format`: a user who changes the format chip
/// mid-encode cannot change what this run was asked to produce.
fn finishIfComplete(model: *Model) void {
    if (model.avif_outcome == .pending or model.webp_outcome == .pending) return;

    var avif_buffer: [256]u8 = undefined;
    var webp_buffer: [256]u8 = undefined;
    const avif_failed = model.avif_outcome.isFailure();
    const webp_failed = model.webp_outcome.isFailure();

    if (!model.hasAvifResult() and !model.hasWebpResult()) {
        // Nothing landed. In single-format mode this is just "the encode
        // failed"; in Both mode it is both sentences, and either way it is
        // the one path that may set `.failed`.
        if (avif_failed and webp_failed) return model.fail("{s} {s}", .{
            failureText(model, .avif, &avif_buffer),
            failureText(model, .webp, &webp_buffer),
        });
        if (avif_failed) return model.fail("{s}", .{failureText(model, .avif, &avif_buffer)});
        if (webp_failed) return model.fail("{s}", .{failureText(model, .webp, &webp_buffer)});
        return; // Nothing was requested at all — leave the status alone.
    }

    // At least one format landed: the run succeeded. Exactly one of the two
    // can be a failure here (both failing is the branch above).
    model.status = .done;
    if (avif_failed) return model.warn("{s}", .{failureText(model, .avif, &avif_buffer)});
    if (webp_failed) return model.warn("{s}", .{failureText(model, .webp, &webp_buffer)});
}

// --------------------------------------------------------- M8: Save As
//
// PLAN.md: "Wire save_as -> showSaveDialog -> copy the already-produced
// output(s) to the chosen location. Does not replace auto-save from M7."
// `showSaveDialog` only ever returns ONE path, and Smoosh can produce two
// files ("Both"), so this is SEQUENTIAL rather than a folder-picker PLAN
// never mentions: one save-dialog-then-copy round per landed format, one
// after another. A user who cancels one round still gets offered the
// other; only a copy failure is reported as a problem — a cancel is an
// ordinary "not now", same as `dialog_result`'s cancel-is-not-an-error
// precedent above.

/// `/a/b/large.avif` -> `large.avif` — the default filename `HostBridge`
/// hands the save panel. Truncates (silently, via `@min`) rather than
/// erroring on a name longer than `buf`; a lost suffix in a default
/// filename the user can freely retype is not worth a failure state.
fn defaultSaveName(model: *const Model, output: Output, buf: []u8) []const u8 {
    const path = outputPathOf(model, output);
    const name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
    const len = @min(name.len, buf.len);
    @memcpy(buf[0..len], name[0..len]);
    return buf[0..len];
}

/// One line per format that actually resolved — never for a cancel, which
/// is silent. Appended, not overwritten: "Both" can report on both formats
/// in the one status line.
fn appendSaveNote(model: *Model, comptime fmt: []const u8, args: anytype) void {
    var note_buf: [128]u8 = undefined;
    const note = std.fmt.bufPrint(&note_buf, fmt, args) catch return;
    const existing = model.save_message_len;
    const sep: []const u8 = if (existing > 0) " " else "";
    if (existing + sep.len + note.len > model.save_message_buffer.len) return;
    @memcpy(model.save_message_buffer[existing..][0..sep.len], sep);
    @memcpy(model.save_message_buffer[existing + sep.len ..][0..note.len], note);
    model.save_message_len = existing + sep.len + note.len;
}

/// Starts the save-dialog round for whatever `save_queue_index` currently
/// points at. Called by `.save_as` for the first round and by the two
/// result arms below for every subsequent one — the same "dialogs block
/// the loop" fact that lets M3's pick chain issue one host request per arm
/// with no staleness guard applies here too, so this needs none either.
fn beginSaveRound(model: *Model, fx: *Effects) void {
    var name_buf: [128]u8 = undefined;
    const default_name = defaultSaveName(model, model.save_queue[model.save_queue_index], &name_buf);
    fx.hostRequest(.{
        .key = save_dialog_key,
        .name = host_save_file,
        .payload = default_name,
        .on_result = Effects.hostMsg(.save_as_dialog_result),
    });
}

/// Moves to the next queued format, if any. The queue sits at `index ==
/// len` when nothing is in flight (true at rest, since both start at 0) —
/// reached exactly when this increments past the last round, so nothing
/// else needs to reset it.
fn advanceSaveQueue(model: *Model, fx: *Effects) void {
    model.save_queue_index += 1;
    if (model.save_queue_index < model.save_queue_len) beginSaveRound(model, fx);
}

// ------------------------------------------------------------ M11: drops
//
// `UiApp.Options.on_drop` (SDK 0.8.2+, `src/runtime/ui_app.zig:635`),
// dispatched from `handleRuntimeEvent`'s `.files_dropped` arm against
// `platform.FileDropEvent{ window_id, view_label, point, paths }`. A real
// drag never carries `view_label`/`point` (the macOS host builds the event
// from window + paths alone), so this is a WINDOW-wide drop, not a
// drop-zone-shaped one — anywhere in the Smoosh window accepts.

/// `on_drop`'s callback. Pure: `fn(event) ?Msg`, no `*Model` — it can turn
/// a drop into a Msg or refuse it, but it cannot gate on run state (e.g.
/// ignore a drop mid-`.compressing`); that gating, if ever wanted, belongs
/// in `update`'s arm, not here.
///
/// `drop.paths` is drain scratch, valid only for this call and the
/// dispatch that follows — never stashed. Takes the first path and ignores
/// the rest: the same single-select behaviour `showOpenDialog` already has
/// (`allow_multiple` defaults false), so a drop and a pick behave alike.
/// Empty `paths` (e.g. a drag of something with no file) returns null, so
/// `handleRuntimeEvent` dispatches nothing.
pub fn onDrop(drop: platform.FileDropEvent) ?Msg {
    if (drop.paths.len == 0) return null;
    return .{ .dropped_file = drop.paths[0] };
}

/// Starts the load chain for a path that just arrived — from the open
/// panel (`.dialog_result`'s ok branch) or a real window drop
/// (`.dropped_file`, M11). Both land here because the chain itself doesn't
/// care where the path came from: `stat_result` -> `dimensions_result` ->
/// `thumbnail_result` -> `image_loaded` -> `.ready` is the same either way.
fn beginLoad(model: *Model, fx: *Effects, path: []const u8) void {
    model.status = .loading;
    model.setPath(path);
    // A new file invalidates the previous file's outputs and preview —
    // see `clearResults`/`clearPreview`'s own doc comments for why each
    // exists (M7/M9 respectively).
    model.clearResults();
    model.clearPreview();
    fx.hostRequest(.{
        .key = stat_key,
        .name = host_file_size,
        .payload = model.path(),
        .on_result = Effects.hostMsg(.stat_result),
    });
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .pick_file => {
            model.status = .loading;
            fx.hostRequest(.{
                .key = dialog_key,
                .name = host_open_file,
                .on_result = Effects.hostMsg(.dialog_result),
            });
        },

        .dialog_result => |result| {
            if (!result.ok) {
                // Cancelled, or the panel itself failed. Neither is an
                // error state: fall back to whatever we were showing.
                model.status = if (model.hasPreview()) .ready else .idle;
                return;
            }
            beginLoad(model, fx, result.bytes);
        },

        // M11: a real drag onto the window. `onDrop` (pure, no model
        // access) already reduced the drop to one path; from here it is
        // the exact same chain a dialog pick starts — a picked-file and a
        // dropped-file are indistinguishable to `update` past this point.
        .dropped_file => |dropped_path| beginLoad(model, fx, dropped_path),

        .stat_result => |result| {
            const size = if (result.ok)
                std.fmt.parseInt(u64, result.bytes, 10) catch null
            else
                null;
            model.original_size = size orelse {
                // PLAN.md error state: "write/read to path failed".
                return model.fail("Can't read that file.", .{});
            };
            if (model.original_size > max_original_bytes) {
                // PLAN.md error state: input exceeds the size/megapixel limit.
                return model.fail(
                    "That file is {d:.1} MB — Smoosh handles files up to {d:.0} MB.",
                    .{ bytesToMb(model.original_size), bytesToMb(max_original_bytes) },
                );
            }
            // The megapixel check needs the SOURCE's real dimensions, and
            // `sips` refuses to combine `-g` (query) with `-s`/`-Z` (modify)
            // in one invocation ("cannot get properties and modify file in
            // the same invocation", confirmed against a real fixture) — so
            // this is a second, separate `sips` call, not a free read off
            // the thumbnail spawn's own output.
            fx.spawn(.{
                .key = dimensions_key,
                .argv = &.{ "/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", "-1", model.path() },
                .output = .collect,
                .on_exit = Effects.exitMsg(.dimensions_result),
            });
        },

        .dimensions_result => |exit| {
            // Same staleness hazard as `thumbnail_result` below: `.reset`
            // cancels this spawn too, and the cancellation is an ordinary
            // terminal indistinguishable from a real (if useless) result.
            if (model.status != .loading) return;
            over_limit: {
                if (exit.reason != .exited or exit.code != 0) break :over_limit;
                const dims = parseDimensions(exit.output) orelse break :over_limit;
                // Kept for the preview's drawn size (see `previewWidth`),
                // not just the limit check below.
                model.source_width = dims.width;
                model.source_height = dims.height;
                const megapixels = @as(f64, @floatFromInt(dims.width)) *
                    @as(f64, @floatFromInt(dims.height)) / 1_000_000.0;
                if (megapixels > max_source_megapixels) {
                    // PLAN.md error state: input exceeds the size/megapixel limit.
                    return model.fail(
                        "That image is {d:.0} megapixels — the limit is {d:.0} MP.",
                        .{ megapixels, max_source_megapixels },
                    );
                }
            }
            // Phase A's system-tools rule applies to the PREVIEW too, and
            // `sips` ships with macOS — no detection, no brew install.
            // Absolute path so it does not depend on the inherited PATH.
            fx.spawn(.{
                .key = thumbnail_key,
                .argv = &.{
                    "/usr/bin/sips",
                    "-s",         "format", "png",
                    "-Z",         thumbnail_max_edge,
                    model.path(), "--out",  thumbnail_path,
                },
                .output = .collect,
                .on_exit = Effects.exitMsg(.thumbnail_result),
            });
        },

        .thumbnail_result => |exit| {
            // The two arms below are the only ones that can hear a STALE
            // result. `dialog.openFile`/`file.stat` are answered
            // synchronously by our own `HostBridge` inside `hostRequest`,
            // and cancelling a host request delivers no Msg at all — but
            // the spawn and the image load are real async effects whose
            // cancellation (from `.reset`) arrives as an ordinary
            // terminal, indistinguishable from a genuine failure.
            if (model.status != .loading) return;
            if (exit.reason != .exited or exit.code != 0) {
                // PLAN.md error state: unsupported/undecodable input.
                return model.fail(
                    "Not an image Smoosh can read. Try JPEG, PNG, HEIC or WebP.",
                    .{},
                );
            }
            fx.loadImage(.{
                .id = preview_image_id,
                .path = thumbnail_path,
                .on_result = Effects.imageMsg(.image_loaded),
            });
        },

        .image_loaded => |result| {
            if (model.status != .loading) return;
            if (result.outcome != .loaded) {
                return model.fail("Couldn't build a preview for that file.", .{});
            }
            model.image_id = result.id;
            model.preview_width = @intCast(result.width);
            model.preview_height = @intCast(result.height);
            model.status = .ready;
        },

        .reset => {
            // Nothing in flight may land on the next model: the status
            // guard above already drops late results, and cancelling
            // frees the keys so an immediate re-pick is not rejected as
            // a duplicate. `cancel` on an idle key is a no-op.
            fx.cancel(dialog_key);
            fx.cancel(stat_key);
            fx.cancel(dimensions_key);
            fx.cancel(thumbnail_key);
            fx.cancel(preview_image_id);
            fx.cancel(heic_convert_key);
            fx.cancel(avif_encode_key);
            fx.cancel(webp_encode_key);
            fx.cancel(avif_stat_key);
            fx.cancel(webp_stat_key);
            fx.cancel(save_dialog_key);
            fx.cancel(save_copy_key);
            _ = fx.unregisterImage(preview_image_id);
            // Format is a user preference, not per-file state — it is
            // the one thing Reset deliberately keeps.
            const format = model.format;
            model.* = .{ .format = format };
        },

        .set_format => |format| model.format = format,

        .smoosh => {
            // `hasPreview` is the real gate, not `status == .ready`: it is
            // also true after a failed encode, so a retry works, and false
            // after a failed LOAD, where there is nothing to encode.
            if (!model.hasPreview()) return;
            if (model.status == .compressing) return;

            model.clearResults();
            model.status = .compressing;
            // M12: HEIC/HEIF cannot go to the encoders directly (see
            // `isHeicSource`) — stage it as a PNG first, ONE shared spawn
            // for whichever format(s) were requested, rather than one per
            // format. `.pending` on each requested outcome is the same
            // marker `beginEncode` itself would set; `.convert_result`
            // reads it back to know which formats to actually start.
            if (isHeicSource(model.path())) {
                if (model.format != .webp) model.avif_outcome = .pending;
                if (model.format != .avif) model.webp_outcome = .pending;
                fx.spawn(.{
                    .key = heic_convert_key,
                    .argv = &.{ "/usr/bin/sips", "-s", "format", "png", model.path(), "--out", converted_path },
                    .output = .collect,
                    .on_exit = Effects.exitMsg(.convert_result),
                });
                return;
            }
            // Two independent encodes, not one operation with two steps.
            if (model.format != .webp) beginEncode(model, fx, .avif, model.path());
            if (model.format != .avif) beginEncode(model, fx, .webp, model.path());
            // Every requested format may have short-circuited (both
            // encoders missing), in which case the run is already over.
            finishIfComplete(model);
        },

        .convert_result => |exit| {
            // Same staleness hazard as the rest of the encode chain:
            // `.reset` cancels this spawn too.
            if (model.status != .compressing) return;
            if (exit.reason != .exited or exit.code != 0) {
                // The staging step is ONE shared prerequisite for whichever
                // formats were requested, not two independent encoder
                // failures — fail directly with one sentence rather than
                // routing through `finishIfComplete`, which would
                // concatenate the identical message twice in "Both" mode.
                // Nothing landed either way, so `.failed` is correct here
                // regardless of how many formats were requested (the same
                // "all-failed floor" M7 already established).
                if (model.avif_outcome == .pending) setOutcome(model, .avif, .convert_failed);
                if (model.webp_outcome == .pending) setOutcome(model, .webp, .convert_failed);
                return model.fail("Couldn't prepare that HEIC file for encoding.", .{});
            }
            if (model.avif_outcome == .pending) beginEncode(model, fx, .avif, converted_path);
            if (model.webp_outcome == .pending) beginEncode(model, fx, .webp, converted_path);
            finishIfComplete(model);
        },

        .encode_result => |exit| {
            // Same staleness hazard as the load chain: `.reset` cancels
            // these spawns and the cancellation arrives as an ordinary
            // nonzero terminal.
            if (model.status != .compressing) return;
            const output: Output = if (exit.key == avif_encode_key)
                .avif
            else if (exit.key == webp_encode_key)
                .webp
            else
                return;
            if (exit.reason != .exited or exit.code != 0) {
                setOutcome(model, output, .encode_failed);
                return finishIfComplete(model);
            }
            // A zero exit is not yet a result: the output's SIZE is half of
            // what M7 has to show. `file.stat` (M3's own host command, kept
            // separate for exactly this reuse — PLAN.md M3) answers it, and
            // its failure is also how a file that never landed is caught.
            fx.hostRequest(.{
                .key = switch (output) {
                    .avif => avif_stat_key,
                    .webp => webp_stat_key,
                },
                .name = host_file_size,
                .payload = outputPathOf(model, output),
                .on_result = Effects.hostMsg(.encode_size_result),
            });
        },

        .encode_size_result => |result| {
            if (model.status != .compressing) return;
            const output: Output = if (result.key == avif_stat_key)
                .avif
            else if (result.key == webp_stat_key)
                .webp
            else
                return;
            const size = if (result.ok)
                std.fmt.parseInt(u64, result.bytes, 10) catch null
            else
                null;
            if (size) |bytes| {
                switch (output) {
                    .avif => model.avif_size = bytes,
                    .webp => model.webp_size = bytes,
                }
                setOutcome(model, output, .ok);
            } else {
                setOutcome(model, output, .write_failed);
            }
            finishIfComplete(model);
        },

        .save_as => {
            var queue: [2]Output = undefined;
            var len: usize = 0;
            if (model.hasAvifResult()) {
                queue[len] = .avif;
                len += 1;
            }
            if (model.hasWebpResult()) {
                queue[len] = .webp;
                len += 1;
            }
            if (len == 0) return; // nothing produced yet — nothing to save
            // Defensive, like `smoosh`'s own re-press guard: a save round
            // is only ever "in progress" while a dialog blocks the loop,
            // which this dispatch cannot observe live, but a stray
            // double-send under automation/tests should still be a no-op
            // rather than clobbering a queue mid-round.
            if (model.save_queue_index < model.save_queue_len) return;
            model.save_queue = queue;
            model.save_queue_len = len;
            model.save_queue_index = 0;
            model.save_message_len = 0;
            beginSaveRound(model, fx);
        },

        .save_as_dialog_result => |result| {
            if (model.save_queue_index >= model.save_queue_len) return;
            if (!result.ok) return advanceSaveQueue(model, fx); // cancelled: silent, offer the next format
            const output = model.save_queue[model.save_queue_index];
            var payload_buf: [platform.max_dialog_path_bytes * 2 + 1]u8 = undefined;
            const payload = std.fmt.bufPrint(&payload_buf, "{s}\n{s}", .{ outputPathOf(model, output), result.bytes }) catch {
                appendSaveNote(model, "Couldn't save {s} — the destination path is too long.", .{outputLabel(output)});
                return advanceSaveQueue(model, fx);
            };
            fx.hostRequest(.{
                .key = save_copy_key,
                .name = host_file_copy,
                .payload = payload,
                .on_result = Effects.hostMsg(.save_as_result),
            });
        },

        .save_as_result => |result| {
            if (model.save_queue_index >= model.save_queue_len) return;
            const output = model.save_queue[model.save_queue_index];
            if (result.ok) {
                appendSaveNote(model, "Saved {s}.", .{outputLabel(output)});
            } else {
                // PLAN.md error state: write to output path failed — the
                // same family of failure as M7's own write step, just at a
                // user-chosen destination instead of next to the source.
                appendSaveNote(model, "Couldn't save {s} — check the folder's permissions.", .{outputLabel(output)});
            }
            advanceSaveQueue(model, fx);
        },

        .encoder_check_result => |exit| {
            const found = exit.reason == .exited and exit.code == 0;
            if (exit.key == avifenc_check_key) {
                model.avifenc_present = found;
            } else if (exit.key == cwebp_check_key) {
                model.cwebp_present = found;
            }
            // Join: only decide once BOTH checks have answered, in
            // whichever order they land.
            const avifenc_present = model.avifenc_present orelse return;
            const cwebp_present = model.cwebp_present orelse return;
            if (avifenc_present and cwebp_present) return;
            // PLAN.md error state: encoder binary missing. Three distinct
            // messages (not one templated over a joined tool list) so each
            // names the exact `brew install` command for what is actually
            // missing.
            if (!avifenc_present and !cwebp_present) {
                return model.fail(
                    "Smoosh needs avifenc and cwebp to compress images. Install with: brew install libavif webp",
                    .{},
                );
            }
            if (!avifenc_present) {
                return model.fail(
                    "Smoosh needs avifenc to create AVIF files. Install with: brew install libavif",
                    .{},
                );
            }
            return model.fail(
                "Smoosh needs cwebp to create WebP files. Install with: brew install webp",
                .{},
            );
        },
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const App = native_sdk.UiApp(Model, Msg);

/// The host side of the seams `update` reaches through `fx.hostRequest`.
/// It closes over the `*Runtime` we build by hand — the whole reason
/// `main.zig` is hand-authored (CLAUDE.md, "File acquisition, honestly")
/// — plus the `std.Io` `update` can never hold. `request_fn` runs on the
/// loop thread, synchronously from `fx.hostRequest`, and answers through
/// `effects.feedHostResult`, so the result comes back as an ordinary Msg.
const HostBridge = struct {
    runtime: *native_sdk.Runtime,
    app_state: *App,
    io: std.Io,

    var dialog_path_buf: [platform.max_dialog_paths_bytes]u8 = undefined;
    var save_path_buf: [platform.max_dialog_path_bytes]u8 = undefined;
    var reply_buf: [128]u8 = undefined;

    /// What the open panel offers. Everything macOS ImageIO decodes that
    /// we would plausibly be handed; `sips` is the real gate, and its
    /// failure is a named error state, so this list only has to be
    /// convenient, not exhaustive.
    const image_filters = [_]platform.FileFilter{.{
        .name = "Images",
        .extensions = &.{ "jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "gif", "bmp" },
    }};

    fn requestFn(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
        const self: *HostBridge = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, name, host_open_file)) return self.openFile(key);
        if (std.mem.eql(u8, name, host_file_size)) return self.fileSize(key, payload);
        if (std.mem.eql(u8, name, host_save_file)) return self.saveFile(key, payload);
        if (std.mem.eql(u8, name, host_file_copy)) return self.copyFile(key, payload);
        self.reply(key, false, "unknown host command");
    }

    fn openFile(self: *HostBridge, key: u64) void {
        const result = self.runtime.showOpenDialog(.{
            .title = "Choose an image to smoosh",
            .filters = &image_filters,
        }, &dialog_path_buf) catch |err| {
            return self.reply(key, false, @errorName(err));
        };
        // Single-select (`allow_multiple` defaults false), so `paths` is
        // the one path; count 0 is the user cancelling.
        if (result.count == 0) return self.reply(key, false, "cancelled");
        self.reply(key, true, result.paths);
    }

    /// The source file's byte size as decimal text. `update` needs it for
    /// `original_size` (and M7 for the before/after delta), and a stat is
    /// far too cheap to deserve a worker thread or a `stat(1)` spawn.
    fn fileSize(self: *HostBridge, key: u64, path: []const u8) void {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| {
            return self.reply(key, false, @errorName(err));
        };
        const text = std.fmt.bufPrint(&reply_buf, "{d}", .{stat.size}) catch "0";
        self.reply(key, true, text);
    }

    /// M8's save panel. `payload` is a bare default filename (e.g.
    /// "large.avif") — no filter list, unlike the open panel: the
    /// destination already carries the right extension via `default_name`,
    /// and the user is free to rename, so there is nothing worth
    /// restricting. `showSaveDialog` answers `null` on cancel, same
    /// "false + a reason" shape `openFile` uses for its own cancel.
    fn saveFile(self: *HostBridge, key: u64, default_name: []const u8) void {
        const path = self.runtime.showSaveDialog(.{
            .title = "Save a copy",
            .default_name = default_name,
        }, &save_path_buf) catch |err| {
            return self.reply(key, false, @errorName(err));
        };
        if (path) |chosen| return self.reply(key, true, chosen);
        self.reply(key, false, "cancelled");
    }

    /// `payload` is `"<source>\n<destination>"` — the same newline-joined
    /// shape the SDK's own multi-path open-dialog results use. Unbounded,
    /// unlike `fx.writeFile`/`fx.readFile` (capped at `max_effect_file_bytes`,
    /// 1 MiB): a real encoder output can exceed that, the same bound M3 hit
    /// with the source image itself.
    fn copyFile(self: *HostBridge, key: u64, payload: []const u8) void {
        const sep = std.mem.indexOfScalar(u8, payload, '\n') orelse {
            return self.reply(key, false, "malformed copy request");
        };
        const source = payload[0..sep];
        const destination = payload[sep + 1 ..];
        std.Io.Dir.copyFileAbsolute(source, destination, self.io, .{}) catch |err| {
            return self.reply(key, false, @errorName(err));
        };
        self.reply(key, true, "");
    }

    fn reply(self: *HostBridge, key: u64, ok: bool, bytes: []const u8) void {
        self.app_state.effects.feedHostResult(key, ok, bytes) catch {};
    }

    fn sendFn(context: *anyopaque, name: []const u8, payload: []const u8) void {
        _ = context;
        _ = name;
        _ = payload;
    }
};

/// Preview is a THUMBNAIL, not the source image — and that is a hard SDK
/// constraint, not a shortcut. Registered images are capped at 1 MiB of
/// DECODED RGBA (`max_registered_canvas_image_pixel_bytes`, i.e. 512x512)
/// and `fx.loadImage` refuses encoded sources past 1.25 MiB, so no real
/// photo can ever be registered directly. `sips -Z 160` downscales into
/// this path first; `fx.loadImage` then reads THAT. See PLAN.md M3.
///
/// Shared by `thumbnail_path` and M12's `converted_path` — same app-temp-dir
/// resolution, different filename. `dir_buf`/`path_buf` are caller-owned
/// (not function-local statics) on purpose: this runs twice at startup, and
/// both resolved paths must stay valid simultaneously, so they cannot share
/// backing storage the way a function-local `var` would force them to.
fn resolveAppTempPath(
    io: std.Io,
    environ: std.process.Environ,
    filename: []const u8,
    dir_buf: []u8,
    path_buf: []u8,
) ![]const u8 {
    const State = struct {
        /// `getPosix` hands back a sentinel slice; `app_dirs.Env` wants a
        /// plain one, and the optional blocks the implicit coercion.
        fn env(block: std.process.Environ, key: []const u8) ?[]const u8 {
            const value = block.getPosix(key) orelse return null;
            return value;
        }
    };
    const dir = try app_dirs.resolveOne(
        .{ .name = "smoosh" },
        app_dirs.currentPlatform(),
        .{ .home = State.env(environ, "HOME"), .tmpdir = State.env(environ, "TMPDIR") },
        .temp,
        dir_buf,
    );
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return app_dirs.join(app_dirs.currentPlatform(), path_buf, &.{ dir, filename });
}

var thumbnail_dir_buf: [platform.max_dialog_path_bytes]u8 = undefined;
var thumbnail_path_buf: [platform.max_dialog_path_bytes]u8 = undefined;
var converted_dir_buf: [platform.max_dialog_path_bytes]u8 = undefined;
var converted_path_buf: [platform.max_dialog_path_bytes]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const app_info: platform.AppInfo = .{
        .app_name = "smoosh",
        .display_name = "Smoosh",
        .version = "0.1.0",
        .description = "A tiny native macOS app that compresses images into modern web formats.",
        .bundle_id = "dev.native_sdk.smoosh",
        .window_title = window_title,
        .main_window = .{
            .id = 1,
            .label = "main",
            .title = window_title,
            .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
            .restore_state = false,
            .restore_policy = .center_on_primary,
        },
    };

    const mac_platform = try platform.macos.MacPlatform.createWithOptions(
        geometry.SizeF.init(window_width, window_height),
        .system,
        app_info,
    );
    defer mac_platform.destroy();

    const app_state = try App.create(std.heap.page_allocator, .{
        .name = "smoosh",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = initFx,
        .on_drop = onDrop,
        .markup = .{
            .source = app_markup,
            .watch_path = if (dev) "src/app.native" else null,
            .io = init.io,
        },
    });
    defer app_state.destroy();

    spawn_environ = try resolveSpawnEnviron(std.heap.page_allocator, init.minimal.environ);

    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    defer runtime.deinit();
    native_sdk.Runtime.initAt(runtime, .{
        .platform = mac_platform.platform(),
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
        .automation = if (dev) native_sdk.automation.Server.init(
            init.io,
            ".zig-cache/native-sdk-automation",
            window_title,
        ) else null,
        .environ = spawn_environ,
    });

    thumbnail_path = try resolveAppTempPath(init.io, spawn_environ, "preview.png", &thumbnail_dir_buf, &thumbnail_path_buf);
    converted_path = try resolveAppTempPath(init.io, spawn_environ, "converted.png", &converted_dir_buf, &converted_path_buf);

    var bridge = HostBridge{ .runtime = runtime, .app_state = app_state, .io = init.io };
    app_state.effects.bindHostCalls(.{
        .context = &bridge,
        .request_fn = HostBridge.requestFn,
        .send_fn = HostBridge.sendFn,
    });

    try runtime.run(app_state.app());
}

test {
    _ = @import("tests.zig");
}
