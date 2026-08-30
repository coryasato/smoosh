//! Smoosh — image compression for the desktop.
//!
//! `main.zig` is hand-authored: platform + Runtime are stood up BY HAND (not
//! through the CLI's `runner.runWithOptions`, whose per-platform bring-up is
//! non-`pub`) so a `HostCallBinding` can close over the `*Runtime` and reach
//! `showOpenDialog`. See CLAUDE.md, "File acquisition, honestly", and the
//! validated reference at `docs/spikes/dialog-open-file-spike.zig`.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const imageio = @import("imageio.zig");
const encoders = @import("encoders.zig");
const chroma = @import("chroma.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

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
// 540x400 is the floor for the tallest state — header, a 160px preview
// card, the format row, the actions row and the status line — a smaller
// window overflows it (`zero_canvas_layout`). `min_*` below stops a
// resize from re-creating that overflow. All three declarations of this
// geometry move together (see the block comment above): these consts
// feed the `AppInfo` frame and the `ShellWindow`, and `app.zon` states
// it a third time.
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
// Buffers use `platform.max_dialog_path_bytes` (4096) to hold whatever
// `showOpenDialog` hands back — see the spike's own dialog wiring at
// docs/spikes/dialog-open-file-spike.zig.

pub const Format = enum { avif, webp, both };
pub const Status = enum { idle, loading, ready, compressing, done, failed };
// NOTE: `failed`, not `error` — `error` is a Zig keyword and won't parse as
// a bare enum field.

/// Where ONE output format got to in the current smoosh run. The
/// partial-failure decision lives in this type: the two formats carry
/// their own outcome, so "Both" is two independent encodes joined at the
/// end rather than one all-or-nothing operation.
///
/// `.none` means "not part of this run" and `.pending` means "the encode
/// worker is running, still waiting" — which is what makes the join immune
/// to the user changing `Model.format` mid-encode: completion is "neither
/// is `.pending`", never a re-read of the current selection.
///
/// The failure tags are separate rather than one `.failed` because each
/// one is a different sentence to the user.
pub const EncodeOutcome = enum {
    none,
    pending,
    ok,
    /// The output path would BE the source path — encoding a `.webp` to
    /// WebP would read and overwrite the same file.
    same_path,
    /// The worker could not decode the source or the encoder rejected the
    /// frame.
    encode_failed,
    /// The encode produced bytes but the atomic write (or the rename onto
    /// the destination) failed — the "write to output path failed" state.
    write_failed,

    fn isFailure(outcome: EncodeOutcome) bool {
        return switch (outcome) {
            .none, .pending, .ok => false,
            .same_path, .encode_failed, .write_failed => true,
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
    /// The SOURCE's DISPLAY dimensions, from `image.probe` — orientation
    /// already applied, so a portrait photo stored landscape with EXIF
    /// Orientation 6 reports 3000x4000, not 4000x3000. 0 until the probe
    /// answers; a probe that cannot read them fails the load outright,
    /// which is the change M13 makes here (the `sips -g` hop this replaces
    /// tolerated an unparseable answer and let the preview decide).
    source_width: u32 = 0,
    source_height: u32 = 0,
    /// The source's Uniform Type Identifier as ImageIO names it
    /// ("public.jpeg", "public.heic", "org.webmproject.webp") — the
    /// container, decided by sniffing the file rather than by trusting its
    /// extension. Recorded here because M14's chroma table keys on it (a
    /// JPEG keeps its own subsampling, everything else goes 4:4:4) and
    /// `image.probe` is already returning it; nothing in v0.2 reads it.
    source_uti_buffer: [imageio.max_uti_bytes]u8 = undefined,
    source_uti_len: usize = 0,
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
    format: Format = .both,
    // ui
    status: Status = .idle,
    error_message_buffer: [256]u8 = undefined,
    error_message_len: usize = 0,
    /// A `.done` run that still lost a format. Distinct from
    /// `error_message_buffer` because the two coexist in exactly the case
    /// the partial-failure decision creates: AVIF landed, WebP did not,
    /// and the run is a success WITH something to say. The invariant
    /// "`.failed` is always paired with an error message, and no other
    /// path sets `.failed`" survives precisely because this is its own
    /// buffer rather than a second meaning for that one.
    warning_message_buffer: [256]u8 = undefined,
    warning_message_len: usize = 0,

    // Save As is per-format: each landed result line carries its own save
    // icon, dispatching `save_avif_as`/`save_webp_as` directly — no queue,
    // since only one dialog+copy round is ever in flight at once.
    /// Which format the in-flight round is for, if any. `null` at rest.
    saving: ?Output = null,
    /// The one-line note the last round left behind (a cancel is silent —
    /// see `update`'s `.save_as_dialog_result` arm). Its own buffer, not
    /// `warning_message_buffer`: a save note and an encode warning are
    /// different facts, and folding them into one field would mean one
    /// silently overwriting the other.
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
    /// Naming these here keeps `native check`'s warnings meaningful — an
    /// unlisted field with no binding is a real bug, not expected noise.
    pub const view_unbound = .{
        "path_buffer",
        "path_len",
        "original_size",
        "source_width",
        "source_height",
        "source_uti_buffer",
        "source_uti_len",
        "avif_path_buffer",
        "avif_path_len",
        "avif_size",
        "avif_outcome",
        "webp_path_buffer",
        "webp_path_len",
        "webp_size",
        "webp_outcome",
        "status",
        "error_message_buffer",
        "error_message_len",
        "warning_message_buffer",
        "warning_message_len",
        "saving",
        "save_message_buffer",
        "save_message_len",
        "path",
        "sourceUti",
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
    pub fn sourceUti(model: *const Model) []const u8 {
        return model.source_uti_buffer[0..model.source_uti_len];
    }

    /// The picked file's last path component — what the UI names, and
    /// what every error message interpolates. Empty until a pick lands.
    pub fn fileName(model: *const Model) []const u8 {
        const full = model.path();
        if (std.mem.lastIndexOfScalar(u8, full, '/')) |slash| return full[slash + 1 ..];
        return full;
    }

    /// True once `thumbnail_result` registered preview pixels — the `<if>`
    /// gate on the `<image>` leaf, since id 0 draws nothing anyway but
    /// the surrounding chrome shouldn't reserve space for it.
    pub fn hasPreview(model: *const Model) bool {
        return model.image_id != 0;
    }

    // -------------------------------------------------------- view state
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

    /// Gates each result line's save icon: only while no round is already
    /// in flight. The icon's own existence (inside `hasAvifResult`/
    /// `hasWebpResult`) already implies that format landed.
    pub fn isSaving(model: *const Model) bool {
        return model.saving != null;
    }

    /// "2.4 MB" — the picked file's size on its own line, the sketch's
    /// "Original: 2.4 MB". Empty with no file.
    pub fn originalSize(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!model.hasFile()) return "";
        return formatBytes(arena, model.original_size);
    }

    // ---------------------------------------------------------- results
    //
    // One line per format, shown only for a format that actually landed —
    // "combined savings" for Both mode reads per-format, side by side, not
    // as one sum. A summed total would describe a download that never
    // happens (no client fetches both files), so each line reports what
    // would really be served if that format were chosen.

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

    /// Every `.failed` transition goes through here, so "`.failed` is
    /// always paired with an error message" holds by construction: it is
    /// never set without a message beside it.
    ///
    /// These messages do NOT name the file. The `<status-bar>` is one
    /// honest line that elides what does not fit (it takes no `wrap`, by
    /// design), and a quoted filename cost ~18 of the ~65 characters that
    /// fit — enough to truncate the part that says what to do about it.
    /// The file card directly above names the file in every state that
    /// can fail, so the message explains what happened and nothing else.
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
        model.source_uti_len = 0;
    }

    /// Wipes the previous run's outputs. Called when a new run starts and
    /// when a new file lands — without it, a fresh pick would keep
    /// rendering the last file's result lines. Also wipes any Save As
    /// note: it names a file this call is about to invalidate, and a save
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
        model.saving = null;
        model.save_message_len = 0;
    }

    /// The single line of text `<status-bar>` renders — a Save As note
    /// takes priority (see below), otherwise one line per `Status`.
    pub fn statusLine(model: *const Model) []const u8 {
        // A Save As note is the freshest thing the user did, so it wins
        // over whatever `status` says — including a stale `.done` warning
        // about the run that PRODUCED the file just saved. It cannot mask
        // a genuine new `.failed`/`.done`: both `smoosh` and a new pick
        // clear it (see `clearResults`), and `.reset` clears the whole
        // model.
        if (model.save_message_len > 0) return model.saveMessage();
        return switch (model.status) {
            // Idle copy lives on the dropzone itself, not here — no need
            // to say it twice.
            .idle => "",
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
    pick_file, // dropzone clicked
    dialog_result: native_sdk.EffectHostResult, // host open-dialog callback
    dropped_file: []const u8, // on_drop callback — a file dragged onto the window
    stat_result: native_sdk.EffectHostResult, // host file-size callback -> original_size
    probe_result: native_sdk.EffectHostResult, // host ImageIO properties callback -> dimensions, UTI, megapixel check
    thumbnail_result: native_sdk.EffectHostResult, // host ImageIO thumbnail callback -> the preview pixels
    set_format: Format, // format chip pressed
    smoosh, // "Smoosh" clicked
    encode_result: native_sdk.EffectHostResult, // `image.encode` worker callback, one per format — carries the output size
    save_avif_as, // AVIF result row's save icon clicked
    save_webp_as, // WebP result row's save icon clicked
    save_as_dialog_result: native_sdk.EffectHostResult, // host save-dialog callback
    // A host command we bind ourselves, `file.copy` — not `fx.writeFile`.
    // `fx.writeFile`/`fx.readFile` cap at 1 MiB (`max_effect_file_bytes`),
    // and a real encoder output can exceed that (the same bound the
    // preview thumbnail load hits, for the same reason: a bundled-effect
    // ceiling sized for small payloads, not an arbitrary file).
    // `std.Io.Dir.copyFileAbsolute` has no such cap.
    save_as_result: native_sdk.EffectHostResult, // host copy-file callback
    reset, // clear current image, return to idle

    // Dispatched by effect/host-call result paths, never from markup —
    // same idiom the spike uses for its `dialog_result` Msg.
    pub const view_unbound = .{
        "dialog_result",
        "dropped_file",
        "stat_result",
        "probe_result",
        "thumbnail_result",
        "encode_result",
        "save_as_dialog_result",
        "save_as_result",
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
/// (312 B) encodes to a 315-byte AVIF with the pinned encoder argv — this
/// displays sanely rather than as a broken percentage, so the sign flips
/// and the word changes, rather than printing "−-1%". Differences under
/// half a percent round to nothing meaningful in either direction, so
/// they say so outright.
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
// One key space across spawns, fetches, files and host requests
// (`max_effects` = 16 slots).

const dialog_key: u64 = 1;
const stat_key: u64 = 2;
const thumbnail_key: u64 = 3;
/// NOT an effect key: the only thing `preview_image_id` names now is the
/// registry slot `fx.registerImage` fills and the `<image>` leaf draws.
/// It was both until M13 retired `fx.loadImage`, which is why it sits in
/// this list — the two namespaces are separate, but keeping it distinct
/// costs nothing and a reader looking for "id 4" finds it here.
const preview_image_id: u64 = 4;
const probe_key: u64 = 5;
const avif_encode_key: u64 = 8;
const webp_encode_key: u64 = 9;
const save_dialog_key: u64 = 12;
const save_copy_key: u64 = 13;

/// Host-call names our own `HostBridge` answers (see `main`). Not SDK
/// vocabulary — we bind the seam, so we name it.
const host_open_file = "dialog.openFile";
const host_file_size = "file.stat";
const host_save_file = "dialog.saveFile";
const host_file_copy = "file.copy";
/// The ImageIO reads and the encode, all answered OFF the loop thread (see
/// `HostBridge`'s worker carrier). `probe` allocates no bitmap; `thumbnail`
/// decodes a 160px preview; `encode` decodes at full resolution, runs
/// libavif/libwebp, and writes the output file atomically.
const host_image_probe = "image.probe";
const host_image_thumbnail = "image.thumbnail";
const host_image_encode = "image.encode";

// ----------------------------------------------------------- input limits
//
// 100 MB / 50 megapixels, whichever comes first — the top of the
// considered 80-100MB/40-50MP range. A local tool should be more
// permissive than a web upload limit, and the failure mode being guarded
// against (exhausting memory on decode) only bites well past either number.

const max_original_bytes: u64 = 100 * 1024 * 1024; // 100 MB
const max_source_megapixels: f64 = 50.0;

fn bytesToMb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

// -------------------------------------------------------- host replies
//
// `image.probe` and `image.thumbnail` answer as BYTES on the host result,
// so both wire shapes are parsed here rather than in the bridge — the
// bridge writes them on a worker thread and `update` is the only reader.
// Both parsers are `pub` for the same reason `formatBytes` is: a pure
// function worth pinning directly instead of only through the full
// dispatch path.

/// `image.probe`'s answer: `"<width> <height> <orientation> <uti>"`.
/// Dimensions are DISPLAY dimensions (`imageio.probe` has already applied
/// the EXIF transform); orientation is the raw 1-8 tag, or 0 for a source
/// carrying none.
pub const SourceInfo = struct {
    width: u32,
    height: u32,
    orientation: u8,
    uti: []const u8,
};

pub fn parseProbeReply(reply: []const u8) ?SourceInfo {
    var it = std.mem.splitScalar(u8, reply, ' ');
    const width = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const height = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const orientation = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    // Everything after the third space is the UTI, which never contains
    // one — but taking the remainder rather than the next field means a
    // type ImageIO names oddly arrives whole instead of truncated.
    const uti = it.rest();
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height, .orientation = orientation, .uti = uti };
}

/// `image.thumbnail`'s answer: a fixed-width `"<width> <height>\n"` header
/// (see `thumbnail_reply_header`) followed by exactly `width * height * 4`
/// bytes of straight-alpha 8-bit sRGB RGBA.
///
/// The pixels RIDE THE RESULT rather than sitting in a bridge-owned
/// global. That is safe only because the preview is capped at 160px —
/// `max_effect_host_result_bytes` is 256 KiB and an over-cap answer is
/// silently rewritten to the err route — so the fit is asserted at
/// COMPTIME below rather than left as a comment for someone raising the
/// preview size to trip over. A full-resolution decode (M14) can never
/// ride the result and must use a descriptor.
pub const Preview = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
};

comptime {
    const max_pixel_bytes = imageio.max_thumbnail_edge * imageio.max_thumbnail_edge * 4;
    std.debug.assert(thumbnail_reply_header + max_pixel_bytes <= native_sdk.max_effect_host_result_bytes);
}

/// `"<width> <height>\n"` with both numbers zero-padded to five digits —
/// FIXED WIDTH so the bridge can decode the pixels straight into the rest
/// of the buffer instead of moving them afterwards. Five digits is far
/// more than `max_thumbnail_edge` needs; the assert is what keeps the two
/// honest if that ever grows.
const thumbnail_reply_header: usize = 12;

comptime {
    std.debug.assert(imageio.max_thumbnail_edge < 100_000);
}

pub fn parsePreviewReply(reply: []const u8) ?Preview {
    const newline = std.mem.indexOfScalar(u8, reply, '\n') orelse return null;
    var it = std.mem.splitScalar(u8, reply[0..newline], ' ');
    const width = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const height = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    const pixels = reply[newline + 1 ..];
    if (width == 0 or height == 0) return null;
    if (pixels.len != @as(usize, width) * height * 4) return null;
    return .{ .width = width, .height = height, .pixels = pixels };
}

// ---------------------------------------------------------- encode pipeline
//
// THE PARTIAL-FAILURE DECISION: in "Both" mode the two encodes are
// INDEPENDENT. If one succeeds and the other fails, the run is `.done` —
// the successful format's numbers are shown and the failed one is named
// in the status bar. Only when NO requested format landed is the run
// `.failed`.
//
// The deciding fact is that the encode worker writes its own output file
// (atomically): by the time WebP's failure arrives, `photo.avif` is
// already on disk next to the source. Failing the whole run would mean
// either claiming failure with a good file sitting right there, or
// deleting a file the user can see.
//
// The floor keeps the "Status → error mapping" invariant intact: a run
// where everything failed is `.failed` with a message, which in
// single-format mode is just the ordinary failure path — no special case.
//
// Each format is one `image.encode` host request, answered off the loop
// thread by `HostBridge`'s worker carrier: the worker decodes the source
// at full resolution through ImageIO, runs libavif/libwebp, and writes the
// output atomically, replying with just the output size. There is no HEIC
// staging step any more — ImageIO decodes HEIC directly — and no
// subprocess of any kind.

/// ONE encodable output format. `Format.both` is a REQUEST for two of
/// these; every per-format path below works on this type, never on `Format`,
/// which is exactly what keeps the two encodes independent.
const Output = enum { avif, webp };

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

/// `/a/b/photo.jpg` + `.avif` -> `/a/b/photo.avif` — the output lands next
/// to the source. The extension search is scoped to the last path
/// component so a dot in a PARENT directory can never be mistaken for
/// one; a name with no dot of its own just gets the extension appended.
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

/// `image.encode`'s request payload: `"<format>\x00<source>\x00<uti>\x00<dest>"`.
/// The worker needs the source path (it decodes the file itself), the
/// source UTI (for `chroma.forSource` on the AVIF path), and the
/// destination it writes atomically. Parsed by `HostBridge.startEncode`.
///
/// NUL-delimited, not newline: a macOS path may legally contain `\n` (only
/// `/` and NUL are forbidden), so a source file named "a\nb.jpg" would
/// otherwise shift every field. Both variable-length fields are paths.
fn encodePayload(buffer: []u8, output: Output, source: []const u8, uti: []const u8, dest: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "{s}\x00{s}\x00{s}\x00{s}", .{
        outputLabel(output), source, uti, dest,
    }) catch null;
}

/// Starts one format, or records why it could not start. Every path out of
/// here leaves the format's outcome non-`.none`, so the join below always
/// terminates. The DESTINATION is derived from `model.path()` and written
/// into the format's path buffer so the result line and Save As can find
/// it; the worker reads the source and writes that destination itself.
fn beginEncode(model: *Model, fx: *Effects, output: Output) void {
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
    // A `.webp` source encoded to WebP would read and overwrite itself.
    // "Overwrite silently" is about a previous OUTPUT, never the source.
    //
    // CASE-INSENSITIVELY, because macOS volumes are: APFS is
    // case-insensitive by default, so `Photo.AVIF` and the `Photo.avif`
    // this derives are ONE FILE, and a byte-exact compare would let the
    // worker's atomic write land a lossy re-encode on top of the user's
    // original. Comparing the whole path rather than just the extension is
    // safe and not a widening: `outputPath` copies everything up to the
    // stem verbatim, so the two strings can only differ in the extension —
    // pure ASCII, no Unicode folding question.
    //
    // The residual is a genuinely case-SENSITIVE volume (opt-in on macOS),
    // where `Photo.AVIF` and `Photo.avif` really are two files and this
    // now skips a legal encode. That trade is deliberate: the failure it
    // prevents is silent data loss, the one it introduces is a visible
    // "Skipped AVIF" the user can work around by renaming. Symlinked or
    // hardlinked destinations are still not covered — catching those needs
    // an `Io` to stat with, which `update` can never hold.
    if (std.ascii.eqlIgnoreCase(destination, model.path())) {
        return setOutcome(model, output, .same_path);
    }
    switch (output) {
        .avif => model.avif_path_len = destination.len,
        .webp => model.webp_path_len = destination.len,
    }

    var payload_buffer: [platform.max_dialog_path_bytes * 2 + 128]u8 = undefined;
    const payload = encodePayload(&payload_buffer, output, model.path(), model.sourceUti(), destination) orelse
        return setOutcome(model, output, .encode_failed);

    setOutcome(model, output, .pending);
    fx.hostRequest(.{
        .key = switch (output) {
            .avif => avif_encode_key,
            .webp => webp_encode_key,
        },
        .name = host_image_encode,
        .payload = payload,
        .on_result = Effects.hostMsg(.encode_result),
    });
}

/// One failed format's user-facing sentence. Written into `buffer` (caller
/// owned) for the cases that must name the file; the rest are static.
fn failureText(model: *const Model, output: Output, buffer: []u8) []const u8 {
    const label = outputLabel(output);
    return switch (outcomeOf(model, output)) {
        .same_path => switch (output) {
            .avif => "Skipped AVIF — the source is already an AVIF file.",
            .webp => "Skipped WebP — the source is already a WebP file.",
        },
        // Names the source file, which is also where the output was
        // headed.
        .write_failed => std.fmt.bufPrint(
            buffer,
            "Couldn't save the {s} — check the folder's permissions.",
            .{label},
        ) catch "Couldn't save the compressed file.",
        // Deliberately short and non-technical; the encoder's stderr is
        // not surfaced.
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

// -------------------------------------------------------------- Save As
//
// `save_avif_as`/`save_webp_as` -> `showSaveDialog` -> copy that one
// already-produced output to the chosen location, without touching the
// auto-saved original. One format, one dialog-then-copy round — each
// result line's own icon names which format it wants, so there is no
// queue to sequence. Only a copy failure is reported as a problem; a
// cancelled dialog is an ordinary "not now", same as `dialog_result`'s
// cancel-is-not-an-error precedent above.

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

/// Overwrites the save note. Unlike `fail`/`warn` there is never a second
/// note to append beside it — only one round is ever in flight.
fn setSaveMessage(model: *Model, comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&model.save_message_buffer, fmt, args) catch return;
    model.save_message_len = written.len;
}

/// Starts the save-dialog round for whatever format `model.saving` names.
/// Its only caller is `beginSave` — a cancelled or completed round simply
/// clears `model.saving` rather than chaining into another round.
fn beginSaveRound(model: *Model, fx: *Effects) void {
    const output = model.saving orelse return;
    var name_buf: [128]u8 = undefined;
    const default_name = defaultSaveName(model, output, &name_buf);
    fx.hostRequest(.{
        .key = save_dialog_key,
        .name = host_save_file,
        .payload = default_name,
        .on_result = Effects.hostMsg(.save_as_dialog_result),
    });
}

/// Shared by `.save_avif_as`/`.save_webp_as`: refuses to start a round for
/// a format that never landed, or while another round is already using
/// the shared dialog/copy keys.
fn beginSave(model: *Model, fx: *Effects, output: Output) void {
    if (outcomeOf(model, output) != .ok) return;
    if (model.saving != null) return;
    model.saving = output;
    model.save_message_len = 0;
    beginSaveRound(model, fx);
}

// ------------------------------------------------------------------ drops
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
/// (`.dropped_file`). Both land here because the chain itself doesn't
/// care where the path came from: `stat_result` -> `probe_result` ->
/// `thumbnail_result` -> `.ready` is the same either way.
fn beginLoad(model: *Model, fx: *Effects, path: []const u8) void {
    model.status = .loading;
    model.setPath(path);
    // A new file invalidates the previous file's outputs and preview —
    // see `clearResults`/`clearPreview`'s own doc comments for why each
    // exists.
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

        // A real drag onto the window. `onDrop` (pure, no model access)
        // already reduced the drop to one path; from here it is the exact
        // same chain a dialog pick starts — a picked-file and a
        // dropped-file are indistinguishable to `update` past this point.
        .dropped_file => |dropped_path| beginLoad(model, fx, dropped_path),

        .stat_result => |result| {
            const size = if (result.ok)
                std.fmt.parseInt(u64, result.bytes, 10) catch null
            else
                null;
            model.original_size = size orelse {
                // The file could not be read.
                return model.fail("Can't read that file.", .{});
            };
            if (model.original_size > max_original_bytes) {
                // Input exceeds the byte-size limit.
                return model.fail(
                    "That file is {d:.1} MB — Smoosh handles files up to {d:.0} MB.",
                    .{ bytesToMb(model.original_size), bytesToMb(max_original_bytes) },
                );
            }
            // The megapixel check needs the source's real dimensions, and
            // `image.probe` reads them out of ImageIO's property
            // dictionary WITHOUT decoding anything. That ordering is the
            // point: the `sips -g` hop this replaces could only report
            // dimensions a decode had already paid for.
            fx.hostRequest(.{
                .key = probe_key,
                .name = host_image_probe,
                .payload = model.path(),
                .on_result = Effects.hostMsg(.probe_result),
            });
        },

        // The FORMAT GATE, and the megapixel gate, both before a single
        // pixel is decoded. A failure here is the undecodable-input state:
        // `imageio.probe` reports it off the frame COUNT rather than off a
        // null source, because `CGImageSourceCreateWithURL` succeeds on 49
        // bytes of text named `.jpg`.
        //
        // Unlike the `sips -g` hop this replaces, an unparseable answer is
        // NOT tolerated. There is no longer a later gate to defer to — the
        // thumbnail is the same ImageIO read, so a probe that could not
        // name the image's size is a file the preview cannot draw either.
        .probe_result => |result| {
            if (!result.ok) {
                // Unsupported or undecodable input.
                return model.fail(
                    "Not an image Smoosh can read. Try JPEG, PNG, HEIC or WebP.",
                    .{},
                );
            }
            const info = parseProbeReply(result.bytes) orelse return model.fail(
                "Not an image Smoosh can read. Try JPEG, PNG, HEIC or WebP.",
                .{},
            );
            model.source_width = info.width;
            model.source_height = info.height;
            const uti_len = @min(info.uti.len, model.source_uti_buffer.len);
            @memcpy(model.source_uti_buffer[0..uti_len], info.uti[0..uti_len]);
            model.source_uti_len = uti_len;

            const megapixels = @as(f64, @floatFromInt(info.width)) *
                @as(f64, @floatFromInt(info.height)) / 1_000_000.0;
            if (megapixels > max_source_megapixels) {
                // Input exceeds the megapixel limit.
                return model.fail(
                    "That image is {d:.0} megapixels — the limit is {d:.0} MP.",
                    .{ megapixels, max_source_megapixels },
                );
            }
            fx.hostRequest(.{
                .key = thumbnail_key,
                .name = host_image_thumbnail,
                .payload = model.path(),
                .on_result = Effects.hostMsg(.thumbnail_result),
            });
        },

        // No staleness guard on this arm or `.probe_result` above, and
        // none is needed: every hop of the load chain is now a HOST
        // request, and a cancelled one delivers no Msg at all — a queued
        // answer dies by generation mismatch at drain (`cancelHostRequest`).
        // A second pick mid-load replaces the in-flight request on the same
        // key and drops its answer the same way. The encode chain below
        // still guards, because those are real spawns whose cancellation
        // arrives as an ordinary nonzero terminal.
        .thumbnail_result => |result| {
            if (!result.ok) {
                return model.fail("Couldn't build a preview for that file.", .{});
            }
            const preview = parsePreviewReply(result.bytes) orelse {
                return model.fail("Couldn't build a preview for that file.", .{});
            };
            // Synchronous — the pixels are copied before this returns, so
            // `result.bytes` outliving the dispatch is not a concern.
            fx.registerImage(preview_image_id, preview.width, preview.height, preview.pixels) catch {
                return model.fail("Couldn't build a preview for that file.", .{});
            };
            model.image_id = preview_image_id;
            model.preview_width = preview.width;
            model.preview_height = preview.height;
            model.status = .ready;
        },

        .reset => {
            // Nothing in flight may land on the next model. Every hop is
            // now a HOST request, and a cancelled one delivers no Msg — its
            // queued answer dies by generation mismatch at drain. An encode
            // worker already running keeps going and may still write its
            // output file (there is no process to kill), but its result is
            // dropped and the `status` check in `.encode_result` is a
            // second guard. Cancelling also frees the keys, so an immediate
            // re-pick is not rejected as a duplicate. `cancel` on an idle
            // key is a no-op.
            fx.cancel(dialog_key);
            fx.cancel(stat_key);
            fx.cancel(probe_key);
            fx.cancel(thumbnail_key);
            fx.cancel(avif_encode_key);
            fx.cancel(webp_encode_key);
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
            // Two independent encodes, not one operation with two steps.
            // Each is one `image.encode` host request; the worker decodes
            // the source (HEIC included — ImageIO reads it directly, so
            // there is no staging step) and writes the output itself.
            if (model.format != .webp) beginEncode(model, fx, .avif);
            if (model.format != .avif) beginEncode(model, fx, .webp);
            // A requested format may have short-circuited (`same_path`, or
            // a path that would not fit its buffer), in which case the run
            // may already be over.
            finishIfComplete(model);
        },

        .encode_result => |result| {
            // Staleness: `.reset` cancels the request; a superseded answer
            // is dropped at drain, and this guard is the backstop.
            if (model.status != .compressing) return;
            const output: Output = if (result.key == avif_encode_key)
                .avif
            else if (result.key == webp_encode_key)
                .webp
            else
                return;
            // On success `result.bytes` is the output's size as decimal
            // text — the worker has already written the file atomically.
            // On failure it is a short tag: "write" means the encode
            // produced bytes but the atomic write/rename failed; anything
            // else (decode or encoder failure) is `encode_failed`.
            if (result.ok) {
                const bytes = std.fmt.parseInt(u64, result.bytes, 10) catch {
                    setOutcome(model, output, .encode_failed);
                    return finishIfComplete(model);
                };
                switch (output) {
                    .avif => model.avif_size = bytes,
                    .webp => model.webp_size = bytes,
                }
                setOutcome(model, output, .ok);
            } else {
                setOutcome(model, output, if (std.mem.eql(u8, result.bytes, "write"))
                    .write_failed
                else
                    .encode_failed);
            }
            finishIfComplete(model);
        },

        .save_avif_as => beginSave(model, fx, .avif),
        .save_webp_as => beginSave(model, fx, .webp),

        .save_as_dialog_result => |result| {
            const output = model.saving orelse return;
            if (!result.ok) { // cancelled: silent, not a failure
                model.saving = null;
                return;
            }
            var payload_buf: [platform.max_dialog_path_bytes * 2 + 1]u8 = undefined;
            const payload = std.fmt.bufPrint(&payload_buf, "{s}\n{s}", .{ outputPathOf(model, output), result.bytes }) catch {
                setSaveMessage(model, "Couldn't save {s} — the destination path is too long.", .{outputLabel(output)});
                model.saving = null;
                return;
            };
            fx.hostRequest(.{
                .key = save_copy_key,
                .name = host_file_copy,
                .payload = payload,
                .on_result = Effects.hostMsg(.save_as_result),
            });
        },

        .save_as_result => |result| {
            const output = model.saving orelse return;
            if (result.ok) {
                setSaveMessage(model, "Saved {s}.", .{outputLabel(output)});
            } else {
                // The same family of failure as the auto-save write step,
                // just at a user-chosen destination instead of next to
                // the source.
                setSaveMessage(model, "Couldn't save {s} — check the folder's permissions.", .{outputLabel(output)});
            }
            model.saving = null;
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
/// — plus the `std.Io` `update` can never hold.
///
/// TWO ANSWERING DISCIPLINES live here, and the split is deliberate:
///
///  - The dialogs and the two file operations answer SYNCHRONOUSLY from
///    `request_fn`, on the loop thread, through `effects.feedHostResult`.
///    A panel has to run on the main thread anyway, and a stat or a copy
///    is far too cheap to deserve a worker.
///  - `image.probe` and `image.thumbnail` answer from a WORKER THREAD
///    through the carrier mailbox below. `feedHostResult` is
///    loop-thread-only (`HostCallBinding`'s own doc comment says so, and
///    `docs/spikes/threaded-host-call-spike.zig` proved the supported
///    seam is the `poll_fn`/`pending_fn`/`bind_services_fn` trio plus
///    `shutdown_fn`), so a worker never calls it — it parks its answer and
///    nudges the loop, which drains and feeds on the right thread.
const HostBridge = struct {
    runtime: *native_sdk.Runtime,
    app_state: *App,
    io: std.Io,
    /// The platform's thread-safe wake handle, handed over by
    /// `bind_services_fn` after `UiApp` binds it. `null` until then, which
    /// is only a window before the first frame.
    services: ?*const platform.PlatformServices = null,
    slots: [worker_slot_count]Slot = @splat(.{}),

    var dialog_path_buf: [platform.max_dialog_paths_bytes]u8 = undefined;
    var save_path_buf: [platform.max_dialog_path_bytes]u8 = undefined;
    var reply_buf: [128]u8 = undefined;

    // ------------------------------------------------------ worker carrier

    /// The load chain is strictly sequential (one probe, then one
    /// thumbnail), but an encode run issues TWO `image.encode` requests at
    /// once in Both mode. A `reset` cancels the pending REQUESTS but cannot
    /// stop a running encode worker — `avifEncoderWrite` has no
    /// cancellation token — so it runs to completion holding its slot
    /// (~1 s), then `pollFn` frees it and drops the answer (`abandoned`, or
    /// the cancel's generation bump, or `.encode_result`'s status guard —
    /// it is guarded three ways). The slot count only has to outrun how
    /// fast a person can pile up abandoned encodes: reset -> drop -> smoosh
    /// is three deliberate actions and neither the drop nor a dialog can be
    /// automated (see CLAUDE.md), so ~4 workers in flight is the realistic
    /// ceiling. Eight is unreachable, and a full pool degrades gracefully
    /// (`startEncode` -> "no worker slot" -> one `.encode_failed`), which
    /// still beats v0.1's unbounded `avifenc` spawn. Each encode worker
    /// also holds a full-resolution decode transiently (~w·h·4, ≤200 MB at
    /// the 50 MP guard); two at once is fine, and the guard has already run
    /// off `probe` before any encode starts.
    const worker_slot_count = 8;

    const Job = enum { probe, thumbnail, encode_avif, encode_webp };

    /// A worker's whole world. Its result buffer is sized for the largest
    /// answer any job can produce — a full 160x160 preview (the encode
    /// jobs reply with just a size string). Per-slot rather than shared is
    /// what makes an abandoned worker harmless. The encode jobs also carry
    /// a destination path and the source UTI.
    const Slot = struct {
        key: u64 = 0,
        job: Job = .probe,
        /// Loop thread owns this: claimed on request, released on poll.
        busy: bool = false,
        /// A NEWER request for the same key arrived while this worker was
        /// still running. Its answer is dropped at poll rather than fed —
        /// otherwise `feedHostResult` would find the new request's slot
        /// (it matches on key alone) and deliver the OLD file's pixels as
        /// the new one's preview.
        abandoned: bool = false,
        thread: ?std.Thread = null,
        path_buffer: [platform.max_dialog_path_bytes]u8 = undefined,
        path_len: usize = 0,
        /// Encode jobs only: where the worker writes the output file.
        dest_buffer: [platform.max_dialog_path_bytes]u8 = undefined,
        dest_len: usize = 0,
        /// Encode jobs only: the source UTI, for `chroma.forSource`.
        uti_buffer: [imageio.max_uti_bytes]u8 = undefined,
        uti_len: usize = 0,
        result: [thumbnail_reply_header + imageio.max_thumbnail_edge * imageio.max_thumbnail_edge * 4]u8 = undefined,
        result_len: usize = 0,
        ok: bool = false,
        /// Worker -> loop: the answer is parked and ready to adopt. The
        /// release store publishes every write above it to whichever
        /// loop-thread poll acquires it.
        done: std.atomic.Value(bool) = .init(false),

        fn path(slot: *const Slot) []const u8 {
            return slot.path_buffer[0..slot.path_len];
        }
        fn dest(slot: *const Slot) []const u8 {
            return slot.dest_buffer[0..slot.dest_len];
        }
        fn uti(slot: *const Slot) []const u8 {
            return slot.uti_buffer[0..slot.uti_len];
        }
    };

    /// No lock anywhere in this carrier, deliberately: `claim`, `abandon`,
    /// `pollFn` and `pendingFn` all run on the LOOP thread, and a slot's
    /// result bytes are written by exactly one worker and read by the loop
    /// only after `done` publishes them. Single-producer, single-consumer,
    /// one flag — the handoff a mutex would only decorate.
    fn claim(self: *HostBridge, key: u64, job: Job, path: []const u8) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.busy) continue;
            if (slot.thread) |thread| {
                // A retired-but-unjoined worker: reap it before reuse.
                thread.join();
                slot.thread = null;
            }
            slot.* = .{ .key = key, .job = job, .busy = true };
            const len = @min(path.len, slot.path_buffer.len);
            @memcpy(slot.path_buffer[0..len], path[0..len]);
            slot.path_len = len;
            return slot;
        }
        return null;
    }

    /// Retire any live worker still answering for `key`, because a newer
    /// request has taken that key over. The thread keeps running and keeps
    /// writing its own slot — which is exactly why slots are not shared —
    /// and `pollFn` throws its answer away.
    fn abandon(self: *HostBridge, key: u64) void {
        for (&self.slots) |*slot| {
            if (slot.busy and slot.key == key) slot.abandoned = true;
        }
    }

    fn startWorker(self: *HostBridge, key: u64, job: Job, path: []const u8) void {
        self.abandon(key);
        const slot = self.claim(key, job, path) orelse
            return self.reply(key, false, "no worker slot");
        slot.thread = std.Thread.spawn(.{}, workerMain, .{ self, slot }) catch {
            slot.busy = false;
            return self.reply(key, false, "thread spawn failed");
        };
        // Returns WITHOUT answering: the mailbox is the only route out.
    }

    /// `image.encode`'s request handler (loop thread). `payload` is
    /// `"<format>\x00<source>\x00<uti>\x00<dest>"` — see `main.encodePayload`
    /// (NUL-delimited because a path may contain `\n`). Parses it, then
    /// hands the worker a source path, a destination and a UTI; the worker
    /// does the decode + encode + atomic write.
    fn startEncode(self: *HostBridge, key: u64, payload: []const u8) void {
        var it = std.mem.splitScalar(u8, payload, 0);
        const format = it.next() orelse return self.reply(key, false, "malformed encode request");
        const source = it.next() orelse return self.reply(key, false, "malformed encode request");
        const source_uti = it.next() orelse return self.reply(key, false, "malformed encode request");
        const destination = it.rest();
        const job: Job = if (std.mem.eql(u8, format, "AVIF"))
            .encode_avif
        else if (std.mem.eql(u8, format, "WebP"))
            .encode_webp
        else
            return self.reply(key, false, "unknown encode format");

        self.abandon(key);
        const slot = self.claim(key, job, source) orelse
            return self.reply(key, false, "no worker slot");
        const dest_len = @min(destination.len, slot.dest_buffer.len);
        @memcpy(slot.dest_buffer[0..dest_len], destination[0..dest_len]);
        slot.dest_len = dest_len;
        const uti_len = @min(source_uti.len, slot.uti_buffer.len);
        @memcpy(slot.uti_buffer[0..uti_len], source_uti[0..uti_len]);
        slot.uti_len = uti_len;

        slot.thread = std.Thread.spawn(.{}, workerMain, .{ self, slot }) catch {
            slot.busy = false;
            return self.reply(key, false, "thread spawn failed");
        };
    }

    /// Worker thread. The probe/thumbnail jobs are pure `imageio` calls
    /// over a path — no SDK, no Model, no allocator. The encode jobs go
    /// further: they decode at full resolution (page allocator), run
    /// libavif/libwebp through `encoders`, and write the output file
    /// atomically via `self.io`. Still no SDK and no Model.
    fn workerMain(self: *HostBridge, slot: *Slot) void {
        switch (slot.job) {
            .encode_avif, .encode_webp => self.runEncode(slot),
            .probe => {
                const info = imageio.probe(slot.path()) catch |err| {
                    return self.finish(slot, false, @errorName(err));
                };
                const text = std.fmt.bufPrint(&slot.result, "{d} {d} {d} {s}", .{
                    info.width, info.height, info.orientation, info.uti(),
                }) catch return self.finish(slot, false, "probe reply too long");
                slot.result_len = text.len;
                slot.ok = true;
                slot.done.store(true, .release);
                self.wake();
            },
            .thumbnail => {
                // ImageIO decodes STRAIGHT INTO the reply buffer, past the
                // header — that is why the header is fixed width. A
                // variable-length one would mean either moving 100 KiB of
                // pixels afterwards or decoding into scratch and copying,
                // and neither buys anything a zero-padded number does not.
                const preview = imageio.thumbnail(
                    slot.path(),
                    slot.result[thumbnail_reply_header..],
                ) catch |err| {
                    return self.finish(slot, false, @errorName(err));
                };
                _ = std.fmt.bufPrint(slot.result[0..thumbnail_reply_header], "{d:0>5} {d:0>5}\n", .{
                    preview.width, preview.height,
                }) catch return self.finish(slot, false, "preview header too long");
                slot.result_len = thumbnail_reply_header + preview.pixels.len;
                slot.ok = true;
                slot.done.store(true, .release);
                self.wake();
            },
        }
    }

    /// WORKER THREAD. The encode job in full: decode the source at full
    /// resolution, run the vendored encoder, write the output atomically,
    /// reply with the output's byte size. On failure the reply tag is
    /// "write" if only the atomic write/rename failed (the encode itself
    /// produced bytes), "encode" otherwise.
    fn runEncode(self: *HostBridge, slot: *Slot) void {
        const gpa = std.heap.page_allocator;

        var decoded = imageio.decode(gpa, slot.path()) catch
            return self.finish(slot, false, "encode");
        defer decoded.deinit(gpa);

        var encoded = (if (slot.job == .encode_avif)
            encoders.encodeAvif(
                decoded.pixels,
                decoded.width,
                decoded.height,
                jpegSubsampling(gpa, self.io, slot.path(), slot.uti()),
            )
        else
            encoders.encodeWebp(decoded.pixels, decoded.width, decoded.height)) catch
            return self.finish(slot, false, "encode");
        defer encoded.deinit();

        atomicWrite(self.io, slot.dest(), encoded.bytes) catch
            return self.finish(slot, false, "write");

        const text = std.fmt.bufPrint(&slot.result, "{d}", .{encoded.bytes.len}) catch
            return self.finish(slot, false, "encode");
        slot.result_len = text.len;
        slot.ok = true;
        slot.done.store(true, .release);
        self.wake();
    }

    /// The chroma format `avifenc --yuv auto` would have picked for this
    /// source, reproduced from the container. Only a JPEG needs the file
    /// scanned; `chroma.forSource` answers everything else off the UTI
    /// alone. Any read failure falls back to 4:4:4 — the guess that cannot
    /// lose chroma detail (`chroma.zig` says why).
    fn jpegSubsampling(gpa: std.mem.Allocator, io: std.Io, path: []const u8, source_uti: []const u8) chroma.Subsampling {
        if (!std.mem.eql(u8, source_uti, chroma.jpeg_uti)) return chroma.forSource(source_uti, "");
        const head = gpa.alloc(u8, chroma.jpeg_scan_bytes) catch return .yuv444;
        defer gpa.free(head);
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return .yuv444;
        defer file.close(io);
        const n = file.readPositionalAll(io, head, 0) catch return .yuv444;
        return chroma.forSource(source_uti, head[0..n]);
    }

    /// Write `bytes` to `dest` atomically: a temp sibling in the
    /// destination directory, then a rename onto `dest`. A crash mid-write
    /// leaves the temp, never a truncated `dest`.
    fn atomicWrite(io: std.Io, dest: []const u8, bytes: []const u8) !void {
        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, dest, .{ .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, bytes);
        try atomic.replace(io);
    }

    /// WORKER THREAD: park a short answer and nudge the loop. The two
    /// failure paths in `startWorker` do not come through here — they run
    /// on the loop thread and answer synchronously, the way every other
    /// command in this bridge does.
    fn finish(self: *HostBridge, slot: *Slot, ok: bool, bytes: []const u8) void {
        const len = @min(bytes.len, slot.result.len);
        @memcpy(slot.result[0..len], bytes[0..len]);
        slot.result_len = len;
        slot.ok = ok;
        slot.done.store(true, .release);
        self.wake();
    }

    fn wake(self: *HostBridge) void {
        const services = self.services orelse return;
        services.wake() catch {};
    }

    /// Loop thread, via `Effects.hasPending`.
    fn pendingFn(context: *anyopaque) bool {
        const self: *HostBridge = @ptrCast(@alignCast(context));
        for (&self.slots) |*slot| {
            if (slot.busy and slot.done.load(.acquire)) return true;
        }
        return false;
    }

    /// Loop thread, via `Effects.adoptHostCompletions`, which calls
    /// `feedHostResult` for us. `bytes` need only stay valid until the
    /// next poll — Effects copies immediately — but the slot owns them for
    /// its whole life anyway.
    fn pollFn(context: *anyopaque) ?native_sdk.HostCallCompletion {
        const self: *HostBridge = @ptrCast(@alignCast(context));
        for (&self.slots) |*slot| {
            if (!slot.busy or !slot.done.load(.acquire)) continue;
            slot.busy = false;
            slot.done.store(false, .release);
            // A superseded worker's answer is dropped here, not fed.
            if (slot.abandoned) continue;
            return .{ .key = slot.key, .ok = slot.ok, .bytes = slot.result[0..slot.result_len] };
        }
        return null;
    }

    fn bindServicesFn(context: *anyopaque, services: *const platform.PlatformServices) void {
        const self: *HostBridge = @ptrCast(@alignCast(context));
        self.services = services;
    }

    /// Called from `Effects.deinit` while the platform wake binding is
    /// still live, before `PlatformServices` is severed — the one window
    /// in which joining a worker that might still call `wake()` is safe.
    /// Not optional: `UiApp.destroy` reaches it, and a still-decoding
    /// worker at quit would otherwise outlive the services it nudges.
    fn shutdownFn(context: *anyopaque) void {
        const self: *HostBridge = @ptrCast(@alignCast(context));
        for (&self.slots) |*slot| {
            if (slot.thread) |thread| {
                thread.join();
                slot.thread = null;
            }
        }
    }

    /// What the open panel offers. Everything macOS ImageIO decodes that
    /// we would plausibly be handed; `image.probe` is the real gate, and
    /// its failure is a named error state, so this list only has to be
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
        // The ImageIO reads and the encode return without answering — see
        // the worker carrier above.
        if (std.mem.eql(u8, name, host_image_probe)) return self.startWorker(key, .probe, payload);
        if (std.mem.eql(u8, name, host_image_thumbnail)) return self.startWorker(key, .thumbnail, payload);
        if (std.mem.eql(u8, name, host_image_encode)) return self.startEncode(key, payload);
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
    /// `original_size` (and the before/after delta after an encode), and
    /// a stat is far too cheap to deserve a worker thread or a `stat(1)`
    /// spawn.
    fn fileSize(self: *HostBridge, key: u64, path: []const u8) void {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| {
            return self.reply(key, false, @errorName(err));
        };
        const text = std.fmt.bufPrint(&reply_buf, "{d}", .{stat.size}) catch "0";
        self.reply(key, true, text);
    }

    /// The save panel. `payload` is a bare default filename (e.g.
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
    /// 1 MiB): a real encoder output can exceed that, the same bound the
    /// source image itself hits going through those effects.
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

    // Allocated BEFORE the app, so its `defer` runs AFTER `app_state.destroy()`
    // — defers unwind in reverse. `Effects.deinit` calls `shutdown_fn` with
    // this pointer to join a worker that may still be decoding, so freeing
    // the bridge first would be a use-after-free at quit. Heap rather than
    // `main`'s stack because it carries `worker_slot_count` slots with a
    // 100 KiB reply buffer each (~820 KB), and a worker holds a `*Slot`
    // into it while it runs.
    const bridge = try std.heap.page_allocator.create(HostBridge);
    defer std.heap.page_allocator.destroy(bridge);

    const app_state = try App.create(std.heap.page_allocator, .{
        .name = "smoosh",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .on_drop = onDrop,
        .markup = .{
            .source = app_markup,
            .watch_path = if (dev) "src/app.native" else null,
            .io = init.io,
        },
    });
    defer app_state.destroy();

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
    });

    bridge.* = .{ .runtime = runtime, .app_state = app_state, .io = init.io };
    app_state.effects.bindHostCalls(.{
        .context = bridge,
        .request_fn = HostBridge.requestFn,
        .send_fn = HostBridge.sendFn,
        // The worker carrier: without these four, `image.probe`,
        // `image.thumbnail` and `image.encode` would park answers nobody
        // ever drains.
        .poll_fn = HostBridge.pollFn,
        .pending_fn = HostBridge.pendingFn,
        .bind_services_fn = HostBridge.bindServicesFn,
        .shutdown_fn = HostBridge.shutdownFn,
    });

    try runtime.run(app_state.app());
}

test {
    _ = @import("tests.zig");
    // Runnable under `native test` since M14a: `build.zig` now states the
    // ImageIO frameworks on the test artifact's module, which the SDK's
    // own platform wiring never reached. Before that these had to be run
    // by hand from a file nothing imported.
    _ = @import("imageio_tests.zig");
}
