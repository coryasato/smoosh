//! VALIDATED SPIKE — not built as part of the app, kept as a transplant
//! reference for the real `src/main.zig`.
//!
//! PLAN.md's Phase B step 1: prove a `HostCallBinding.request_fn` can
//! hand long CPU work to a worker thread, return WITHOUT answering, and
//! land the answer back in `Model` as an ordinary Msg — while the window
//! keeps painting. Every long operation in M13 (ImageIO decode) and M14
//! (libaom/libwebp encode) depends on this seam, because `Effects` has
//! spawn/fetch/file/db/pty/channel and nothing that runs arbitrary Zig
//! off the loop thread.
//!
//! VERDICT: works. Measured live (2026-08-27, ReleaseFast +
//! `-Dautomation=true`, against a throwaway `native init --template
//! zig-core` app), pressing "Run two" so both workers overlap:
//!
//!     A: A done f7c1 · 1359ms · ticks during 14
//!     B: B done 6673 · 2209ms · ticks during 22
//!
//! A 100ms repeating fx timer fired 14 times across A's 1.36s and 22
//! times across B's 2.21s — i.e. the loop thread never blocked — and the
//! snapshot's `gpu_frame` advanced monotonically the whole time (105 ->
//! 353 across the run), so the window really was painting, not just
//! dispatching. Two concurrent workers each routed to their own key and
//! their own Msg arm.
//!
//! FOUR THINGS THIS SPIKE SETTLED THAT PLAN.md HAD WRONG OR MISSING:
//!
//! 1. `feedHostResult` IS NOT THREAD-SAFE, and must not be called from
//!    the worker. PLAN.md assumed it was ("uses atomic slot state and
//!    calls `wakeHost()`, so it is built for this"). The `HostCallBinding`
//!    doc comment is explicit the other way: "A host answers a request by
//!    calling `Effects.feedHostResult(key, ok, bytes)` ON THE LOOP THREAD
//!    — synchronously from `request_fn`, or later from an event the host
//!    marshals back." The atomics inside it guard the SDK's own worker
//!    families (`storeWorkerMain` and friends hand-roll the slot write +
//!    `enqueue` + `wakeHost` sequence themselves rather than calling it).
//!
//! 2. The marshal seam already exists and is the supported path: the
//!    optional carrier trio on `HostCallBinding` — `poll_fn`,
//!    `pending_fn`, `bind_services_fn` (plus `shutdown_fn`). The worker
//!    parks its answer in a bridge-owned mailbox and calls
//!    `services.wake()`; `Effects.hasPending` consults `pending_fn`, and
//!    `adoptHostCompletions` (loop thread) drains `poll_fn` and calls
//!    `feedHostResult` itself. `HostCallCompletion.bytes` need only stay
//!    valid until the next poll — Effects copies immediately.
//!
//! 3. RESULT BYTES ARE CAPPED AT `max_effect_host_result_bytes` = 256 KiB,
//!    and an over-cap answer is silently rewritten to the err route with
//!    the bytes "host result over budget" (verified by unit test, not
//!    just by reading `feedHostResult`). This SHAPES M13: a 160x160 RGBA
//!    thumbnail is 100 KiB and fits, but 256x256 RGBA is exactly the cap
//!    and anything larger (a 2x-scale preview, and every full-resolution
//!    decode without exception) cannot ride the result payload. Those
//!    must return a small descriptor ("<w> <h> <len>") with the pixels
//!    left in a bridge-owned `pub var` buffer that `update` reads —
//!    exactly the shape `pub var thumbnail_path` already has today. Note
//!    the registered-image cap is a separate, larger 1 MiB
//!    (`max_registered_canvas_image_pixel_bytes`, raisable to 8 MiB), so
//!    the host-result cap is the binding constraint, not the registry.
//!
//! 4. Teardown with a worker still running is handled, but only because
//!    `shutdown_fn` is wired: `Effects.deinit` calls it while
//!    `PlatformServices` is still live, before severing the services
//!    binding — the one window in which joining a worker that might still
//!    call `wake()` is safe. `UiApp.destroy` -> `deinit` -> `effects.deinit`
//!    reaches it, so the app-owned path is covered too. Verified by a unit
//!    test that dispatches a long job and then destroys the app.
//!
//! HONEST CAVEATS, so a later reader does not over-claim this spike:
//!
//! - The `services.wake()` nudge was NOT proven load-bearing here. This
//!   app's view is a `gpu_present_mode = .timer` surface, so the loop
//!   already wakes ~60x/s and would have polled the mailbox on its own.
//!   The wake is contract-correct and free; treat it as required, but do
//!   not cite this spike as evidence that delivery fails without it.
//! - `parkAndWake` drops a rejection on the floor if no slot is free (the
//!   effect slot then stays in flight until its key is replaced). Fine at
//!   4 slots against at most 3 concurrent Smoosh requests; the real app
//!   should still size the table against its own key set deliberately.
//! - The worker burns sha256 rather than doing real image work. What it
//!   proves is that a saturated core does not stall the loop, which is
//!   the actual question — an encode burns a core the same way.
//!
//! Everything below is the spike verbatim, trimmed of the scaffold's
//! counter example. `main` uses `runner.runWithOptions` because this
//! binding needs no `*Runtime` (unlike `dialog-open-file-spike.zig`);
//! Smoosh's hand-authored root keeps its own bring-up and simply passes
//! the same `HostCallBinding` to `bindHostCalls`.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const platform = native_sdk.platform;

pub const canvas_label = "main-canvas";
const window_width: f32 = 480;
const window_height: f32 = 320;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Spike canvas", .accessibility_label = "Spike", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Spike Threaded",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    start_one,
    start_two,
    tick: native_sdk.EffectTimer,
    job_a_result: native_sdk.EffectHostResult,
    job_b_result: native_sdk.EffectHostResult,

    pub const view_unbound = .{ "tick", "job_a_result", "job_b_result" };
};

const Job = struct {
    state_buf: [48]u8 = [_]u8{0} ** 48,
    state_len: usize = 0,
    started_ms: i64 = 0,
    /// Loop-thread-measured wall time from `hostRequest` to the Msg.
    elapsed_ms: i64 = -1,
    /// Ticks that fired while this job was in flight — the proof the
    /// loop never blocked.
    ticks_at_start: i64 = 0,
    ticks_during: i64 = -1,

    fn set(job: *Job, text: []const u8) void {
        const len = @min(text.len, job.state_buf.len);
        @memcpy(job.state_buf[0..len], text[0..len]);
        job.state_len = len;
    }

    pub fn state(job: *const Job) []const u8 {
        if (job.state_len == 0) return "idle";
        return job.state_buf[0..job.state_len];
    }
};

pub const Model = struct {
    tick_count: i64 = 0,
    a: Job = .{},
    b: Job = .{},

    pub fn aState(model: *const Model) []const u8 {
        return model.a.state();
    }
    pub fn bState(model: *const Model) []const u8 {
        return model.b.state();
    }
    pub fn aElapsed(model: *const Model) i64 {
        return model.a.elapsed_ms;
    }
    pub fn bElapsed(model: *const Model) i64 {
        return model.b.elapsed_ms;
    }
    pub fn aTicks(model: *const Model) i64 {
        return model.a.ticks_during;
    }
    pub fn bTicks(model: *const Model) i64 {
        return model.b.ticks_during;
    }
};

pub const Effects = native_sdk.Effects(Msg);

const tick_timer_key: u64 = 100;
const job_a_key: u64 = 1;
const job_b_key: u64 = 2;

const host_burn = "work.burn";

fn startJob(model: *Model, fx: *Effects, job: *Job, key: u64, payload: []const u8, on_result: anytype) void {
    job.set("working");
    job.started_ms = fx.wallMs();
    job.elapsed_ms = -1;
    job.ticks_at_start = model.tick_count;
    job.ticks_during = -1;
    fx.hostRequest(.{
        .key = key,
        .name = host_burn,
        .payload = payload,
        .on_result = on_result,
    });
}

fn finishJob(model: *Model, job: *Job, result: native_sdk.EffectHostResult, fx: *Effects) void {
    job.elapsed_ms = fx.wallMs() - job.started_ms;
    job.ticks_during = model.tick_count - job.ticks_at_start;
    if (result.ok) {
        job.set(result.bytes);
    } else {
        var buf: [48]u8 = undefined;
        job.set(std.fmt.bufPrint(&buf, "failed: {s}", .{result.bytes}) catch "failed");
    }
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .start_one => startJob(model, fx, &model.a, job_a_key, "A:600000", Effects.hostMsg(.job_a_result)),
        .start_two => {
            startJob(model, fx, &model.a, job_a_key, "A:600000", Effects.hostMsg(.job_a_result));
            startJob(model, fx, &model.b, job_b_key, "B:1000000", Effects.hostMsg(.job_b_result));
        },
        .tick => |timer| {
            if (timer.outcome != .fired) return;
            model.tick_count += 1;
        },
        .job_a_result => |result| finishJob(model, &model.a, result, fx),
        .job_b_result => |result| finishJob(model, &model.b, result, fx),
    }
}

pub fn initFx(model: *Model, fx: *Effects) void {
    _ = model;
    fx.startTimer(.{
        .key = tick_timer_key,
        .interval_ms = 100,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const App = native_sdk.UiApp(Model, Msg);

/// The worker-carrier host binding.
///
/// `feedHostResult` is documented LOOP-THREAD-ONLY (`HostCallBinding`:
/// "A host answers a request by calling `Effects.feedHostResult` on the
/// loop thread — synchronously from `request_fn`, or later from an event
/// the host marshals back"). The marshal seam is the optional carrier
/// trio on `HostCallBinding`: the worker parks its answer in a
/// bridge-owned mailbox and nudges the platform's thread-safe
/// `wake_fn`; the loop then calls `pending_fn` (from `hasPending`) and
/// drains through `poll_fn` (`adoptHostCompletions`), which calls
/// `feedHostResult` for us on the right thread.
const WorkerBridge = struct {
    /// Per-key worker state. Fixed table: no allocation on the loop
    /// thread, and each slot owns the result bytes the loop reads.
    const Slot = struct {
        key: u64 = 0,
        busy: bool = false,
        thread: ?std.Thread = null,
        payload: [64]u8 = undefined,
        payload_len: usize = 0,
        result: [128]u8 = undefined,
        result_len: usize = 0,
        ok: bool = false,
        /// Worker -> loop: the answer is parked and ready to adopt.
        done: std.atomic.Value(bool) = .init(false),
    };

    slots: [4]Slot = [_]Slot{.{}} ** 4,
    services: ?*const platform.PlatformServices = null,

    fn requestFn(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
        const self: *WorkerBridge = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, name, host_burn)) {
            self.parkAndWake(key, false, "unknown host command");
            return;
        }
        const slot = self.claim(key) orelse {
            self.parkAndWake(key, false, "no worker slot");
            return;
        };
        const len = @min(payload.len, slot.payload.len);
        @memcpy(slot.payload[0..len], payload[0..len]);
        slot.payload_len = len;
        slot.thread = std.Thread.spawn(.{}, workerMain, .{ self, slot }) catch {
            slot.busy = false;
            self.parkAndWake(key, false, "thread spawn failed");
            return;
        };
        // Returns WITHOUT answering — the whole point of the spike.
    }

    /// Reserve a slot for `key`.
    ///
    /// No lock anywhere in this bridge, deliberately: `claim`, `pollFn`
    /// and `pendingFn` all run on the LOOP thread, and a slot's result
    /// bytes are written by exactly one worker and read by the loop only
    /// after `done` publishes them (release/acquire). Single-producer,
    /// single-consumer, one flag — the handoff a mutex would only
    /// decorate. (`std.Thread.Mutex` is gone in Zig 0.16 anyway:
    /// `std.atomic.Mutex` is try-lock only and `std.Io.Mutex` wants an
    /// `Io` the bridge has no reason to hold.)
    fn claim(self: *WorkerBridge, key: u64) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.busy) continue;
            if (slot.thread) |thread| {
                // A retired-but-unjoined worker: reap it before reuse.
                thread.join();
                slot.thread = null;
            }
            slot.* = .{ .key = key, .busy = true };
            return slot;
        }
        return null;
    }

    fn workerMain(self: *WorkerBridge, slot: *Slot) void {
        // "A:600000" — a label and how many KiB-blocks to hash. Real work,
        // not a sleep: an encode burns a core, and the question is
        // whether the loop keeps painting while one is burnt.
        const payload = slot.payload[0..slot.payload_len];
        const sep = std.mem.indexOfScalar(u8, payload, ':') orelse payload.len;
        const label = payload[0..sep];
        const blocks: usize = if (sep < payload.len)
            std.fmt.parseInt(usize, payload[sep + 1 ..], 10) catch 1000
        else
            1000;

        var digest: [32]u8 = [_]u8{0} ** 32;
        var block: [4096]u8 = undefined;
        for (&block, 0..) |*byte, index| byte.* = @truncate(index);
        var round: usize = 0;
        while (round < blocks) : (round += 1) {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(&digest);
            hasher.update(&block);
            hasher.final(&digest);
        }

        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s} done {x:0>2}{x:0>2}", .{
            label, digest[0], digest[1],
        }) catch "done";
        self.finish(slot, true, text);
    }

    /// Worker thread: park the answer, then nudge the loop. The
    /// `done` store is the release edge that publishes every write
    /// above it to whichever loop-thread poll acquires it.
    fn finish(self: *WorkerBridge, slot: *Slot, ok: bool, bytes: []const u8) void {
        const len = @min(bytes.len, slot.result.len);
        @memcpy(slot.result[0..len], bytes[0..len]);
        slot.result_len = len;
        slot.ok = ok;
        slot.done.store(true, .release);
        self.wake();
    }

    /// A rejection with no worker behind it. Same mailbox — never
    /// `feedHostResult` from here either, so every answer takes exactly
    /// one path.
    fn parkAndWake(self: *WorkerBridge, key: u64, ok: bool, bytes: []const u8) void {
        const slot = self.claim(key) orelse return;
        self.finish(slot, ok, bytes);
    }

    fn wake(self: *WorkerBridge) void {
        const services = self.services orelse return;
        services.wake() catch {};
    }

    /// Loop thread, via `hasPending`.
    fn pendingFn(context: *anyopaque) bool {
        const self: *WorkerBridge = @ptrCast(@alignCast(context));
        for (&self.slots) |*slot| {
            if (slot.busy and slot.done.load(.acquire)) return true;
        }
        return false;
    }

    /// Loop thread, via `adoptHostCompletions`. `bytes` need only stay
    /// valid until the next poll — Effects copies immediately — but the
    /// slot owns them for its whole life anyway.
    fn pollFn(context: *anyopaque) ?native_sdk.HostCallCompletion {
        const self: *WorkerBridge = @ptrCast(@alignCast(context));
        for (&self.slots) |*slot| {
            if (!slot.busy or !slot.done.load(.acquire)) continue;
            slot.busy = false;
            slot.done.store(false, .release);
            return .{ .key = slot.key, .ok = slot.ok, .bytes = slot.result[0..slot.result_len] };
        }
        return null;
    }

    fn bindServicesFn(context: *anyopaque, services: *const platform.PlatformServices) void {
        const self: *WorkerBridge = @ptrCast(@alignCast(context));
        self.services = services;
    }

    /// Called while the platform wake binding is still live, before
    /// `PlatformServices` is severed.
    fn shutdownFn(context: *anyopaque) void {
        const self: *WorkerBridge = @ptrCast(@alignCast(context));
        for (&self.slots) |*slot| {
            if (slot.thread) |thread| {
                thread.join();
                slot.thread = null;
            }
        }
    }

    fn sendFn(context: *anyopaque, name: []const u8, payload: []const u8) void {
        _ = context;
        _ = name;
        _ = payload;
    }
};

/// The binding, in one place so `main` and the teardown test wire the
/// identical seam.
pub fn hostBinding() native_sdk.HostCallBinding {
    return .{
        .context = &bridge,
        .request_fn = WorkerBridge.requestFn,
        .send_fn = WorkerBridge.sendFn,
        .poll_fn = WorkerBridge.pollFn,
        .pending_fn = WorkerBridge.pendingFn,
        .bind_services_fn = WorkerBridge.bindServicesFn,
        .shutdown_fn = WorkerBridge.shutdownFn,
    };
}

pub fn initialModel() Model {
    return .{};
}

var bridge: WorkerBridge = .{};

pub fn main(init: std.process.Init) !void {
    const app_state = try App.create(std.heap.page_allocator, .{
        .name = "spike-threaded",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = initFx,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    app_state.effects.bindHostCalls(hostBinding());

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "spike-threaded",
        .window_title = "Spike Threaded",
        .bundle_id = "dev.native_sdk.spike-threaded",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

// ------------------------------------------------------------------ tests
//
// The two checks that validated the seam, inlined from the spike app's
// own `src/tests.zig` so this file is the whole reference. Both pass.

test "in-flight worker is joined at teardown" {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);

    const App = native_sdk.UiApp(Model, Msg);
    const app_state = try App.create(std.testing.allocator, .{
        .name = "spike-threaded",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .markup = .{ .source = app_markup },
    });
    defer app_state.destroy();

    app_state.effects.bindHostCalls(hostBinding());
    app_state.effects.bindServices(&harness.runtime.options.platform.services);

    // Long job, then tear down immediately while it is still running.
    try app_state.dispatch(&harness.runtime, 1, .start_one);
    try std.testing.expect(std.mem.eql(u8, app_state.model.a.state(), "working"));
}

test "a result over max_effect_host_result_bytes lands on the err route" {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);

    const App = native_sdk.UiApp(Model, Msg);
    const app_state = try App.create(std.testing.allocator, .{
        .name = "spike-threaded",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .markup = .{ .source = app_markup },
    });
    defer app_state.destroy();

    app_state.effects.executor = .fake;
    const app = app_state.app();
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = native_sdk.geometry.SizeF.init(480, 320),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try app_state.dispatch(&harness.runtime, 1, .start_one);

    const oversize = try std.testing.allocator.alloc(u8, native_sdk.max_effect_host_result_bytes + 1);
    defer std.testing.allocator.free(oversize);
    @memset(oversize, 'x');
    try app_state.effects.feedHostResult(1, true, oversize);
    try harness.runtime.dispatchPlatformEvent(app, .wake);

    try std.testing.expectEqualStrings("failed: host result over budget", app_state.model.a.state());
}
