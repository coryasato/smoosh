//! VALIDATED SPIKE — not built as part of the app, kept as a transplant
//! reference for the real `src/main.zig`.
//!
//! Proves: a native-markup button dispatching `pick_file` can round-trip
//! through the effects channel's generic host-call seam
//! (`fx.hostRequest` -> `HostCallBinding.request_fn` ->
//! `runtime.showOpenDialog` -> `effects.feedHostResult` -> `Msg` ->
//! `Model`) and land a real file path picked from a real macOS
//! NSOpenPanel back in the model. Confirmed end-to-end with
//! `native build` + `native automate widget-click` against a throwaway
//! `native init --template zig-core` app (2026-08-03); the picked path
//! rendered correctly in the view with zero dispatch errors. See
//! CLAUDE.md's "File acquisition, honestly" for the fuller writeup.
//!
//! Trimmed of the scaffold's counter/tick example code — this keeps
//! only the parts specific to the host-call dialog wiring. Field names,
//! window config, etc. should be adapted to Smoosh's real Model.
//!
//! Two things this spike discovered that aren't obvious from the docs:
//!
//! 1. `runner.runWithOptions`'s per-platform bring-up (`runMacos`,
//!    `prepareStateStore`, `setupSessionRecorder`, ...) is all
//!    non-`pub`, private to the CLI's `app_runner/root.zig` — a
//!    hand-authored `main.zig` cannot call into it and must replicate
//!    the relevant bring-up itself using only public APIs
//!    (`platform.macos.MacPlatform.createWithOptions`,
//!    `native_sdk.Runtime.initAt`). In practice this is fine: the only
//!    things actually needed are the platform handle and the Runtime;
//!    trace-sink fanout, session recording, and window-state
//!    persistence are `runWithOptions` extras that can be skipped or
//!    added back deliberately.
//!
//! 2. The `build_options` module (the `-Dautomation` comptime flag) is
//!    wired into the CLI's internal `runner` module only, NOT into a
//!    hand-authored root module — so a hand-rolled `main.zig` can't
//!    gate `RuntimeOptions.automation` on `build_options.automation`
//!    the way the generated scaffold does. This spike always
//!    constructs the automation server unconditionally; the real app
//!    should gate on something it does control (e.g.
//!    `builtin.mode == .Debug`) instead.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const platform = native_sdk.platform;

const canvas_label = "main-canvas";
const window_width: f32 = 480;
const window_height: f32 = 320;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "canvas", .accessibility_label = "canvas", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "App",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    pick_file,
    dialog_result: native_sdk.EffectHostResult,

    // Dispatched by the host-call result path, never from markup — keeps
    // the unbound-state lint honest about that (same idiom the scaffold
    // uses for timer `tick` Msgs).
    pub const view_unbound = .{"dialog_result"};
};

pub const Model = struct {
    status_buf: [64]u8 = [_]u8{0} ** 64,
    status_len: usize = 0,
    path_buf: [platform.max_dialog_path_bytes]u8 = undefined,
    path_len: usize = 0,

    pub fn status(model: *const Model) []const u8 {
        return model.status_buf[0..model.status_len];
    }
    pub fn picked_path(model: *const Model) []const u8 {
        return model.path_buf[0..model.path_len];
    }

    fn setStatus(model: *Model, text: []const u8) void {
        const len = @min(text.len, model.status_buf.len);
        @memcpy(model.status_buf[0..len], text[0..len]);
        model.status_len = len;
    }

    fn setPath(model: *Model, text: []const u8) void {
        const len = @min(text.len, model.path_buf.len);
        @memcpy(model.path_buf[0..len], text[0..len]);
        model.path_len = len;
    }
};

pub const Effects = native_sdk.Effects(Msg);

pub const pick_file_key: u64 = 1;

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .pick_file => {
            model.setStatus("picking...");
            fx.hostRequest(.{
                .key = pick_file_key,
                .name = "dialog.openFile",
                .on_result = Effects.hostMsg(.dialog_result),
            });
        },
        .dialog_result => |result| {
            if (result.ok) {
                model.setStatus("picked");
                model.setPath(result.bytes);
            } else {
                model.setStatus("failed/cancelled");
                model.setPath(result.bytes);
            }
        },
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const App = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    var model = Model{};
    model.setStatus("idle");
    return model;
}

/// The host side of the `dialog.openFile` seam: closes over the
/// `*Runtime` we constructed by hand and the app state's `*Effects`, so
/// it can call `runtime.showOpenDialog` synchronously and answer back
/// through `effects.feedHostResult`. `request_fn` runs on the loop
/// thread, synchronously from `fx.hostRequest` — no threading to worry
/// about.
const HostBridge = struct {
    runtime: *native_sdk.Runtime,
    app_state: *App,

    var dialog_path_buf: [platform.max_dialog_paths_bytes]u8 = undefined;
    var err_buf: [128]u8 = undefined;

    fn requestFn(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
        _ = payload;
        const self: *HostBridge = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, name, "dialog.openFile")) {
            self.app_state.effects.feedHostResult(key, false, "unknown host command") catch {};
            return;
        }
        const result = self.runtime.showOpenDialog(.{
            .title = "Pick a file",
        }, &dialog_path_buf) catch |err| {
            const msg = std.fmt.bufPrint(&err_buf, "{s}", .{@errorName(err)}) catch "dialog error";
            self.app_state.effects.feedHostResult(key, false, msg) catch {};
            return;
        };
        if (result.count == 0) {
            self.app_state.effects.feedHostResult(key, false, "cancelled") catch {};
            return;
        }
        self.app_state.effects.feedHostResult(key, true, result.paths) catch {};
    }

    fn sendFn(context: *anyopaque, name: []const u8, payload: []const u8) void {
        _ = context;
        _ = name;
        _ = payload;
    }
};

pub fn main(init: std.process.Init) !void {
    const app_info: platform.AppInfo = .{
        .app_name = "app",
        .display_name = "App",
        .bundle_id = "dev.native_sdk.app",
        .window_title = "App",
    };
    // Own platform + Runtime construction directly (not
    // `runner.runWithOptions`, which builds and owns the Runtime
    // internally and never exposes the pointer) so the host-call
    // binding below can close over it. See file header, finding (1).
    const mac_platform = try platform.macos.MacPlatform.createWithOptions(
        geometry.SizeF.init(window_width, window_height),
        .system,
        app_info,
    );
    defer mac_platform.destroy();

    const app_state = try App.create(std.heap.page_allocator, .{
        .name = "app",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    defer runtime.deinit();
    native_sdk.Runtime.initAt(runtime, .{
        .platform = mac_platform.platform(),
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
        .environ = init.minimal.environ,
    });

    var bridge = HostBridge{ .runtime = runtime, .app_state = app_state };
    app_state.effects.bindHostCalls(.{
        .context = &bridge,
        .request_fn = HostBridge.requestFn,
        .send_fn = HostBridge.sendFn,
    });

    try runtime.run(app_state.app());
}
