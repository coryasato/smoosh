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
//! Effects-bearing paths (the dialog chain, encoder detection, encoding)
//! test through a fake executor (`fx.executor = .fake`, driven by the
//! `Harness` below), never a real process or a real dialog.

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

// ================================================================ packaging
//
// A packaged `.app` launched from `/Applications` fails the encoder
// presence check even with avifenc/cwebp installed, because Finder/Dock-
// launched processes inherit launchd's minimal PATH, not the
// interactive-shell PATH `brew shellenv` adds — the exact opposite of every
// `native dev`/`native build` run, which is always launched from a Terminal.
// `resolveSpawnEnviron` is pure enough to test directly: build a fake
// `Environ` with a chosen PATH, no process or spawn involved.

fn testEnviron(gpa: std.mem.Allocator, path: ?[]const u8) !std.process.Environ {
    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    if (path) |value| try map.put("PATH", value);
    return .{ .block = try map.createPosixBlock(gpa, .{}) };
}

test "resolveSpawnEnviron appends Homebrew's bin dirs when PATH lacks them" {
    const gpa = testing.allocator;
    const base = try testEnviron(gpa, "/usr/bin:/bin");
    defer base.block.deinit(gpa);

    const resolved = try main.resolveSpawnEnviron(gpa, base);
    defer resolved.block.deinit(gpa);

    const path = std.process.Environ.getPosix(resolved, "PATH").?;
    try testing.expect(std.mem.indexOf(u8, path, "/opt/homebrew/bin") != null);
    try testing.expect(std.mem.indexOf(u8, path, "/usr/bin:/bin") != null);
}

test "resolveSpawnEnviron leaves PATH untouched when Homebrew's bin is already present" {
    const gpa = testing.allocator;
    const base = try testEnviron(gpa, "/opt/homebrew/bin:/usr/bin");
    defer base.block.deinit(gpa);

    const resolved = try main.resolveSpawnEnviron(gpa, base);

    // No new block was built — `resolveSpawnEnviron` returned `base` itself,
    // proven by pointer identity, not just equal content (a mutation that
    // always reallocates would still pass a content-only check).
    try testing.expectEqual(base.block.slice.ptr, resolved.block.slice.ptr);
}

test "resolveSpawnEnviron sets PATH from scratch when the base environ has none" {
    const gpa = testing.allocator;
    const base = try testEnviron(gpa, null);
    defer base.block.deinit(gpa);

    const resolved = try main.resolveSpawnEnviron(gpa, base);
    defer resolved.block.deinit(gpa);

    const path = std.process.Environ.getPosix(resolved, "PATH").?;
    try testing.expectEqualStrings(
        "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin",
        path,
    );
}

// ==================================================================== effects
//
// The dialog -> stat -> thumbnail -> preview chain, driven through the fake
// executor: assert the REQUEST each arm made, feed the answer, drain
// through the same `.wake` path live platforms use, then assert the
// model. No GUI, no NSOpenPanel, no `sips`.

const App = native_sdk.UiApp(Model, Msg);

/// Where `main.thumbnail_path` points during tests. Never written to — the
/// spawn is faked and `feedImageResult` delivers a recorded terminal — but
/// it has to be non-empty, since `fx.loadImage` rejects an empty source
/// outright and the rejection would mask what the test is checking.
const test_thumbnail_path = "/tmp/smoosh-tests/preview.png";

/// `test_thumbnail_path`'s counterpart — where `main.converted_path`
/// points during tests. Same reasoning: the staging spawn is faked, but the
/// path still flows into a real encode spawn's argv, which tests assert on.
const test_converted_path = "/tmp/smoosh-tests/converted.png";

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,

    /// Most tests' entry point: boots the app AND resolves the launch-time
    /// encoder check to "both present" — the happy path — so
    /// `avifenc`/`cwebp` presence never shows up as a stray pending spawn
    /// in a test that has nothing to do with encoder detection.
    fn create() !Harness {
        var h = try Harness.createBare();
        try h.resolveEncoders(true, true);
        return h;
    }

    /// Boots the app and stops right after install, before the launch-time
    /// encoder check is resolved — `avifenc`'s and `cwebp`'s presence
    /// spawns are still pending. Only the encoder-detection tests call
    /// this directly; everything else goes through `create`.
    fn createBare() !Harness {
        main.thumbnail_path = test_thumbnail_path;
        main.converted_path = test_converted_path;

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

        // Fake BEFORE the installing frame: `init_fx`'s boot spawns (the
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

    /// Feeds the two boot-time presence spawns, in the order `init_fx`
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

    /// The dimension query, fed as the standard happy-path result: well
    /// under the 50 MP limit, so the chain proceeds to the thumbnail spawn.
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

    // ------------------------------------------------------------ encoding
    //
    // These find their request by CONTENT (argv[0], the stat payload's
    // extension) rather than by slot index, because the two encodes are
    // independent: a test must be able to answer them in EITHER order
    // without the helper caring.

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

    /// The HEIC->PNG staging spawn — ONE per run regardless of how many
    /// formats were requested, unlike the per-format encode spawns above.
    fn convertExit(self: *Harness, code: i32) !void {
        const request = self.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
        try self.fx().feedExit(request.key, code);
        try self.drain();
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

    // The dimension query is a SEPARATE `sips` call (can't combine `-g`
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
    // `sips -g` still exits 0 on a non-image, printing literal `<nil>` for
    // both properties — confirmed against a real fixture. That must not
    // itself be treated as an error; `sips` doing the real format check at
    // the thumbnail step (next) is what should fail.
    try h.dimensionsRaw("pixelWidth: <nil>|pixelHeight: <nil>|", 0);
    // `sips` is the real format gate — a text file renamed .jpg exits nonzero.
    try h.thumbnail(1);

    try testing.expectEqual(Status.failed, h.model().status);
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
    // dimensions, thumbnail) runs with the card already showing the new
    // file's name, and any of those hops can fail or simply take time.
    try testing.expect(!h.model().hasPreview());
    try testing.expectEqual(@as(u32, 0), h.model().previewWidth());

    const tree = try buildTree(arena, h.model());
    _ = try expectByText(tree.root, .text, "not-an-image.jpg");
    try testing.expect(findByKind(tree.root, .image) == null);
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
    try testing.expect(std.mem.indexOf(u8, h.model().errorMessage(), "preview") != null);
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

// ================================================================== limits
//
// 100 MB / 50 megapixels, whichever comes first. `oversized.jpg` is the
// fixture that separates the two branches — 51.2 MP but only ~5.7 MB — so
// both need their own test, over numbers rather than a real 51 MP decode.

test "a file over the byte limit fails before any dimension query" {
    var h = try Harness.create();
    defer h.destroy();

    try h.pick("/Users/someone/Pictures/huge.jpg");
    // 132 MB — over the 100 MB limit.
    try h.stat("138412032");

    try testing.expectEqual(Status.failed, h.model().status);
    const message = h.model().errorMessage();
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

// ============================================================== encoder detection
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
    try h.dimensions(4000, 3000);
    try h.thumbnail(0);
    try h.preview(.loaded, 160, 120);

    // The pick chain touches file/preview state only; format is a
    // standing preference, not something a load can clobber.
    try testing.expectEqual(Format.webp, h.model().format);
}

// =============================================================== encode pipeline
//
// The sizes below are REAL: recorded by running the pinned argv against
// `test-images/`. `large.jpg` (5,846,465 B) -> AVIF 717,003 / WebP
// 671,054; `tiny.png` (312 B) -> AVIF 315 (LARGER than the source) / WebP
// 68.

const large_jpg = "/Users/someone/Pictures/large.jpg";
const large_jpg_bytes = "5846465";

test "AVIF alone spawns the pinned avifenc argv and writes next to the source" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .avif });
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

    // avifenc present, cwebp absent — the launch-time check would have
    // failed outright. In Both mode the AVIF half must still work.
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
    try h.send(.{ .set_format = .avif });
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

    try h.send(.{ .set_format = .avif });
    try h.load(large_jpg, large_jpg_bytes);
    try h.send(.smoosh);
    try h.encodeExit("avifenc", 0);
    // The output stat is what proves the file landed — the "write to
    // output path failed" state has no other signal, since the encoder
    // writes its own destination.
    try h.encodeSize(".avif", false, "AccessDenied");

    try testing.expectEqual(Status.failed, h.model().status);
    const message = h.model().errorMessage();
    try testing.expect(std.mem.indexOf(u8, message, "AVIF") != null);
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
    // "Overwrite silently" is about a previous OUTPUT, never the user's
    // source file.
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

// -------------------------------------------------------------- HEIC input
//
// `avifenc`/`cwebp` reject HEIC as an INPUT format outright (confirmed
// live), even though `sips` decodes it fine for the preview. `smoosh`
// routes a HEIC/HEIF source through ONE shared `sips`-to-PNG staging spawn
// first; both encoders then read the staged PNG instead of the original
// file.

const photo_heic = "/Users/someone/Pictures/photo.heic";
const photo_heic_bytes = "2202009";

test "isHeicSource matches .heic/.heif case-insensitively and nothing else" {
    try testing.expect(main.isHeicSource("photo.heic"));
    try testing.expect(main.isHeicSource("/a/b/PHOTO.HEIC"));
    try testing.expect(main.isHeicSource("photo.heif"));
    try testing.expect(main.isHeicSource("photo.HEIF"));
    try testing.expect(!main.isHeicSource("photo.jpg"));
    try testing.expect(!main.isHeicSource("photo"));
    try testing.expect(!main.isHeicSource(""));
    // A dot in a parent directory, no extension of its own — the same
    // hazard `outputPath` guards against, checked here too.
    try testing.expect(!main.isHeicSource("/a/my.photos/holiday"));
}

test "a HEIC source stages a sips conversion before either encoder runs" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .avif });
    try h.load(photo_heic, photo_heic_bytes);
    try h.send(.smoosh);

    try testing.expectEqual(Status.compressing, h.model().status);
    // The staging spawn only — the encoder has not started yet.
    try testing.expectEqual(@as(usize, 1), h.fx().pendingSpawnCount());
    const spawn = h.fx().pendingSpawnAt(0) orelse return error.NoSpawn;
    const expected_argv = [_][]const u8{
        "/usr/bin/sips", "-s", "format", "png", photo_heic, "--out", test_converted_path,
    };
    try testing.expectEqual(expected_argv.len, spawn.argv.len);
    for (expected_argv, spawn.argv) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }

    try h.convertExit(0);

    // Now the real encode is pending, reading the STAGED path but writing
    // next to the ORIGINAL source — never a file named after the staging
    // file.
    const encode = h.encodeSpawn("avifenc") orelse return error.NoSpawn;
    const expected_encode_argv = [_][]const u8{
        "avifenc",          "-q",     "58", "--speed",
        "6",                 test_converted_path,
        "/Users/someone/Pictures/photo.avif",
    };
    try testing.expectEqual(expected_encode_argv.len, encode.argv.len);
    for (expected_encode_argv, encode.argv) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }

    try h.encodeOk("avifenc", ".avif", "204800");
    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasAvifResult());
}

test "Both formats share one HEIC conversion spawn, not one each" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(photo_heic, photo_heic_bytes);
    try h.send(.smoosh);

    // ONE staging spawn for the whole run, not one per requested format.
    try testing.expectEqual(@as(usize, 1), h.fx().pendingSpawnCount());
    try h.convertExit(0);

    // Both encodes now pending, both reading the staged path.
    try testing.expectEqual(@as(usize, 2), h.fx().pendingSpawnCount());
    const avif = h.encodeSpawn("avifenc") orelse return error.NoSpawn;
    const webp = h.encodeSpawn("cwebp") orelse return error.NoSpawn;
    try testing.expectEqualStrings(test_converted_path, avif.argv[avif.argv.len - 2]);
    try testing.expectEqualStrings(test_converted_path, webp.argv[webp.argv.len - 3]);

    try h.encodeOk("avifenc", ".avif", "204800");
    try h.encodeOk("cwebp", ".webp", "184320");
    try testing.expectEqual(Status.done, h.model().status);
    try testing.expect(h.model().hasAvifResult());
    try testing.expect(h.model().hasWebpResult());
}

test "a failed HEIC conversion fails the run without ever spawning the encoder" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(photo_heic, photo_heic_bytes);
    try h.send(.smoosh);
    try h.convertExit(1);

    try testing.expectEqual(Status.failed, h.model().status);
    try testing.expectEqualStrings(
        "Couldn't prepare that HEIC file for encoding.",
        h.model().errorMessage(),
    );
    try testing.expectEqual(@as(usize, 0), h.fx().pendingSpawnCount());
    try testing.expect(!h.model().hasAvifResult());
}

test "a failed HEIC conversion in Both mode fails once, not with a doubled message" {
    var h = try Harness.create();
    defer h.destroy();

    try h.send(.{ .set_format = .both });
    try h.load(photo_heic, photo_heic_bytes);
    try h.send(.smoosh);
    try h.convertExit(1);

    try testing.expectEqual(Status.failed, h.model().status);
    // The staging failure is ONE shared cause, not two independent encoder
    // failures — the message must not repeat itself the way the per-format
    // join would for two genuinely different failures.
    try testing.expectEqualStrings(
        "Couldn't prepare that HEIC file for encoding.",
        h.model().errorMessage(),
    );
}

test "a HEIC conversion result that lands after reset is ignored" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load(photo_heic, photo_heic_bytes);
    try h.send(.smoosh);
    const staging_key = (h.fx().pendingSpawnAt(0) orelse return error.NoSpawn).key;

    try h.send(.reset);
    try h.drain();
    try testing.expectEqual(Status.idle, h.model().status);

    // The real hazard: a stale terminal for the CANCELLED staging spawn
    // arriving anyway (a race the effects channel itself does not fully
    // close — same reasoning as the pre-existing `.encode_result` guard).
    // Dispatched directly, bypassing `fx` entirely, the same technique the
    // Save As dead-code guards used, since this is the only way to
    // actually reach the arm with the model already reset out of
    // `.compressing`.
    try h.send(.{ .convert_result = .{ .key = staging_key, .code = 1, .reason = .exited } });

    try testing.expectEqual(Status.idle, h.model().status);
    try testing.expectEqualStrings("", h.model().errorMessage());
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

    // Re-running Smoosh on the same source is treated as "redo this" —
    // including redoing the format that failed, and dropping the warning
    // it left behind.
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

    try h.send(.{ .set_format = .avif });
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
    try h.encodeOk("avifenc", ".avif", "717003");

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
    try h.encodeOk("avifenc", ".avif", "717003");
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
    try h.encodeOk("avifenc", ".avif", "717003");
    try h.encodeOk("cwebp", ".webp", "671054");

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
    try h.encodeOk("avifenc", ".avif", "717003");
    try h.encodeOk("cwebp", ".webp", "671054");

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
    try h.encodeOk("avifenc", ".avif", "717003");
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
    try h.encodeOk("avifenc", ".avif", "717003");
    try h.encodeOk("cwebp", ".webp", "671054");

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
    try h.encodeOk("avifenc", ".avif", "717003");
    try h.encodeOk("cwebp", ".webp", "671054");

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
    try h.encodeOk("avifenc", ".avif", "717003");

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
    try h.encodeOk("avifenc", ".avif", "717003");
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
    try h.encodeOk("avifenc", ".avif", "717003");
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
    try h.encodeOk("avifenc", ".avif", "717003");
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
    try h.encodeOk("avifenc", ".avif", "717003");
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
    try h.encodeOk("avifenc", ".avif", "98304");
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

test "the preview clamps to the source, so sips' upscaling never shows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `sips -Z 160` UPSCALES anything smaller than 160px — `tiny.png` came
    // back a 160x160 blur. The registered pixels are whatever sips
    // produced; the drawn size is the source's.
    var model = readyModel();
    model.preview_width = 160;
    model.preview_height = 160;
    model.source_width = 12;
    model.source_height = 12;
    try testing.expectEqual(@as(u32, 12), model.previewWidth());
    try testing.expectEqual(@as(u32, 12), model.previewHeight());
    const tiny = try buildTree(arena, &model);
    const drawn = findByKind(tiny.root, .image) orelse return error.WidgetNotFound;
    try testing.expectEqual(@as(f32, 12), drawn.layout.max_size.width);

    // A source larger than the thumbnail is left alone — the clamp is a
    // floor on upscaling, not a resize.
    model.source_width = 4000;
    model.source_height = 3000;
    try testing.expectEqual(@as(u32, 160), model.previewWidth());

    // And an unparsed `sips -g` (dimensions still 0) falls back to the
    // registered size rather than collapsing the preview to nothing.
    model.source_width = 0;
    model.source_height = 0;
    try testing.expectEqual(@as(u32, 160), model.previewWidth());
    try testing.expectEqual(@as(u32, 160), model.previewHeight());
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
    try h.dimensions(800, 600);
    try h.thumbnail(0);
    try h.preview(.loaded, 160, 120);

    try testing.expectEqual(Status.ready, h.model().status);
    try testing.expect(h.model().hasPreview());
}

test "a drop clears the previous file's results and preview, like a pick does" {
    var h = try Harness.create();
    defer h.destroy();

    try h.load("/Users/someone/Pictures/large.jpg", "5846465");
    try h.send(.smoosh);
    try h.encodeOk("avifenc", ".avif", "717003");
    try testing.expect(h.model().hasAvifResult());
    try testing.expect(h.model().hasPreview());

    try h.drop("/Users/someone/Pictures/tiny.png");
    try testing.expectEqualStrings("/Users/someone/Pictures/tiny.png", h.model().path());
    try testing.expect(!h.model().hasAvifResult());
    try testing.expect(!h.model().hasPreview());
}
