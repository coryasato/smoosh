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
