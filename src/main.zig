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
pub const window_width: f32 = 480;
pub const window_height: f32 = 320;

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

pub const Model = struct {
    // file
    path_buffer: [platform.max_dialog_path_bytes]u8 = undefined,
    path_len: usize = 0,
    original_size: u64 = 0,
    // preview
    image_id: u64 = 0,
    preview_width: u32 = 0,
    preview_height: u32 = 0,
    // result
    avif_path_buffer: [platform.max_dialog_path_bytes]u8 = undefined,
    avif_path_len: usize = 0,
    avif_size: u64 = 0,
    webp_path_buffer: [platform.max_dialog_path_bytes]u8 = undefined,
    webp_path_len: usize = 0,
    webp_size: u64 = 0,
    savings_percent: f32 = 0,
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

    /// The chip iterable for the format toggle-group (see "Chips" in the
    /// native-ui skill) — must live inside Model for `for each` to see it.
    pub const formats = [_]Format{ .avif, .webp, .both };

    pub fn path(model: *const Model) []const u8 {
        return model.path_buffer[0..model.path_len];
    }
    pub fn errorMessage(model: *const Model) []const u8 {
        return model.error_message_buffer[0..model.error_message_len];
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

    /// "photo.jpg (2.4 MB)" — derived per rebuild, never stored
    /// (native-ui's "Derive, don't store"). Empty with no file picked.
    pub fn fileSummary(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.path_len == 0) return "";
        return std.fmt.allocPrint(arena, "{s} ({s})", .{
            model.fileName(),
            formatBytes(arena, model.original_size),
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

    /// M2 scaffold status line — just enough for the placeholder
    /// `<status-bar>` to bind to. Later milestones will likely replace this
    /// with something that also reports sizes/savings once those are real.
    pub fn statusLine(model: *const Model) []const u8 {
        return switch (model.status) {
            .idle => "Drop or choose an image to get started.",
            .loading => "Loading…",
            .ready => "Ready to smoosh.",
            .compressing => "Smooshing…",
            .done => "Done.",
            .failed => model.errorMessage(),
        };
    }
};

pub const Msg = union(enum) {
    pick_file, // "Choose Image…" clicked
    dialog_result: native_sdk.EffectHostResult, // host open-dialog callback
    stat_result: native_sdk.EffectHostResult, // host file-size callback -> original_size
    dimensions_result: native_sdk.EffectExit, // `sips -g` source pixel dimensions -> megapixel limit check
    thumbnail_result: native_sdk.EffectExit, // `sips` downscale for the preview
    image_loaded: native_sdk.EffectImageResult, // fx.loadImage callback (registers the preview pixels)
    set_format: Format, // format chip pressed
    smoosh, // "Smoosh" clicked
    encode_result: native_sdk.EffectExit, // fx.spawn callback, one per format encoded
    save_as, // "Save As…" clicked
    save_as_dialog_result: native_sdk.EffectHostResult, // host save-dialog callback
    save_as_result: native_sdk.EffectFileResult, // fx.writeFile callback
    encoder_check_result: native_sdk.EffectExit, // launch-time `which avifenc`/`which cwebp`
    reset, // clear current image, return to idle

    // Dispatched by effect/host-call result paths, never from markup —
    // same idiom the spike uses for its `dialog_result` Msg.
    pub const view_unbound = .{
        "dialog_result",
        "stat_result",
        "dimensions_result",
        "thumbnail_result",
        "image_loaded",
        "encode_result",
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

/// Host-call names our own `HostBridge` answers (see `main`). Not SDK
/// vocabulary — we bind the seam, so we name it.
const host_open_file = "dialog.openFile";
const host_file_size = "file.stat";

/// Absolute so the check does not depend on the inherited PATH — but
/// `which`'s OWN job is to search that PATH for `avifenc`/`cwebp`, which is
/// exactly what a real encode spawn (M7) would do resolving argv[0] the
/// same way, so the check is honest about what it is proving.
const which_path = "/usr/bin/which";

/// Where `sips` writes the downscaled preview, resolved once in `main`
/// (see the "Preview is a thumbnail" note there). `pub var` so tests can
/// point it somewhere harmless; `update` only ever reads it.
pub var thumbnail_path: []const u8 = "";

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
            model.setPath(result.bytes);
            fx.hostRequest(.{
                .key = stat_key,
                .name = host_file_size,
                .payload = model.path(),
                .on_result = Effects.hostMsg(.stat_result),
            });
        },

        .stat_result => |result| {
            const size = if (result.ok)
                std.fmt.parseInt(u64, result.bytes, 10) catch null
            else
                null;
            model.original_size = size orelse {
                // PLAN.md error state: "write/read to path failed".
                return model.fail("Can't read \"{s}\".", .{model.fileName()});
            };
            if (model.original_size > max_original_bytes) {
                // PLAN.md error state: input exceeds the size/megapixel limit.
                return model.fail(
                    "\"{s}\" is {d:.1} MB — Smoosh handles files up to {d:.0} MB.",
                    .{ model.fileName(), bytesToMb(model.original_size), bytesToMb(max_original_bytes) },
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
                const megapixels = @as(f64, @floatFromInt(dims.width)) *
                    @as(f64, @floatFromInt(dims.height)) / 1_000_000.0;
                if (megapixels > max_source_megapixels) {
                    // PLAN.md error state: input exceeds the size/megapixel limit.
                    return model.fail(
                        "\"{s}\" is {d:.0} megapixels — Smoosh handles images up to {d:.0} MP.",
                        .{ model.fileName(), megapixels, max_source_megapixels },
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
                    "\"{s}\" isn't an image Smoosh can read. Try JPEG, PNG, HEIC, WebP, TIFF, or GIF.",
                    .{model.fileName()},
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
                return model.fail("Couldn't build a preview for \"{s}\".", .{model.fileName()});
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
            _ = fx.unregisterImage(preview_image_id);
            // Format is a user preference, not per-file state — it is
            // the one thing Reset deliberately keeps.
            const format = model.format;
            model.* = .{ .format = format };
        },

        .set_format => {},
        .smoosh => {},
        .encode_result => {},
        .save_as => {},
        .save_as_dialog_result => {},
        .save_as_result => {},

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
fn resolveThumbnailPath(io: std.Io, environ: std.process.Environ) ![]const u8 {
    const State = struct {
        var dir_buf: [platform.max_dialog_path_bytes]u8 = undefined;
        var path_buf: [platform.max_dialog_path_bytes]u8 = undefined;

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
        &State.dir_buf,
    );
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return app_dirs.join(app_dirs.currentPlatform(), &State.path_buf, &.{ dir, "preview.png" });
}

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
        .environ = init.minimal.environ,
    });

    thumbnail_path = try resolveThumbnailPath(init.io, init.minimal.environ);

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
