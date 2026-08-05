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

const canvas_label = "main-canvas";
const window_title = "Smoosh";
const window_width: f32 = 480;
const window_height: f32 = 320;

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

const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

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
    image_loaded: native_sdk.EffectFileResult, // fx.readFile callback (M3 registers the image bytes synchronously in this arm)
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
        "image_loaded",
        "encode_result",
        "save_as_dialog_result",
        "save_as_result",
        "encoder_check_result",
    };
};

pub const Effects = native_sdk.Effects(Msg);

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    _ = model;
    _ = fx;
    switch (msg) {
        .pick_file => {},
        .dialog_result => {},
        .image_loaded => {},
        .set_format => {},
        .smoosh => {},
        .encode_result => {},
        .save_as => {},
        .save_as_dialog_result => {},
        .save_as_result => {},
        .encoder_check_result => {},
        .reset => {},
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const App = native_sdk.UiApp(Model, Msg);

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

    try runtime.run(app_state.app());
}

test {
    _ = @import("tests.zig");
}
