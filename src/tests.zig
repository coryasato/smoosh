//! Smoosh unit tests — the markup/model seam, exercised through the real
//! dispatch path with no GUI.
//!
//! Scope, deliberately: this file tests facts that EXIST after M2 and that
//! later milestones would regress silently — that `app.native` builds against
//! the real `Model`, that every control dispatches the `Msg` it claims (chip
//! payload coercion included), and that `Model`'s derived accessors hold. It
//! does NOT test `update`'s arms: they are empty by design until M3-M8 fill
//! them in one at a time, and "asserts nothing happened" tests would just be
//! deleted milestone by milestone. Msg-tag exhaustiveness is already a compile
//! error via `update`'s switch, so it needs no test either.
//!
//! Effects-bearing milestones (M3 dialog, M5 encoder detection, M7 encode)
//! test through the fake executor — see PLAN.md's "Testing strategy".

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;
const Format = main.Format;
const Status = main.Status;

const AppMarkup = canvas.MarkupView(Model, Msg);

fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    var view = try AppMarkup.init(arena, main.app_markup);
    var ui = AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        // Name the app.native position instead of leaving a bare error trace:
        // the usual causes are a binding without a matching Model field or an
        // on-* message without a Msg arm.
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{
                view.diagnostic.line,
                view.diagnostic.column,
                view.diagnostic.message,
            });
        }
        return err;
    };
    return ui.finalize(node);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

/// For leaves with no text of their own to find them by (the preview
/// `<image>`), where the kind alone is unambiguous in this view.
fn findByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findByKind(child, kind)) |found| return found;
    }
    return null;
}

/// A miss fails the test with the mismatch spelled out instead of a
/// null-unwrap panic: the usual cause is app.native and this file drifting
/// apart after an edit.
fn expectByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) !canvas.Widget {
    return findByText(widget, kind, text) orelse {
        std.debug.print(
            "no {t} with text \"{s}\" in the view - if you changed app.native, update this test to match\n",
            .{ kind, text },
        );
        return error.WidgetNotFound;
    };
}

fn expectMsgTag(expected: std.meta.Tag(Msg), actual: ?Msg) !void {
    const msg = actual orelse {
        std.debug.print("expected a {t} message, got no dispatch at all\n", .{expected});
        return error.NoMessageDispatched;
    };
    try testing.expectEqual(expected, std.meta.activeTag(msg));
}

// ------------------------------------------------------------- markup builds

test "app.native builds against the real Model in every Status" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every status the model can hold renders: this catches a binding that
    // only resolves on the happy path, and it pins statusLine's coverage of
    // the enum at the view layer rather than only in Zig.
    for (std.enums.values(Status)) |status| {
        var model: Model = .{ .status = status };
        const tree = try buildTree(arena, &model);
        const status_bar = findByText(tree.root, .status_bar, model.statusLine());
        try testing.expect(status_bar != null);
    }
}

test "the view exposes every control M3-M8 drive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model: Model = .{};
    const tree = try buildTree(arena, &model);

    _ = try expectByText(tree.root, .button, "Choose Image…");
    _ = try expectByText(tree.root, .button, "Smoosh");
    _ = try expectByText(tree.root, .button, "Save As…");
    _ = try expectByText(tree.root, .button, "Reset");
    // One chip per Format, labelled by the enum tag name.
    for (Model.formats) |format| {
        _ = try expectByText(tree.root, .toggle_button, @tagName(format));
    }
}

test "widget ids are stable across a rebuild" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model: Model = .{};
    const first = try buildTree(arena, &model);
    const smoosh_before = try expectByText(first.root, .button, "Smoosh");

    // A status change rebuilds the tree; structural ids must not move, since
    // `native automate widget-click` scripts and the tests below address
    // controls by id.
    model.status = .compressing;
    const second = try buildTree(arena, &model);
    const smoosh_after = try expectByText(second.root, .button, "Smoosh");

    try testing.expectEqual(smoosh_before.id, smoosh_after.id);
}

test "widget ids survive the conditional rows appearing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The preview and the two result lines are `<if>` children of the root
    // column, so they come and go. Unkeyed same-kind siblings take
    // POSITIONAL identity, which means a conditional that starts rendering
    // re-disambiguates every sibling after it and all their ids move. That
    // really happened: driving M7 live, the Smoosh button took three
    // different ids across idle -> ready -> done, breaking automation
    // scripts mid-run. The `key` on each root child is what pins this, and
    // the test above cannot catch it — it only changes `status`, which
    // alters no structure.
    var empty: Model = .{};
    const before = try buildTree(arena, &empty);

    var full: Model = .{
        .status = .done,
        .image_id = 4,
        .preview_width = 160,
        .preview_height = 120,
        .original_size = 5_846_465,
        .avif_size = 717_003,
        .avif_outcome = .ok,
        .webp_size = 671_054,
        .webp_outcome = .ok,
    };
    const after = try buildTree(arena, &full);
    // Precondition: the two trees really do differ structurally, or this
    // test would pass without proving anything.
    try testing.expect(findByKind(before.root, .image) == null);
    try testing.expect(findByKind(after.root, .image) != null);

    for ([_][]const u8{ "Smoosh", "Save As…", "Choose Image…", "Reset" }) |label| {
        const empty_widget = try expectByText(before.root, .button, label);
        const full_widget = try expectByText(after.root, .button, label);
        try testing.expectEqual(empty_widget.id, full_widget.id);
    }
    for (Model.formats) |format| {
        const empty_chip = try expectByText(before.root, .toggle_button, @tagName(format));
        const full_chip = try expectByText(after.root, .toggle_button, @tagName(format));
        try testing.expectEqual(empty_chip.id, full_chip.id);
    }
}

// ---------------------------------------------------------------- dispatch

test "every control dispatches the message it claims" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model: Model = .{};
    const tree = try buildTree(arena, &model);

    const choose = try expectByText(tree.root, .button, "Choose Image…");
    try expectMsgTag(.pick_file, tree.msgForPointer(choose.id, .up));

    const smoosh = try expectByText(tree.root, .button, "Smoosh");
    try expectMsgTag(.smoosh, tree.msgForPointer(smoosh.id, .up));

    const save_as = try expectByText(tree.root, .button, "Save As…");
    try expectMsgTag(.save_as, tree.msgForPointer(save_as.id, .up));

    const reset = try expectByText(tree.root, .button, "Reset");
    try expectMsgTag(.reset, tree.msgForPointer(reset.id, .up));
}

test "each format chip coerces its own tag into the set_format payload" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model: Model = .{};
    const tree = try buildTree(arena, &model);

    // The one piece of real wiring M2 landed: `on-toggle="set_format:{f}"`
    // must carry the loop variable through as a typed Format payload, not
    // just fire a bare tag. M6 relies on this exact coercion.
    for (Model.formats) |format| {
        const chip = try expectByText(tree.root, .toggle_button, @tagName(format));
        const msg = tree.msgFor(chip.id, .toggle) orelse {
            std.debug.print("chip \"{t}\" dispatched nothing on toggle\n", .{format});
            return error.NoMessageDispatched;
        };
        switch (msg) {
            .set_format => |payload| try testing.expectEqual(format, payload),
            else => {
                std.debug.print("chip \"{t}\" dispatched {t}, not set_format\n", .{ format, msg });
                return error.UnexpectedMessage;
            },
        }
    }
}

test "the chip matching Model.format is the selected one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `selected="{f == format}"` is what makes the chip row model-driven
    // rather than uncontrolled. It reads correctly for every Format even
    // though `update` cannot move `format` yet (M6 wires that).
    for (Model.formats) |selected_format| {
        var model: Model = .{ .format = selected_format };
        const tree = try buildTree(arena, &model);
        for (Model.formats) |format| {
            const chip = try expectByText(tree.root, .toggle_button, @tagName(format));
            try testing.expectEqual(format == selected_format, chip.state.selected);
        }
    }
}

// ------------------------------------------------------------ model accessors

test "path and errorMessage slice at zero and populated lengths" {
    var model: Model = .{};
    try testing.expectEqualStrings("", model.path());
    try testing.expectEqualStrings("", model.errorMessage());

    const source = "/Users/someone/Pictures/photo.jpg";
    @memcpy(model.path_buffer[0..source.len], source);
    model.path_len = source.len;
    try testing.expectEqualStrings(source, model.path());

    const message = "avifenc not found — run: brew install libavif";
    @memcpy(model.error_message_buffer[0..message.len], message);
    model.error_message_len = message.len;
    try testing.expectEqualStrings(message, model.errorMessage());
}

test "path buffers hold a maximum-length dialog path" {
    // PLAN.md's sketch said 1024; M2 sized these at platform.max_dialog_path_bytes
    // so M3 can land whatever showOpenDialog returns without a resize. Pin that.
    var model: Model = .{};
    const max = model.path_buffer.len;
    try testing.expectEqual(native_sdk.platform.max_dialog_path_bytes, max);

    @memset(model.path_buffer[0..max], 'a');
    model.path_len = max;
    try testing.expectEqual(max, model.path().len);
}

test "statusLine names every Status, and .failed reports the error message" {
    var model: Model = .{};

    // Non-failed statuses each get their own non-empty line, all distinct —
    // a copy/paste duplicate in the switch would otherwise ship silently.
    var seen: [std.enums.values(Status).len][]const u8 = undefined;
    var count: usize = 0;
    for (std.enums.values(Status)) |status| {
        if (status == .failed) continue;
        model.status = status;
        const line = model.statusLine();
        try testing.expect(line.len > 0);
        for (seen[0..count]) |previous| {
            try testing.expect(!std.mem.eql(u8, previous, line));
        }
        seen[count] = line;
        count += 1;
    }

    // PLAN.md's "Status → error mapping": `.failed` always surfaces the
    // error buffer, never a canned string of its own.
    const message = "That file is 132 MB — the limit is 100 MB.";
    @memcpy(model.error_message_buffer[0..message.len], message);
    model.error_message_len = message.len;
    model.status = .failed;
    try testing.expectEqualStrings(message, model.statusLine());
}

// ============================================================ M3: effects
//
// The dialog -> stat -> thumbnail -> preview chain, driven through the fake
// executor (PLAN.md's "Testing strategy", tier 1): assert the REQUEST each
// arm made, feed the answer, drain through the same `.wake` path live
// platforms use, then assert the model. No GUI, no NSOpenPanel, no `sips`.

const App = native_sdk.UiApp(Model, Msg);

/// Where `main.thumbnail_path` points during tests. Never written to — the
/// spawn is faked and `feedImageResult` delivers a recorded terminal — but
/// it has to be non-empty, since `fx.loadImage` rejects an empty source
/// outright and the rejection would mask what the test is checking.
const test_thumbnail_path = "/tmp/smoosh-tests/preview.png";

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,

    /// Every non-M5 test's entry point: boots the app AND resolves the
    /// M5 launch-time encoder check to "both present" — the happy path —
    /// so `avifenc`/`cwebp` presence never shows up as a stray pending
    /// spawn in a test that has nothing to do with M5.
    fn create() !Harness {
        var h = try Harness.createBare();
        try h.resolveEncoders(true, true);
        return h;
    }

    /// Boots the app and stops right after install, before the M5 launch
    /// check is resolved — `avifenc`'s and `cwebp`'s presence spawns are
    /// still pending. Only M5's own tests call this directly; everything
    /// else goes through `create`.
    fn createBare() !Harness {
        main.thumbnail_path = test_thumbnail_path;

        const size = geometry.SizeF.init(main.window_width, main.window_height);
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = size });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;

        // `create`, not `init`: the Model carries three 4 KiB path buffers,
        // and a by-value Model rides the stack (native-ui's Zig-0.16 idioms).
        const app_state = try App.create(std.heap.page_allocator, .{
            .name = "smoosh",
            .scene = main.shell_scene,
            .canvas_label = main.canvas_label,
            .update_fx = main.update,
            .init_fx = main.initFx,
            .markup = .{ .source = main.app_markup, .io = testing.io },
        });
        errdefer app_state.destroy();

        // Fake BEFORE the installing frame: `init_fx`'s boot spawns (M5's
        // encoder presence check) must be RECORDED, not actually executed
        // — the same ordering `native_sdk`'s own init_fx test uses.
        app_state.effects.executor = .fake;

        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = main.canvas_label,
            .size = size,
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        try testing.expect(app_state.installed);

        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    /// Feeds M5's two boot-time presence spawns, in the order `init_fx`
    /// issued them (`avifenc` then `cwebp`), and drains once.
    fn resolveEncoders(self: *Harness, avifenc_present: bool, cwebp_present: bool) !void {
        const avifenc_req = self.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
        try testing.expectEqualStrings("avifenc", avifenc_req.argv[avifenc_req.argv.len - 1]);
        try self.fx().feedExit(avifenc_req.key, if (avifenc_present) 0 else 1);
        const cwebp_req = self.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
        try testing.expectEqualStrings("cwebp", cwebp_req.argv[cwebp_req.argv.len - 1]);
        try self.fx().feedExit(cwebp_req.key, if (cwebp_present) 0 else 1);
        try self.drain();
    }

    fn destroy(self: *Harness) void {
        self.app_state.destroy();
        self.harness.destroy(testing.allocator);
    }

    fn model(self: *Harness) *Model {
        return &self.app_state.model;
    }

    fn fx(self: *Harness) *main.Effects {
        return &self.app_state.effects;
    }

    fn send(self: *Harness, msg: Msg) !void {
        try self.app_state.dispatch(&self.harness.runtime, 1, msg);
    }

    /// Consume the pending wake requests and deliver one `.wake` for the
    /// batch — exactly how macOS marshals worker completions onto the loop.
    fn drain(self: *Harness) !void {
        var nudged = false;
        while (self.harness.null_platform.takeWake()) |_| nudged = true;
        if (nudged) try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }

    // ------------------------------------------------------------- steps
    //
    // The happy path, one fn per hop, so a test that only cares about the
    // third hop's failure can walk to it without restating the first two.

    fn pick(self: *Harness, path: []const u8) !void {
        try self.send(.pick_file);
        const request = self.fx().pendingHostAt(0) orelse return error.NoHostRequest;
        try testing.expectEqualStrings("dialog.openFile", request.name);
        try self.fx().feedHostResult(request.key, true, path);
        try self.drain();
    }

    fn stat(self: *Harness, size: []const u8) !void {
        const request = self.fx().pendingHostAt(0) orelse return error.NoHostRequest;
        try testing.expectEqualStrings("file.stat", request.name);
        try self.fx().feedHostResult(request.key, true, size);
        try self.drain();
    }

    /// M4's dimension query, fed as the standard happy-path result:
    /// well under the 50 MP limit, so the chain proceeds to the thumbnail
    /// spawn exactly as it did before M4 existed.
    fn dimensions(self: *Harness, width: u64, height: u64) !void {
        var buf: [64]u8 = undefined;
        const output = std.fmt.bufPrint(&buf, "pixelWidth: {d}|pixelHeight: {d}|", .{ width, height }) catch unreachable;
        try self.dimensionsRaw(output, 0);
    }

    /// The general form, for tests that need control over the raw `sips -g`
    /// output or a nonzero exit — e.g. the `<nil>` shape `sips` prints for
    /// a non-image file, or a genuinely failed query.
    fn dimensionsRaw(self: *Harness, output: []const u8, code: i32) !void {
        const request = self.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
        try self.fx().feedOutput(request.key, output);
        try self.fx().feedExit(request.key, code);
        try self.drain();
    }

    fn thumbnail(self: *Harness, code: i32) !void {
        const request = self.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
        try self.fx().feedExit(request.key, code);
        try self.drain();
    }

    fn preview(self: *Harness, outcome: native_sdk.EffectImageOutcome, w: u64, h: u64) !void {
        const request = self.fx().pendingImageLoadAt(0) orelse return error.NoImageLoad;
        try self.fx().feedImageResult(request.id, outcome, w, h, 0, "");
        try self.drain();
    }

    // ------------------------------------------------------ M7: encoding
    //
    // These find their request by CONTENT (argv[0], the stat payload's
    // extension) rather than by slot index, because the whole point of M7
    // is that the two encodes are independent: a test must be able to
    // answer them in EITHER order without the helper caring.

    /// The full pick chain, landing in `.ready` with a preview — the state
    /// `smoosh` requires. Dimensions and thumbnail take their happy path.
    fn load(self: *Harness, path: []const u8, size: []const u8) !void {
        try self.pick(path);
        try self.stat(size);
        try self.dimensions(4000, 3000);
        try self.thumbnail(0);
        try self.preview(.loaded, 160, 120);
    }

    /// The pending encode spawn whose argv[0] is `program`, or null.
    fn encodeSpawn(self: *Harness, program: []const u8) ?@TypeOf(self.fx().pendingSpawnAt(0).?) {
        var index: usize = 0;
        while (self.fx().pendingSpawnAt(index)) |request| : (index += 1) {
            if (std.mem.eql(u8, request.argv[0], program)) return request;
        }
        return null;
    }

    fn encodeExit(self: *Harness, program: []const u8, code: i32) !void {
        const request = self.encodeSpawn(program) orelse return error.NoSpawn;
        try self.fx().feedExit(request.key, code);
        try self.drain();
    }

    /// Answers the output-size stat for whichever format's destination path
    /// ends in `extension`.
    fn encodeSize(self: *Harness, extension: []const u8, ok: bool, size: []const u8) !void {
        var index: usize = 0;
        while (self.fx().pendingHostAt(index)) |request| : (index += 1) {
            if (std.mem.endsWith(u8, request.payload, extension)) {
                try self.fx().feedHostResult(request.key, ok, size);
                return self.drain();
            }
        }
        return error.NoHostRequest;
    }

    /// One format's whole happy path: a clean exit, then its output size.
    fn encodeOk(self: *Harness, program: []const u8, extension: []const u8, size: []const u8) !void {
        try self.encodeExit(program, 0);
        try self.encodeSize(extension, true, size);
    }
};

test "picking a file lands the real path, its size, and a preview" {
    var h = try Harness.create();
    defer h.destroy();

    const path = "/Users/someone/Pictures/photo.jpg";
    try h.pick(path);

    // The path is the REAL one from the panel, not a display string.
    try testing.expectEqualStrings(path, h.model().path());
    try testing.expectEqual(Status.loading, h.model().status);

    // ...and the stat request carries it as its payload, so the host side
    // never has to guess which file update meant.
    const stat_request = h.fx().pendingHostAt(0) orelse return error.NoHostRequest;
    try testing.expectEqualStrings("file.stat", stat_request.name);
    try testing.expectEqualStrings(path, stat_request.payload);

    try h.stat("2516582");
    try testing.expectEqual(@as(u64, 2516582), h.model().original_size);

    // M4: the dimension query is a SEPARATE `sips` call (can't combine `-g`
    // with `-s`/`-Z` in one invocation) that runs before the thumbnail spawn.
    const dims_spawn = h.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
    const expected_dims_argv = [_][]const u8{
        "/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", "-1", path,
    };
    try testing.expectEqual(expected_dims_argv.len, dims_spawn.argv.len);
    for (expected_dims_argv, dims_spawn.argv) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }
    try h.dimensions(4000, 3000);

    // The preview is a downscaled copy: `sips` reads the source and writes
    // the thumbnail `fx.loadImage` then reads. Pin the whole argv — a
    // silently reordered flag would still exit 0 on some other file.
    const spawn = h.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
    try testing.expectEqual(@as(usize, 9), spawn.argv.len);
    const expected_argv = [_][]const u8{
        "/usr/bin/sips", "-s", "format", "png", "-Z", "160", path, "--out", test_thumbnail_path,
    };
    for (expected_argv, spawn.argv) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }

    try h.thumbnail(0);

    const load = h.fx().pendingImageLoadAt(0) orelse return error.NoImageLoad;
    try testing.expectEqualStrings(test_thumbnail_path, load.path);

    try h.preview(.loaded, 160, 120);
    try testing.expectEqual(Status.ready, h.model().status);
    try testing.expect(h.model().image_id != 0);
    try testing.expect(h.model().hasPreview());
    try testing.expectEqual(@as(u32, 160), h.model().preview_width);
    try testing.expectEqual(@as(u32, 120), h.model().preview_height);
    try testing.expectEqualStrings("", h.model().errorMessage());
}

test "cancelling the dialog is not an error state" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.pick_file);
    const request = h.fx().pendingHostAt(0) orelse return error.NoHostRequest;
    try h.fx().feedHostResult(request.key, false, "cancelled");
    try h.drain();

    // Back where we started, with nothing to explain to the user.
    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().path());
    try testing.expectEqualStrings("", h.model().errorMessage());
}

test "cancelling a re-pick keeps the image already loaded" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/photo.jpg");
    try h.stat("2516582");
    try h.dimensions(4000, 3000);
    try h.thumbnail(0);
    try h.preview(.loaded, 160, 120);

    try h.send(.pick_file);
    const request = h.fx().pendingHostAt(0) orelse return error.NoHostRequest;
    try h.fx().feedHostResult(request.key, false, "cancelled");
    try h.drain();

    // `.ready`, not `.idle`: the previous image is still on screen, so
    // claiming idle would contradict what the user is looking at.
    try testing.expectEqual(Status.ready, h.model().status);
    try testing.expect(h.model().hasPreview());
}

test "an unreadable file fails, naming the file" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/locked.jpg");
    const request = h.fx().pendingHostAt(0) orelse return error.NoHostRequest;
    try h.fx().feedHostResult(request.key, false, "AccessDenied");
    try h.drain();

    try testing.expectEqual(Status.failed, h.model().status);
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "locked.jpg") != null);
    // PLAN.md's "Status → error mapping": `.failed` always surfaces the
    // error buffer through the status line, never a canned string.
    try testing.expectEqualStrings(h.model().errorMessage(), h.model().statusLine());
}

test "a non-image input fails with the supported-formats message" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/not-an-image.jpg");
    try h.stat("128");
    // `sips -g` still exits 0 on a non-image, printing literal `<nil>` for
    // both properties — confirmed against a real fixture. That must not
    // itself be treated as an error; `sips` doing the real format check at
    // the thumbnail step (next) is what should fail.
    try h.dimensionsRaw("pixelWidth: <nil>|pixelHeight: <nil>|", 0);
    // `sips` is the real format gate — a text file renamed .jpg exits nonzero.
    try h.thumbnail(1);

    try testing.expectEqual(Status.failed, h.model().status);
    const message = h.model().errorMessage();
    try testing.expect(std.mem.indexOf(u8, message, "not-an-image.jpg") != null);
    try testing.expect(std.mem.indexOf(u8, message, "JPEG") != null);
    // No preview may survive a failed decode.
    try testing.expect(!h.model().hasPreview());
}

test "a preview that will not decode fails instead of silently showing nothing" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/photo.jpg");
    try h.stat("2516582");
    try h.dimensions(4000, 3000);
    try h.thumbnail(0);
    try h.preview(.decode_failed, 0, 0);

    try testing.expectEqual(Status.failed, h.model().status);
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "photo.jpg") != null);
    try testing.expect(!h.model().hasPreview());
}

test "a stat result that is not a number fails rather than reporting 0 bytes" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/photo.jpg");
    const request = h.fx().pendingHostAt(0) orelse return error.NoHostRequest;
    try h.fx().feedHostResult(request.key, true, "not a number");
    try h.drain();

    try testing.expectEqual(Status.failed, h.model().status);
    try testing.expectEqual(@as(u64, 0), h.model().original_size);
    // A "0 B" original would make M7's savings % nonsense, so this must
    // never reach the encode path.
    try testing.expectEqual(@as(usize, 0), h.fx().pendingSpawnCount());
}

test "reset clears the file but keeps the chosen format" {
    var h = try Harness.create();
    defer h.destroy();

    h.model().format = .both;
    try h.pick("/Users/someone/Pictures/photo.jpg");
    try h.stat("2516582");
    try h.dimensions(4000, 3000);
    try h.thumbnail(0);
    try h.preview(.loaded, 160, 120);

    try h.send(.reset);

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().path());
    try testing.expectEqual(@as(u64, 0), h.model().original_size);
    try testing.expect(!h.model().hasPreview());
    // Format is a user preference, not per-file state.
    try testing.expectEqual(Format.both, h.model().format);
}

test "an effect result that lands after reset is ignored" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/photo.jpg");
    try h.stat("2516582");

    // Reset while the dimensions spawn is still in flight. Its cancel
    // delivers a terminal exit, and a later real exit could too — neither
    // may resurrect a file the user just cleared.
    try h.send(.reset);
    try h.drain();

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().path());
    try testing.expect(!h.model().hasPreview());
    try testing.expectEqual(@as(usize, 0), h.fx().pendingImageLoadCount());
}

test "a preview cancelled by reset is not reported as a broken image" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/photo.jpg");
    try h.stat("2516582");
    try h.dimensions(4000, 3000);
    try h.thumbnail(0);
    try testing.expect(h.fx().pendingImageLoadAt(0) != null);

    // Reset with the image load in flight. Cancelling it delivers a
    // terminal whose outcome is `.cancelled`, not `.loaded` — which is
    // exactly the shape of a real decode failure. Only the status guard
    // tells them apart, so without it the user gets "Couldn't build a
    // preview for photo.jpg" for pressing Reset.
    try h.send(.reset);
    try h.drain();

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().errorMessage());
    try testing.expect(!h.model().hasPreview());
}

test "reset frees the effect keys so the next pick is not rejected" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/first.jpg");
    try h.stat("100");
    try h.send(.reset);
    try h.drain();

    // A duplicate active key rejects, so if reset leaked one the second
    // pick would fail here rather than round-trip.
    try h.pick("/Users/someone/Pictures/second.jpg");
    try h.stat("200");
    try h.dimensions(4000, 3000);
    try h.thumbnail(0);
    try h.preview(.loaded, 160, 90);

    try testing.expectEqual(Status.ready, h.model().status);
    try testing.expectEqualStrings("/Users/someone/Pictures/second.jpg", h.model().path());
    try testing.expectEqual(@as(u64, 200), h.model().original_size);
}

// ============================================================ M4: limits
//
// PLAN.md's "Input size limits": 80-100MB / 40-50 megapixels, whichever
// comes first. `oversized.jpg` is the fixture that separates the two
// branches — 51.2 MP but only ~5.7 MB — so both need their own test, over
// numbers rather than a real 51 MP decode (per the testing strategy).

test "a file over the byte limit fails before any dimension query" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/huge.jpg");
    // 132 MB — over the 100 MB limit.
    try h.stat("138412032");

    try testing.expectEqual(Status.failed, h.model().status);
    const message = h.model().errorMessage();
    try testing.expect(std.mem.indexOf(u8, message, "huge.jpg") != null);
    try testing.expect(std.mem.indexOf(u8, message, "132.0 MB") != null);
    try testing.expect(std.mem.indexOf(u8, message, "100 MB") != null);
    // The byte check must short-circuit before spawning anything else —
    // an oversized file has no business being decoded even for a dimension
    // query.
    try testing.expectEqual(@as(usize, 0), h.fx().pendingSpawnCount());
}

test "a file exactly at the byte limit is not rejected" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/exactly-100mb.jpg");
    try h.stat("104857600"); // exactly 100 MB
    try testing.expectEqual(Status.loading, h.model().status);
    try testing.expectEqual(@as(usize, 1), h.fx().pendingSpawnCount());
}

test "a file under the byte limit but over the megapixel limit fails, naming the file" {
    var h = try Harness.create();
    defer h.destroy();

    // oversized.jpg's real shape: 8000x6400 = 51.2 MP, ~5.7 MB — well
    // under the byte limit, over the megapixel one. This is the case that
    // proves the two checks are independent branches.
    try h.pick("/Users/someone/Pictures/oversized.jpg");
    try h.stat("5955395");
    try testing.expectEqual(Status.loading, h.model().status);
    try h.dimensions(8000, 6400);

    try testing.expectEqual(Status.failed, h.model().status);
    const message = h.model().errorMessage();
    try testing.expect(std.mem.indexOf(u8, message, "oversized.jpg") != null);
    try testing.expect(std.mem.indexOf(u8, message, "51") != null);
    try testing.expect(std.mem.indexOf(u8, message, "50 MP") != null);
    // No thumbnail may be spawned for a file that already failed the limit.
    try testing.expectEqual(@as(usize, 0), h.fx().pendingSpawnCount());
    try testing.expect(!h.model().hasPreview());
}

test "a file exactly at the megapixel limit is not rejected" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/exactly-50mp.jpg");
    try h.stat("5000000");
    // 10000 x 5000 = 50,000,000 px = exactly 50.0 MP.
    try h.dimensions(10000, 5000);

    try testing.expectEqual(Status.loading, h.model().status);
    try testing.expectEqual(@as(usize, 1), h.fx().pendingSpawnCount());
}

test "unparseable dimensions do not block the chain — the thumbnail spawn is the real gate" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/weird.jpg");
    try h.stat("5000000");
    // A failed or garbled dimension query is not itself an error — proceed
    // to the thumbnail spawn and let `sips`'s real conversion decide.
    try h.dimensionsRaw("", 1);

    try testing.expectEqual(Status.loading, h.model().status);
    try testing.expectEqual(@as(usize, 1), h.fx().pendingSpawnCount());
    try h.thumbnail(0);
    try testing.expectEqual(@as(usize, 1), h.fx().pendingImageLoadCount());
}

test "a dimension query cancelled by reset is not reported as a broken image" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/photo.jpg");
    try h.stat("2516582");
    try testing.expect(h.fx().pendingSpawnAt(0) != null);

    // Same hazard as the thumbnail/image-load cancel tests above: cancelling
    // the in-flight dimensions spawn delivers an ordinary failed exit, which
    // must not be mistaken for a real megapixel-limit failure.
    try h.send(.reset);
    try h.drain();

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().errorMessage());
    try testing.expect(!h.model().hasPreview());
}

// ================================================== M5: encoder detection
//
// `init_fx` fires both presence checks on the installing frame, before
// `create` resolves them via `resolveEncoders` — these tests go through
// `createBare` instead, so the two spawns are still there to inspect and
// feed directly.

test "the launch-time presence check runs which against both encoders" {
    var h = try Harness.createBare();
    defer h.destroy();

    const avifenc_req = h.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
    try testing.expectEqualStrings("/usr/bin/which", avifenc_req.argv[0]);
    try testing.expectEqualStrings("avifenc", avifenc_req.argv[1]);
    try testing.expectEqual(@as(usize, 2), avifenc_req.argv.len);
    try h.fx().feedExit(avifenc_req.key, 0);

    const cwebp_req = h.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
    try testing.expectEqualStrings("/usr/bin/which", cwebp_req.argv[0]);
    try testing.expectEqualStrings("cwebp", cwebp_req.argv[1]);
    try h.fx().feedExit(cwebp_req.key, 0);
    try h.drain();

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().errorMessage());
}

test "both encoders present at launch is not an error" {
    var h = try Harness.createBare();
    defer h.destroy();

    try h.resolveEncoders(true, true);

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().errorMessage());
}

test "avifenc missing at launch fails, naming avifenc's brew install" {
    var h = try Harness.createBare();
    defer h.destroy();

    try h.resolveEncoders(false, true);

    try testing.expectEqual(Status.failed, h.model().status);
    const message = h.model().errorMessage();
    try testing.expect(std.mem.indexOf(u8, message, "avifenc") != null);
    try testing.expect(std.mem.indexOf(u8, message, "brew install libavif") != null);
    // Only the missing tool's install command belongs here — cwebp is fine.
    try testing.expect(std.mem.indexOf(u8, message, "webp") == null);
    try testing.expectEqualStrings(h.model().errorMessage(), h.model().statusLine());
}

test "cwebp missing at launch fails, naming cwebp's brew install" {
    var h = try Harness.createBare();
    defer h.destroy();

    try h.resolveEncoders(true, false);

    try testing.expectEqual(Status.failed, h.model().status);
    const message = h.model().errorMessage();
    try testing.expect(std.mem.indexOf(u8, message, "cwebp") != null);
    try testing.expect(std.mem.indexOf(u8, message, "brew install webp") != null);
    try testing.expect(std.mem.indexOf(u8, message, "libavif") == null);
}

test "both encoders missing at launch names both brew installs" {
    var h = try Harness.createBare();
    defer h.destroy();

    try h.resolveEncoders(false, false);

    try testing.expectEqual(Status.failed, h.model().status);
    const message = h.model().errorMessage();
    try testing.expect(std.mem.indexOf(u8, message, "avifenc") != null);
    try testing.expect(std.mem.indexOf(u8, message, "cwebp") != null);
    try testing.expect(std.mem.indexOf(u8, message, "brew install libavif webp") != null);
}

test "the missing-encoder failure is decided only once both checks land, in either order" {
    var h = try Harness.createBare();
    defer h.destroy();

    // cwebp answers FIRST this time — the join must not fire (or fail
    // early) on a single result, regardless of which check lands first.
    const cwebp_req = h.fx().pendingSpawnAt(1) orelse return error.NoSpawn;
    try testing.expectEqualStrings("cwebp", cwebp_req.argv[1]);
    try h.fx().feedExit(cwebp_req.key, 0);
    try h.drain();
    try testing.expectEqual(Status.idle, h.model().status);

    const avifenc_req = h.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
    try testing.expectEqualStrings("avifenc", avifenc_req.argv[1]);
    try h.fx().feedExit(avifenc_req.key, 1);
    try h.drain();

    try testing.expectEqual(Status.failed, h.model().status);
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "avifenc") != null);
}

// ==================================================== M6: format selection
//
// The chip -> `set_format:{f}` payload coercion and the `selected="{f ==
// format}"` binding are already proven at the markup level (M2a, above) —
// what M6 actually adds is `update` moving `Model.format`. `.avif` is the
// model default, so the AVIF case here also stands in as "sending your own
// current selection is a no-op."

test "set_format moves Model.format, one send per option" {
    var h = try Harness.create();
    defer h.destroy();

    try testing.expectEqual(Format.avif, h.model().format);
    for (Model.formats) |format| {
        try h.send(.{ .set_format = format });
        try testing.expectEqual(format, h.model().format);
    }
}

test "format survives picking a file, unlike the rest of the model" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .webp });
    try h.pick("/Users/someone/Pictures/photo.jpg");
    try h.stat("2516582");
    try h.dimensions(4000, 3000);
    try h.thumbnail(0);
    try h.preview(.loaded, 160, 120);

    // The pick chain touches file/preview state only; format is a
    // standing preference, not something a load can clobber.
    try testing.expectEqual(Format.webp, h.model().format);
}

// ==================================================== M7: encode pipeline
//
// The sizes below are REAL: PLAN.md's "Encoder invocations" recorded them
// by running the pinned argv against `test-images/` in M5. `large.jpg`
// (5,846,465 B) -> AVIF 717,003 / WebP 671,054; `tiny.png` (312 B) -> AVIF
// 315 (LARGER than the source) / WebP 68.

const large_jpg = "/Users/someone/Pictures/large.jpg";
const large_jpg_bytes = "5846465";

test "AVIF alone spawns the pinned avifenc argv and writes next to the source" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    try testing.expectEqual(Status.compressing, h.model().status);
    // Exactly one encode: selecting AVIF must not also run cwebp.
    try testing.expectEqual(@as(usize, 1), h.fx().pendingSpawnCount());

    const spawn = h.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
    const expected_argv = [_][]const u8{
        "avifenc",  "-q",  "58",
        "--speed",  "6",   large_jpg,
        "/Users/someone/Pictures/large.avif",
    };
    try testing.expectEqual(expected_argv.len, spawn.argv.len);
    for (expected_argv, spawn.argv) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }

    try h.encodeOk("avifenc", ".avif", "717003");

    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasAvifResult());
    try testing.expect(!h.model().hasWebpResult());
    try testing.expectEqual(@as(u64, 717003), h.model().avif_size);
    try testing.expectEqualStrings("Done.", h.model().statusLine());
}

test "WebP alone spawns the pinned cwebp argv, whose output flag is -o" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .webp });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    try testing.expectEqual(@as(usize, 1), h.fx().pendingSpawnCount());
    const spawn = h.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
    // cwebp takes its destination after `-o`, unlike avifenc's positional
    // second argument — a reordering here would silently write the wrong file.
    const expected_argv = [_][]const u8{
        "cwebp", "-q", "80", large_jpg, "-o", "/Users/someone/Pictures/large.webp",
    };
    try testing.expectEqual(expected_argv.len, spawn.argv.len);
    for (expected_argv, spawn.argv) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }

    try h.encodeOk("cwebp", ".webp", "671054");

    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasWebpResult());
    try testing.expect(!h.model().hasAvifResult());
    try testing.expectEqual(@as(u64, 671054), h.model().webp_size);
}

test "Both runs two encodes at once and joins them" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    // Concurrent, not sequential: both spawns are in flight before either
    // answers. A pipeline that chained them would show one here.
    try testing.expectEqual(@as(usize, 2), h.fx().pendingSpawnCount());

    try h.encodeOk("avifenc", ".avif", "717003");
    // One format done is not the run done.
    try testing.expectEqual(Status.compressing, h.model().status);

    try h.encodeOk("cwebp", ".webp", "671054");

    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasAvifResult());
    try testing.expect(h.model().hasWebpResult());
    try testing.expectEqualStrings("", h.model().warningMessage());
}

test "Both joins in whichever order the encoders finish" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    // cwebp answers FIRST this time. Real encoders finish in whatever order
    // the OS gives them, so the join must not depend on the spawn order.
    try h.encodeOk("cwebp", ".webp", "671054");
    try testing.expectEqual(Status.compressing, h.model().status);
    try h.encodeOk("avifenc", ".avif", "717003");

    try testing.expectEqual(Status.done, h.model().status);
    try testing.expectEqual(@as(u64, 717003), h.model().avif_size);
    try testing.expectEqual(@as(u64, 671054), h.model().webp_size);
}

// ---------------------------------------------- the partial-failure rule

test "AVIF succeeding while WebP fails is a done run that names WebP" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    try h.encodeOk("avifenc", ".avif", "717003");
    try h.encodeExit("cwebp", 1);

    // THE decision (PLAN.md's "Open decisions", settled in M7): `.done`,
    // not `.failed`. avifenc already wrote large.avif to disk — claiming
    // the run failed would contradict the file sitting next to the source.
    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasAvifResult());
    try testing.expect(!h.model().hasWebpResult());
    // The loss is never silent: the status bar is the only place the
    // missing format can be named, since it has no result line.
    const warning = h.model().warningMessage();
    try testing.expect(std.mem.indexOf(u8, warning, "WebP") != null);
    try testing.expectEqualStrings(warning, h.model().statusLine());
    // ...and the error buffer stays empty, so nothing can mistake this for
    // a failed run.
    try testing.expectEqualStrings("", h.model().errorMessage());
}

test "WebP succeeding while AVIF fails is the same rule, mirrored" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    try h.encodeExit("avifenc", 1);
    try h.encodeOk("cwebp", ".webp", "671054");

    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasWebpResult());
    try testing.expect(!h.model().hasAvifResult());
    try testing.expect(std.mem.indexOf(u8, h.model().warningMessage(), "AVIF") != null);
}

test "Both formats failing is a failed run, not a done one" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    try h.encodeExit("avifenc", 1);
    try h.encodeExit("cwebp", 1);

    // The floor under the partial-success rule: nothing landed, so nothing
    // may claim success. This also keeps PLAN.md's "`.failed` is always
    // paired with an error message" true.
    try testing.expectEqual(Status.failed, h.model().status);
    const message = h.model().errorMessage();
    try testing.expect(std.mem.indexOf(u8, message, "AVIF") != null);
    try testing.expect(std.mem.indexOf(u8, message, "WebP") != null);
    try testing.expectEqualStrings(message, h.model().statusLine());
    try testing.expect(!h.model().hasAvifResult());
    try testing.expect(!h.model().hasWebpResult());
}

test "the only selected format failing is an ordinary failed run" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeExit("avifenc", 1);

    // Single-format mode reaches the SAME branch as "both failed" — there
    // is no separate code path for it, which is the point of the rule.
    try testing.expectEqual(Status.failed, h.model().status);
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "AVIF") != null);
    // A format that was never requested must not be blamed.
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "WebP") == null);
}

// ------------------------------------------------- encoders and encoding

test "a missing encoder fails only its own format" {
    var h = try Harness.createBare();
    defer h.destroy();

    // avifenc present, cwebp absent — the machine M5 would have failed
    // outright at launch. In Both mode the AVIF half must still work.
    try h.resolveEncoders(true, false);
    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    // No point spawning a binary that is not there.
    try testing.expectEqual(@as(usize, 1), h.fx().pendingSpawnCount());
    try testing.expect(h.encodeSpawn("cwebp") == null);

    try h.encodeOk("avifenc", ".avif", "717003");

    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasAvifResult());
    try testing.expect(std.mem.indexOf(u8, h.model().warningMessage(), "brew install webp") != null);
}

test "a missing encoder for the only selected format fails, naming its brew install" {
    var h = try Harness.createBare();
    defer h.destroy();

    try h.resolveEncoders(false, true);
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    // Decided without any spawn at all, so the run is over in one dispatch.
    try testing.expectEqual(@as(usize, 0), h.fx().pendingSpawnCount());
    try testing.expectEqual(Status.failed, h.model().status);
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "brew install libavif") != null);
}

test "an encoder that exits clean without leaving a file is a write failure" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeExit("avifenc", 0);
    // The output stat is what proves the file landed — PLAN.md's "write to
    // output path failed" state has no other signal, since the encoder
    // writes its own destination.
    try h.encodeSize(".avif", false, "AccessDenied");

    try testing.expectEqual(Status.failed, h.model().status);
    const message = h.model().errorMessage();
    try testing.expect(std.mem.indexOf(u8, message, "large.jpg") != null);
    try testing.expect(std.mem.indexOf(u8, message, "permissions") != null);
    try testing.expect(!h.model().hasAvifResult());
}

test "smooshing a WebP source to WebP is skipped rather than overwriting the source" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load("/Users/someone/Pictures/photo.webp", "204800");
    try h.send(.smoosh);

    // cwebp would have been handed the same path to read AND write.
    // "Overwrite silently" (PLAN.md's Output handling) is about a previous
    // OUTPUT, never the user's source file.
    try testing.expect(h.encodeSpawn("cwebp") == null);
    try testing.expect(h.encodeSpawn("avifenc") != null);

    try h.encodeOk("avifenc", ".avif", "98304");

    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(std.mem.indexOf(u8, h.model().warningMessage(), "already a WebP") != null);
}

test "the output path replaces the source extension, not a dot in a parent directory" {
    var h = try Harness.create();
    defer h.destroy();

    // No extension on the file, and a dot in a directory above it: the
    // naive "last dot in the whole path" rule would write
    // /Users/someone/my.photos.avif and clobber a directory name.
    try h.load("/Users/someone/my.photos/holiday", "204800");
    try h.send(.smoosh);

    const spawn = h.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
    try testing.expectEqualStrings(
        "/Users/someone/my.photos/holiday.avif",
        spawn.argv[spawn.argv.len - 1],
    );
}

// ------------------------------------------------------------- reporting

test "an output larger than the source reads as larger, not a broken percentage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h = try Harness.create();
    defer h.destroy();

    // tiny.png really does grow as AVIF (312 B -> 315 B), measured in M5.
    // PLAN.md asks that this display sanely rather than as a failure.
    try h.send(.{ .set_format = .both });
    try h.load("/Users/someone/Pictures/tiny.png", "312");
    try h.send(.smoosh);
    try h.encodeOk("avifenc", ".avif", "315");
    try h.encodeOk("cwebp", ".webp", "68");

    try testing.expectEqual(Status.done, h.model().status);
    const avif_line = h.model().avifResult(arena);
    try testing.expect(std.mem.indexOf(u8, avif_line, "larger") != null);
    try testing.expect(std.mem.indexOf(u8, avif_line, "−") == null);
    // The other format compressed fine in the same run — one growing does
    // not make the run a failure, or the other line wrong.
    try testing.expect(std.mem.indexOf(u8, h.model().webpResult(arena), "−78%") != null);
}

test "formatSavings covers smaller, larger, and unchanged outputs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("−88%", main.formatSavings(arena, 5_846_465, 717_003));
    try testing.expectEqualStrings("−89%", main.formatSavings(arena, 5_846_465, 671_054));
    try testing.expectEqualStrings("+1% larger", main.formatSavings(arena, 312, 315));
    // Neither a saving nor a loss worth a number.
    try testing.expectEqualStrings("same size", main.formatSavings(arena, 1000, 1000));
    // No original size means no honest percentage to report.
    try testing.expectEqualStrings("", main.formatSavings(arena, 0, 100));
}

test "result lines render only for the formats that landed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk("avifenc", ".avif", "717003");
    try h.encodeExit("cwebp", 1);

    try testing.expectEqualStrings("AVIF  700.2 KB  −88%", h.model().avifResult(arena));
    try testing.expectEqualStrings("", h.model().webpResult(arena));

    // ...and the view agrees: exactly one result line is in the tree.
    const tree = try buildTree(arena, h.model());
    try testing.expect(findByText(tree.root, .text, "AVIF  700.2 KB  −88%") != null);
    try testing.expect(findByText(tree.root, .text, "") == null);
}

// ------------------------------------------------------ lifecycle guards

test "smooshing with no image loaded does nothing" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.smoosh);

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqual(@as(usize, 0), h.fx().pendingSpawnCount());
}

test "re-smooshing clears the previous run's results" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk("avifenc", ".avif", "717003");
    try h.encodeExit("cwebp", 1);
    try testing.expect(h.model().warning_message_len > 0);

    // "Re-running Smoosh on the same source is treated as redo this"
    // (PLAN.md's Output handling) — including redoing the format that
    // failed, and dropping the warning it left behind.
    try h.send(.smoosh);
    try testing.expectEqual(Status.compressing, h.model().status);
    try testing.expect(!h.model().hasAvifResult());
    try testing.expectEqualStrings("", h.model().warningMessage());

    try h.encodeOk("avifenc", ".avif", "717003");
    try h.encodeOk("cwebp", ".webp", "671054");
    try testing.expectEqual(Status.done, h.model().status);
    try testing.expectEqualStrings("", h.model().warningMessage());
}

test "a second Smoosh press while encoding is ignored" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.send(.smoosh);

    // A duplicate active key would be REJECTED by the effects channel, so
    // without the guard the second press would deliver a spurious failure.
    try testing.expectEqual(@as(usize, 1), h.fx().pendingSpawnCount());
    try h.encodeOk("avifenc", ".avif", "717003");
    try testing.expectEqual(Status.done, h.model().status);
}

test "an encode result that lands after reset is ignored" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    // Same hazard the load chain hit twice: cancelling the encode delivers
    // an ordinary nonzero terminal, indistinguishable from a real failure.
    try h.send(.reset);
    try h.drain();

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().errorMessage());
    try testing.expectEqualStrings("", h.model().warningMessage());
    try testing.expect(!h.model().hasAvifResult());
}

test "picking a new file clears the previous file's results" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk("avifenc", ".avif", "717003");
    try testing.expect(h.model().hasAvifResult());

    // Without the clear, the new file's "Ready to smoosh" screen would
    // still be showing the OLD file's savings line.
    try h.pick("/Users/someone/Pictures/other.jpg");
    try testing.expect(!h.model().hasAvifResult());
    try testing.expectEqual(@as(u64, 0), h.model().avif_size);

    try h.stat("204800");
    try h.dimensions(4000, 3000);
    try h.thumbnail(0);
    try h.preview(.loaded, 160, 120);
    try testing.expectEqual(Status.ready, h.model().status);
}

test "changing the format mid-encode does not change what the run produces" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    // The chips stay live while encoding, so narrow the selection to AVIF
    // while BOTH encodes are still in flight — the ordering that actually
    // exposes the hazard. The join must be driven by what was REQUESTED
    // (the per-format `.pending` outcome), never by re-reading
    // `Model.format`: a join that re-read it would call the run finished
    // the moment AVIF landed and silently drop the WebP file still on its
    // way, leaving a file on disk the UI never mentions.
    try h.send(.{ .set_format = .avif });
    try h.encodeOk("avifenc", ".avif", "717003");
    try testing.expectEqual(Status.compressing, h.model().status);

    try h.encodeOk("cwebp", ".webp", "671054");
    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasWebpResult());
}

// -------------------------------------------------------- M3: derived text

test "fileName is the last path component" {
    var model: Model = .{};
    try testing.expectEqualStrings("", model.fileName());

    const path = "/Users/someone/Pictures/holiday photo.jpg";
    @memcpy(model.path_buffer[0..path.len], path);
    model.path_len = path.len;
    try testing.expectEqualStrings("holiday photo.jpg", model.fileName());
}

test "formatBytes scales across the units the UI shows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("0 B", main.formatBytes(arena, 0));
    try testing.expectEqualStrings("512 B", main.formatBytes(arena, 512));
    try testing.expectEqualStrings("1.0 KB", main.formatBytes(arena, 1024));
    try testing.expectEqualStrings("2.4 MB", main.formatBytes(arena, 2_516_582));
}

test "fileSummary is empty with no file and names the file with one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model: Model = .{};
    try testing.expectEqualStrings("", model.fileSummary(arena));

    const path = "/Users/someone/Pictures/photo.jpg";
    @memcpy(model.path_buffer[0..path.len], path);
    model.path_len = path.len;
    model.original_size = 2_516_582;
    try testing.expectEqualStrings("photo.jpg (2.4 MB)", model.fileSummary(arena));
}

test "the preview renders only once an image is registered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model: Model = .{};
    const empty = try buildTree(arena, &model);
    try testing.expect(findByKind(empty.root, .image) == null);

    model.image_id = 4;
    model.preview_width = 160;
    model.preview_height = 120;
    const loaded = try buildTree(arena, &model);
    const image = findByKind(loaded.root, .image) orelse return error.WidgetNotFound;
    // The leaf draws the model's ImageId — the id is model data, never a
    // markup literal.
    try testing.expectEqual(@as(u64, 4), image.image_id);
    // The bound dimensions are the thumbnail's real ones, so the preview
    // keeps the source's aspect ratio instead of a hardcoded box. (Frames
    // are zero here: `finalize` builds the tree, the runtime lays it out.
    // The declared definite size is what the markup actually states.)
    try testing.expectEqual(@as(f32, 160), image.layout.max_size.width);
    try testing.expectEqual(@as(f32, 120), image.layout.max_size.height);
}
