//! Smoosh — image compression for the desktop.
//!
//! `main.zig` is hand-authored: platform + Runtime are stood up BY HAND (not
//! through the CLI's `runner.runWithOptions`, whose per-platform bring-up is
//! non-`pub`) so a `HostCallBinding` can close over the `*Runtime` and reach
//! `showOpenDialog`. See CLAUDE.md, "File acquisition, honestly".

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const imageio = @import("imageio.zig");
const encoders = @import("encoders.zig");
const chroma = @import("chroma.zig");
const workspace = @import("workspace.zig");
const pasteboard = @import("pasteboard.zig");
const dockopen = @import("dockopen.zig");

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

/// The one window's id, shared by `AppInfo.main_window` and every
/// hand-made dispatch into the app (`onDockOpen`). The runtime's own
/// events carry it; a direct caller has to state it.
const main_window_id: platform.WindowId = 1;

/// The app's identity, stated here because a hand-authored root builds
/// its own `AppInfo` — the CLI runner would derive these from `app.zon`
/// at comptime, and this tree has no such path (same reason the window
/// geometry is restated below).
///
/// **`app.zon` states every one of these a second time**, and nothing in
/// the build makes them agree: `AppInfo.version` is what the RUNNING app
/// reports about itself, `app.zon`'s is what `native check` and packaging
/// read, and they sat two releases apart (0.1.0 against 0.3.0) without a
/// single warning. `tests.zig` now parses `app.zon` and fails naming the
/// field that drifted — bump one and the other is not optional.
pub const app_version = "0.8.0";
pub const app_name = "smoosh";
pub const app_display_name = "Smoosh";
pub const app_bundle_id = "dev.native_sdk.smoosh";
pub const app_description = "A tiny native macOS app that compresses images into modern web formats.";
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

// ----------------------------------------------------------------- tokens
//
// The palette is APP-OWNED: `Options.tokens_fn` hands a complete
// `canvas.DesignTokens` back on every rebuild, derived from the appearance
// the model stores (`on_appearance` -> `.appearance_changed`). Claiming
// `tokens_fn` opts out of the SDK's automatic system-appearance theming,
// which is why the model has to carry the scheme itself.
//
// Everything below is stated as OVERRIDES on the house theme rather than a
// fresh `ColorTokens`: roles this app never draws (warning, the syntax
// ladder, the scrim) then keep the house value FOR THE CURRENT SCHEME,
// instead of silently inheriting the light register's near-black ink in a
// dark window.
//
// One colour at a time: peach is the Smoosh button and nothing else — the
// only saturated peach fill in the window. Lilac (`success`) is the
// savings figure on every result row; at 70%+ savings it also fills that
// row's badge solid — the same hue graded by weight, not a new colour.
// Sky (`info`) is work in progress: the spinner. The format segments stay
// neutral. A fourth hue means something else has gone wrong.

/// `surface_pressed` is DARKER than `surface_subtle` in BOTH schemes,
/// which is where this palette departs from the stock pack (there, dark's
/// pressed step is the LIGHTER one). It is forced, not a preference:
/// `surface_pressed` is the segmented-control track, and a ghost
/// `toggle-button`'s selected state is hard-wired to `surface_subtle` —
/// so the track must sit UNDER the thumb or the thumb disappears. The
/// first dark track tried, `#17171C`, measured ΔL* 2.07 against the
/// window and was invisible; `tokens tests` in `tests.zig` now pin the
/// separation.
fn palette(scheme: canvas.ColorScheme) canvas.ColorTokenOverrides {
    return switch (scheme) {
        .light => .{
            .background = canvas.Color.rgb8(0xFD, 0xFC, 0xFA),
            .surface = canvas.Color.rgb8(0xFF, 0xFF, 0xFF),
            // #F4ECDF, warmer than the token sheet's #F7F1EA. Not a
            // correction — the sheet's value renders exactly as drawn —
            // but a compensation for where it renders: on the canvas that
            // patch sits inside a cream window on a warm page, and every
            // neighbour confirms its warmth. In a 540pt window on someone
            // else's desktop the same field has nothing warm near it, and
            // 13 points of red-over-blue reads as grey. This spends 21.
            //
            // The ceiling is the segmented track (`surface_pressed`,
            // #EAE1D3) that this sits above: past about #F3EADB the two
            // close to under ΔL* 3 and the track stops reading. The
            // contrast test in `tests.zig` pins both ends.
            .surface_subtle = canvas.Color.rgb8(0xF4, 0xEC, 0xDF),
            // #E7D7C7 — warmer AND a shade darker than the sheet's
            // #EAE1D3. The warmth is for the same reason the cards above
            // it got theirs; the darkening is because they got theirs:
            // once `surface_subtle` warmed to #F4ECDF the track had only
            // ΔL* 3.81 left under it, and the track's whole job is to sit
            // UNDER the thumb. Three points of lightness buys 6.83 back.
            .surface_pressed = canvas.Color.rgb8(0xE7, 0xD7, 0xC7),
            .text = canvas.Color.rgb8(0x2A, 0x2A, 0x32),
            // #6B6773, which is what the drawn states use — NOT the
            // #75717C the token sheet lists. The lighter value measures
            // 4.25:1 on `surface_subtle`, and muted ink lands on that
            // surface constantly (the drop zone's hint, every result
            // row's size figure). The contrast test pins it.
            .text_muted = canvas.Color.rgb8(0x6B, 0x67, 0x73),
            .border = canvas.Color.rgba8(0x2A, 0x2A, 0x32, 26),
            // #F2B79A — deeper and slightly more saturated than the
            // #F8CDB7 this replaces. That lighter peach cleared ΔL* ~11.8
            // against the dark ground and read as a pale glowing bar with
            // no body; this drops ~5 L* and adds chroma so the one
            // saturated fill in the window carries weight. It reverses an
            // earlier call that rejected roughly this value (the sheet's
            // #F3B89A) for the LIGHT window as a "muddy tan" — at the
            // button's size, against neutral desktops, body beats
            // brightness, and the same value has to work in dark. Still
            // ONE value across both schemes: peach does not flip.
            // Knockout ink clears 8.1:1 either way.
            .accent = canvas.Color.rgb8(0xF2, 0xB7, 0x9A),
            .accent_text = canvas.Color.rgb8(0x2A, 0x2A, 0x32),
            .success = canvas.Color.rgb8(0x6A, 0x55, 0xB8),
            .success_text = canvas.Color.rgb8(0xFD, 0xFC, 0xFA),
            .info = canvas.Color.rgb8(0x50, 0x90, 0xC8),
            .info_text = canvas.Color.rgb8(0xFD, 0xFC, 0xFA),
            .destructive = canvas.Color.rgb8(0xC4, 0x45, 0x3D),
            .destructive_text = canvas.Color.rgb8(0xFD, 0xFC, 0xFA),
            .focus_ring = canvas.Color.rgb8(0x75, 0x71, 0x7C),
            .disabled = canvas.Color.rgb8(0xE7, 0xD7, 0xC7),
        },
        .dark => .{
            // The dark neutrals are WARM, mirroring the light ramp's
            // structure rather than the sheet's hexes: a near-neutral
            // ground (+3 red over blue, like #FDFCFA) with the warmth
            // spent on the surfaces that sit on it. The sheet's
            // #1B1B21/#232329/#121216 all lean the other way (blue over
            // red by 4-6), which put cool surfaces under this scheme's
            // warm ink (#F4F0EA) and read as a different app from the
            // light one. Every value below holds its predecessor's L* to
            // within 0.25, so the ramp's lightness — and every contrast
            // gate the test pins — is unchanged; only the hue moved.
            .background = canvas.Color.rgb8(0x1D, 0x1B, 0x1A),
            // Deliberately the same value as `surface_subtle`: the dark
            // window has no raised-card surface of its own, and giving
            // it one would put a third near-black step between the
            // ground and the drop zone that nothing would read as
            // elevation.
            .surface = canvas.Color.rgb8(0x28, 0x22, 0x1C),
            .surface_subtle = canvas.Color.rgb8(0x28, 0x22, 0x1C),
            // Warmed to match the light track's spend (+16 red over
            // blue). Dark needs no darkening — the ramp already leaves
            // ΔL* 8.44 under the cards.
            .surface_pressed = canvas.Color.rgb8(0x18, 0x10, 0x08),
            .text = canvas.Color.rgb8(0xF4, 0xF0, 0xEA),
            // Warm grey, not the sheet's violet-leaning #98939F: muted
            // ink sits on the warm surfaces above and inherited their
            // problem.
            .text_muted = canvas.Color.rgb8(0x99, 0x94, 0x8F),
            .border = canvas.Color.rgba8(0xFF, 0xFF, 0xFF, 23),
            // Peach is the one hue that does NOT flip: same value in
            // both schemes (see the light block for why #F2B79A), only
            // ever a fill under dark ink, and it clears 4.5:1 against
            // `accent_text` in both.
            .accent = canvas.Color.rgb8(0xF2, 0xB7, 0x9A),
            .accent_text = canvas.Color.rgb8(0x2A, 0x2A, 0x32),
            .success = canvas.Color.rgb8(0xC9, 0xB7, 0xF2),
            .success_text = canvas.Color.rgb8(0x1B, 0x1B, 0x21),
            .info = canvas.Color.rgb8(0xA8, 0xD4, 0xF5),
            .info_text = canvas.Color.rgb8(0x1B, 0x1B, 0x21),
            .destructive = canvas.Color.rgb8(0xF0, 0x9A, 0x93),
            .destructive_text = canvas.Color.rgb8(0x1B, 0x1B, 0x21),
            .focus_ring = canvas.Color.rgb8(0x98, 0x93, 0x9F),
            .disabled = canvas.Color.rgb8(0x18, 0x10, 0x08),
        },
    };
}

/// Five radii are drawn and the token scale holds four, so the two
/// registers are split: SURFACES take the scale (below), CONTROLS state
/// their own through `ControlVisualTokens.radius`. Without that split the
/// drop zone's 16 and the segment thumb's 8 could not both exist.
///
/// ONE outer radius across everything a hand lands on: the segmented
/// track, every button, and a result card are all 10. The canvas draws
/// the track at 8 against a 10 button, and side by side that read as a
/// mistake rather than a distinction — the track is a 32pt pill and the
/// button a 28pt one, so the same arc on the shorter shape looks larger.
/// The thumb keeps the design's one-step-in relationship: track minus its
/// own 2pt padding, which is 8.
///
/// `sm` is 6, not the scale's usual 8, and it is the savings badge's
/// corner: the SDK fixes a badge at 20pt tall, so an 8pt corner is 40%
/// of the height and reads as a pill, while the 10pt result row it sits
/// in is a 29% corner. 6pt puts the badge at 30% — the same rounded-rect
/// family as the row and the buttons. The only other `sm` consumer is
/// the 7pt done-dot, which clamps to a circle at any radius over 3.5.
const radii: canvas.RadiusTokenOverrides = .{
    .sm = 6, // the savings badge's corner (and the done-dot); no surface uses it
    .md = 10, // the segmented track, and a result card
    .lg = 12, // the preview frame
    .xl = 16, // the drop zone
};

/// The whole palette, rebuilt per view build. Cheap by construction — it
/// is a few hundred bytes of struct copy, no allocation.
pub fn tokens(model: *const Model) canvas.DesignTokens {
    const scheme = model.color_scheme;
    return canvas.DesignTokens.themeWithOverrides(.{
        .color_scheme = scheme,
        .contrast = if (model.high_contrast) .high else .standard,
        .reduce_motion = model.reduce_motion,
    }, .{
        .colors = palette(scheme),
        .radius = radii,
        // The surface shadow, zeroed — the other half of the panel
        // chrome above. `shadow.sm` is drawn under every opaque panel,
        // and this app's two panels are recesses: a drop shadow lifts
        // them off the page, which is the opposite of what they say.
        // Nothing else in this app reads `shadow.sm`.
        .shadow = .{ .sm = .{ .y = 0, .blur = 0, .spread = 0 } },
        // One step, not 1.2. The house `sm` button label is
        // `button_size - 1.2` = 12.8, which sat beside 13pt text
        // everywhere in this window — the format label next to the
        // segments, a result row's size next to its Save. At 1 the whole
        // app resolves to three sizes and no more: 14 (the file name and
        // the drop zone's headline), 13 (everything else, labels and
        // button text alike), and the badge's 12.
        .metrics = .{ .button_label_sm_step = 1 },
        .controls = .{
            .button_default = .{ .radius = 10 },
            .button_primary = .{
                .radius = 10,
                // A disabled Smoosh is a NEUTRAL chip, not faded peach.
                // The house treatment washes the rest colour at
                // `states.disabled_alpha`, which on a saturated fill
                // leaves a washed-out peach that still reads as the
                // primary action. The design states the pair instead —
                // the token doc's own "colour SWAP" case.
                .disabled_background = palette(scheme).surface_pressed,
                .disabled_foreground = palette(scheme).text_muted,
            },
            // Reset, each result row's Save, and the appearance toggle.
            // Muted ink: a ghost control is a secondary action, and
            // full-ink Reset competed with Smoosh beside it. 7 rather
            // than the buttons' 10 — a ghost control has no fill to
            // shape, so the radius only ever shows on its hover wash.
            .button_ghost = .{
                .radius = 10,
                .foreground = palette(scheme).text_muted,
                // A TRANSLUCENT wash, and it has to be. The house hover
                // fill for a quiet control is the flat `surface_subtle`
                // token, which collides with two surfaces this app
                // actually draws: every result row states
                // `background="surface_subtle"`, so the Save buttons
                // sitting on one washed to the exact colour already
                // behind them and had no hover at all; and in DARK
                // `surface` and `surface_subtle` are deliberately the
                // same #28221C (see `palette`), which killed the hover on
                // every ghost control in the window — Reset, Show in
                // Finder and the appearance toggle included.
                //
                // Ink at ~8% composites over whatever is behind it, so
                // one value covers white, cream and near-black without a
                // per-surface table. It is the same device the `border`
                // token already uses (ink at 26/255, white at 23/255).
                //
                // `pressed_background` is stated too, and is not
                // optional: the quiet ladder falls back
                // pressed -> active -> HOVER, so stating only the hover
                // wash would make a press look identical to a hover.
                .hover_background = if (scheme == .light)
                    canvas.Color.rgba8(0x2A, 0x2A, 0x32, 20)
                else
                    canvas.Color.rgba8(0xFF, 0xFF, 0xFF, 20),
                .pressed_background = if (scheme == .light)
                    canvas.Color.rgba8(0x2A, 0x2A, 0x32, 40)
                else
                    canvas.Color.rgba8(0xFF, 0xFF, 0xFF, 40),
            },
            // The segments are ghost toggle-buttons, so without this they
            // would inherit the muted ghost ink above. They take FULL
            // ink, all three of them — the design mutes the unselected
            // pair, and the SDK cannot: a ghost variant resolves one
            // `foreground` for both states (`active_foreground` is
            // consulted only for `default` and detached-group members),
            // and `foreground` is a token-name attribute that takes no
            // binding, so a per-item ink would need an `<if>` inside the
            // `<for>` and the widget-identity collision that causes.
            // Full ink for all three is also what macOS itself does: the
            // thumb marks the selection, not the ink.
            //
            // A `<panel>` strokes a hairline and casts a shadow whether or
            // not you asked: `emitPanelWidgetChrome` always emits both,
            // with no attribute to decline. The drop zone and the preview
            // frame are washes, not cards — the recess IS the affordance,
            // and an outline around it was never in the design. Zero the
            // stroke here and the shadow below; this is the only table a
            // `<panel>` reads.
            .panel = .{ .stroke_width = 0 },
            .toggle_button = .{ .radius = 8, .foreground = palette(scheme).text },
        },
    });
}

/// The appearance channel. Returns a Msg rather than mutating anything —
/// the scheme is model state like everything else, so `tokens` above stays
/// a pure function of the model and the flip is testable by dispatching
/// one message.
pub fn onAppearance(appearance: platform.Appearance) ?Msg {
    return .{ .appearance_changed = .{
        .color_scheme = switch (appearance.color_scheme) {
            .light => .light,
            .dark => .dark,
        },
        .high_contrast = appearance.high_contrast,
        .reduce_motion = appearance.reduce_motion,
    } };
}

/// What `.appearance_changed` carries — the canvas-side spelling of
/// `platform.Appearance`. The two `ColorScheme` enums are distinct types
/// (one per layer), and translating at the boundary keeps the platform
/// type out of the Model.
pub const AppearanceState = struct {
    color_scheme: canvas.ColorScheme = .light,
    high_contrast: bool = false,
    reduce_motion: bool = false,
};

// ------------------------------------------------------------------ model
//
// Buffers use `platform.max_dialog_path_bytes` (4096) to hold whatever
// `showOpenDialog` hands back.

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

/// WHERE a run's outputs go, decided once per file by the writability
/// probe at the end of the load chain (`file.destination`) and fixed for
/// the run. It is decided UP FRONT rather than retried after a failed
/// write on purpose: a blanket "the write failed, try somewhere else"
/// cannot tell a read-only screenshot staging directory apart from a
/// read-only USB stick or a full disk, and would drop files where nobody
/// asked for them.
pub const Destination = enum {
    /// Beside the source, `photo.jpg` -> `photo.avif`. The ordinary case
    /// and the only one before the probe existed: the source's folder
    /// takes a write.
    beside_source,
    /// The source's folder is read-only AND the source is a screenshot
    /// (`looksLikeScreenshot`) — so it is one macOS itself parked
    /// somewhere unwritable, and the screenshot folder is where its owner
    /// already expects to find it. `dest_dir` names that folder.
    desktop,
    /// The source's folder is read-only and nothing suggests where else
    /// the user would want the files — a read-only volume, a disc image,
    /// `/Applications`. The outputs are encoded into the app cache
    /// (`dest_dir`) and Save As is the only way out; nothing is claimed
    /// to have been saved anywhere the user can keep.
    ask,
};

pub const Model = struct {
    // file
    path_buffer: [platform.max_dialog_path_bytes]u8 = undefined,
    path_len: usize = 0,
    /// Where the IMAGE COMMANDS read from, when that is not `path_buffer`.
    /// Empty for an ordinary source, and then `readPath` falls through to
    /// `path()` — the two are the same file and nothing is copied.
    ///
    /// Non-empty only for an EPHEMERAL source (`isEphemeralSource`), where
    /// it names a copy of the bytes in the app cache dir that `file.stash`
    /// made at load. `path_buffer` still holds the ORIGINAL path, and must:
    /// it is what the file card names, what `outputPath` derives the
    /// destination from, and what `beginEncode`'s `same_path` guard
    /// compares against. Only the READ moves.
    stash_path_buffer: [platform.max_dialog_path_bytes]u8 = undefined,
    stash_path_len: usize = 0,
    /// Where this file's outputs go — see `Destination`. Decided by
    /// `destination_result` before `.ready`, so it is settled by the time
    /// Smoosh can be pressed, and re-decided per file.
    destination: Destination = .beside_source,
    /// The DIRECTORY `destination` names, when that is not the source's
    /// own. Empty for `.beside_source`, in which case `outputPath` keeps
    /// the source's directory exactly as it always did. `update` can
    /// never derive either of these itself — the Desktop needs `$HOME`
    /// and the cache needs `app_dirs`, both of which live in the bridge.
    dest_dir_buffer: [platform.max_dialog_path_bytes]u8 = undefined,
    dest_dir_len: usize = 0,
    original_size: u64 = 0,
    // preview
    image_id: u64 = 0,
    preview_width: u32 = 0,
    preview_height: u32 = 0,
    /// The SOURCE's DISPLAY dimensions, from `image.probe` — orientation
    /// already applied, so a portrait photo stored landscape with EXIF
    /// Orientation 6 reports 3000x4000, not 4000x3000. 0 until the probe
    /// answers; a probe that cannot read them fails the load outright,
    /// because there is no later gate to defer to.
    source_width: u32 = 0,
    source_height: u32 = 0,
    /// The source's Uniform Type Identifier as ImageIO names it
    /// ("public.jpeg", "public.heic", "org.webmproject.webp") — the
    /// container, decided by sniffing the file rather than by trusting its
    /// extension. Recorded because `chroma.forSource` keys on it — a JPEG
    /// keeps its own subsampling, everything else goes 4:4:4 — and a
    /// mis-named JPEG must still be read as a JPEG.
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
    ///
    /// Save As is its main producer but not its only one: a failed "Show
    /// in Finder" writes here too. Both are the same KIND of fact — the
    /// freshest thing the user did, transient, cleared by the next run —
    /// which is exactly what `statusLine` gives this slot priority for.
    save_message_buffer: [256]u8 = undefined,
    save_message_len: usize = 0,

    // appearance — the input to `tokens` above, never bound by the view.
    // The defaults are what the app themes with for the one frame before
    // `on_appearance` first fires.
    color_scheme: canvas.ColorScheme = .light,
    high_contrast: bool = false,
    reduce_motion: bool = false,
    /// Pointer-hover state for the footer's "Show in Finder", and the
    /// only reason the control is a `<row>` of `<text>` rather than a
    /// `<button>`: the design wants hover to DIM THE LABEL, and no stock
    /// control can. A ghost button's ink is one value in every state
    /// (`buttonTextColorForWidget`'s `.ghost` arm reads no state
    /// channel), `ControlVisualTokens` has no `hover_foreground`, and
    /// markup's `foreground` takes a literal token name and refuses a
    /// binding ("dynamic styling stays in Zig"). What markup DOES give is
    /// `on-hover-enter`/`on-hover-leave`, so the hover becomes ordinary
    /// Model state and the ink becomes two `<if>` arms — the same shape
    /// the savings badge already uses, and for the same reason.
    reveal_hovered: bool = false,

    /// The same hover-ink treatment on each result row's Save, one flag
    /// per row. TWO independent flags rather than one `?Output`: moving
    /// the pointer straight from one row to the other dispatches an enter
    /// and a leave whose order is not promised, and a single field would
    /// let the leave land second and mute a button the pointer is on.
    avif_save_hovered: bool = false,
    webp_save_hovered: bool = false,

    /// Set once the user works the footer's appearance toggle. From then
    /// on `appearance_changed` stops moving `color_scheme` — a manual
    /// choice that the next OS flip silently undid would be worse than no
    /// toggle at all. Contrast and reduce-motion keep following the OS
    /// either way: those are accessibility settings, not a preference the
    /// button offers.
    scheme_pinned: bool = false,

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
        "stash_path_buffer",
        "stash_path_len",
        "readPath",
        "destination",
        "dest_dir_buffer",
        "dest_dir_len",
        "destDir",
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
        "sourceKind",
        "originalSize",
        "errorMessage",
        "warningMessage",
        "saveMessage",
        "color_scheme",
        "high_contrast",
        "reduce_motion",
        "scheme_pinned",
    };

    pub fn path(model: *const Model) []const u8 {
        return model.path_buffer[0..model.path_len];
    }
    /// The path every ImageIO read goes through — `image.probe`,
    /// `image.thumbnail`, and the source field of `image.encode`. The
    /// cache stash when there is one, the picked path otherwise. See
    /// `stash_path_buffer` for why the write side deliberately does NOT
    /// use this.
    pub fn readPath(model: *const Model) []const u8 {
        if (model.stash_path_len == 0) return model.path();
        return model.stash_path_buffer[0..model.stash_path_len];
    }
    /// The directory outputs are written into, or empty for "beside the
    /// source" — `outputPath` reads it exactly that way.
    pub fn destDir(model: *const Model) []const u8 {
        return model.dest_dir_buffer[0..model.dest_dir_len];
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
    /// The picked file's last path component, for DISPLAY. macOS names
    /// screenshots with a NARROW NO-BREAK SPACE (U+202F) before "AM"/"PM"
    /// and some downloads carry a NO-BREAK SPACE (U+00A0); both render as
    /// a tofu box on the reference/screenshot/mobile paths and trip the
    /// `zero_canvas_ui` diagnostic under `native dev`. They ARE spaces —
    /// swap each for an ASCII one here, in an arena copy, never in
    /// `path_buffer`, which every host file command reads verbatim.
    pub fn fileName(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const full = model.path();
        const base = if (std.mem.lastIndexOfScalar(u8, full, '/')) |slash|
            full[slash + 1 ..]
        else
            full;
        // U+202F = E2 80 AF, U+00A0 = C2 A0 — each collapses to one ASCII
        // space, so the copy is never longer than `base`.
        const out = arena.alloc(u8, base.len) catch return base;
        var w: usize = 0;
        var i: usize = 0;
        while (i < base.len) {
            if (i + 3 <= base.len and base[i] == 0xE2 and base[i + 1] == 0x80 and base[i + 2] == 0xAF) {
                i += 3;
            } else if (i + 2 <= base.len and base[i] == 0xC2 and base[i + 1] == 0xA0) {
                i += 2;
            } else {
                out[w] = base[i];
                w += 1;
                i += 1;
                continue;
            }
            out[w] = ' ';
            w += 1;
        }
        return out[0..w];
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

    /// The third face of the one status mark: the slot beside the status
    /// bar carries a spinner while busy and an alert on failure, so a
    /// success dot completes the set rather than adding chrome. A
    /// partially-successful run is `.done` and gets the dot — it landed a
    /// file; the format that did not is named in the bar's own text.
    pub fn isDone(model: *const Model) bool {
        return model.status == .done;
    }

    /// Gates the footer's "Show in Finder" button.
    ///
    /// Keyed on the OUTPUTS rather than on `status == .done`, which
    /// `finishIfComplete` keeps exactly equivalent (a run that lands no
    /// file is `.failed`, never `.done`). The outputs are the right key
    /// anyway: they are what the press SENDS, so gate and payload cannot
    /// drift apart — a `status` gate would let a future outcome that is
    /// `.done` without a path put up a button with nothing to reveal.
    ///
    /// A partially successful run qualifies: one file landed, and that
    /// one is worth showing.
    ///
    /// It deliberately does NOT follow a Save As. A user who picked a
    /// destination already knows where the copy went; this button exists
    /// to unveil the automatic write beside the source, which is the one
    /// nobody was asked about.
    pub fn canReveal(model: *const Model) bool {
        // `.ask` wrote into the app cache, not anywhere the user asked
        // for. Revealing that would hand them a Finder window onto a
        // purgeable directory and imply the run had saved something —
        // exactly the claim the status line is refusing to make.
        if (model.destination == .ask) return false;
        return model.hasAvifResult() or model.hasWebpResult();
    }

    // ------------------------------------------------- appearance toggle
    //
    // The button offers the OTHER scheme, so it shows that scheme's glyph
    // and says what pressing it will do. Both are model fns rather than
    // an `<if>` in the markup: two conditional buttons would be two
    // widget ids for one control, and the footer is addressed by
    // automation as a fixed set.

    /// `sun` while dark, `moon` while light — the icon names what the
    /// press produces, not the state it is in.
    pub fn schemeIcon(model: *const Model) []const u8 {
        return switch (model.color_scheme) {
            .light => "moon",
            .dark => "sun",
        };
    }

    /// The toggle's accessible name, and the only place the appearance
    /// states are spelled for a person.
    pub fn schemeToggleLabel(model: *const Model) []const u8 {
        return switch (model.color_scheme) {
            .light => "Switch to dark appearance",
            .dark => "Switch to light appearance",
        };
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

    /// The source container, spelled the way the format spells itself
    /// ("JPEG", "HEIC") rather than the way ImageIO identifies it
    /// ("public.jpeg"). Empty for anything not on this list, which is
    /// what makes `fileSubtitle` degrade rather than print a UTI at the
    /// user: ImageIO decodes more than Smoosh advertises, and a name
    /// nobody recognises is worse than no name.
    pub fn sourceKind(model: *const Model) []const u8 {
        const uti = model.sourceUti();
        const table = [_]struct { uti: []const u8, name: []const u8 }{
            .{ .uti = "public.jpeg", .name = "JPEG" },
            .{ .uti = "public.png", .name = "PNG" },
            .{ .uti = "public.heic", .name = "HEIC" },
            .{ .uti = "public.heif", .name = "HEIF" },
            .{ .uti = "org.webmproject.webp", .name = "WebP" },
            .{ .uti = "public.tiff", .name = "TIFF" },
            .{ .uti = "com.compuserve.gif", .name = "GIF" },
            .{ .uti = "com.microsoft.bmp", .name = "BMP" },
        };
        for (table) |entry| {
            if (std.mem.eql(u8, uti, entry.uti)) return entry.name;
        }
        return "";
    }

    /// "Original 5.7 MB · JPEG" — the line under the file name. The
    /// container is appended rather than given a row of its own: it is a
    /// fact ABOUT the size line (what those bytes are), and the card has
    /// exactly two lines of room beside a 144px preview.
    pub fn fileSubtitle(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!model.hasFile()) return "";
        const size = model.originalSize(arena);
        const kind = model.sourceKind();
        if (kind.len == 0) return std.fmt.allocPrint(arena, "Original {s}", .{size}) catch "";
        return std.fmt.allocPrint(arena, "Original {s} · {s}", .{ size, kind }) catch "";
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

    /// Whether this format's result row should occupy space right now.
    /// True once its result is in — and ALSO the whole time the run is
    /// `.compressing` and this format is part of it (`outcome != .none`),
    /// which is what reserves the row at full height before the encode
    /// replies. Without it, a "Both" run where WebP finishes first drew
    /// the WebP row, then inserted the AVIF row ABOVE it and punted WebP
    /// down on the next frame. With both rows reserved from the first
    /// post-`smoosh` paint, whichever lands first fills its own row in
    /// place and nothing moves. The reservation drops at settle
    /// (`status` leaves `.compressing`): a format that FAILED collapses
    /// its row then — one reflow, off the common path — which keeps "a
    /// failed format shows no row; the status bar names it".
    pub fn showAvifRow(model: *const Model) bool {
        return model.hasAvifResult() or (model.status == .compressing and model.avif_outcome != .none);
    }
    pub fn showWebpRow(model: *const Model) bool {
        return model.hasWebpResult() or (model.status == .compressing and model.webp_outcome != .none);
    }

    // A result row is drawn in THREE registers — the format name in ink,
    // the output size muted, the savings figure in lilac inside a badge —
    // so it is three bindings, not one line. `<span>` carries weight and
    // scale but NOT `foreground`, so a multi-tone line can never be one
    // `<text>`; the split lives here rather than as markup gymnastics.

    /// "700.2 KB" once AVIF lands; an em dash while its reserved row is
    /// still waiting on the encode; empty when there is no row.
    pub fn avifSize(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.hasAvifResult()) return formatBytes(arena, model.avif_size);
        return if (model.showAvifRow()) "—" else "";
    }
    /// "−88%" — or "+1% larger" for an output bigger than a tiny source.
    pub fn avifSavings(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!model.hasAvifResult()) return "";
        return formatSavings(arena, model.original_size, model.avif_size);
    }
    /// "655.3 KB" once WebP lands; an em dash while its reserved row is
    /// still waiting on the encode; empty when there is no row.
    pub fn webpSize(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.hasWebpResult()) return formatBytes(arena, model.webp_size);
        return if (model.showWebpRow()) "—" else "";
    }
    /// "−89%". Empty unless WebP landed this run.
    pub fn webpSavings(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!model.hasWebpResult()) return "";
        return formatSavings(arena, model.original_size, model.webp_size);
    }

    // The savings badge takes three weights by how much a format saved
    // (`savingsGate` below): `quiet` under 30%, `keep` from 30 to under
    // 70, `win` at 70 and over. `foreground` on a `<badge>` is a
    // token-NAME attribute that takes no binding, so the gate cannot be
    // one styled badge whose colour varies — it is three `<if>` arms in
    // the markup, one predicate each, the same shape the status line's
    // three marks use. Each predicate also carries the `hasXResult`
    // guard so a gate is never true for a format that did not land.
    pub fn avifSavingsQuiet(model: *const Model) bool {
        return model.hasAvifResult() and savingsGate(model.original_size, model.avif_size) == .quiet;
    }
    pub fn avifSavingsKeep(model: *const Model) bool {
        return model.hasAvifResult() and savingsGate(model.original_size, model.avif_size) == .keep;
    }
    pub fn avifSavingsWin(model: *const Model) bool {
        return model.hasAvifResult() and savingsGate(model.original_size, model.avif_size) == .win;
    }
    pub fn webpSavingsQuiet(model: *const Model) bool {
        return model.hasWebpResult() and savingsGate(model.original_size, model.webp_size) == .quiet;
    }
    pub fn webpSavingsKeep(model: *const Model) bool {
        return model.hasWebpResult() and savingsGate(model.original_size, model.webp_size) == .keep;
    }
    pub fn webpSavingsWin(model: *const Model) bool {
        return model.hasWebpResult() and savingsGate(model.original_size, model.webp_size) == .win;
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
        // A new file's reads start at the new file. The previous stash (if
        // there was one) is about to be deleted by the next `file.stash`
        // anyway; leaving its path here would point this load's probe at
        // the PREVIOUS image.
        model.stash_path_len = 0;
    }

    fn setStashPath(model: *Model, text: []const u8) void {
        const len = @min(text.len, model.stash_path_buffer.len);
        @memcpy(model.stash_path_buffer[0..len], text[0..len]);
        model.stash_path_len = len;
    }

    fn setDestDir(model: *Model, text: []const u8) void {
        const len = @min(text.len, model.dest_dir_buffer.len);
        @memcpy(model.dest_dir_buffer[0..len], text[0..len]);
        model.dest_dir_len = len;
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
        // The control is about to leave the view. Without this it would
        // come back hot the next time a run lands, because the pointer
        // left a widget that no longer exists to report the leave.
        model.reveal_hovered = false;
        model.avif_save_hovered = false;
        model.webp_save_hovered = false;
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
            // format that did NOT land can be named. A lost format is
            // more urgent than WHERE the rest went, so the warning still
            // wins the line.
            .done => if (model.warning_message_len > 0)
                model.warningMessage()
            else switch (model.destination) {
                // The files are beside the source, where the user is
                // already looking. Naming that would be noise — and
                // "Saved to Desktop." on a file in Pictures would be a
                // lie, which is the whole reason this is a switch.
                .beside_source => "Done.",
                .desktop => "Saved to Desktop.",
                // Nothing the user can keep has been written: the outputs
                // are in a cache the OS may purge, and Save As is the way
                // out. The line has to say so, because "Done." over a
                // read-only folder would be the worst lie available.
                .ask => "That folder is read-only — save a copy.",
            },
            .failed => model.errorMessage(),
        };
    }
};

pub const Msg = union(enum) {
    pick_file, // dropzone clicked
    dialog_result: native_sdk.EffectHostResult, // host open-dialog callback
    dropped_file: []const u8, // on_drop callback — a file dragged onto the window
    paste, // Cmd+V — the `app.paste` shortcut, through `onCommand`
    paste_result: native_sdk.EffectHostResult, // `clipboard.paste` callback -> the pasted image's nominal and read paths
    stash_result: native_sdk.EffectHostResult, // `file.stash` callback -> the cache copy's path, then on to the stat
    stat_result: native_sdk.EffectHostResult, // host file-size callback -> original_size
    probe_result: native_sdk.EffectHostResult, // host ImageIO properties callback -> dimensions, UTI, megapixel check
    thumbnail_result: native_sdk.EffectHostResult, // host ImageIO thumbnail callback -> the preview pixels
    destination_result: native_sdk.EffectHostResult, // `file.destination` callback -> where this run's outputs go, then `.ready`
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
    show_in_finder, // footer "Show in Finder" pressed
    reveal_hover_on, // pointer entered "Show in Finder"
    reveal_hover_off, // pointer left "Show in Finder"
    avif_save_hover_on, // pointer entered the AVIF row's Save
    avif_save_hover_off,
    webp_save_hover_on, // pointer entered the WebP row's Save
    webp_save_hover_off,
    reveal_result: native_sdk.EffectHostResult, // host reveal callback — only its failure is used
    reset, // clear current image, return to idle
    toggle_color_scheme, // footer appearance toggle
    appearance_changed: AppearanceState, // `on_appearance` — the input to `tokens`

    // Dispatched by host-call results and the app-level input hooks
    // (`on_drop`, `on_command`), never from markup. Naming them keeps
    // `native check`'s warnings meaningful: an unlisted Msg with no
    // binding is a real bug, not expected noise.
    pub const view_unbound = .{
        "dialog_result",
        "dropped_file",
        "paste",
        "paste_result",
        "stash_result",
        "stat_result",
        "probe_result",
        "thumbnail_result",
        "destination_result",
        "encode_result",
        "save_as_dialog_result",
        "save_as_result",
        "reveal_result",
        "appearance_changed",
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

/// The savings badge's emphasis gate, by how much the output saved:
/// `.quiet` under 30% — barely worth keeping, and anything that GREW,
/// since "+12% larger" is the opposite of a win — `.keep` from 30 to
/// under 70 (the outline the badge has always drawn), `.win` at 70 and
/// over (a solid `success` chip that reads at a glance).
///
/// This is a magnitude threshold, which the palette's "one colour"
/// note used to argue against: at −89% vs −88% two format rows land the
/// same gate, so the cue goes quiet exactly where comparing formats is
/// worth doing. That comparison is deliberately not a goal — by the time
/// both rows exist the encode is done, and what the badge answers is the
/// per-file "was this worth running". Same hue throughout; only weight
/// moves. Boundaries are pinned by `savingsGate bands ...` in tests.zig.
pub const SavingsGate = enum { quiet, keep, win };

pub fn savingsGate(original: u64, output: u64) SavingsGate {
    if (original == 0) return .quiet;
    const percent = (1.0 - @as(f64, @floatFromInt(output)) / @as(f64, @floatFromInt(original))) * 100.0;
    if (percent < 30.0) return .quiet;
    if (percent < 70.0) return .keep;
    return .win;
}

pub const Effects = native_sdk.Effects(Msg);

// ------------------------------------------------------------- effect keys
//
// One key space across spawns, fetches, files and host requests
// (`max_effects` = 16 slots).

const dialog_key: u64 = 1;
const stat_key: u64 = 2;
const thumbnail_key: u64 = 3;
/// NOT an effect key: `preview_image_id` names the registry slot
/// `fx.registerImage` fills and the `<image>` leaf draws. It sits in this
/// list only so a reader looking for "id 4" finds it — the two namespaces
/// are separate.
const preview_image_id: u64 = 4;
const probe_key: u64 = 5;
const avif_encode_key: u64 = 8;
const webp_encode_key: u64 = 9;
const save_dialog_key: u64 = 12;
const save_copy_key: u64 = 13;
const reveal_key: u64 = 14;
const stash_key: u64 = 15;
const destination_key: u64 = 16;
const paste_key: u64 = 17;

/// Host-call names our own `HostBridge` answers (see `main`). Not SDK
/// vocabulary — we bind the seam, so we name it.
const host_open_file = "dialog.openFile";
const host_file_size = "file.stat";
const host_save_file = "dialog.saveFile";
const host_file_copy = "file.copy";
/// Captures an ephemeral source's bytes into the app cache dir before
/// anything reads them — see `isEphemeralSource` and `HostBridge.stashFile`.
const host_file_stash = "file.stash";
/// Answers whether the source's own folder takes a write, and names the
/// two directories `update` cannot derive itself (the screenshot folder
/// and the app cache's outbox) — see `HostBridge.destinationFor`.
const host_destination = "file.destination";
/// Reads an image off the general pasteboard — see `src/pasteboard.zig`
/// for why the SDK's own clipboard seam cannot serve this.
const host_clipboard_paste = "clipboard.paste";
/// "Show in Finder" — see `src/workspace.zig` for why revealing a file
/// needs a seam of our own at all.
const host_reveal = "shell.reveal";
/// The ImageIO reads and the encode, all answered OFF the loop thread (see
/// `HostBridge`'s worker carrier). `probe` allocates no bitmap; `thumbnail`
/// decodes a capped preview; `encode` decodes at full resolution, runs
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
/// global. That is safe only because the preview is capped at
/// `imageio.max_thumbnail_edge` —
/// `max_effect_host_result_bytes` is 256 KiB and an over-cap answer is
/// silently rewritten to the err route — so the fit is asserted at
/// COMPTIME below rather than left as a comment for someone raising the
/// preview size to trip over. A full-resolution decode can never ride the
/// result, which is why `imageio.decode` is not a host command at all.
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
// output atomically, replying with just the output size. HEIC needs no
// staging step — ImageIO decodes it directly — and nothing spawns a
// subprocess.

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
/// to the source when `dest_dir` is empty. A non-empty `dest_dir` REPLACES
/// the source's directory and keeps only the name (`/desktop` here gives
/// `/desktop/photo.avif`), which is how the two rescue destinations write
/// somewhere else without a second path builder.
///
/// The extension search is scoped to the last path component so a dot in a
/// PARENT directory can never be mistaken for one; a name with no dot of
/// its own just gets the extension appended. Returns null only when the
/// result would not fit the buffer.
fn outputPath(buffer: []u8, source: []const u8, dest_dir: []const u8, extension: []const u8) ?[]const u8 {
    const name_start = if (std.mem.lastIndexOfScalar(u8, source, '/')) |slash| slash + 1 else 0;
    const stem_end = blk: {
        const dot = std.mem.lastIndexOfScalar(u8, source[name_start..], '.') orelse break :blk source.len;
        // A leading dot is a hidden file (".profile"), not an extension.
        if (dot == 0) break :blk source.len;
        break :blk name_start + dot;
    };
    if (dest_dir.len == 0) {
        if (stem_end + extension.len > buffer.len) return null;
        @memcpy(buffer[0..stem_end], source[0..stem_end]);
        @memcpy(buffer[stem_end..][0..extension.len], extension);
        return buffer[0 .. stem_end + extension.len];
    }
    // A trailing slash on the directory would double up; every producer
    // here sends one without, but the join must not depend on that.
    const dir = if (dest_dir[dest_dir.len - 1] == '/') dest_dir[0 .. dest_dir.len - 1] else dest_dir;
    const stem = source[name_start..stem_end];
    return std.fmt.bufPrint(buffer, "{s}/{s}{s}", .{ dir, stem, extension }) catch null;
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
    const destination = outputPath(buffer, model.path(), model.destDir(), extension) orelse
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
    // The SOURCE is `readPath` (the stash, when there is one) and the
    // DESTINATION is derived from `path()`. That asymmetry is the whole
    // point of the stash — see `Model.stash_path_buffer`.
    const payload = encodePayload(&payload_buffer, output, model.readPath(), model.sourceUti(), destination) orelse
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

/// The half of a write-failure sentence that says what to do about it —
/// shared by the per-format text and by the collapsed one below, so the
/// two can never give contradictory advice about the same failure.
///
/// The generic "check the folder's permissions" is only true for
/// `.beside_source`. Aimed at the Desktop it is actively misleading: a
/// denial there is TCC, not a mode bit — the folder IS writable and the
/// app was refused by Privacy & Security — so a user following that
/// advice inspects Get Info on Desktop, finds nothing wrong, and is
/// stuck. Aimed at the app's own cache it is meaningless, because the
/// folder is ours and the user cannot act on its permissions at all.
///
/// All three are kept short deliberately: the `<status-bar>` is one line
/// that elides rather than wraps, and the clause that says what to do is
/// the half worth keeping when something has to go.
fn writeFailureAdvice(destination: Destination) []const u8 {
    return switch (destination) {
        .beside_source => "check the folder's permissions.",
        .desktop => "check Privacy & Security.",
        // Nothing about permissions to offer: this is the app's own cache
        // directory, so a failure here is the disk or the OS having purged
        // it mid-run, neither of which is a folder the user can fix.
        .ask => "the disk may be full.",
    };
}

/// The whole sentence for a run where BOTH formats failed to write —
/// one shared cause said once (see the join). Its second clause matches
/// `writeFailureAdvice`'s for the same destination; only the opening
/// differs, because "Couldn't write to that folder — check the folder's
/// permissions." says folder twice.
fn writeFailureCollapsed(destination: Destination) []const u8 {
    return switch (destination) {
        .beside_source => "Couldn't write to that folder — check its permissions.",
        // NAMING the Desktop matters: the user never chose it, so "that
        // folder" would point at something they have no reason to think of.
        .desktop => "Couldn't write to your Desktop — check Privacy & Security.",
        .ask => "Couldn't write the compressed files — the disk may be full.",
    };
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
        // What to DO about it depends entirely on where the write was
        // aimed, so the advice follows `destination` rather than being one
        // generic sentence. Getting this wrong sends the user somewhere
        // they will find nothing amiss — see each arm.
        .write_failed => std.fmt.bufPrint(
            buffer,
            "Couldn't save the {s} — {s}",
            .{ label, writeFailureAdvice(model.destination) },
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
        // failed"; in Both mode it is the one path that may set `.failed`.
        //
        // Two failure sentences fit the status line only when both are the
        // short "X encoding failed." form. A shared WRITE failure — the
        // real case: a screenshot dropped from a read-only temp folder —
        // is "Couldn't save the AVIF … Couldn't save the WebP …" at ~113
        // chars, and the line elided the half that says what to do. So a
        // shared cause gets ONE sentence, and a `same_path` skip (never
        // the story when the whole run failed) yields to the format that
        // genuinely could not be produced.
        if (avif_failed and webp_failed) {
            if (model.avif_outcome == .write_failed or model.webp_outcome == .write_failed)
                return model.fail("{s}", .{writeFailureCollapsed(model.destination)});
            if (model.avif_outcome == .same_path)
                return model.fail("{s}", .{failureText(model, .webp, &webp_buffer)});
            if (model.webp_outcome == .same_path)
                return model.fail("{s}", .{failureText(model, .avif, &avif_buffer)});
            return model.fail("{s} {s}", .{
                failureText(model, .avif, &avif_buffer),
                failureText(model, .webp, &webp_buffer),
            });
        }
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

/// Overwrites the transient note (see `save_message_buffer`). Unlike
/// `fail`/`warn` there is never a second note to append beside it — only
/// one round is ever in flight.
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
/// The formats Smoosh PROMISES, named in the one failure a user sees for
/// a file it cannot read. It is a promise in two places at once:
/// `app.zon`'s `.file_associations` extension list has to accept every
/// format named here, or the Dock tile refuses a drag for a file the app
/// would have opened happily. `tests.zig` pins that agreement — the list
/// and this sentence cannot drift apart silently.
///
/// The set is deliberately smaller than what ImageIO can actually decode:
/// the probe rules on the bytes and will read more than this (BMP among
/// them). Naming fewer formats than are accepted is safe; naming more
/// than `app.zon` declares is not.
pub const unsupported_source_message = "Not an image. Try JPEG, PNG, HEIC, WebP, AVIF, TIFF or GIF.";

pub fn onDrop(drop: platform.FileDropEvent) ?Msg {
    if (drop.paths.len == 0) return null;
    return .{ .dropped_file = drop.paths[0] };
}

/// `dockopen.Handler` — a file dragged onto the Dock tile, or opened
/// through Finder's "Open With". It is NOT an `on_*` hook: the SDK has no
/// document channel, so this arrives on the delegate method
/// `src/dockopen.zig` adds and dispatches by hand.
///
/// `.dropped_file` rather than a Msg of its own, because there is nothing
/// to tell apart downstream — a Dock drop and a window drop are both an
/// absolute path to a file that already exists, and `beginLoad` is
/// indifferent to which one it got. A separate Msg would only be a second
/// name for the same arm.
///
/// Dispatching straight from an AppKit callback is what `UiApp.dispatch`
/// is for ("direct callers — command handlers, embedders, tests"), and it
/// is already correct BEFORE the first frame: a launch-with-document
/// request that beats the installing rebuild still applies to the model,
/// and the installing rebuild then renders the accumulated state. That is
/// the whole of the app-not-running case — there is no separate path.
fn onDockOpen(context: *anyopaque, path: []const u8) void {
    const bridge: *HostBridge = @ptrCast(@alignCast(context));
    // A rebuild failure here has nowhere to go: this is the bottom of an
    // Objective-C call, so returning an error would unwind into AppKit.
    // `dispatch` has already reported it through the app's own dispatch
    // error channel by this point.
    bridge.app_state.dispatch(bridge.runtime, main_window_id, .{ .dropped_file = path }) catch {};
}

/// The one chrome shortcut this app registers, and the id it dispatches.
///
/// **Cmd+V cannot go through `on_key`**, which is where every other key
/// in this app lives. Two things stand between a Command-modified key
/// and the canvas: AppKit resolves key EQUIVALENTS against the menu bar
/// before the responder chain, so the standard Edit menu's Paste item
/// claims it and the surface's `keyDown:` never runs; and the SDK's own
/// canvas view answers that menu item by re-emitting the chord only when
/// a text widget has focus — this window has no text widgets, so it
/// returns having done nothing. `RuntimeOptions.shortcuts` installs a
/// local `NSEventMaskKeyDown` monitor instead, which runs BEFORE
/// `NSApp.sendEvent:` and therefore before the menu ever sees the event.
///
/// Registration also has to be a modified key: `isValidShortcutBinding`
/// rejects a bare character precisely so a registration can never steal
/// typing.
const paste_shortcut_id = "app.paste";

pub const app_shortcuts = [_]platform.Shortcut{.{
    .id = paste_shortcut_id,
    .key = "v",
    // `primary` is the platform's own "the modifier shortcuts use" —
    // Command here. Stating `.command` instead would be the same key on
    // macOS and the wrong one everywhere else.
    .modifiers = .{ .primary = true },
}};

/// `Options.on_command` — the landing point for shortcut and menu
/// commands. `.paste` is safe unconditionally: the arm only issues a
/// host request, and an empty pasteboard is a named failure rather than
/// a bad state, so there is nothing to gate on here.
pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, paste_shortcut_id)) return .paste;
    return null;
}

/// Keyboard shortcuts, from `Options.on_key`. It only fires for keys
/// nothing else claimed — a Tab'd-to button keeps its own Enter/Space,
/// and this window has no text fields and no anchored surfaces to
/// compete. Plain keys only: any nav modifier or Shift means the user
/// meant a chord or a character. Enter runs the primary action, Esc
/// clears, 1/2/3 pick the format. Every one of these Msgs is safe when
/// it does not apply — `.smoosh` no-ops without a loaded file
/// (`hasPreview` guard in `update`), `.reset` is idempotent on an
/// already-idle model (its `fx.cancel`s hit dead keys, the model
/// rewrites the same defaults), and `.set_format` is just model state —
/// so the "only when a file is loaded" part needs no check here.
pub fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (keyboard.phase != .key_down) return null;
    if (keyboard.modifiers.hasNavigationModifier() or keyboard.modifiers.shift) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "enter")) return .smoosh;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "escape")) return .reset;
    if (std.mem.eql(u8, keyboard.key, "1")) return .{ .set_format = .avif };
    if (std.mem.eql(u8, keyboard.key, "2")) return .{ .set_format = .webp };
    if (std.mem.eql(u8, keyboard.key, "3")) return .{ .set_format = .both };
    return null;
}

/// True for a source sitting somewhere macOS may empty out from under us
/// between the preview and the Smoosh press. Pure over the path text, so
/// `update` can call it: no stat, no existence check, no `Io`.
///
/// The case this exists for is a screenshot dragged straight off its
/// floating thumbnail. `screencapture` serves that drag from a staging
/// directory under the per-user Darwin temp container, and a few seconds
/// later the OS MOVES the file to ~/Desktop — or deletes it outright, if
/// the thumbnail was dismissed. The load chain reads the file three times
/// (probe, thumbnail, then the encode worker's full-resolution decode) and
/// the third read is the one the user waits for, so an image that
/// previewed perfectly would fail to encode. The window is seconds wide
/// and entirely outside our control; the only fix is to own the bytes.
///
/// Deliberately COARSE — every listed root is a place the OS owns, and a
/// stash of a file that would in fact have survived costs one copy of an
/// image already capped at 100 MB. Being wrong the other way costs the
/// user their smoosh.
///
/// `/private` prefixes appear because `/tmp` and `/var` are symlinks into
/// `/private` on macOS and different producers hand out different spellings
/// of the same directory — a drop may carry either. `TemporaryItems`
/// (`.TemporaryItems` on a non-boot volume) is matched anywhere in the
/// path: it is the staging directory Finder and AppKit use for a drag
/// promise, and on an external volume it lives at the volume root rather
/// than under any of these prefixes.
pub fn isEphemeralSource(path: []const u8) bool {
    const roots = [_][]const u8{
        "/tmp/",
        "/private/tmp/",
        "/var/tmp/",
        "/private/var/tmp/",
        "/var/folders/",
        "/private/var/folders/",
    };
    for (roots) |root| {
        if (std.mem.startsWith(u8, path, root)) return true;
    }
    return std.mem.indexOf(u8, path, "/TemporaryItems/") != null or
        std.mem.indexOf(u8, path, "/.TemporaryItems/") != null;
}

/// True when the source is a macOS screenshot — the ONE case where the
/// app is willing to write somewhere the user did not point at. Pure over
/// the path text, like `isEphemeralSource`.
///
/// The justification for the special case is narrow and worth stating: a
/// screenshot in an unwritable folder is one macOS itself parked there,
/// not one the user filed. Its owner already expects to find it in the
/// screenshot folder, so putting the compressed copies there too is
/// following the file rather than guessing. NOTHING ELSE gets this
/// treatment — an ordinary photo on a read-only volume goes to `.ask`.
///
/// Two signals, either sufficient:
///  - the BASENAME starts with "Screenshot", macOS's own default naming;
///  - the path runs through `screencaptureui`'s staging directory, which
///    covers a drag off the floating thumbnail whatever the file is named.
///
/// The residual is a LOCALIZED screenshot name — a German system writes
/// "Bildschirmfoto 2026-09-08 um 10.14.02.png", which the first signal
/// misses. Such a file dragged from the thumbnail still matches the
/// second; one already filed in an unwritable folder falls to `.ask`, and
/// gets a Save As instead of a wrong guess. That is the safe direction to
/// be wrong in, and reading the real localized prefix means a
/// `CFBundleCopyLocalizedString` binding this app has no other use for.
pub fn looksLikeScreenshot(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "screencaptureui") != null) return true;
    const name_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| slash + 1 else 0;
    return std.mem.startsWith(u8, path[name_start..], "Screenshot");
}

/// `file.destination`'s answer: `"<0|1>\x00<screenshot dir>\x00<outbox dir>"`.
/// The flag is whether the SOURCE's own folder took a probe write; the two
/// directories are the fallbacks, always sent so `update` can pick between
/// them without a second round trip. NUL-delimited for the same reason
/// `encodePayload` is: both fields are paths, and a path may contain a
/// newline.
pub const DestinationInfo = struct {
    source_dir_writable: bool,
    screenshot_dir: []const u8,
    outbox_dir: []const u8,
};

pub fn parseDestinationReply(bytes: []const u8) ?DestinationInfo {
    var it = std.mem.splitScalar(u8, bytes, 0);
    const flag = it.next() orelse return null;
    if (flag.len != 1 or (flag[0] != '0' and flag[0] != '1')) return null;
    const screenshot_dir = it.next() orelse return null;
    const outbox_dir = it.next() orelse return null;
    return .{
        .source_dir_writable = flag[0] == '1',
        .screenshot_dir = screenshot_dir,
        .outbox_dir = outbox_dir,
    };
}

/// `strftime` over `localtime`, for `pastedName`. The `tm` it passes
/// between them is OPAQUE — the two calls are libc's own pair, so its
/// layout never has to be restated here, and getting a hand-written
/// Darwin `struct tm` subtly wrong is exactly the silent corruption this
/// avoids. `localtime` keeps its result in a static, which is safe here
/// because the one caller runs on the loop thread.
const CTm = opaque {};
extern "c" fn time(destination: ?*i64) i64;
extern "c" fn localtime(clock: *const i64) ?*CTm;
extern "c" fn strftime(buffer: [*]u8, size: usize, format: [*:0]const u8, timeptr: *const CTm) usize;

/// The name a raw-bytes paste is filed under: `smoosh-2026-09-10-143005`,
/// extension added by the caller.
///
/// **LOCAL time, not UTC** — the name is read by a person looking at
/// their Desktop, and one stamped four hours off their own clock is
/// worse than no stamp. Seconds-resolution and no collision check: two
/// pastes cannot land in the same second by hand, and the pasteboard
/// would have to change between them for the collision to even matter.
/// A re-press of Smoosh on the SAME pasted image deliberately does
/// reuse the name — it is fixed at paste time, so a redo overwrites its
/// own outputs, which is what the overwrite policy says a redo is.
///
/// The shape is `%Y-%m-%d-%H%M%S` rather than macOS's own screenshot
/// spelling ("2026-09-10 at 14.30.05") because this one has no spaces
/// and no dots before the extension: it survives a shell, a URL and a
/// `find` invocation untouched, which a name the user will plausibly
/// pipe somewhere should.
pub fn pastedName(buffer: []u8) ?[]const u8 {
    const now = time(null);
    const parts = localtime(&now) orelse return null;
    const len = strftime(buffer.ptr, buffer.len, "smoosh-%Y-%m-%d-%H%M%S", parts);
    // `strftime` answers 0 for a buffer that could not hold the result,
    // and cannot otherwise produce an empty string from this format.
    if (len == 0) return null;
    return buffer[0..len];
}

/// `clipboard.paste`'s answer, split. See `HostBridge.pasteImage` for
/// what the bridge puts in each half.
pub const PasteInfo = struct {
    /// The path the run is about — a real file for the Finder-copy
    /// shape, an invented name in a real directory for the raw-bytes
    /// one.
    nominal: []const u8,
    /// Where the bytes are, when that is not `nominal`. Empty for the
    /// Finder-copy shape, which needs no indirection.
    read: []const u8,
};

/// `"<nominal>\x00<read>"`, the NUL-delimited shape
/// `parseDestinationReply` already uses. A missing second field is
/// malformed rather than an empty `read`: the bridge always writes the
/// separator, so its absence means the reply is not one of ours.
pub fn parsePasteReply(bytes: []const u8) ?PasteInfo {
    var it = std.mem.splitScalar(u8, bytes, 0);
    const nominal = it.next() orelse return null;
    if (nominal.len == 0) return null;
    const read = it.next() orelse return null;
    return .{ .nominal = nominal, .read = read };
}

/// Starts the load chain for a path that just arrived — from the open
/// panel (`.dialog_result`'s ok branch) or a real window drop
/// (`.dropped_file`). Both land here because the chain itself doesn't
/// care where the path came from: `stat_result` -> `probe_result` ->
/// `thumbnail_result` -> `.ready` is the same either way.
///
/// An EPHEMERAL source gets one extra hop in front: `file.stash` copies
/// the bytes into the app cache dir and answers with the copy's path,
/// which `.stash_result` records before starting that same chain. The
/// stat runs against the stash for the same reason everything else does —
/// by then the original may already be gone, and a size read off a file
/// that no longer exists would fail the load for the wrong reason.
fn beginLoad(model: *Model, fx: *Effects, path: []const u8) void {
    model.status = .loading;
    model.setPath(path);
    // A new file invalidates the previous file's outputs and preview —
    // see `clearResults`/`clearPreview`'s own doc comments for why each
    // exists.
    model.clearResults();
    model.clearPreview();
    if (isEphemeralSource(path)) {
        fx.hostRequest(.{
            .key = stash_key,
            .name = host_file_stash,
            .payload = model.path(),
            .on_result = Effects.hostMsg(.stash_result),
        });
        return;
    }
    beginStat(model, fx);
}

/// `beginLoad` for a source whose bytes are ALREADY somewhere of our
/// own: the paste of raw pasteboard pixels, which the bridge has written
/// into the cache before answering (`HostBridge.pasteImage`).
///
/// `nominal` is the path the run is ABOUT — the name on the file card,
/// what `outputPath` derives from, and what the destination probe asks
/// about. For a paste it names a file that does not exist and never
/// will; only its DIRECTORY is real. `read` is where the bytes actually
/// are. That split is exactly what `Model.stash_path_buffer` already
/// means, so the paste rides the machinery the ephemeral-source stash
/// built rather than a second one — with the `file.stash` hop skipped,
/// because the copy has already happened.
fn beginLoadStashed(model: *Model, fx: *Effects, nominal: []const u8, read: []const u8) void {
    model.status = .loading;
    model.setPath(nominal);
    model.clearResults();
    model.clearPreview();
    // AFTER `setPath`, which clears the stash: a new file's reads start
    // at the new file, and this one's reads start at the copy.
    model.setStashPath(read);
    beginStat(model, fx);
}

/// The load chain proper, from the stat on. Split out of `beginLoad` so
/// the stash hop can rejoin it without duplicating the request.
fn beginStat(model: *Model, fx: *Effects) void {
    fx.hostRequest(.{
        .key = stat_key,
        .name = host_file_size,
        .payload = model.readPath(),
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
                // Cancelled, or the panel itself failed — not an error
                // state. `.pick_file` set `.loading` optimistically; undo
                // exactly that here.
                //   - nothing loaded  -> back to `.idle`.
                //   - a previous image still on screen (`hasPreview`, and
                //     still `.loading`) -> back to `.ready`.
                // Any OTHER `.loading`/`.failed` belongs to a real load
                // that started since (a drop, or a pick that resolved):
                // `beginLoad` cleared the preview, so `hasPreview` is
                // false and that load keeps `status` — a failure included,
                // which must not be stomped back to `.ready`.
                if (!model.hasFile()) {
                    model.status = .idle;
                } else if (model.hasPreview() and model.status == .loading) {
                    model.status = .ready;
                }
                return;
            }
            beginLoad(model, fx, result.bytes);
        },

        // A real drag onto the window. `onDrop` (pure, no model access)
        // already reduced the drop to one path; from here it is the exact
        // same chain a dialog pick starts — a picked-file and a
        // dropped-file are indistinguishable to `update` past this point.
        .dropped_file => |dropped_path| beginLoad(model, fx, dropped_path),

        // Cmd+V. The pasteboard cannot be read from `update` — it is an
        // AppKit call, and `update` is pure — so this is a host command
        // like every other acquisition, and the arm is just the request.
        // `.loading` optimistically, exactly as `.pick_file` does: the
        // raw-bytes shape writes a file before it answers, and that is
        // the one moment a paste is not instant.
        .paste => {
            model.status = .loading;
            fx.hostRequest(.{
                .key = paste_key,
                .name = host_clipboard_paste,
                .on_result = Effects.hostMsg(.paste_result),
            });
        },

        // The pasteboard's answer, in the one shape both payloads share:
        // a path the run is ABOUT, and optionally a second path the bytes
        // are actually AT (see `beginLoadStashed`).
        //
        // A failure here is the empty/text clipboard, and it is reported
        // rather than swallowed: the user pressed a key and is owed an
        // answer. It deliberately does NOT clear a file already loaded —
        // nothing was acquired, so there is nothing to replace, and the
        // card the user was looking at stays put behind the message.
        .paste_result => |result| {
            if (!result.ok) return model.fail("No image on the clipboard.", .{});
            const paste = parsePasteReply(result.bytes) orelse
                return model.fail("No image on the clipboard.", .{});
            if (paste.read.len == 0) {
                // A file copied in Finder: an ordinary path, and from
                // here indistinguishable from a pick or a drop — the
                // ephemeral check in `beginLoad` included, since a file
                // copied out of /tmp is as perishable as one dragged.
                beginLoad(model, fx, paste.nominal);
            } else {
                beginLoadStashed(model, fx, paste.nominal, paste.read);
            }
        },

        // The ephemeral-source hop (see `beginLoad`). A failure here is
        // reported as an unreadable file, which is exactly what it is: the
        // copy failed because the source was already gone, or because the
        // cache dir could not be resolved or written. Deliberately NOT a
        // fall-through to reading the original — if the stash could not be
        // taken, the original is the thing that is disappearing, and going
        // on would just move the same failure to the encode, minutes of
        // user attention later.
        .stash_result => |result| {
            if (!result.ok) return model.fail("Can't read that file.", .{});
            model.setStashPath(result.bytes);
            beginStat(model, fx);
        },

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
            // point — the guard runs before a single pixel is decoded.
            fx.hostRequest(.{
                .key = probe_key,
                .name = host_image_probe,
                .payload = model.readPath(),
                .on_result = Effects.hostMsg(.probe_result),
            });
        },

        // The FORMAT GATE, and the megapixel gate, both before a single
        // pixel is decoded. A failure here is the undecodable-input state:
        // `imageio.probe` reports it off the frame COUNT rather than off a
        // null source, because `CGImageSourceCreateWithURL` succeeds on 49
        // bytes of text named `.jpg`.
        //
        // An unparseable answer is NOT tolerated, because there is no
        // later gate to defer to: the thumbnail is the same ImageIO read,
        // so a probe that could not name the image's size is a file the
        // preview cannot draw either.
        .probe_result => |result| {
            if (!result.ok) {
                // Unsupported or undecodable input.
                return model.fail(
                    unsupported_source_message,
                    .{},
                );
            }
            const info = parseProbeReply(result.bytes) orelse return model.fail(
                unsupported_source_message,
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
                .payload = model.readPath(),
                .on_result = Effects.hostMsg(.thumbnail_result),
            });
        },

        // No staleness guard on this arm or `.probe_result` above, and
        // none is needed: every hop of the load chain is a HOST request,
        // and a cancelled one delivers no Msg at all — a queued answer dies
        // by generation mismatch at drain (`cancelHostRequest`). A second
        // pick mid-load replaces the in-flight request on the same key and
        // drops its answer the same way. The encode chain below still
        // guards, because a worker already running cannot be cancelled.
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
            // The last hop before `.ready`: WHERE this file's outputs can
            // go. It runs at load rather than at the Smoosh press so the
            // answer is in hand before the button is live, and it probes
            // the SOURCE's folder (`path()`, never `readPath()`) — the
            // stash lives in a cache directory that is always writable
            // and would answer the wrong question.
            fx.hostRequest(.{
                .key = destination_key,
                .name = host_destination,
                .payload = model.path(),
                .on_result = Effects.hostMsg(.destination_result),
            });
        },

        // Chooses between the three `Destination` arms. `update` decides,
        // not the bridge: the bridge reports only what it alone can know
        // (did the folder take a write, and where are the two fallback
        // directories), and the policy over those facts stays pure and
        // testable here.
        .destination_result => |result| {
            model.destination = .beside_source;
            model.dest_dir_len = 0;
            if (result.ok) {
                if (parseDestinationReply(result.bytes)) |info| {
                    // An EPHEMERAL source's folder is doomed, not
                    // unwritable, and the probe cannot tell the
                    // difference: `/var/folders/.../screencaptureui/` is
                    // the user's own temp directory and takes a write
                    // happily right up until macOS tears it down, which
                    // it does seconds after the drag. The probe wins that
                    // race almost always — it runs during the load — and
                    // the encode, which runs whenever the user gets round
                    // to pressing Smoosh, almost always loses it. The
                    // result was an output written into a directory that
                    // no longer existed, reported as a folder-permissions
                    // failure it was never about.
                    //
                    // So ephemerality forces the same branch unwritability
                    // does. `isEphemeralSource` is the SAME predicate that
                    // decided to stash the bytes in the first place, and
                    // it has to be: any source whose bytes were worth
                    // rescuing has a folder not worth writing to. A
                    // screenshot then lands on the Desktop (where macOS
                    // was about to put it anyway) and anything else falls
                    // to `.ask`.
                    if (!info.source_dir_writable or isEphemeralSource(model.path())) {
                        if (looksLikeScreenshot(model.path())) {
                            model.destination = .desktop;
                            model.setDestDir(info.screenshot_dir);
                        } else {
                            model.destination = .ask;
                            model.setDestDir(info.outbox_dir);
                        }
                    }
                }
            }
            // A probe that could not run at all is NOT a load failure —
            // it degrades to the behaviour that predates it. The write is
            // still attempted beside the source and still reports
            // `.write_failed` with the folder-permissions message if it
            // cannot land, which is exactly where this started.
            model.status = .ready;
        },

        .reset => {
            // Nothing in flight may land on the next model. Every hop is
            // a HOST request, and a cancelled one delivers no Msg — its
            // queued answer dies by generation mismatch at drain. An encode
            // worker already running keeps going and may still write its
            // output file (there is nothing to kill), but its result is
            // dropped and the `status` check in `.encode_result` is a
            // second guard. `cancel` on an idle key is a no-op.
            //
            // These cancels are about DROPPING STALE ANSWERS, not about
            // freeing the key space. A same-key host occupancy is REPLACED,
            // never rejected (`effects.zig`'s `startHostRequest`: "a same-key
            // HOST occupancy is replaced, never rejected" — the old result
            // dies by generation mismatch), so a re-pick straight after a
            // reset would have gone through regardless. Only the other keyed
            // families — staged images, channels, ptys — reject a busy key,
            // and Smoosh issues none of them.
            fx.cancel(dialog_key);
            fx.cancel(stash_key);
            fx.cancel(stat_key);
            fx.cancel(probe_key);
            fx.cancel(thumbnail_key);
            fx.cancel(destination_key);
            fx.cancel(paste_key);
            fx.cancel(avif_encode_key);
            fx.cancel(webp_encode_key);
            fx.cancel(save_dialog_key);
            fx.cancel(save_copy_key);
            _ = fx.unregisterImage(preview_image_id);
            // Reset clears PER-FILE state. Two things survive it because
            // neither describes the file: the format preference, and the
            // appearance — the latter arrives once, from the OS, and
            // wiping it would re-theme the window on a Reset press until
            // the next system flip.
            const format = model.format;
            const color_scheme = model.color_scheme;
            const high_contrast = model.high_contrast;
            const reduce_motion = model.reduce_motion;
            const scheme_pinned = model.scheme_pinned;
            model.* = .{
                .format = format,
                .color_scheme = color_scheme,
                .high_contrast = high_contrast,
                .reduce_motion = reduce_motion,
                .scheme_pinned = scheme_pinned,
            };
        },

        .set_format => |format| model.format = format,

        .appearance_changed => |appearance| {
            // A pinned scheme is the user's, not the OS's — see
            // `scheme_pinned`. The other two always follow the system.
            if (!model.scheme_pinned) model.color_scheme = appearance.color_scheme;
            model.high_contrast = appearance.high_contrast;
            model.reduce_motion = appearance.reduce_motion;
        },

        .toggle_color_scheme => {
            model.color_scheme = switch (model.color_scheme) {
                .light => .dark,
                .dark => .light,
            };
            model.scheme_pinned = true;
        },

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
            // the source (HEIC included — ImageIO reads it directly) and
            // writes the output itself.
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

        .reveal_hover_on => model.reveal_hovered = true,
        .reveal_hover_off => model.reveal_hovered = false,
        .avif_save_hover_on => model.avif_save_hovered = true,
        .avif_save_hover_off => model.avif_save_hovered = false,
        .webp_save_hover_on => model.webp_save_hovered = true,
        .webp_save_hover_off => model.webp_save_hovered = false,

        .show_in_finder => {
            // Newline-joined, the same shape `file.copy` and the SDK's own
            // multi-path dialog results use. A Both run sends both paths so
            // Finder opens once with both files selected; a partial run
            // sends the one that landed.
            var payload_buffer: [platform.max_dialog_path_bytes * 2 + 1]u8 = undefined;
            var len: usize = 0;
            for ([_]Output{ .avif, .webp }) |output| {
                if (outcomeOf(model, output) != .ok) continue;
                const path = outputPathOf(model, output);
                if (len > 0) {
                    payload_buffer[len] = '\n';
                    len += 1;
                }
                @memcpy(payload_buffer[len..][0..path.len], path);
                len += path.len;
            }
            if (len == 0) return; // `canReveal` already gates the button
            fx.hostRequest(.{
                .key = reveal_key,
                .name = host_reveal,
                .payload = payload_buffer[0..len],
                .on_result = Effects.hostMsg(.reveal_result),
            });
        },

        // Success is silent: Finder coming forward with the files selected
        // IS the feedback, and a "Shown." note would push a real Save As
        // message off the status line for nothing. Only the failure — the
        // file was moved or deleted between the write and the press —
        // needs saying, because AppKit's own response to a dead URL is to
        // do nothing at all.
        .reveal_result => |result| {
            if (result.ok) return;
            setSaveMessage(model, "Those files aren’t there anymore.", .{});
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
///    the supported seam is instead the `poll_fn`/`pending_fn`/
///    `bind_services_fn` trio plus `shutdown_fn`), so a worker never calls
///    it — it parks its answer and nudges the loop, which drains and feeds
///    on the right thread.
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
    /// `stashFile`'s answer is a PATH, which `reply_buf` (sized for a
    /// decimal byte count) cannot hold.
    var stash_path_buf: [platform.max_dialog_path_bytes]u8 = undefined;
    /// `destinationFor`'s answer carries two paths and a flag.
    var destination_reply_buf: [platform.max_dialog_path_bytes * 2 + 4]u8 = undefined;
    /// `pasteImage`'s two answers: the pasteboard's own path (or the
    /// invented nominal one), and the NUL-joined reply built from it.
    var paste_path_buf: [platform.max_dialog_path_bytes]u8 = undefined;
    var paste_reply_buf: [platform.max_dialog_path_bytes * 2 + 1]u8 = undefined;

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
    /// (`startEncode` -> "no worker slot" -> one `.encode_failed`). Each
    /// encode worker
    /// also holds a full-resolution decode transiently (~w·h·4, ≤200 MB at
    /// the 50 MP guard); two at once is fine, and the guard has already run
    /// off `probe` before any encode starts.
    const worker_slot_count = 8;

    const Job = enum { probe, thumbnail, encode_avif, encode_webp };

    /// A worker's whole world. Its result buffer is sized for the largest
    /// answer any job can produce — a preview at the full thumbnail cap
    /// on both edges (the encode
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

    fn requestFn(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
        const self: *HostBridge = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, name, host_open_file)) return self.openFile(key);
        if (std.mem.eql(u8, name, host_file_size)) return self.fileSize(key, payload);
        if (std.mem.eql(u8, name, host_save_file)) return self.saveFile(key, payload);
        if (std.mem.eql(u8, name, host_file_copy)) return self.copyFile(key, payload);
        if (std.mem.eql(u8, name, host_file_stash)) return self.stashFile(key, payload);
        if (std.mem.eql(u8, name, host_clipboard_paste)) return self.pasteImage(key);
        if (std.mem.eql(u8, name, host_destination)) return self.destinationFor(key, payload);
        if (std.mem.eql(u8, name, host_reveal)) return self.revealPaths(key, payload);
        // The ImageIO reads and the encode return without answering — see
        // the worker carrier above.
        if (std.mem.eql(u8, name, host_image_probe)) return self.startWorker(key, .probe, payload);
        if (std.mem.eql(u8, name, host_image_thumbnail)) return self.startWorker(key, .thumbnail, payload);
        if (std.mem.eql(u8, name, host_image_encode)) return self.startEncode(key, payload);
        self.reply(key, false, "unknown host command");
    }

    /// **No `filters`, deliberately.** `OpenDialogOptions.filters`
    /// defaults to empty, which shows everything, and that is the right
    /// answer here: `image.probe` is the real gate — it rules on the
    /// BYTES and its failure is already a named error state naming the
    /// supported formats — and the two other ways in never consult a
    /// list at all. A drop and a paste hand the path straight to
    /// `beginLoad`, so any extension list here is a set of files the
    /// user can drag in but cannot pick, which reads as a bug rather
    /// than a filter. A partial list is worse than none: `avif` was
    /// missing from it through v0.5 and greyed out real, decodable
    /// images in the panel. Do not reintroduce one.
    fn openFile(self: *HostBridge, key: u64) void {
        const result = self.runtime.showOpenDialog(.{
            .title = "Choose an image to smoosh",
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

    /// Copies an ephemeral source into the app cache dir and answers with
    /// the copy's absolute path. `payload` is the source path. Synchronous
    /// on the loop thread like the other file commands: the input is capped
    /// at 100 MB, and the whole reason this exists is that the source is
    /// disappearing — handing the copy to a worker would add exactly the
    /// delay being raced.
    ///
    /// Only ONE stash is kept. The directory is deleted whole and remade on
    /// every call, so the cache holds at most one image and a load that
    /// never gets smooshed leaves nothing behind past the next load. It is
    /// `Library/Caches`, which the OS may purge at any time — safe here,
    /// because the stash is only read during the seconds a load is live.
    ///
    /// The source's own basename is kept: it costs nothing, and it is what
    /// a user staring at the cache directory would expect to find. The
    /// extension is NOT what any read keys on — `image.probe` sniffs the
    /// container out of the bytes.
    /// `$HOME`, or null when the process has none. `std.c.getenv` rather
    /// than an `Environ`: a hand-authored root never receives the runner's
    /// env map (see CLAUDE.md's "File acquisition, honestly"), and this
    /// links libc regardless.
    fn homeDir() ?[]const u8 {
        const home_z = std.c.getenv("HOME") orelse return null;
        return std.mem.span(home_z);
    }

    /// `<cache>/<child>` for this app, e.g. `~/Library/Caches/smoosh/staged`.
    fn cacheSubdir(child: []const u8, buffer: []u8) ?[]const u8 {
        const home = homeDir() orelse return null;
        var dir_buf: [platform.max_dialog_path_bytes]u8 = undefined;
        const cache_dir = native_sdk.app_dirs.resolveOne(
            .{ .name = "smoosh" },
            .macos,
            .{ .home = home },
            .cache,
            &dir_buf,
        ) catch return null;
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ cache_dir, child }) catch null;
    }

    fn stashFile(self: *HostBridge, key: u64, source: []const u8) void {
        var staged_buf: [platform.max_dialog_path_bytes]u8 = undefined;
        const staged_dir = cacheSubdir("staged", &staged_buf) orelse
            return self.reply(key, false, "no cache dir");
        // Best-effort: a first run has nothing to delete, and a stash left
        // by a crashed run is exactly what this is clearing.
        std.Io.Dir.cwd().deleteTree(self.io, staged_dir) catch {};
        std.Io.Dir.cwd().createDirPath(self.io, staged_dir) catch |err| {
            return self.reply(key, false, @errorName(err));
        };

        const name_start = if (std.mem.lastIndexOfScalar(u8, source, '/')) |slash| slash + 1 else 0;
        const destination = std.fmt.bufPrint(&stash_path_buf, "{s}/{s}", .{ staged_dir, source[name_start..] }) catch
            return self.reply(key, false, "stash path too long");
        std.Io.Dir.copyFileAbsolute(source, destination, self.io, .{}) catch |err| {
            return self.reply(key, false, @errorName(err));
        };
        self.reply(key, true, destination);
    }

    /// Reads the general pasteboard and answers
    /// `"<nominal>\x00<read>"` — the two paths `parsePasteReply` splits.
    ///
    /// Two payload shapes, and the FILE URL is tried first because it is
    /// strictly better: a real path keeps the file's own name and lands
    /// the outputs beside the original, which raw bytes can only invent.
    /// It answers with an empty `read`, so `update` runs the ordinary
    /// load — the ephemeral stash included, since an image copied out of
    /// /tmp is as perishable as one dragged from there.
    ///
    /// Raw bytes (a Cmd-Ctrl-Shift-4 screenshot, "Copy Image" in a
    /// browser) have no name and no home, so this invents both:
    ///
    ///  - the bytes go to the cache `staged` directory, the same single
    ///    slot `stashFile` uses and clears the same way, and that is the
    ///    `read` path;
    ///  - the `nominal` path is `~/Desktop/smoosh-<timestamp>.png`. It is never
    ///    written. It exists so the machinery downstream has a name and a
    ///    DIRECTORY to reason about, and the Desktop is the honest answer
    ///    to "where does an image with no source folder go" — the same
    ///    call v0.5 already makes for a screenshot stranded somewhere
    ///    read-only.
    ///
    /// The nominal name is a LOCAL TIMESTAMP (`pastedName`), which is
    /// what keeps two different pastes from clobbering each other's
    /// outputs on the Desktop — the silent-overwrite policy is about
    /// re-running on the same source, and two pastes are not that. It
    /// also reads: a Desktop of `smoosh-2026-09-10-143005.avif` says
    /// which is which, where a counter would not.
    ///
    /// Synchronous on the loop thread, like the other file commands and
    /// for the same reason `stashFile` is — AppKit's pasteboard is
    /// main-thread-only, so the read could not move off it even if the
    /// write could.
    fn pasteImage(self: *HostBridge, key: u64) void {
        if (pasteboard.filePath(&paste_path_buf)) |path| {
            const reply_text = std.fmt.bufPrint(&paste_reply_buf, "{s}\x00", .{path}) catch
                return self.reply(key, false, "paste path too long");
            return self.reply(key, true, reply_text);
        }

        const kind = pasteboard.imageKind() orelse
            return self.reply(key, false, "no image on the pasteboard");

        const home = homeDir() orelse return self.reply(key, false, "no home dir");
        var desktop_buf: [platform.max_dialog_path_bytes]u8 = undefined;
        const desktop = std.fmt.bufPrint(&desktop_buf, "{s}/Desktop", .{home}) catch
            return self.reply(key, false, "desktop path too long");

        var name_buf: [64]u8 = undefined;
        const name = pastedName(&name_buf) orelse
            return self.reply(key, false, "could not name the pasted image");
        const nominal = std.fmt.bufPrint(&paste_path_buf, "{s}/{s}.{s}", .{
            desktop,
            name,
            kind.extension(),
        }) catch return self.reply(key, false, "paste path too long");

        var staged_buf: [platform.max_dialog_path_bytes]u8 = undefined;
        const staged_dir = cacheSubdir("staged", &staged_buf) orelse
            return self.reply(key, false, "no cache dir");
        // Same single-slot discipline as `stashFile`: the directory is
        // deleted whole and remade, so the cache never accumulates
        // pastes. Best-effort — a first run has nothing to delete.
        std.Io.Dir.cwd().deleteTree(self.io, staged_dir) catch {};
        std.Io.Dir.cwd().createDirPath(self.io, staged_dir) catch |err| {
            return self.reply(key, false, @errorName(err));
        };
        const staged = std.fmt.bufPrint(&stash_path_buf, "{s}/{s}.{s}", .{
            staged_dir,
            name,
            kind.extension(),
        }) catch return self.reply(key, false, "stash path too long");

        if (!pasteboard.writeImage(kind, staged)) {
            return self.reply(key, false, "could not write the pasted image");
        }

        const reply_text = std.fmt.bufPrint(&paste_reply_buf, "{s}\x00{s}", .{ nominal, staged }) catch
            return self.reply(key, false, "paste path too long");
        self.reply(key, true, reply_text);
    }

    /// Answers `"<0|1>\x00<screenshot dir>\x00<outbox dir>"` for the source
    /// path in `payload` — the three facts `update` needs to pick a
    /// `Destination` and cannot work out itself.
    ///
    /// The flag comes from a REAL WRITE, not from a mode bit: create a
    /// uniquely-named temp file in the source's own directory and unlink
    /// it. Nothing short of that is honest here — a directory can be
    /// mode 0755 and owned by you and still refuse the write (a read-only
    /// mount, a full disk, a sandbox denial, an ACL), and every one of
    /// those is a case this exists to catch. The probe file is created
    /// truncating rather than exclusive, and removed immediately: a crash
    /// between the two leaves one zero-byte dotfile behind, and exclusive
    /// creation would then report that still-writable folder as read-only
    /// forever. Nothing but this command writes a file of that name, so
    /// clobbering one costs nothing.
    ///
    /// The outbox is created eagerly because `.ask` needs somewhere for
    /// the encode to land, and creating it here means `beginEncode` never
    /// has to. The screenshot directory is NOT created: it is `~/Desktop`,
    /// which exists, and if it somehow does not the write reports its own
    /// failure rather than this command inventing a folder.
    fn destinationFor(self: *HostBridge, key: u64, source: []const u8) void {
        const dir_end = std.mem.lastIndexOfScalar(u8, source, '/') orelse
            return self.reply(key, false, "no directory");
        // A source at the volume root ("/photo.jpg") has an empty parent
        // by this slicing; "/" is the directory it means.
        const source_dir = if (dir_end == 0) source[0..1] else source[0..dir_end];

        var probe_buf: [platform.max_dialog_path_bytes]u8 = undefined;
        const probe_path = std.fmt.bufPrint(
            &probe_buf,
            "{s}/.smoosh-write-probe-{d}",
            .{ source_dir, std.c.getpid() },
        ) catch return self.reply(key, false, "probe path too long");
        const writable = blk: {
            const file = std.Io.Dir.cwd().createFile(self.io, probe_path, .{}) catch
                break :blk false;
            file.close(self.io);
            std.Io.Dir.cwd().deleteFile(self.io, probe_path) catch {};
            break :blk true;
        };

        // Both fallbacks are sent on every answer, writable or not: they
        // are constants for the process, and one round trip that carries
        // everything beats a second one at the moment a decision is made.
        const home = homeDir() orelse "";
        var screenshot_buf: [platform.max_dialog_path_bytes]u8 = undefined;
        const screenshot_dir = if (home.len == 0)
            ""
        else
            std.fmt.bufPrint(&screenshot_buf, "{s}/Desktop", .{home}) catch "";

        var outbox_buf: [platform.max_dialog_path_bytes]u8 = undefined;
        const outbox_dir = blk: {
            const dir = cacheSubdir("outbox", &outbox_buf) orelse break :blk "";
            std.Io.Dir.cwd().createDirPath(self.io, dir) catch break :blk "";
            break :blk dir;
        };

        const reply_text = std.fmt.bufPrint(&destination_reply_buf, "{s}\x00{s}\x00{s}", .{
            if (writable) "1" else "0",
            screenshot_dir,
            outbox_dir,
        }) catch return self.reply(key, false, "reply too long");
        self.reply(key, true, reply_text);
    }

    /// "Show in Finder". `payload` is one or more newline-joined absolute
    /// paths, the same shape `copyFile` takes.
    ///
    /// Paths are STATTED here before the reveal, and a path that no longer
    /// exists is dropped. That check is not defensive noise: it is the only
    /// way this command can ever fail usefully.
    /// `activateFileViewerSelectingURLs:` returns void and silently does
    /// nothing for a URL with no file behind it, so without the stat a
    /// press on a deleted output would look identical to a press that
    /// worked — Finder simply would not appear. Dropping the dead paths
    /// also means a Both run whose AVIF was deleted still reveals the WebP
    /// rather than failing whole.
    fn revealPaths(self: *HostBridge, key: u64, payload: []const u8) void {
        var paths: [workspace.max_paths][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, payload, '\n');
        while (it.next()) |path| {
            if (path.len == 0) continue;
            if (count == paths.len) break;
            _ = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch continue;
            paths[count] = path;
            count += 1;
        }
        if (count == 0) return self.reply(key, false, "gone");
        if (!workspace.reveal(paths[0..count])) return self.reply(key, false, "reveal failed");
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
        .app_name = app_name,
        .display_name = app_display_name,
        .version = app_version,
        .description = app_description,
        .bundle_id = app_bundle_id,
        .window_title = window_title,
        .main_window = .{
            .id = main_window_id,
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
        .on_key = onKey,
        .on_command = onCommand,
        .tokens_fn = tokens,
        .on_appearance = onAppearance,
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
        // Installed on the platform at start-up (`flow.zig`'s
        // `configureShortcuts`) and delivered back as a `.command` event
        // that `on_command` maps. See `app_shortcuts`.
        .shortcuts = &app_shortcuts,
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

    // Dock-tile drops and Finder's "Open With", through a delegate method
    // added to the SDK's own app delegate. MUST be here: after `bridge` is
    // populated (the handler dereferences it) and before `runtime.run`,
    // which is where the host sets `NSApp.delegate` and AppKit snapshots
    // which methods that delegate has. See `src/dockopen.zig`'s header.
    //
    // The answer is deliberately not checked. A false here means Dock
    // drops never arrive; the window drop, the paste and the picker are
    // all untouched, and there is no user-facing state that could honestly
    // report it — the app cannot tell a delegate it failed to extend from
    // a Dock the user never drags onto.
    _ = dockopen.install(bridge, onDockOpen);

    try runtime.run(app_state.app());
}

test {
    _ = @import("tests.zig");
    // Reachable under `native test` because `build.zig` states the ImageIO
    // frameworks on the test artifact's module — the SDK's own platform
    // wiring never reaches it. See `build.zig` before adding a library.
    _ = @import("imageio_tests.zig");
}
