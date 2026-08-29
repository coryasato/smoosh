//! Smoosh unit tests — the markup/model seam, exercised through the real
//! dispatch path with no GUI.
//!
//! Scope, deliberately: this file tests facts that would regress silently —
//! that `app.native` builds against the real `Model`, that every control
//! dispatches the `Msg` it claims (chip payload coercion included), that
//! `Model`'s derived accessors hold, and every `update` arm's behavior.
//! Msg-tag exhaustiveness is already a compile error via `update`'s switch,
//! so it needs no test.
//!
//! Effects-bearing paths (the load chain and the encode chain, both host
//! requests now) test through a fake executor (`fx.executor = .fake`,
//! driven by the `Harness` below), never a real process or a real dialog.
//! The exception is the encode smoke tests, which run real
//! libavif/libwebp in-process.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const imageio = @import("imageio.zig");
const encoders = @import("encoders.zig");
const chroma = @import("chroma.zig");

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

/// For icon-only controls (the per-format save buttons): no text content
/// of their own, so their accessible name lives in `semantics.label`
/// instead of `text`.
fn findByLabel(widget: canvas.Widget, kind: canvas.WidgetKind, label: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, kind, label)) |found| return found;
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

/// The drop zone has no text of its own — it is a `panel` whose bound
/// `on-press` is the only thing making it a hit target. Find it by what it
/// dispatches rather than by kind alone: the preview frame is a panel too.
fn findPanelDispatching(tree: anytype, widget: canvas.Widget, expected: std.meta.Tag(Msg)) ?canvas.Widget {
    if (widget.kind == .panel) {
        if (tree.msgForPointer(widget.id, .up)) |msg| {
            if (std.meta.activeTag(msg) == expected) return widget;
        }
    }
    for (widget.children) |child| {
        if (findPanelDispatching(tree, child, expected)) |found| return found;
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

fn expectByLabel(widget: canvas.Widget, kind: canvas.WidgetKind, label: []const u8) !canvas.Widget {
    return findByLabel(widget, kind, label) orelse {
        std.debug.print(
            "no {t} labelled \"{s}\" in the view - if you changed app.native, update this test to match\n",
            .{ kind, label },
        );
        return error.WidgetNotFound;
    };
}

/// The view splits on `hasFile`, so a test about the file card (or about
/// a control that only enables once there is something to act on) has to
/// give the model a path — the same thing `dialog_result` does live.
fn setPath(model: *Model, path: []const u8) void {
    @memcpy(model.path_buffer[0..path.len], path);
    model.path_len = path.len;
}

/// A model as it stands right after a successful pick: file, preview, and
/// `.ready`. What the empty model is to the drop zone, this is to the file
/// card.
fn readyModel() Model {
    var model: Model = .{
        .status = .ready,
        .image_id = 4,
        .preview_width = 160,
        .preview_height = 120,
        .source_width = 4000,
        .source_height = 3000,
        .original_size = 5_846_465,
    };
    setPath(&model, "/Users/someone/Pictures/photo.jpg");
    return model;
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

test "the view exposes every control update drives" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model: Model = .{};
    const tree = try buildTree(arena, &model);

    _ = try expectByText(tree.root, .button, "Smoosh");
    _ = try expectByText(tree.root, .button, "Reset");
    // One chip per Format, labelled by `Format.label` — an item-method
    // binding, so the chips read "AVIF"/"WebP"/"Both" instead of the
    // lowercase Zig tag names.
    for (Model.formats) |chip| {
        _ = try expectByText(tree.root, .toggle_button, chip.label);
    }
}

test "the empty state offers a drop zone that picks a file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // With no file the middle of the window is one big pressable target,
    // not just a button in a row. It is a `panel` with a
    // bound `on-press`, which is what makes it a hit target at all — an
    // unbound panel would swallow the click into dead space.
    var model: Model = .{};
    const empty = try buildTree(arena, &model);
    _ = try expectByText(empty.root, .text, "Drop an image here — or click to choose");
    // The copy itself is not pressable: the press falls through to the
    // nearest pressable ancestor, which is the panel.
    const zone = findPanelDispatching(empty, empty.root, .pick_file) orelse {
        std.debug.print("no panel in the empty view dispatches pick_file\n", .{});
        return error.WidgetNotFound;
    };
    try expectMsgTag(.pick_file, empty.msgForPointer(zone.id, .up));

    // ...and it is gone the moment a file lands, replaced by the file card.
    var ready = readyModel();
    const card = try buildTree(arena, &ready);
    try testing.expect(findByText(card.root, .text, "Drop an image here — or click to choose") == null);
    _ = try expectByText(card.root, .text, "photo.jpg");
}

test "Smoosh disables on exactly the guard update enforces" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Nothing picked: `.smoosh` returns on `!hasPreview`, so the view says
    // so rather than accepting a press that does nothing.
    var empty: Model = .{};
    const idle = try buildTree(arena, &empty);
    try testing.expect((try expectByText(idle.root, .button, "Smoosh")).state.disabled);

    // A picked file enables it.
    var ready = readyModel();
    const with_file = try buildTree(arena, &ready);
    try testing.expect(!(try expectByText(with_file.root, .button, "Smoosh")).state.disabled);

    // Mid-encode, it goes quiet again (the arm's own re-press guard).
    ready.status = .compressing;
    const busy = try buildTree(arena, &ready);
    try testing.expect((try expectByText(busy.root, .button, "Smoosh")).state.disabled);

    // A landed output keeps it enabled — Smoosh runs again over the same file.
    ready.status = .done;
    ready.avif_outcome = .ok;
    ready.avif_size = 717_003;
    const done = try buildTree(arena, &ready);
    try testing.expect(!(try expectByText(done.root, .button, "Smoosh")).state.disabled);
}

test "a format's save icon exists only once that format has landed, and disables mid-round" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Picked but not yet smooshed: no result, so no save icon at all —
    // there is nothing yet for it to act on.
    var ready = readyModel();
    const with_file = try buildTree(arena, &ready);
    try testing.expect(findByLabel(with_file.root, .button, "Save AVIF as…") == null);

    // AVIF lands: its icon appears and is enabled; WebP's does not exist,
    // since WebP never ran this go.
    ready.status = .done;
    ready.avif_outcome = .ok;
    ready.avif_size = 717_003;
    const avif_done = try buildTree(arena, &ready);
    try testing.expect(!(try expectByLabel(avif_done.root, .button, "Save AVIF as…")).state.disabled);
    try testing.expect(findByLabel(avif_done.root, .button, "Save WebP as…") == null);

    // Mid-save-round, BOTH landed icons go quiet — `isSaving` gates the
    // whole shared dialog/copy channel, not just the format in flight.
    ready.webp_outcome = .ok;
    ready.webp_size = 671_054;
    ready.saving = .avif;
    const mid_save = try buildTree(arena, &ready);
    try testing.expect((try expectByLabel(mid_save.root, .button, "Save AVIF as…")).state.disabled);
    try testing.expect((try expectByLabel(mid_save.root, .button, "Save WebP as…")).state.disabled);
}

test "the busy spinner tracks isBusy, not any single Status" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two statuses mean "wait", and they are reached by different chains
    // (a pick vs. an encode) — the spinner is bound to the predicate that
    // unions them, so neither can render a frozen-looking window.
    for (std.enums.values(Status)) |status| {
        var model: Model = .{ .status = status };
        const tree = try buildTree(arena, &model);
        const spinner = findByKind(tree.root, .spinner);
        try testing.expectEqual(status == .loading or status == .compressing, spinner != null);
    }
}

test "only a failed run marks the status line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every message — "Done.", a partial-success warning, and a hard
    // failure — reaches the user as the same line of text, so the alert
    // icon is the only thing separating the last from the first two.
    var done = readyModel();
    done.status = .done;
    const ok = try buildTree(arena, &done);
    try testing.expect(findByText(ok.root, .icon, "alert") == null);

    // A partial-success run is NOT a failure: it warns on the status line
    // and keeps its result lines, and marking it would say otherwise.
    const warning = "AVIF landed; WebP failed.";
    @memcpy(done.warning_message_buffer[0..warning.len], warning);
    done.warning_message_len = warning.len;
    const partial = try buildTree(arena, &done);
    try testing.expect(findByText(partial.root, .icon, "alert") == null);

    var failed = readyModel();
    failed.status = .failed;
    const bad = try buildTree(arena, &failed);
    try testing.expect(findByText(bad.root, .icon, "alert") != null);
    // And the card still names the file in the failed state — which is
    // what lets the message itself stop quoting the filename (see `fail`).
    _ = try expectByText(bad.root, .text, "photo.jpg");
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
    // really happened live: the Smoosh button took three different ids
    // across idle -> ready -> done, breaking automation scripts mid-run.
    // The `key` on each root child is what pins this, and the test above
    // cannot catch it — it only changes `status`, which alters no
    // structure.
    var empty: Model = .{};
    const before = try buildTree(arena, &empty);

    var full = readyModel();
    full.status = .done;
    full.avif_size = 717_003;
    full.avif_outcome = .ok;
    full.webp_size = 671_054;
    full.webp_outcome = .ok;
    const after = try buildTree(arena, &full);
    // Precondition: the two trees really do differ structurally, or this
    // test would pass without proving anything.
    try testing.expect(findByKind(before.root, .image) == null);
    try testing.expect(findByKind(after.root, .image) != null);

    for ([_][]const u8{ "Smoosh", "Reset" }) |label| {
        const empty_widget = try expectByText(before.root, .button, label);
        const full_widget = try expectByText(after.root, .button, label);
        try testing.expectEqual(empty_widget.id, full_widget.id);
    }
    for (Model.formats) |format| {
        const empty_chip = try expectByText(before.root, .toggle_button, format.label);
        const full_chip = try expectByText(after.root, .toggle_button, format.label);
        try testing.expectEqual(empty_chip.id, full_chip.id);
    }
}

// ---------------------------------------------------------------- dispatch

test "every control dispatches the message it claims" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A model with a file AND both formats landed, because the view
    // disables Smoosh and hides each save icon when there is nothing for
    // it to act on — and `msgForPointer` yields null for a disabled
    // control, so an empty model would prove nothing about their wiring.
    // Both formats, not just one, so a copy-paste swap between the two
    // icons' `on-press` targets would actually be caught.
    var model = readyModel();
    model.status = .done;
    model.avif_outcome = .ok;
    model.avif_size = 717_003;
    model.webp_outcome = .ok;
    model.webp_size = 671_054;
    const tree = try buildTree(arena, &model);

    const smoosh = try expectByText(tree.root, .button, "Smoosh");
    try expectMsgTag(.smoosh, tree.msgForPointer(smoosh.id, .up));

    const save_avif = try expectByLabel(tree.root, .button, "Save AVIF as…");
    try expectMsgTag(.save_avif_as, tree.msgForPointer(save_avif.id, .up));

    const save_webp = try expectByLabel(tree.root, .button, "Save WebP as…");
    try expectMsgTag(.save_webp_as, tree.msgForPointer(save_webp.id, .up));

    const reset = try expectByText(tree.root, .button, "Reset");
    try expectMsgTag(.reset, tree.msgForPointer(reset.id, .up));
}

test "each format chip coerces its own tag into the set_format payload" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model: Model = .{};
    const tree = try buildTree(arena, &model);

    // `on-toggle="set_format:{f}"` must carry the loop variable through as
    // a typed Format payload, not just fire a bare tag — `update`'s
    // `.set_format` arm relies on this exact coercion.
    for (Model.formats) |chip_source| {
        const chip = try expectByText(tree.root, .toggle_button, chip_source.label);
        const msg = tree.msgFor(chip.id, .toggle) orelse {
            std.debug.print("chip \"{s}\" dispatched nothing on toggle\n", .{chip_source.label});
            return error.NoMessageDispatched;
        };
        switch (msg) {
            .set_format => |payload| try testing.expectEqual(chip_source.value, payload),
            else => {
                std.debug.print("chip \"{s}\" dispatched {t}, not set_format\n", .{ chip_source.label, msg });
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
    // rather than uncontrolled. It reads correctly for every Format.
    for (Model.formats) |selected| {
        var model: Model = .{ .format = selected.value };
        const tree = try buildTree(arena, &model);
        for (Model.formats) |chip_source| {
            const chip = try expectByText(tree.root, .toggle_button, chip_source.label);
            try testing.expectEqual(chip_source.value == selected.value, chip.state.selected);
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
    // Sized at platform.max_dialog_path_bytes so a pick can land whatever
    // showOpenDialog returns without a resize. Pin that.
    var model: Model = .{};
    const max = model.path_buffer.len;
    try testing.expectEqual(native_sdk.platform.max_dialog_path_bytes, max);

    @memset(model.path_buffer[0..max], 'a');
    model.path_len = max;
    try testing.expectEqual(max, model.path().len);
}

test "statusLine names every Status, and .failed reports the error message" {
    var model: Model = .{};

    // Non-failed, non-idle statuses each get their own non-empty line, all
    // distinct — a copy/paste duplicate in the switch would otherwise ship
    // silently. `.idle` is deliberately blank: its copy lives on the
    // dropzone itself, not the status bar.
    var seen: [std.enums.values(Status).len][]const u8 = undefined;
    var count: usize = 0;
    for (std.enums.values(Status)) |status| {
        if (status == .failed) continue;
        model.status = status;
        const line = model.statusLine();
        if (status == .idle) {
            try testing.expectEqual(@as(usize, 0), line.len);
            continue;
        }
        try testing.expect(line.len > 0);
        for (seen[0..count]) |previous| {
            try testing.expect(!std.mem.eql(u8, previous, line));
        }
        seen[count] = line;
        count += 1;
    }

    // `.failed` always surfaces the error buffer, never a canned string
    // of its own.
    const message = "That file is 132 MB — the limit is 100 MB.";
    @memcpy(model.error_message_buffer[0..message.len], message);
    model.error_message_len = message.len;
    model.status = .failed;
    try testing.expectEqualStrings(message, model.statusLine());
}

// ==================================================================== effects
//
// The dialog -> stat -> probe -> thumbnail -> encode chain, driven through
// the fake executor: assert the REQUEST each arm made, feed the answer,
// drain through the same `.wake` path live platforms use, then assert the
// model. No GUI, no NSOpenPanel, no ImageIO, no libavif.
//
// M13 moved the load chain off spawns and onto HOST REQUESTS; M14c moved
// the encode half the same way. Nothing in the app spawns a subprocess any
// more, so every helper below drives `pendingHostAt`/`feedHostResult`.

const App = native_sdk.UiApp(Model, Msg);

/// A synthetic `image.thumbnail` answer: the same fixed-width header the
/// bridge writes, then `width * height * 4` bytes of opaque grey. Sized
/// for the largest preview the 160px cap allows, which is also what the
/// bridge's own slot holds.
var preview_reply_buffer: [16 + 160 * 160 * 4]u8 = undefined;

fn previewReply(width: u32, height: u32) []const u8 {
    const header = std.fmt.bufPrint(&preview_reply_buffer, "{d:0>5} {d:0>5}\n", .{ width, height }) catch unreachable;
    const pixels = preview_reply_buffer[header.len..][0 .. @as(usize, width) * height * 4];
    @memset(pixels, 0x80);
    return preview_reply_buffer[0 .. header.len + pixels.len];
}

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,

    /// Every test's entry point: boots the app and stops right after
    /// install. There is no launch-time work to settle any more — the
    /// encoder presence check went with the vendored encoders.
    fn create() !Harness {
        const size = geometry.SizeF.init(main.window_width, main.window_height);
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = size });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;

        // `create`, not `init`: the Model carries several 4 KiB path
        // buffers, and a by-value Model rides the stack (native-ui's
        // Zig-0.16 idioms).
        const app_state = try App.create(std.heap.page_allocator, .{
            .name = "smoosh",
            .scene = main.shell_scene,
            .canvas_label = main.canvas_label,
            .update_fx = main.update,
            .markup = .{ .source = main.app_markup, .io = testing.io },
        });
        errdefer app_state.destroy();

        // No spawns exist, but host requests still go through the fake
        // completion queue this flips on.
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

    /// `pick`'s counterpart for a real window drop — dispatches the
    /// `.dropped_file` Msg `onDrop` would have produced directly (there is
    /// no dialog round trip to answer), and starts the same load chain.
    fn drop(self: *Harness, path: []const u8) !void {
        try self.send(.{ .dropped_file = path });
        try self.drain();
    }

    fn stat(self: *Harness, size: []const u8) !void {
        const request = self.fx().pendingHostAt(0) orelse return error.NoHostRequest;
        try testing.expectEqualStrings("file.stat", request.name);
        try self.fx().feedHostResult(request.key, true, size);
        try self.drain();
    }

    /// `image.probe`'s answer, in the standard happy-path shape: a JPEG,
    /// upright, well under the 50 MP limit, so the chain proceeds to the
    /// thumbnail request.
    fn probe(self: *Harness, width: u64, height: u64) !void {
        var buf: [64]u8 = undefined;
        const reply = std.fmt.bufPrint(&buf, "{d} {d} 0 public.jpeg", .{ width, height }) catch unreachable;
        try self.probeRaw(true, reply);
    }

    /// The general form, for tests that need a failed probe (an
    /// undecodable file) or a malformed answer.
    fn probeRaw(self: *Harness, ok: bool, reply: []const u8) !void {
        const request = self.pendingHostNamed("image.probe") orelse return error.NoHostRequest;
        try self.fx().feedHostResult(request.key, ok, reply);
        try self.drain();
    }

    /// `image.thumbnail`'s answer: a real, well-formed preview reply at
    /// the given size, which `update` registers as the preview pixels.
    fn thumbnail(self: *Harness, width: u32, height: u32) !void {
        try self.thumbnailRaw(true, previewReply(width, height));
    }

    fn thumbnailRaw(self: *Harness, ok: bool, reply: []const u8) !void {
        const request = self.pendingHostNamed("image.thumbnail") orelse return error.NoHostRequest;
        try self.fx().feedHostResult(request.key, ok, reply);
        try self.drain();
    }

    // ------------------------------------------------------------ encoding
    //
    // Each format is one `image.encode` host request, payload
    // "<format>\n<source>\n<uti>\n<dest>" (see `main.encodePayload`). The
    // helpers find a request by its format line, not by slot index,
    // because the two encodes are independent and a test must be able to
    // answer them in EITHER order.

    /// The full pick chain, landing in `.ready` with a preview — the state
    /// `smoosh` requires. Dimensions and thumbnail take their happy path.
    fn load(self: *Harness, path: []const u8, size: []const u8) !void {
        try self.pick(path);
        try self.stat(size);
        try self.probe(4000, 3000);
        try self.thumbnail(160, 120);
    }

    fn encodeLabel(format: Format) []const u8 {
        return switch (format) {
            .avif => "AVIF",
            .webp => "WebP",
            .both => unreachable,
        };
    }

    /// The pending `image.encode` request for `format`, or null. Payload is
    /// NUL-delimited `"<format>\x00<source>\x00<uti>\x00<dest>"`.
    fn encodeRequest(self: *Harness, format: Format) ?@TypeOf(self.fx().pendingHostAt(0).?) {
        var buf: [8]u8 = undefined;
        const prefix = std.fmt.bufPrint(&buf, "{s}\x00", .{encodeLabel(format)}) catch unreachable;
        var index: usize = 0;
        while (self.fx().pendingHostAt(index)) |request| : (index += 1) {
            if (std.mem.eql(u8, request.name, "image.encode") and
                std.mem.startsWith(u8, request.payload, prefix)) return request;
        }
        return null;
    }

    /// The destination field of `format`'s pending `image.encode` payload —
    /// what the worker will write, and where the result line points.
    fn encodeDest(self: *Harness, format: Format) ![]const u8 {
        const request = self.encodeRequest(format) orelse return error.NoHostRequest;
        var it = std.mem.splitScalar(u8, request.payload, 0);
        _ = it.next(); // format
        _ = it.next(); // source
        _ = it.next(); // uti
        return it.rest();
    }

    /// Answer one format's `image.encode`. On success `reply` is the output
    /// size as decimal text (the worker has "written" the file); on failure
    /// it is the short tag `update` reads — "write" or "encode".
    fn encodeReply(self: *Harness, format: Format, ok: bool, reply: []const u8) !void {
        const request = self.encodeRequest(format) orelse return error.NoHostRequest;
        try self.fx().feedHostResult(request.key, ok, reply);
        try self.drain();
    }

    /// One format's happy path: the worker wrote the file, here is its size.
    fn encodeOk(self: *Harness, format: Format, size: []const u8) !void {
        try self.encodeReply(format, true, size);
    }

    // ------------------------------------------------------------ Save As
    //
    // Two host requests per round, in order: `dialog.saveFile`, then, only
    // if the dialog wasn't cancelled, `file.copy`. Found by NAME rather
    // than slot position — same discipline as the encode helpers above,
    // for the same reason: only one of these is ever pending at a time
    // (the copy is not issued until the dialog answers), but a test
    // should never rely on that as a slot-index assumption either.

    fn pendingHostNamed(self: *Harness, name: []const u8) ?@TypeOf(self.fx().pendingHostAt(0).?) {
        var index: usize = 0;
        while (self.fx().pendingHostAt(index)) |request| : (index += 1) {
            if (std.mem.eql(u8, request.name, name)) return request;
        }
        return null;
    }

    /// Answers the pending save panel. `path` is the destination the user
    /// picked; `null` is a cancel (`showSaveDialog` answering no path).
    fn saveDialog(self: *Harness, path: ?[]const u8) !void {
        const request = self.pendingHostNamed("dialog.saveFile") orelse return error.NoHostRequest;
        if (path) |p| {
            try self.fx().feedHostResult(request.key, true, p);
        } else {
            try self.fx().feedHostResult(request.key, false, "cancelled");
        }
        try self.drain();
    }

    fn saveCopy(self: *Harness, ok: bool) !void {
        const request = self.pendingHostNamed("file.copy") orelse return error.NoHostRequest;
        try self.fx().feedHostResult(request.key, ok, "");
        try self.drain();
    }

    /// One round's whole happy path: pick a destination, the copy succeeds.
    fn saveRoundOk(self: *Harness, destination: []const u8) !void {
        try self.saveDialog(destination);
        try self.saveCopy(true);
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

    // `image.probe` reads ImageIO's property dictionary and decodes
    // NOTHING, which is what lets the megapixel guard run before any
    // pixels exist. It carries the same path as its payload.
    const probe_request = h.fx().pendingHostAt(0) orelse return error.NoHostRequest;
    try testing.expectEqualStrings("image.probe", probe_request.name);
    try testing.expectEqualStrings(path, probe_request.payload);
    // Nothing is spawned anywhere in the load chain any more — the two
    // `sips` calls M13 replaced were the last of it.
    try testing.expectEqual(@as(usize, 0), h.fx().pendingSpawnCount());

    // A rotated source: the probe reports DISPLAY dimensions, so 3000x4000
    // is what the model records for a 4000x3000 file tagged Orientation 6.
    try h.probeRaw(true, "3000 4000 6 public.jpeg");
    try testing.expectEqual(@as(u32, 3000), h.model().source_width);
    try testing.expectEqual(@as(u32, 4000), h.model().source_height);
    // The container, sniffed by ImageIO rather than read off the
    // extension — M14's chroma table keys on this.
    try testing.expectEqualStrings("public.jpeg", h.model().sourceUti());

    const thumb_request = h.fx().pendingHostAt(0) orelse return error.NoHostRequest;
    try testing.expectEqualStrings("image.thumbnail", thumb_request.name);
    try testing.expectEqualStrings(path, thumb_request.payload);

    // The pixels ride the result, so this lands as a registered image
    // with no temp file and no second decode.
    try h.thumbnail(120, 160);
    try testing.expectEqual(Status.ready, h.model().status);
    try testing.expect(h.model().image_id != 0);
    try testing.expect(h.model().hasPreview());
    try testing.expectEqual(@as(u32, 120), h.model().preview_width);
    try testing.expectEqual(@as(u32, 160), h.model().preview_height);
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

    try h.load("/Users/someone/Pictures/photo.jpg", "2516582");

    try h.send(.pick_file);
    const request = h.fx().pendingHostAt(0) orelse return error.NoHostRequest;
    try h.fx().feedHostResult(request.key, false, "cancelled");
    try h.drain();

    // `.ready`, not `.idle`: the previous image is still on screen, so
    // claiming idle would contradict what the user is looking at.
    try testing.expectEqual(Status.ready, h.model().status);
    try testing.expect(h.model().hasPreview());
}

test "an unreadable file fails, and the card is what names it" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/locked.jpg");
    const request = h.fx().pendingHostAt(0) orelse return error.NoHostRequest;
    try h.fx().feedHostResult(request.key, false, "AccessDenied");
    try h.drain();

    try testing.expectEqual(Status.failed, h.model().status);
    // The filename lives in the file card, which stands in every failed
    // state — the status bar is one elided line and the quoted name
    // would crowd out the explanation. What the message still has to do
    // is explain.
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "read") != null);
    try testing.expectEqualStrings("locked.jpg", h.model().fileName());
    // `.failed` always surfaces the error buffer through the status
    // line, never a canned string.
    try testing.expectEqualStrings(h.model().errorMessage(), h.model().statusLine());
}

test "a non-image input fails with the supported-formats message" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/not-an-image.jpg");
    try h.stat("128");
    // THE PROBE is the format gate now, one hop earlier than `sips` was.
    // `imageio.probe` reports `NotAnImage` off the frame count, because
    // `CGImageSourceCreateWithURL` succeeds on 49 bytes of text named
    // `.jpg` and hands back a perfectly non-null source.
    try h.probeRaw(false, "NotAnImage");

    try testing.expectEqual(Status.failed, h.model().status);
    // Nothing was decoded: the thumbnail request is never issued.
    try testing.expectEqual(@as(usize, 0), h.fx().pendingHostCount());
    const message = h.model().errorMessage();
    // The message does not name the file — the card above it does: the
    // status bar is one elided line, and a quoted name would crowd out
    // the part that says what to do.
    try testing.expect(std.mem.indexOf(u8, message, "JPEG") != null);
    // No preview may survive a failed decode.
    try testing.expect(!h.model().hasPreview());
}

test "a new pick drops the previous file's preview before it can load" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h = try Harness.create();
    defer h.destroy();

    // The test above starts from an empty model, so it could never catch
    // this: the preview is only stale on a SECOND pick. The file card is
    // what made it visible — running live, picking not-an-image.jpg after
    // tiny.png rendered tiny.png's thumbnail beside the new file's name.
    try h.load("/Users/someone/Pictures/tiny.png", "312");
    try testing.expect(h.model().hasPreview());

    try h.pick("/Users/someone/Pictures/not-an-image.jpg");
    // Gone at the PICK, not at the failure: the whole load chain (stat,
    // probe, thumbnail) runs with the card already showing the new
    // file's name, and any of those hops can fail or simply take time.
    try testing.expect(!h.model().hasPreview());
    try testing.expectEqual(@as(u32, 0), h.model().preview_width);

    const tree = try buildTree(arena, h.model());
    _ = try expectByText(tree.root, .text, "not-an-image.jpg");
    try testing.expect(findByKind(tree.root, .image) == null);
}

test "a preview that will not decode fails instead of silently showing nothing" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/photo.jpg");
    try h.stat("2516582");
    try h.probe(4000, 3000);
    // A file whose properties read fine but whose pixels will not come
    // back — ImageIO declining to build a thumbnail from a source it
    // opened. Distinct from the probe failure above, and a different
    // sentence to the user.
    try h.thumbnailRaw(false, "NoThumbnail");

    try testing.expectEqual(Status.failed, h.model().status);
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "preview") != null);
    try testing.expect(!h.model().hasPreview());
}

test "a preview answer that is not a well-formed reply fails rather than registering junk" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/photo.jpg");
    try h.stat("2516582");
    try h.probe(4000, 3000);
    // The header says 160x120, the pixel run is one byte short. Registering
    // this would hand the canvas a buffer smaller than the dimensions it
    // was told to draw.
    const truncated = previewReply(160, 120);
    try h.thumbnailRaw(true, truncated[0 .. truncated.len - 1]);

    try testing.expectEqual(Status.failed, h.model().status);
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
    // A "0 B" original would make the savings % nonsense, so this must
    // never reach the probe, let alone the encode path.
    try testing.expectEqual(@as(usize, 0), h.fx().pendingHostCount());
    try testing.expectEqual(@as(usize, 0), h.fx().pendingSpawnCount());
}

test "reset clears the file but keeps the chosen format" {
    var h = try Harness.create();
    defer h.destroy();

    h.model().format = .both;
    try h.load("/Users/someone/Pictures/photo.jpg", "2516582");

    try h.send(.reset);

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().path());
    try testing.expectEqual(@as(u64, 0), h.model().original_size);
    try testing.expect(!h.model().hasPreview());
    // Format is a user preference, not per-file state.
    try testing.expectEqual(Format.both, h.model().format);
}

test "a probe in flight at reset is cancelled outright, not merely ignored" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/photo.jpg");
    try h.stat("2516582");
    const request = h.pendingHostNamed("image.probe") orelse return error.NoHostRequest;

    try h.send(.reset);
    try h.drain();

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().path());
    try testing.expect(!h.model().hasPreview());
    try testing.expectEqual(@as(usize, 0), h.fx().pendingHostCount());

    // This is WHY the load chain needs no status guard: a worker that
    // finishes after the reset cannot deliver at all. `cancelHostRequest`
    // released the slot, so the answer has nowhere to land.
    try testing.expectError(error.EffectNotFound, h.fx().feedHostResult(request.key, true, "4000 3000 0 public.jpeg"));
    try h.drain();
    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().errorMessage());
}

test "a preview cancelled by reset is not reported as a broken image" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/photo.jpg");
    try h.stat("2516582");
    try h.probe(4000, 3000);
    const request = h.pendingHostNamed("image.thumbnail") orelse return error.NoHostRequest;

    // Reset with the ImageIO thumbnail still decoding on its worker
    // thread. Its eventual answer must not read as "Couldn't build a
    // preview" for a file the user already cleared.
    try h.send(.reset);
    try h.drain();
    try testing.expectError(error.EffectNotFound, h.fx().feedHostResult(request.key, false, "NoThumbnail"));
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
    try h.probe(4000, 3000);
    try h.thumbnail(160, 90);

    try testing.expectEqual(Status.ready, h.model().status);
    try testing.expectEqualStrings("/Users/someone/Pictures/second.jpg", h.model().path());
    try testing.expectEqual(@as(u64, 200), h.model().original_size);
}

// ================================================================== limits
//
// 100 MB / 50 megapixels, whichever comes first. `oversized.jpg` is the
// fixture that separates the two branches — 51.2 MP but only ~5.7 MB — so
// both need their own test, over numbers rather than a real 51 MP decode.

test "a file over the byte limit fails before the file is even probed" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/huge.jpg");
    // 132 MB — over the 100 MB limit.
    try h.stat("138412032");

    try testing.expectEqual(Status.failed, h.model().status);
    const message = h.model().errorMessage();
    try testing.expect(std.mem.indexOf(u8, message, "132.0 MB") != null);
    try testing.expect(std.mem.indexOf(u8, message, "100 MB") != null);
    // The byte check must short-circuit before anything else is asked
    // for — an oversized file has no business reaching ImageIO at all.
    try testing.expectEqual(@as(usize, 0), h.fx().pendingHostCount());
}

test "a file exactly at the byte limit is not rejected" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/exactly-100mb.jpg");
    try h.stat("104857600"); // exactly 100 MB
    try testing.expectEqual(Status.loading, h.model().status);
    try testing.expect(h.pendingHostNamed("image.probe") != null);
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
    try h.probe(8000, 6400);

    try testing.expectEqual(Status.failed, h.model().status);
    const message = h.model().errorMessage();
    try testing.expect(std.mem.indexOf(u8, message, "51") != null);
    try testing.expect(std.mem.indexOf(u8, message, "50 MP") != null);
    // No decode may be asked for on a file that already failed the limit —
    // and unlike Phase A, none has happened yet either: the probe read
    // properties only.
    try testing.expectEqual(@as(usize, 0), h.fx().pendingHostCount());
    try testing.expect(!h.model().hasPreview());
}

test "a file exactly at the megapixel limit is not rejected" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/exactly-50mp.jpg");
    try h.stat("5000000");
    // 10000 x 5000 = 50,000,000 px = exactly 50.0 MP.
    try h.probe(10000, 5000);

    try testing.expectEqual(Status.loading, h.model().status);
    try testing.expect(h.pendingHostNamed("image.thumbnail") != null);
}

test "the megapixel guard measures DISPLAY dimensions, not stored ones" {
    var h = try Harness.create();
    defer h.destroy();

    // Same pixel count either way, so this is not about the limit passing
    // — it is about which numbers the card then reports. A 4000x3000 file
    // tagged Orientation 6 is a 3000x4000 image, and `imageio.probe` has
    // already applied the transform by the time `update` sees it.
    try h.pick("/Users/someone/Pictures/rotated.jpg");
    try h.stat("5000000");
    try h.probeRaw(true, "3000 4000 6 public.jpeg");

    try testing.expectEqual(@as(u32, 3000), h.model().source_width);
    try testing.expectEqual(@as(u32, 4000), h.model().source_height);
    try testing.expectEqual(Status.loading, h.model().status);
}

test "a garbled probe answer fails the load rather than proceeding blind" {
    var h = try Harness.create();
    defer h.destroy();

    // A DELIBERATE CHANGE from Phase A, where an unparseable `sips -g`
    // answer was tolerated and the thumbnail spawn was left to decide.
    // There is no second gate any more — the thumbnail is the same ImageIO
    // read — so a probe that cannot name the image's size is a file the
    // preview could not have drawn either.
    try h.pick("/Users/someone/Pictures/weird.jpg");
    try h.stat("5000000");
    try h.probeRaw(true, "");

    try testing.expectEqual(Status.failed, h.model().status);
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "JPEG") != null);
    try testing.expectEqual(@as(usize, 0), h.fx().pendingHostCount());
}

test "a zero-dimension probe answer is treated as garbled, not as a 0 MP image" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/weird.jpg");
    try h.stat("5000000");
    try h.probeRaw(true, "0 0 0 public.jpeg");

    try testing.expectEqual(Status.failed, h.model().status);
    try testing.expect(!h.model().hasPreview());
}

// ========================================================== format selection
//
// The chip -> `set_format:{f}` payload coercion and the `selected="{f ==
// format}"` binding are already proven at the markup level (above) — what's
// left is confirming `update` actually moves `Model.format`. `.both` is the
// model default, so the Both case here also stands in as "sending your own
// current selection is a no-op."

test "set_format moves Model.format, one send per option" {
    var h = try Harness.create();
    defer h.destroy();

    try testing.expectEqual(Format.both, h.model().format);
    for (Model.formats) |chip| {
        try h.send(.{ .set_format = chip.value });
        try testing.expectEqual(chip.value, h.model().format);
    }
}

test "format survives picking a file, unlike the rest of the model" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .webp });
    try h.pick("/Users/someone/Pictures/photo.jpg");
    try h.stat("2516582");
    try h.probe(4000, 3000);
    try h.thumbnail(160, 120);

    // The pick chain touches file/preview state only; format is a
    // standing preference, not something a load can clobber.
    try testing.expectEqual(Format.webp, h.model().format);
}

// =============================================================== encode pipeline
//
// The load chain lands in `.ready`; `smoosh` then issues one `image.encode`
// host request per requested format, whose worker decodes + encodes +
// writes atomically off the loop thread and replies with the output size.
// The sizes fed below are the Phase A recorded ones (`large.jpg`
// 5,846,465 B -> AVIF 717,003 / WebP 671,054), so a test asserting a size
// is asserting the model plumbs the worker's answer through unchanged.

const large_jpg = "/Users/someone/Pictures/large.jpg";
const large_jpg_bytes = "5846465";

test "AVIF alone issues one image.encode for the AVIF destination" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .avif });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    try testing.expectEqual(Status.compressing, h.model().status);
    // Exactly one encode: selecting AVIF must not also encode WebP. And
    // nothing spawns — there are no subprocesses left in the app.
    try testing.expectEqual(@as(usize, 1), h.fx().pendingHostCount());
    try testing.expectEqual(@as(usize, 0), h.fx().pendingSpawnCount());
    try testing.expect(h.encodeRequest(.webp) == null);

    const request = h.encodeRequest(.avif) orelse return error.NoHostRequest;
    try testing.expectEqualStrings("image.encode", request.name);
    // Payload: NUL-delimited "<format>\x00<source>\x00<uti>\x00<dest>".
    try testing.expectEqualStrings(
        "AVIF\x00" ++ large_jpg ++ "\x00public.jpeg\x00/Users/someone/Pictures/large.avif",
        request.payload,
    );

    try h.encodeOk(.avif, "717003");

    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasAvifResult());
    try testing.expect(!h.model().hasWebpResult());
    try testing.expectEqual(@as(u64, 717003), h.model().avif_size);
    try testing.expectEqualStrings("Done.", h.model().statusLine());
}

test "WebP alone issues one image.encode for the WebP destination" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .webp });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    try testing.expectEqual(@as(usize, 1), h.fx().pendingHostCount());
    const request = h.encodeRequest(.webp) orelse return error.NoHostRequest;
    try testing.expectEqualStrings(
        "WebP\x00" ++ large_jpg ++ "\x00public.jpeg\x00/Users/someone/Pictures/large.webp",
        request.payload,
    );

    try h.encodeOk(.webp, "671054");

    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasWebpResult());
    try testing.expect(!h.model().hasAvifResult());
    try testing.expectEqual(@as(u64, 671054), h.model().webp_size);
}

test "Both issues two image.encode requests at once and joins them" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    // Concurrent, not sequential: both requests are in flight before either
    // answers. A pipeline that chained them would show one here.
    try testing.expectEqual(@as(usize, 2), h.fx().pendingHostCount());

    try h.encodeOk(.avif, "717003");
    // One format done is not the run done.
    try testing.expectEqual(Status.compressing, h.model().status);

    try h.encodeOk(.webp, "671054");

    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasAvifResult());
    try testing.expect(h.model().hasWebpResult());
    try testing.expectEqualStrings("", h.model().warningMessage());
}

test "Both joins in whichever order the workers finish" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);

    // WebP answers FIRST this time. Real workers finish in whatever order
    // the OS gives them, so the join must not depend on request order.
    try h.encodeOk(.webp, "671054");
    try testing.expectEqual(Status.compressing, h.model().status);
    try h.encodeOk(.avif, "717003");

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

    try h.encodeOk(.avif, "717003");
    try h.encodeReply(.webp, false, "encode");

    // THE decision: `.done`, not `.failed`. avifenc already wrote
    // large.avif to disk — claiming the run failed would contradict the
    // file sitting next to the source.
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

    try h.encodeReply(.avif, false, "encode");
    try h.encodeOk(.webp, "671054");

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

    try h.encodeReply(.avif, false, "encode");
    try h.encodeReply(.webp, false, "encode");

    // The floor under the partial-success rule: nothing landed, so nothing
    // may claim success. This also keeps "`.failed` is always paired with
    // an error message" true.
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

    try h.send(.{ .set_format = .avif });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeReply(.avif, false, "encode");

    // Single-format mode reaches the SAME branch as "both failed" — there
    // is no separate code path for it, which is the point of the rule.
    try testing.expectEqual(Status.failed, h.model().status);
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "AVIF") != null);
    // A format that was never requested must not be blamed.
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "WebP") == null);
}

// ------------------------------------------------- encoders and encoding

test "an encode worker that fails the atomic write is a write failure" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .avif });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    // The worker encoded bytes but the write/rename failed — it replies
    // `ok = false` with the tag "write", which `update` maps to
    // `.write_failed` (permissions wording) rather than `.encode_failed`.
    try h.encodeReply(.avif, false, "write");

    try testing.expectEqual(Status.failed, h.model().status);
    const message = h.model().errorMessage();
    try testing.expect(std.mem.indexOf(u8, message, "AVIF") != null);
    try testing.expect(std.mem.indexOf(u8, message, "permissions") != null);
    try testing.expect(!h.model().hasAvifResult());
}

test "an encode worker that can't decode or encode is an encode failure" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .avif });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    // Any non-"write" failure tag is the generic encode failure.
    try h.encodeReply(.avif, false, "encode");

    try testing.expectEqual(Status.failed, h.model().status);
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "AVIF") != null);
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "permissions") == null);
}

test "smooshing a WebP source to WebP is skipped rather than overwriting the source" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load("/Users/someone/Pictures/photo.webp", "204800");
    try h.send(.smoosh);

    // WebP's worker would have been handed the same path to read AND
    // write. "Overwrite silently" is about a previous OUTPUT, never the
    // user's source file.
    try testing.expect(h.encodeRequest(.webp) == null);
    try testing.expect(h.encodeRequest(.avif) != null);

    try h.encodeOk(.avif, "98304");

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

    try testing.expectEqualStrings(
        "/Users/someone/my.photos/holiday.avif",
        try h.encodeDest(.avif),
    );
}

test "a source path containing a newline still parses the encode payload" {
    var h = try Harness.create();
    defer h.destroy();

    // macOS allows '\n' in a filename. The `image.encode` payload is
    // NUL-delimited precisely so a newline in the source path cannot shift
    // the fields — a '\n' delimiter would put "b.jpg" where the UTI goes.
    try h.send(.{ .set_format = .avif });
    try h.load("/Users/someone/Pictures/a\nb.jpg", "204800");
    try h.send(.smoosh);

    try testing.expectEqualStrings("/Users/someone/Pictures/a\nb.avif", try h.encodeDest(.avif));
    try h.encodeOk(.avif, "150000");
    try testing.expectEqual(Status.done, h.model().status);
}

// -------------------------------------------------------------- HEIC input
//
// HEIC used to be staged to a PNG through `sips` before the encoders could
// read it. M14c deleted that: ImageIO decodes HEIC directly in the encode
// worker, so a `.heic` source takes the exact same path as any other.

const photo_heic = "/Users/someone/Pictures/photo.heic";
const photo_heic_bytes = "2202009";

test "a HEIC source encodes directly, with no staging step" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .avif });
    try h.load(photo_heic, photo_heic_bytes);
    try h.send(.smoosh);

    try testing.expectEqual(Status.compressing, h.model().status);
    // Straight to the encode request — no `sips`, nothing spawned.
    try testing.expectEqual(@as(usize, 0), h.fx().pendingSpawnCount());
    try testing.expectEqual(@as(usize, 1), h.fx().pendingHostCount());
    try testing.expectEqualStrings(
        "/Users/someone/Pictures/photo.avif",
        try h.encodeDest(.avif),
    );

    try h.encodeOk(.avif, "204800");
    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasAvifResult());
}

test "a HEIC source whose worker can't decode fails the run" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .avif });
    try h.load(photo_heic, photo_heic_bytes);
    try h.send(.smoosh);
    try h.encodeReply(.avif, false, "encode");

    try testing.expectEqual(Status.failed, h.model().status);
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "AVIF") != null);
    try testing.expect(!h.model().hasAvifResult());
}

// ------------------------------------------------------------- reporting

test "an output larger than the source reads as larger, not a broken percentage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h = try Harness.create();
    defer h.destroy();

    // tiny.png really does grow as AVIF (312 B -> 315 B) — this must
    // display sanely rather than as a failure.
    try h.send(.{ .set_format = .both });
    try h.load("/Users/someone/Pictures/tiny.png", "312");
    try h.send(.smoosh);
    try h.encodeOk(.avif, "315");
    try h.encodeOk(.webp, "68");

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
    try h.encodeOk(.avif, "717003");
    try h.encodeReply(.webp, false, "encode");

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
    try h.encodeOk(.avif, "717003");
    try h.encodeReply(.webp, false, "encode");
    try testing.expect(h.model().warning_message_len > 0);

    // Re-running Smoosh on the same source is treated as "redo this" —
    // including redoing the format that failed, and dropping the warning
    // it left behind.
    try h.send(.smoosh);
    try testing.expectEqual(Status.compressing, h.model().status);
    try testing.expect(!h.model().hasAvifResult());
    try testing.expectEqualStrings("", h.model().warningMessage());

    try h.encodeOk(.avif, "717003");
    try h.encodeOk(.webp, "671054");
    try testing.expectEqual(Status.done, h.model().status);
    try testing.expectEqualStrings("", h.model().warningMessage());
}

test "a second Smoosh press while encoding is ignored" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .avif });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.send(.smoosh);

    // A duplicate active key would REPLACE the pending `image.encode`, so
    // without the guard the second press would swap the request out from
    // under the round already in flight.
    try testing.expectEqual(@as(usize, 1), h.fx().pendingHostCount());
    try h.encodeOk(.avif, "717003");
    try testing.expectEqual(Status.done, h.model().status);
}

test "an encode result that lands after reset is ignored" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .avif });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    const encode_key = (h.encodeRequest(.avif) orelse return error.NoHostRequest).key;

    // A cancelled host request drops its own queued answer, but a worker
    // already running still parks one — the `.encode_result` arm's own
    // `status != .compressing` guard is the backstop. Feed a stale result
    // directly to exercise it.
    try h.send(.reset);
    try h.drain();
    try h.send(.{ .encode_result = .{ .key = encode_key, .ok = true, .bytes = "717003" } });

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
    try h.encodeOk(.avif, "717003");
    try testing.expect(h.model().hasAvifResult());

    // Without the clear, the new file's "Ready to smoosh" screen would
    // still be showing the OLD file's savings line.
    try h.pick("/Users/someone/Pictures/other.jpg");
    try testing.expect(!h.model().hasAvifResult());
    try testing.expectEqual(@as(u64, 0), h.model().avif_size);

    try h.stat("204800");
    try h.probe(4000, 3000);
    try h.thumbnail(160, 120);
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
    try h.encodeOk(.avif, "717003");
    try testing.expectEqual(Status.compressing, h.model().status);

    try h.encodeOk(.webp, "671054");
    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasWebpResult());
}

// ================================================================== Save As
//
// Each landed result row carries its own save icon (`save_avif_as`/
// `save_webp_as`) rather than one button that would have to sequence two
// dialogs for "Both" — `showSaveDialog` only ever answers ONE path, but
// there is no longer a queue to answer it into: one press names one
// format, runs one dialog-then-copy round, and reports one note. A
// cancelled dialog is silent, same as `dialog_result`'s own cancel
// handling; only a copy failure is reported. Pressing either icon while a
// round is already in flight is a no-op — the two rounds never interleave.

test "saving a landed format opens one dialog defaulting to its filename" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk(.avif, "717003");

    try h.send(.save_avif_as);
    const request = h.pendingHostNamed("dialog.saveFile") orelse return error.NoHostRequest;
    // The default name is a bare filename, not the full source-relative
    // path — a save panel starts in the user's own last-used folder, not
    // wherever the auto-saved original happens to live.
    try testing.expectEqualStrings("large.avif", request.payload);

    try h.saveDialog("/Users/someone/Desktop/large.avif");
    // The copy payload is "source\ndestination" — pinned in full, since a
    // swapped order would copy the chosen destination OVER the real
    // output, backwards, and every result-based assertion here would
    // still read as a clean success.
    const copy = h.pendingHostNamed("file.copy") orelse return error.NoHostRequest;
    try testing.expectEqualStrings(
        "/Users/someone/Pictures/large.avif\n/Users/someone/Desktop/large.avif",
        copy.payload,
    );
    try h.saveCopy(true);

    try testing.expectEqualStrings("Saved AVIF.", h.model().statusLine());
    try testing.expect(!h.model().isSaving());
}

test "saving a copy does not touch the encode results" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk(.avif, "717003");
    try h.send(.save_avif_as);
    try h.saveRoundOk("/Users/someone/Desktop/large.avif");

    // Save As does not replace auto-save — the original next to the
    // source is untouched, and its size/outcome are exactly what they were.
    try testing.expect(h.model().hasAvifResult());
    try testing.expectEqual(@as(u64, 717003), h.model().avif_size);
    try testing.expectEqualStrings(large_jpg[0 .. large_jpg.len - 4] ++ ".avif", h.model().avif_path_buffer[0..h.model().avif_path_len]);
}

test "each format's icon saves independently, and the note names only the most recent one" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk(.avif, "717003");
    try h.encodeOk(.webp, "671054");

    try h.send(.save_avif_as);
    const avif_request = h.pendingHostNamed("dialog.saveFile") orelse return error.NoHostRequest;
    try testing.expectEqualStrings("large.avif", avif_request.payload);
    try h.saveRoundOk("/Users/someone/Desktop/large.avif");
    try testing.expectEqualStrings("Saved AVIF.", h.model().statusLine());

    // WebP's icon is untouched by AVIF's round having just finished — it
    // runs its own round from scratch, same as if AVIF had never saved.
    try h.send(.save_webp_as);
    const webp_request = h.pendingHostNamed("dialog.saveFile") orelse return error.NoHostRequest;
    try testing.expectEqualStrings("large.webp", webp_request.payload);
    try h.saveRoundOk("/Users/someone/Desktop/large.webp");
    // Overwritten, not appended — the note is scoped to the round that
    // just resolved, not a running log of every save this session.
    try testing.expectEqualStrings("Saved WebP.", h.model().statusLine());
}

test "cancelling a round is silent and leaves the other format's icon untouched" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk(.avif, "717003");
    try h.encodeOk(.webp, "671054");

    try h.send(.save_avif_as);
    try h.saveDialog(null); // cancel AVIF's round
    // No note for a cancel — it is a "not now", not a failure.
    try testing.expectEqualStrings("", h.model().saveMessage());
    try testing.expect(!h.model().isSaving());

    // WebP's icon works exactly as if AVIF's round never happened.
    try h.send(.save_webp_as);
    try h.saveRoundOk("/Users/someone/Desktop/large.webp");
    try testing.expectEqualStrings("Saved WebP.", h.model().statusLine());
}

test "cancelling a round leaves the status line exactly as it was" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk(.avif, "717003");
    const before = h.model().statusLine();

    try h.send(.save_avif_as);
    try h.saveDialog(null);

    try testing.expectEqualStrings(before, h.model().statusLine());
    try testing.expectEqualStrings("", h.model().saveMessage());
}

test "a copy failure is reported, and the other format's icon still works" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk(.avif, "717003");
    try h.encodeOk(.webp, "671054");

    try h.send(.save_avif_as);
    try h.saveDialog("/Volumes/Locked/large.avif");
    try h.saveCopy(false); // the destination volume is read-only

    const message = h.model().saveMessage();
    try testing.expect(std.mem.indexOf(u8, message, "AVIF") != null);
    try testing.expect(std.mem.indexOf(u8, message, "permissions") != null);
    try testing.expect(!h.model().isSaving());

    // One format's failed copy must not strand the other, unrelated icon.
    try h.send(.save_webp_as);
    try h.saveRoundOk("/Users/someone/Desktop/large.webp");
    try testing.expectEqualStrings("Saved WebP.", h.model().statusLine());
}

test "pressing a format's save icon before it has landed does nothing" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    // Ready, but never smooshed — there is no output to save.
    try h.send(.save_avif_as);
    try h.send(.save_webp_as);

    try testing.expectEqual(@as(usize, 0), h.fx().pendingHostCount());
    try testing.expectEqualStrings("", h.model().saveMessage());
}

test "pressing a save icon while a round is already in flight is ignored" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk(.avif, "717003");
    try h.encodeOk(.webp, "671054");

    try h.send(.save_avif_as);
    const before = h.pendingHostNamed("dialog.saveFile") orelse return error.NoHostRequest;
    try testing.expectEqualStrings("large.avif", before.payload);

    // A same-key re-request would just REPLACE the pending one (the
    // channel's own documented behavior), so both a stray re-press of the
    // SAME icon and a press of the OTHER icon must be refused by the
    // guard itself — without it, either would silently swap the pending
    // dialog request out from under the round already in progress.
    try h.send(.save_avif_as);
    try h.send(.save_webp_as);

    const still = h.pendingHostNamed("dialog.saveFile") orelse return error.NoHostRequest;
    try testing.expectEqualStrings("large.avif", still.payload);
    try testing.expectEqual(@as(usize, 1), h.fx().pendingHostCount());

    try h.saveRoundOk("/Users/someone/Desktop/large.avif");
    try testing.expectEqualStrings("Saved AVIF.", h.model().statusLine());

    // Now that AVIF's round has resolved, WebP's icon works normally.
    try h.send(.save_webp_as);
    try h.saveRoundOk("/Users/someone/Desktop/large.webp");
    try testing.expectEqualStrings("Saved WebP.", h.model().statusLine());
}

test "a save-dialog result with no round in progress is ignored" {
    var h = try Harness.create();
    defer h.destroy();

    // No save icon was ever pressed — `model.saving` stays null. A result
    // landing here has no legitimate source (the effects channel itself
    // cannot re-feed a key that was never issued or was already
    // consumed), but the arm's own guard is what a wrong key routing
    // would actually be caught by, so it is worth pinning directly rather
    // than trusting the channel alone.
    try h.send(.{ .save_as_dialog_result = .{ .key = 999, .ok = true, .bytes = "/tmp/x.avif" } });

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().saveMessage());
    // Without the guard this unwraps a null `model.saving` and, on
    // `ok = true`, goes on to issue a copy request nobody asked for — the
    // failure mode that actually matters, since the model-state asserts
    // above stay unchanged either way.
    try testing.expectEqual(@as(usize, 0), h.fx().pendingHostCount());
}

test "a save-copy result with no round in progress is ignored" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .save_as_result = .{ .key = 999, .ok = true, .bytes = "" } });

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().saveMessage());
}

test "pressing the same icon again after a round finishes runs a fresh round" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk(.avif, "717003");

    try h.send(.save_avif_as);
    try h.saveRoundOk("/Users/someone/Desktop/copy-one.avif");
    try testing.expectEqualStrings("Saved AVIF.", h.model().statusLine());

    // Pressing it again (saving a SECOND copy elsewhere) must work exactly
    // like the first press — `model.saving` is not left in a used-up state.
    try h.send(.save_avif_as);
    const request = h.pendingHostNamed("dialog.saveFile") orelse return error.NoHostRequest;
    try testing.expectEqualStrings("large.avif", request.payload);
    try h.saveRoundOk("/Users/someone/Desktop/copy-two.avif");
    try testing.expectEqualStrings("Saved AVIF.", h.model().statusLine());
}

test "re-smooshing clears a save note from the previous run" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .avif });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk(.avif, "717003");
    try h.send(.save_avif_as);
    try h.saveRoundOk("/Users/someone/Desktop/large.avif");
    try testing.expect(h.model().saveMessage().len > 0);

    // The note names a file this run is about to overwrite — keeping it
    // around would claim a save that describes a now-stale output.
    try h.send(.smoosh);
    try testing.expectEqualStrings("", h.model().saveMessage());
    try testing.expectEqual(Status.compressing, h.model().status);
}

test "picking a new file clears a save note from the previous file" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk(.avif, "717003");
    try h.send(.save_avif_as);
    try h.saveRoundOk("/Users/someone/Desktop/large.avif");
    try testing.expect(h.model().saveMessage().len > 0);

    try h.pick("/Users/someone/Pictures/other.jpg");
    try testing.expectEqualStrings("", h.model().saveMessage());
}

test "reset clears an in-progress save round" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk(.avif, "717003");
    try h.send(.save_avif_as);
    try testing.expect(h.pendingHostNamed("dialog.saveFile") != null);

    try h.send(.reset);

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().saveMessage());
    // `saving` is null again, so a stray late answer to the cancelled
    // dialog request has nothing to land on.
    try testing.expect(!h.model().isSaving());
}

test "reset cancels the pending save dialog, so a stray answer cannot land" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeOk(.avif, "717003");
    try h.send(.save_avif_as);
    const request = h.pendingHostNamed("dialog.saveFile") orelse return error.NoHostRequest;

    try h.send(.reset);

    // `.reset`'s `fx.cancel(save_dialog_key)` really took effect: the
    // channel refuses a late answer to the now-cancelled request outright
    // (`error.EffectNotFound`), the same guarantee the pick chain's own
    // cancel tests rely on for its keys — Save As gets it for free from
    // being wired the same way, not from a bespoke guard.
    try testing.expectError(error.EffectNotFound, h.fx().feedHostResult(request.key, true, "/Users/someone/Desktop/large.avif"));
    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().path());
}

test "the destination extension names the format, not the source's" {
    var h = try Harness.create();
    defer h.destroy();

    // A source that is itself a `.png` — its own extension must never
    // leak into the produced AVIF's default save name.
    try h.load("/Users/someone/Pictures/photo.png", "204800");
    try h.send(.smoosh);
    try h.encodeOk(.avif, "98304");
    try h.send(.save_avif_as);

    const request = h.pendingHostNamed("dialog.saveFile") orelse return error.NoHostRequest;
    try testing.expectEqualStrings("photo.avif", request.payload);
}

// -------------------------------------------------------------- derived text

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

test "originalSize is empty with no file and formats the size with one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model: Model = .{};
    try testing.expectEqualStrings("", model.originalSize(arena));

    setPath(&model, "/Users/someone/Pictures/photo.jpg");
    model.original_size = 2_516_582;
    try testing.expectEqualStrings("2.4 MB", model.originalSize(arena));
}

test "the file card names the file and its original size" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The sketch's "Original: 2.4 MB", split from the name so the name can
    // carry the visual weight. Both are derived per rebuild.
    var model = readyModel();
    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "photo.jpg");
    _ = try expectByText(tree.root, .text, "Original 5.6 MB");
}

test "a small source draws at its own size, with no clamp left to do it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Phase A needed a clamp here: `sips -Z 160` UPSCALED anything smaller
    // than 160px, so `tiny.png` (8x8) came back a 160x160 blur and the
    // drawn size had to be pulled back to the source's. ImageIO CAPS
    // instead of upscaling — measured over the whole fixture set, where
    // `tiny.png` returns 8x8 and `small.png` returns 64x64 — so the
    // registered size is already honest and the markup binds it directly.
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/tiny.png");
    try h.stat("312");
    try h.probe(8, 8);
    try h.thumbnail(8, 8);

    try testing.expectEqual(@as(u32, 8), h.model().preview_width);
    try testing.expectEqual(@as(u32, 8), h.model().preview_height);
    const tree = try buildTree(arena, h.model());
    const drawn = findByKind(tree.root, .image) orelse return error.WidgetNotFound;
    try testing.expectEqual(@as(f32, 8), drawn.layout.max_size.width);
    try testing.expectEqual(@as(f32, 8), drawn.layout.max_size.height);
}

test "the preview renders only once an image is registered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = readyModel();
    model.image_id = 0;
    const empty = try buildTree(arena, &model);
    try testing.expect(findByKind(empty.root, .image) == null);

    model.image_id = 4;
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

// ================================================================ imageio
//
// The pure half of `src/imageio.zig`, plus the wire parsers that carry its
// answers back to `update`. Both are ordinary functions over bytes, so
// they are pinned here rather than only through the dispatch path.
//
// THE IMAGEIO-CALLING HALF IS IN `src/imageio_tests.zig`, which `native
// test` also runs since M14a — the split is now just tidiness, not the
// link constraint it used to be (the test artifact linked no frameworks,
// so anything touching `imageio.probe` died on `_CFRelease`). Read that
// file's header before moving anything across.

test "parseProbeReply reads dimensions, orientation and the UTI" {
    const info = main.parseProbeReply("3000 4000 6 public.jpeg") orelse return error.NotParsed;
    try testing.expectEqual(@as(u32, 3000), info.width);
    try testing.expectEqual(@as(u32, 4000), info.height);
    try testing.expectEqual(@as(u8, 6), info.orientation);
    try testing.expectEqualStrings("public.jpeg", info.uti);

    // A source with no orientation tag reports 0, which is upright.
    const untagged = main.parseProbeReply("640 200 0 public.heic") orelse return error.NotParsed;
    try testing.expectEqual(@as(u8, 0), untagged.orientation);
    try testing.expectEqualStrings("public.heic", untagged.uti);
}

test "parseProbeReply rejects every shape that is not a probe answer" {
    try testing.expect(main.parseProbeReply("") == null);
    try testing.expect(main.parseProbeReply("4000") == null);
    try testing.expect(main.parseProbeReply("4000 3000") == null);
    try testing.expect(main.parseProbeReply("wide tall 0 public.jpeg") == null);
    // Zero dimensions would sail through the megapixel guard and then
    // collapse the preview — a garbled answer, not a 0 MP image.
    try testing.expect(main.parseProbeReply("0 3000 0 public.jpeg") == null);
    try testing.expect(main.parseProbeReply("4000 0 0 public.jpeg") == null);
    // A missing UTI is tolerated: nothing in v0.2 reads it, and losing it
    // is not worth failing a load the user can otherwise complete.
    const bare = main.parseProbeReply("64 64 0 ") orelse return error.NotParsed;
    try testing.expectEqualStrings("", bare.uti);
}

test "parsePreviewReply splits the fixed-width header from the pixels" {
    const reply = previewReply(160, 120);
    const preview = main.parsePreviewReply(reply) orelse return error.NotParsed;
    try testing.expectEqual(@as(u32, 160), preview.width);
    try testing.expectEqual(@as(u32, 120), preview.height);
    try testing.expectEqual(@as(usize, 160 * 120 * 4), preview.pixels.len);
    try testing.expectEqual(@as(u8, 0x80), preview.pixels[0]);
}

test "parsePreviewReply rejects a pixel run that does not match its header" {
    const reply = previewReply(64, 64);
    // One byte short, and one byte long: both would hand the canvas a
    // buffer that disagrees with the dimensions it was told to draw.
    try testing.expect(main.parsePreviewReply(reply[0 .. reply.len - 1]) == null);
    try testing.expect(main.parsePreviewReply(reply) != null);
    try testing.expect(main.parsePreviewReply("00064 00064") == null);
    try testing.expect(main.parsePreviewReply("") == null);
    try testing.expect(main.parsePreviewReply("00000 00000\n") == null);
}

test "swapsAxes covers exactly the four transposing EXIF orientations" {
    // 0 is "no tag at all", which is upright.
    for ([_]u8{ 0, 1, 2, 3, 4, 9, 255 }) |upright| {
        try testing.expect(!imageio.swapsAxes(upright));
    }
    for ([_]u8{ 5, 6, 7, 8 }) |transposed| {
        try testing.expect(imageio.swapsAxes(transposed));
    }
}

test "orientationTransform reproduces every EXIF orientation's pixel mapping" {
    // An INDEPENDENT check of `imageio.orientationTransform`: rather than
    // restating its table, this re-derives what the table has to mean and
    // asserts the two agree.
    //
    // The derivation: with the image drawn into `(0, 0, w, h)` under the
    // identity CTM, stored pixel (u, v) lands at user-space (u, h - v) —
    // CoreGraphics is y-UP, the stored image is y-down. Applying the
    // transform must then carry it to (X, H - Y), where (X, Y) is where
    // the EXIF spec says that pixel belongs on screen.
    //
    // `src/imageio_tests.zig` proves the same eight mappings a third way,
    // through real ImageIO decodes of tagged PNGs. This test is the one
    // that runs without a decoder and localizes a sign error to the table.
    const w = 7;
    const h = 3;
    for (1..9) |tag| {
        const orientation: u8 = @intCast(tag);
        const transform = imageio.orientationTransform(orientation, w, h);
        try testing.expectEqual(imageio.swapsAxes(orientation), transform.quarter_turn);

        const display_width: f64 = if (transform.quarter_turn) h else w;
        const display_height: f64 = if (transform.quarter_turn) w else h;

        for (0..h + 1) |v| {
            for (0..w + 1) |u| {
                // Where an identity draw would put this stored point.
                const x: f64 = @floatFromInt(u);
                const y: f64 = @as(f64, h) - @as(f64, @floatFromInt(v));

                // The transform, applied in declaration order and so
                // composed OUTERMOST-FIRST: translate . turn . scale.
                var px = x * transform.scale_x;
                var py = y * transform.scale_y;
                if (transform.quarter_turn) {
                    // +90 degrees: (x, y) -> (-y, x).
                    const swapped = px;
                    px = -py;
                    py = swapped;
                }
                px += transform.translate_x;
                py += transform.translate_y;

                // Back into display coordinates, y-down from the top.
                const display_x = px;
                const display_y = display_height - py;

                const fu: f64 = @floatFromInt(u);
                const fv: f64 = @floatFromInt(v);
                const expected: [2]f64 = switch (orientation) {
                    1 => .{ fu, fv },
                    2 => .{ w - fu, fv },
                    3 => .{ w - fu, h - fv },
                    4 => .{ fu, h - fv },
                    5 => .{ fv, fu },
                    6 => .{ h - fv, fu },
                    7 => .{ h - fv, w - fu },
                    8 => .{ fv, w - fu },
                    else => unreachable,
                };
                try testing.expectApproxEqAbs(expected[0], display_x, 1e-9);
                try testing.expectApproxEqAbs(expected[1], display_y, 1e-9);
                // The transform must land inside the destination, never
                // outside it — a sign error usually shows up here first.
                try testing.expect(display_x >= -1e-9 and display_x <= display_width + 1e-9);
                try testing.expect(display_y >= -1e-9 and display_y <= display_height + 1e-9);
            }
        }
    }
}

test "orientationTransform treats a missing or bogus tag as upright" {
    // 0 is "no EXIF at all", which is what `probe` reports for a PNG; the
    // rest are values a corrupt tag could hold. All must be identity,
    // never a rotation applied to a photo that did not ask for one.
    for ([_]u8{ 0, 1, 9, 200, 255 }) |tag| {
        const transform = imageio.orientationTransform(tag, 640, 480);
        try testing.expectEqual(@as(f64, 0), transform.translate_x);
        try testing.expectEqual(@as(f64, 0), transform.translate_y);
        try testing.expectEqual(false, transform.quarter_turn);
        try testing.expectEqual(@as(f64, 1), transform.scale_x);
        try testing.expectEqual(@as(f64, 1), transform.scale_y);
    }
}

test "unpremultiply restores straight alpha and leaves the trivial cases alone" {
    // Opaque and fully transparent pixels are already correct in both
    // conventions — the whole fixture set bar `alpha16.png`.
    var pixels = [_]u8{
        200, 100, 50, 255, // opaque: untouched
        9, 9, 9, 0, // transparent: untouched
        100, 50, 25, 128, // half-alpha: scaled back up
        255, 255, 255, 1, // extreme: must clamp, not wrap
    };
    imageio.unpremultiply(&pixels);

    try testing.expectEqualSlices(u8, &.{ 200, 100, 50, 255 }, pixels[0..4]);
    try testing.expectEqualSlices(u8, &.{ 9, 9, 9, 0 }, pixels[4..8]);
    // (100 * 255 + 64) / 128 = 199
    try testing.expectEqualSlices(u8, &.{ 199, 100, 50, 128 }, pixels[8..12]);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 1 }, pixels[12..16]);
}

// ------------------------------------------------------------------ drops
//
// `onDrop` is pure (`fn(platform.FileDropEvent) ?Msg`, no `*Model`), so it
// is tested directly with a synthetic event — no runtime, no Harness. What
// it produces is then pushed through the Harness like any other Msg, to
// prove the load chain does not care whether a path arrived via the open
// panel or a real drag.

test "onDrop turns a dropped path into a dropped_file Msg" {
    const paths = [_][]const u8{"/Users/someone/Pictures/photo.jpg"};
    const msg = main.onDrop(.{ .paths = &paths }) orelse return error.NoMsg;
    switch (msg) {
        .dropped_file => |path| try testing.expectEqualStrings("/Users/someone/Pictures/photo.jpg", path),
        else => return error.WrongMsgTag,
    }
}

test "onDrop takes the first of several dropped paths and ignores the rest" {
    // Multi-file drop: `paths` may hold more than one entry. v0.1 takes
    // the first and ignores the rest — the same single-select behaviour
    // `showOpenDialog` already has (`allow_multiple` defaults false), so a
    // drop and a pick behave alike.
    const paths = [_][]const u8{ "/a/first.jpg", "/a/second.png" };
    const msg = main.onDrop(.{ .paths = &paths }) orelse return error.NoMsg;
    switch (msg) {
        .dropped_file => |path| try testing.expectEqualStrings("/a/first.jpg", path),
        else => return error.WrongMsgTag,
    }
}

test "onDrop with no paths dispatches nothing" {
    // A drag of something with no file (e.g. dragged text) still reaches
    // this channel with an empty path list — `null` means no Msg, no
    // dispatch, per `handleRuntimeEvent`'s `.files_dropped` arm.
    try testing.expect(main.onDrop(.{ .paths = &.{} }) == null);
}

test "a real drop lands the real path, its size, and a preview" {
    var h = try Harness.create();
    defer h.destroy();

    const path = "/Users/someone/Pictures/dropped.png";
    try h.drop(path);

    // Same shape `pick`'s own first assertions check — a drop is
    // indistinguishable from a pick past `onDrop`.
    try testing.expectEqualStrings(path, h.model().path());
    try testing.expectEqual(Status.loading, h.model().status);

    try h.stat("1024");
    try h.probe(800, 600);
    try h.thumbnail(160, 120);

    try testing.expectEqual(Status.ready, h.model().status);
    try testing.expect(h.model().hasPreview());
}

test "a drop clears the previous file's results and preview, like a pick does" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load("/Users/someone/Pictures/large.jpg", "5846465");
    try h.send(.smoosh);
    try h.encodeOk(.avif, "717003");
    try testing.expect(h.model().hasAvifResult());
    try testing.expect(h.model().hasPreview());

    try h.drop("/Users/someone/Pictures/tiny.png");
    try testing.expectEqualStrings("/Users/someone/Pictures/tiny.png", h.model().path());
    try testing.expect(!h.model().hasAvifResult());
    try testing.expect(!h.model().hasPreview());
}

// ---------------------------------------------------------------------
// The vendored encoders: M14a wired the archives, M14c calls them.
//
// The version probes pin what the Phase A baseline was measured against,
// so a re-copied archive cannot change the encoder out from under
// `docs/phase-b-baseline.md` without a test going red. That they run HERE,
// in the test artifact, is half the link proof: `tests.root_module` is a
// separate Debug module that inherits nothing from the exe's, and wiring
// only the exe is the mistake this catches.
//
// The encode smoke tests run REAL libavif/libaom/libwebp in-process — the
// encode seam links and produces a well-formed container. Byte-level
// parity against Phase A is a separate exercise (`docs/phase-b-baseline.md`,
// "M14c"), not a unit test.

test "libwebp links, at the version the baseline was measured against" {
    try testing.expectEqual(encoders.pinned.libwebp, encoders.libwebpVersion());
}

test "libavif links, at the version the baseline was measured against" {
    try testing.expectEqualStrings(encoders.pinned.libavif, encoders.libavifVersion());
}

test "libaom links, at the version the baseline was measured against" {
    try testing.expectEqualStrings(encoders.pinned.libaom, encoders.libaomVersion());
}

/// A small opaque RGBA gradient — enough to exercise the RGB->YUV path and
/// the container muxer without depending on a gitignored fixture.
fn rgbaGradient(buffer: []u8, width: u32, height: u32) []u8 {
    var index: usize = 0;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            buffer[index + 0] = @intCast((x * 255) / width);
            buffer[index + 1] = @intCast((y * 255) / height);
            buffer[index + 2] = @intCast((x + y) & 0xFF);
            buffer[index + 3] = 255;
            index += 4;
        }
    }
    return buffer[0..index];
}

test "encodeAvif produces a well-formed AVIF container" {
    var buffer: [32 * 32 * 4]u8 = undefined;
    const pixels = rgbaGradient(&buffer, 32, 32);

    var encoded = try encoders.encodeAvif(pixels, 32, 32, .yuv444);
    defer encoded.deinit();

    try testing.expect(encoded.bytes.len > 0);
    // Every AVIF opens with an ftyp box whose major brand is "avif".
    try testing.expectEqualStrings("ftypavif", encoded.bytes[4..12]);
}

test "encodeWebp produces a well-formed WebP container" {
    var buffer: [32 * 32 * 4]u8 = undefined;
    const pixels = rgbaGradient(&buffer, 32, 32);

    var encoded = try encoders.encodeWebp(pixels, 32, 32);
    defer encoded.deinit();

    try testing.expect(encoded.bytes.len > 0);
    try testing.expectEqualStrings("RIFF", encoded.bytes[0..4]);
    try testing.expectEqualStrings("WEBP", encoded.bytes[8..12]);
}

test "encodeAvif honours the requested chroma subsampling" {
    var buffer: [32 * 32 * 4]u8 = undefined;
    const pixels = rgbaGradient(&buffer, 32, 32);

    // 4:2:0 drops chroma resolution, so on the same input it must not
    // produce byte-identical output to 4:4:4 — a cheap check that the
    // `yuv_format` argument reaches libavif at all.
    var a = try encoders.encodeAvif(pixels, 32, 32, .yuv444);
    defer a.deinit();
    var b = try encoders.encodeAvif(pixels, 32, 32, .yuv420);
    defer b.deinit();
    try testing.expect(!std.mem.eql(u8, a.bytes, b.bytes));
}

// ================================================================= chroma
//
// M14b: reproducing `avifenc --yuv auto` from the source container, which
// is the one thing decoding to RGBA would otherwise destroy. The expected
// values below are not invented — every one is the `AVIF yuv` column
// `docs/phase-b-baseline.md` measured on the real fixture, so a change
// here is a change against the shipped v0.1 output.
//
// The JPEG headers are synthesized rather than read from `test-images/`
// (gitignored). Only the marker structure matters to the parser, so a
// header with no scan data in it exercises exactly the same code the real
// 5.8 MB fixture does.

/// A JPEG up to and including its SOF0, with `components` components and
/// the first one sampled `h` x `v`. Everything after SOF is scan data the
/// parser never reaches.
fn jpegHeader(buffer: []u8, components: u8, h: u4, v: u4) []const u8 {
    var length: usize = 0;
    const put = struct {
        fn f(buf: []u8, at: *usize, bytes: []const u8) void {
            @memcpy(buf[at.*..][0..bytes.len], bytes);
            at.* += bytes.len;
        }
    }.f;

    put(buffer, &length, "\xff\xd8"); // SOI
    // An APP0/JFIF segment, so the parser has to skip a length-carrying
    // marker to reach SOF rather than finding it immediately.
    put(buffer, &length, "\xff\xe0\x00\x10JFIF\x00\x01\x02\x00\x00\x01\x00\x01\x00\x00");

    const payload_len: u16 = 8 + 3 * @as(u16, components);
    put(buffer, &length, "\xff\xc0");
    std.mem.writeInt(u16, buffer[length..][0..2], payload_len, .big);
    length += 2;
    put(buffer, &length, &.{ 8, 0x00, 0x40, 0x00, 0x40, components }); // precision, 64x64
    for (0..components) |index| {
        const factors: u8 = if (index == 0) (@as(u8, h) << 4) | v else 0x11;
        put(buffer, &length, &.{ @intCast(index + 1), factors, 0 });
    }
    put(buffer, &length, "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00"); // SOS
    return buffer[0..length];
}

test "parseJpegSampling reads the chroma format Phase A measured, per fixture" {
    var buffer: [64]u8 = undefined;

    // `large.jpg` and `rotated-gps.jpg`: photographs, and 4:4:4 anyway
    // because the JPEG itself is 1x1,1x1,1x1. THE fixture that proves the
    // table reads the source instead of assuming 4:2:0.
    try testing.expectEqual(chroma.Subsampling.yuv444, chroma.parseJpegSampling(jpegHeader(&buffer, 3, 1, 1)));
    // `photo-420.jpg` and `ui.jpg`: the common JPEG path.
    try testing.expectEqual(chroma.Subsampling.yuv420, chroma.parseJpegSampling(jpegHeader(&buffer, 3, 2, 2)));
    // 4:2:2 — no fixture, but libavif reads it and so must we.
    try testing.expectEqual(chroma.Subsampling.yuv422, chroma.parseJpegSampling(jpegHeader(&buffer, 3, 2, 1)));
    // `gray.jpg`: one component is monochrome, measured as YUV400.
    try testing.expectEqual(chroma.Subsampling.yuv400, chroma.parseJpegSampling(jpegHeader(&buffer, 1, 1, 1)));

    // 4:4:0 (1x2) and 4:1:1 (4x1) have no AVIF equivalent. libavif's own
    // reader falls through to the default for exactly these, and 4:4:4 is
    // that default — the choice that cannot lose chroma detail.
    try testing.expectEqual(chroma.Subsampling.yuv444, chroma.parseJpegSampling(jpegHeader(&buffer, 3, 1, 2)));
    try testing.expectEqual(chroma.Subsampling.yuv444, chroma.parseJpegSampling(jpegHeader(&buffer, 3, 4, 1)));
}

test "parseJpegSampling refuses anything that is not a JPEG frame" {
    try testing.expect(chroma.parseJpegSampling("") == null);
    try testing.expect(chroma.parseJpegSampling("\x89PNG\r\n\x1a\n") == null);
    // `not-an-image.jpg` in the fixture set: 49 bytes of text.
    try testing.expect(chroma.parseJpegSampling("this is not an image, whatever the extension says") == null);

    // SOI, then a segment whose length runs off the end of what we were
    // given — a JPEG truncated inside its own EXIF, which is what reading
    // only the head of a file can produce.
    try testing.expect(chroma.parseJpegSampling("\xff\xd8\xff\xe1\x7f\xff\x00") == null);
    // SOI straight into the scan: a JPEG with no frame header at all.
    try testing.expect(chroma.parseJpegSampling("\xff\xd8\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00") == null);
    // A DHT (0xC4) sits inside the SOFn range but is NOT a frame header.
    // Reading it as one would take a Huffman table for sampling factors.
    try testing.expect(chroma.parseJpegSampling("\xff\xd8\xff\xc4\x00\x04\x00\x00") == null);
}

test "parseJpegSampling walks past restart markers and fill bytes" {
    // Both are legal between segments and neither carries a length: a
    // parser that reads two length bytes after them desyncs and returns
    // garbage rather than null, which is the worse failure.
    var buffer: [64]u8 = undefined;
    const header = jpegHeader(&buffer, 3, 2, 2);

    var padded: [80]u8 = undefined;
    @memcpy(padded[0..2], header[0..2]); // SOI
    @memcpy(padded[2..5], "\xff\xd0\xff"); // RST0, then a fill byte
    @memcpy(padded[5..][0 .. header.len - 2], header[2..]);
    try testing.expectEqual(
        chroma.Subsampling.yuv420,
        chroma.parseJpegSampling(padded[0 .. 5 + header.len - 2]),
    );
}

test "forSource keys on the UTI and reads the file only for a JPEG" {
    var buffer: [64]u8 = undefined;
    const jpeg_420 = jpegHeader(&buffer, 3, 2, 2);

    // Every non-JPEG container is 4:4:4, and the bytes are not even looked
    // at — `ui.png` is 4:4:4 while the SAME image as `ui.jpg` is 4:2:0,
    // which is the whole point of keying on the container.
    for ([_][]const u8{ "public.png", "public.heic", "public.tiff", "com.compuserve.gif", "org.webmproject.webp" }) |uti| {
        try testing.expectEqual(chroma.Subsampling.yuv444, chroma.forSource(uti, ""));
        try testing.expectEqual(chroma.Subsampling.yuv444, chroma.forSource(uti, jpeg_420));
    }

    try testing.expectEqual(chroma.Subsampling.yuv420, chroma.forSource("public.jpeg", jpeg_420));
    try testing.expectEqual(
        chroma.Subsampling.yuv444,
        chroma.forSource("public.jpeg", jpegHeader(&buffer, 3, 1, 1)),
    );

    // An unparseable JPEG falls back to 4:4:4, not to 4:2:0: we cannot
    // reproduce `avifenc` on it either way, and of the two guesses only
    // one is incapable of losing chroma detail.
    try testing.expectEqual(chroma.Subsampling.yuv444, chroma.forSource("public.jpeg", ""));
}
