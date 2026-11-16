/*
A surface for Ableton Push 2, made with the kit, on the host's fsurf.daw:
its display over USB, its pads, encoders and buttons over MIDI. From
Ableton's published interface (github.com/Ableton/push-interface).

- **Ports:** the User Port (Ableton Live keeps the Live Port; turn Live's
  Track/Sync/Remote switches for Push 2's User Port off to run both).
  When it starts it sets its colours, turns the display's backlight on and
  puts Push 2 in User mode; when it stops, back in Live mode.
- **The display** (960 x 160, USB bulk): a column for each of the ring's
  eight tracks (its name in its colour, and its volume; or the selected
  device's parameters), and a line for the transport and the mode. Sent
  each time the host asks (30 a second), a steady stream as Live sends:
  drawn again only when what it shows changes.
- **Pads** (8 x 8): Note, a keyboard in the host's scale (Octave Up and
  Down); Layout, drum pads (Repeat held: note repeat); Session, the
  host's clips in an 8 x 8 window (the arrows move it).
- **Encoders:** Mix, the eight tracks' volumes (Shift held: their pans);
  Device, the selected device's parameters (Page < and > for its banks).
  The master encoder: the selected track's volume. Tempo: the tempo.
- **Buttons:** Play, Record, Stop, Metronome, Tap Tempo, Undo (Shift:
  redo); the lower row selects a track, the upper row mutes it.
- Every other button and the encoders' touches are the surface's (none
  reaches the host as a note); the touch strip passes (pitch bend).

	odin build examples/push2_odin -build-mode:dll -out:push2.fsurf
*/
package push2_odin

import "base:runtime"
import "core:fmt"
import "core:log"

import abi "../../abi"
import "../../draw"
import kit "../../surface"

// Controls (Ableton's Push2-map.json).
CC_TAP :: 3
CC_METRONOME :: 9
CC_TEMPO :: 14
CC_SWING :: 15
CC_LOWER :: 20 // 20-27
CC_MASTER_BUTTON :: 28
CC_STOP :: 29
CC_SCENE :: 36 // 36 (1/4, bottom) - 43 (1/32t, top)
CC_LEFT :: 44
CC_RIGHT :: 45
CC_UP :: 46
CC_DOWN :: 47
CC_SELECT :: 48
CC_SHIFT :: 49
CC_NOTE :: 50
CC_SESSION :: 51
CC_OCTAVE_DOWN :: 54
CC_OCTAVE_UP :: 55
CC_REPEAT :: 56
CC_LAYOUT :: 31
CC_MUTE :: 60
CC_SOLO :: 61
CC_PAGE_LEFT :: 62
CC_PAGE_RIGHT :: 63
CC_TRACK_ENCODER :: 71 // 71-78
CC_MASTER_ENCODER :: 79
CC_PLAY :: 85
CC_RECORD :: 86
CC_UPPER :: 102 // 102-109
CC_DEVICE :: 110
CC_MIX :: 112
CC_UNDO :: 119
NOTE_TOUCH :: 0 // 0-7 the track encoders', 8 master, 9 swing, 10 tempo
NOTE_STRIP_TOUCH :: 12

// Colour indices of the RGB LEDs: the palette the surface sets (hello).
// 1-24: hues, for clips (the launcher picks the nearest); 25 and 26: the
// selected track's colour, dim and full (set again when it changes); 100
// on: the surface's own.
OFF :: 0
HUES :: 24 // 1-24
TRACK_DIM :: 25
TRACK :: 26
DIM_WHITE :: 100
ORANGE :: 101
DIM_ORANGE :: 102
GREEN :: 103
DIM_GREEN :: 104
RED :: 105
DIM_RED :: 106
BLUE :: 107
DIM_BLUE :: 108
YELLOW :: 109
PURPLE :: 110
WHITE :: 112

// Brightness of the white LEDs (the white palette).
W_OFF :: 0
W_DIM :: 16
W_HALF :: 48
W_ON :: 127

PALETTE :: [?]struct { index: u8, rgb: u32, white: u8 }{
	{DIM_WHITE, 0x282828, 16}, {ORANGE, 0xff7800, 64}, {DIM_ORANGE, 0x3c1c00, 16},
	{GREEN, 0x00ff00, 64}, {DIM_GREEN, 0x003200, 16}, {RED, 0xff0000, 64}, {DIM_RED, 0x3c0000, 16},
	{BLUE, 0x0050ff, 64}, {DIM_BLUE, 0x000f3c, 16}, {YELLOW, 0xffc800, 64}, {PURPLE, 0xa03cff, 64},
	{WHITE, 0xffffff, 127},
}

MIDI_MODE_LIVE :: [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x0A, 0x00, 0xF7}
MIDI_MODE_USER :: [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x0A, 0x01, 0xF7}
REAPPLY_PALETTE :: [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x05, 0xF7}
// Set Display Brightness 255: the display's backlight on ("to see
// something drawn on the display, the display backlight LEDs must be
// turned on"; USB powered, Push 2 limits it).
DISPLAY_BRIGHTNESS :: [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x08, 0x7F, 0x01, 0xF7}
// Set Touch Strip Configuration 0x68, its default (Live changes it): Push 2
// lights a point where the finger is, returns to the centre, sends pitch bend.
TOUCH_STRIP_DEFAULT :: [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x17, 0x68, 0xF7}

// A Set LED Color Palette Entry command.
palette_entry :: proc "contextless" (index: u8, rgb: u32, white: u8) -> [17]u8 {
	r, g, b := u8(rgb >> 16), u8(rgb >> 8), u8(rgb)
	return {0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x03, index, r & 0x7F, r >> 7, g & 0x7F, g >> 7, b & 0x7F, b >> 7, white & 0x7F, white >> 7, 0xF7}
}

// The clip palette as the launcher looks colours up in it: by index (0, off,
// never chosen for a clip's colour but black).
clip_palette: [HUES + 1]kit.RGB

// The surface's state.
Push2 :: struct {
	keyboard:      ^kit.Keyboard,
	device:        ^kit.Device,
	volumes, pans: ^kit.Mixer,
	encoders:      ^kit.Modes,
	pads:          ^kit.Modes,
	shift:         ^kit.Modifier,
	track_colour:  u32, // what palette entries 25 and 26 are now
	x, y:          f32, // setup: where the next side button goes
}

// Hello: the palettes, the backlight, the touch strip, then User mode (the
// one command with a reply, last).
HELLO_ENTRIES :: len(PALETTE) + HUES + 2
hello_messages: [HELLO_ENTRIES + 4][]u8
hello_bytes: [HELLO_ENTRIES][17]u8
strip := TOUCH_STRIP_DEFAULT
live := MIDI_MODE_LIVE
user := MIDI_MODE_USER
reapply := REAPPLY_PALETTE
backlight := DISPLAY_BRIGHTNESS

spec := kit.Spec{
	id          = "org.fsurf.example.push2",
	name        = "Push 2 (kit example)",
	vendor      = "fire-surface",
	version     = "0.1.0",
	url         = "https://github.com/bcrowe306/fire-surface",
	description = "Ableton Push 2: its display, pads, encoders and buttons",
	ports       = {{
		role    = "main",
		inputs  = {"mac:Ableton Push 2 User Port", "win:MIDIIN2 (Ableton Push 2)*", "linux:Ableton Push 2*:1"},
		outputs = {"mac:Ableton Push 2 User Port", "win:MIDIOUT2 (Ableton Push 2)*", "linux:Ableton Push 2*:1"},
	}},
	devices     = {{role = "display", transport = .Usb_Bulk, vendor_id = 0x2982, product_id = 0x1967, interface = 0, endpoint_out = 0x01}},
	displays    = {{name = "Main", width = 960, height = 160, format = .Bgr565, fps = 30, device = 0}},
	width       = 378, // millimetres, for tools
	height      = 330,
	goodbye     = {live[:]},
	setup       = setup,
	on_destroy  = proc(cs: ^kit.Control_Surface) {
		kit.skin_destroy(cs.skin)
		free(cs.user)
	},
}

library := kit.Library{specs = {&spec}}

// The entry's symbol: fsurf_entry in a .fsurf, its own name linked in.
ENTRY_NAME :: abi.ENTRY_SYMBOL when ODIN_BUILD_MODE == .Dynamic else "push2_odin_entry"

// The library's entry.
@(export = ODIN_BUILD_MODE == .Dynamic, link_name = ENTRY_NAME)
fsurf_entry := abi.Entry{
	fsurf_version = abi.VERSION,
	init          = proc "c" (path: cstring) -> bool {
		context = runtime.default_context()
		// The hello: each palette entry (Set LED Color Palette Entry): the
		// surface's own, the clips' hues, the track's colour; reapplied; the
		// backlight; the touch strip; User mode.
		n := 0
		for p in PALETTE {
			hello_bytes[n] = palette_entry(p.index, p.rgb, p.white)
			n += 1
		}
		for h in 0 ..< HUES {
			c := kit.hsv_to_rgb(f64(h) * 360 / HUES, 1, 1)
			clip_palette[h + 1] = c
			hello_bytes[n] = palette_entry(u8(h + 1), kit.rgb_to_hex(c), 64)
			n += 1
		}
		hello_bytes[n] = palette_entry(TRACK_DIM, 0x000f3c, 16)
		hello_bytes[n + 1] = palette_entry(TRACK, 0x0050ff, 64)
		for &b, i in hello_bytes do hello_messages[i] = b[:]
		hello_messages[HELLO_ENTRIES] = reapply[:]
		hello_messages[HELLO_ENTRIES + 1] = backlight[:]
		hello_messages[HELLO_ENTRIES + 2] = strip[:]
		hello_messages[HELLO_ENTRIES + 3] = user[:]
		spec.hello = hello_messages[:]
		return kit.library_init(&library)
	},
	deinit        = proc "c" () { kit.library_deinit(&library) },
	get_factory   = proc "c" (id: cstring) -> rawptr { return kit.library_factory(&library, id) },
}

// What lights show: palette indices (RGB) and brightness (white).
SKIN :: []struct { name: string, value: u8 }{
	{"Transport.Play.On", GREEN}, {"Transport.Play.Off", DIM_GREEN},
	{"Transport.Stop.On", WHITE}, {"Transport.Stop.Off", DIM_WHITE},
	{"Transport.Record.On", RED}, {"Transport.Record.Off", DIM_RED},
	{"Transport.Metronome.On", W_ON}, {"Transport.Metronome.Off", W_DIM}, {"Transport.Tap.Off", W_DIM},
	{"Mode.On", W_ON}, {"Mode.Off", W_DIM}, {"Shift.On", W_ON}, {"Shift.Off", W_DIM}, {"Repeat.On", W_ON}, {"Repeat.Off", W_DIM},
	{"Drum.Pad", TRACK_DIM}, {"Drum.Hit", TRACK}, {"Repeat.Pad", PURPLE}, {"Repeat.Hit", WHITE},
	{"Keyboard.Root", TRACK}, {"Keyboard.In_Scale", DIM_WHITE}, {"Keyboard.Out_Of_Scale", OFF}, {"Keyboard.Playing", GREEN},
	{"Session.Clip.Empty", OFF}, {"Session.Clip.Stopped", DIM_ORANGE}, {"Session.Clip.Playing", GREEN},
	{"Session.Clip.Queued", YELLOW}, {"Session.Clip.Recording", RED}, {"Session.Clip.Record_Queued", DIM_RED},
	{"Session.Clip.Stopping", ORANGE}, {"Session.Scene.On", DIM_WHITE}, {"Session.Scene.Off", OFF},
	{"Navigation.On", W_ON}, {"Navigation.Off", W_OFF}, {"Device.Bank.On", W_ON}, {"Device.Bank.Off", W_OFF},
	{"Mixer.Select.On", WHITE}, {"Mixer.Select.Off", DIM_WHITE}, {"Mixer.Select.None", OFF},
	{"Mixer.Mute.On", ORANGE}, {"Mixer.Mute.Off", DIM_ORANGE}, {"Mixer.Mute.None", OFF},
	{"App.On", W_HALF}, {"App.Off", W_DIM},
}

// The buttons with nothing to do here: theirs all the same (no note or CC
// reaches the host), and shown by tools.
OTHER_BUTTONS :: []struct { cc: u8, name: string, left: bool }{
	{118, "Delete", true}, {35, "Convert", true}, {117, "Double Loop", true}, {116, "Quantize", true},
	{88, "Duplicate", true}, {87, "New", true}, {90, "Fixed Length", true}, {89, "Automate", true},
	{30, "Setup", false}, {59, "User", false}, {52, "Add Device", false}, {53, "Add Track", false},
	{111, "Browse", false}, {113, "Clip", false}, {CC_MASTER_BUTTON, "Master", false}, {57, "Accent", false},
	{58, "Scale", false}, {CC_SELECT, "Select", false}, {CC_MUTE, "Mute", true}, {CC_SOLO, "Solo", true},
}

setup :: proc(cs: ^kit.Control_Surface) -> bool {
	p := new(Push2)
	cs.user = p
	skin := kit.skin_make()
	for v in SKIN do kit.skin_set(skin, v.name, v.value)
	// What the RGB lights look like, for tools that draw the device.
	for v in SKIN do for c in PALETTE do if c.index == v.value do kit.skin_set_display(skin, v.name, c.rgb)
	kit.set_skin(cs, skin)

	// ── The hardware ──
	pads := kit.matrix_make(cs, "Pads", 8, 8, proc(row, col: int) -> kit.Binding {
		return kit.bind_note(u8(36 + (7 - row) * 8 + col)) // 36 at the bottom left
	})
	kit.place_matrix(pads, 66, 96, 24, 24, gap = 3) // (each pad's size)
	track_encoders: [8]^kit.Control
	for i in 0 ..< 8 {
		track_encoders[i] = kit.touch_encoder(cs, "Encoder", kit.bind_cc(u8(CC_TRACK_ENCODER + i)), kit.bind_note(u8(NOTE_TOUCH + i)))
		kit.place(track_encoders[i], 70 + f32(i) * 29, 8, 16, 16)
	}
	master := kit.touch_encoder(cs, "Master Encoder", kit.bind_cc(CC_MASTER_ENCODER), kit.bind_note(NOTE_TOUCH + 8))
	kit.place(master, 328, 8, 16, 16)
	tempo := kit.touch_encoder(cs, "Tempo Encoder", kit.bind_cc(CC_TEMPO), kit.bind_note(NOTE_TOUCH + 10))
	kit.place(tempo, 10, 8, 16, 16)
	swing := kit.touch_encoder(cs, "Swing Encoder", kit.bind_cc(CC_SWING), kit.bind_note(NOTE_TOUCH + 9))
	kit.place(swing, 36, 8, 16, 16)
	strip := kit.button(cs, "Touch Strip", kit.bind_note(NOTE_STRIP_TOUCH)) // (its touch; its pitch bend passes)
	kit.place(strip, 50, 96, 8, 216)
	upper, lower: [8]^kit.Control
	for i in 0 ..< 8 {
		upper[i] = kit.button(cs, "Upper", kit.bind_cc(u8(CC_UPPER + i)))
		kit.place(upper[i], 68 + f32(i) * 27, 76, 22, 7)
		lower[i] = kit.button(cs, "Lower", kit.bind_cc(u8(CC_LOWER + i)))
		kit.place(lower[i], 68 + f32(i) * 27, 85, 22, 7)
	}
	scenes: [8]^kit.Control
	for i in 0 ..< 8 {
		scenes[i] = kit.button(cs, SCENE_NAMES[i], kit.bind_cc(u8(CC_SCENE + 7 - i)))
		kit.place(scenes[i], 290, 99 + f32(i) * 27, 22, 20)
	}
	p.x, p.y = 8, 96
	side :: proc(cs: ^kit.Control_Surface, name: string, cc: u8, left: bool) -> ^kit.Control {
		p := (^Push2)(cs.user)
		b := kit.button(cs, name, kit.bind_cc(cc))
		if left {
			kit.place(b, 8, p.y, 40, 8)
			p.y += 11
		} else {
			kit.place(b, 322, p.x, 48, 8)
			p.x += 11
		}
		return b
	}
	p.x = 34 // (the right column, from the top)

	// ── The transport ──
	transport := kit.transport_make(cs)
	kit.layer_bind(transport.layer, "tap", side(cs, "Tap Tempo", CC_TAP, true))
	kit.layer_bind(transport.layer, "metronome", side(cs, "Metronome", CC_METRONOME, true))
	kit.layer_bind(transport.layer, "stop", side(cs, "Stop", CC_STOP, true))
	kit.layer_bind(transport.layer, "record", side(cs, "Record", CC_RECORD, true))
	kit.layer_bind(transport.layer, "play", side(cs, "Play", CC_PLAY, true))
	app := kit.app_make(cs)
	undo := side(cs, "Undo", CC_UNDO, true)
	kit.layer_bind(app.layer, "undo", undo)
	redo := kit.app_make(cs, "Redo", priority = 1) // under Shift
	kit.layer_bind(redo.layer, "redo", undo)

	// The tempo encoder: a beat a minute a step.
	tempo_c := kit.component_make(cs, "Tempo")
	kit.layer_bind(tempo_c.layer, "tempo", tempo)
	tempo_c.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Delta do return
		t := kit.daw_get(c.cs, .Tempo)
		kit.daw_set(c.cs, .Tempo, 0, 0, clamp(t + f64(e.delta), 20, 999))
	}

	// ── The encoders: Mix or Device ──
	p.volumes = kit.mixer_make(cs, "Volumes", 8)
	p.pans = kit.mixer_make(cs, "Pans", 8, priority = 1)
	p.device = kit.device_make(cs, "Device", 8)
	for e, i in track_encoders {
		kit.mixer_bind(p.volumes, i, .Volume, e)
		kit.mixer_bind(p.pans, i, .Pan, e)
		kit.device_bind_param(p.device, i, e)
	}
	kit.layer_bind(p.device.layer, "prev_bank", side(cs, "Page <", CC_PAGE_LEFT, false))
	kit.layer_bind(p.device.layer, "next_bank", side(cs, "Page >", CC_PAGE_RIGHT, false))
	p.device.on_change = proc(d: ^kit.Device) { invalidate(d.cs) }
	p.shift = kit.modifier_make(cs, "Shift", side(cs, "Shift", CC_SHIFT, false), {p.pans, redo})
	p.encoders = kit.modes_make(cs, "Encoders")
	kit.modes_add(p.encoders, "mix", {p.volumes}, side(cs, "Mix", CC_MIX, false))
	kit.modes_add(p.encoders, "device", {p.device}, side(cs, "Device", CC_DEVICE, false))
	p.encoders.on_change = proc(m: ^kit.Modes, from, to: int) {
		invalidate(m.cs)
		log.infof("encoders: %s", kit.modes_current(m))
	}
	selected := kit.mixer_make(cs, "Selected", 1, follow_selection = true)
	kit.mixer_bind(selected, 0, .Volume, master)

	// The two rows under the display: mute (upper), select (lower).
	rows := kit.mixer_make(cs, "Rows", 8)
	for i in 0 ..< 8 {
		kit.mixer_bind(rows, i, .Mute, upper[i])
		kit.mixer_bind(rows, i, .Select, lower[i])
	}

	// ── The pads: Note, Layout (drums), Session ──
	p.keyboard = kit.keyboard_make(cs, "Keys", pads, kit.scale_named("Major"), root = 0, octave = 3)
	kit.keyboard_follow_host(p.keyboard)
	octave := kit.component_make(cs, "Octave")
	kit.layer_bind(octave.layer, "up", side(cs, "Octave Up", CC_OCTAVE_UP, false))
	kit.layer_bind(octave.layer, "down", side(cs, "Octave Down", CC_OCTAVE_DOWN, false))
	octave.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) { kit.light_value(control, W_ON) }
	octave.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		k := (^Push2)(c.cs.user).keyboard
		kit.keyboard_set(k, k.scale, k.root, clamp(k.octave + (1 if e.slot == "up" else -1), -1, 8), k.in_key)
		invalidate(c.cs)
	}
	drums := kit.drum_pads_make(cs, "Drum", pads)
	repeat := kit.note_repeat_make(cs, "Note Repeat", pads, rate = 0.25, priority = 1)
	repeat_button := kit.modifier_make(cs, "Repeat", side(cs, "Repeat", CC_REPEAT, false), {repeat})
	session := kit.launcher_make(cs, "Session", pads)
	session.palette = clip_palette[:] // stopped clips in their colours
	for b, i in scenes do kit.launcher_bind_scene(session, i, b) // (scenes[0]: the top one)
	nav := kit.navigation_make(cs, tracks = 1, scenes = 1)
	kit.layer_bind(nav.layer, "left", side(cs, "Left", CC_LEFT, false))
	kit.layer_bind(nav.layer, "right", side(cs, "Right", CC_RIGHT, false))
	kit.layer_bind(nav.layer, "up", side(cs, "Up", CC_UP, false))
	kit.layer_bind(nav.layer, "down", side(cs, "Down", CC_DOWN, false))
	p.pads = kit.modes_make(cs, "Pads")
	kit.modes_add(p.pads, "note", {p.keyboard, octave}, side(cs, "Note", CC_NOTE, false))
	kit.modes_add(p.pads, "drum", {drums, &repeat_button.component}, side(cs, "Layout", CC_LAYOUT, false))
	kit.modes_add(p.pads, "session", {session}, side(cs, "Session", CC_SESSION, false))
	p.pads.on_change = proc(m: ^kit.Modes, from, to: int) {
		invalidate(m.cs)
		log.infof("pads: %s", kit.modes_current(m))
	}

	for b in OTHER_BUTTONS do side(cs, b.name, b.cc, b.left)
	_ = swing; _ = strip

	// The selected track's colour: palette entries 25 and 26, set again
	// (and reapplied, so the lights using them change) when it changes.
	colour := kit.component_make(cs, "Track Colour")
	colour.daw_topics = {.Tracks}
	colour.on_daw = proc(c: ^kit.Component, e: abi.Daw_Event) { track_colour(c.cs) }
	colour.on_activate = proc(c: ^kit.Component) { track_colour(c.cs) }

	// ── The display ──
	screen := kit.component_make(cs, "Screen")
	screen.daw_topics = {.Transport, .Tracks, .Mixer, .Devices, .Parameters}
	screen.on_daw = proc(c: ^kit.Component, e: abi.Daw_Event) { invalidate(c.cs) }
	screen.on_activate = proc(c: ^kit.Component) { invalidate(c.cs) }
	d := kit.display(cs, 0)
	d.draw = draw_screen
	d.send = kit.display_send_push2
	d.resend = true // (a steady stream, as Live sends)
	kit.place_display(d, 66, 30, 234, 39)

	kit.ring_setup(cs, 8, 8)
	for c in ([?]^kit.Component{transport, app, &p.shift.component, tempo_c, selected, rows, nav, &p.encoders.component, &p.pads.component, screen, colour}) do kit.surface_add(cs, c)
	return true
}

SCENE_NAMES := [8]string{"1/32t", "1/32", "1/16t", "1/16", "1/8t", "1/8", "1/4t", "1/4"}

// Palette entries 25 (dim) and 26 as the selected track's colour, when it changed.
track_colour :: proc(cs: ^kit.Control_Surface) {
	p := (^Push2)(cs.user)
	if cs.daw == nil do return
	c := u32(kit.daw_get(cs, .Track_Color, kit.selected_track(cs))) & 0xFFFFFF
	if c == 0 do c = 0x0050ff
	if c == p.track_colour do return
	p.track_colour = c
	rgb := kit.rgb_from_hex(c)
	dim := kit.rgb_to_hex({rgb.r / 5, rgb.g / 5, rgb.b / 5})
	a, b := palette_entry(TRACK_DIM, dim, 16), palette_entry(TRACK, c, 64)
	kit.send(cs, a[:])
	kit.send(cs, b[:])
	kit.send(cs, reapply[:])
	kit.skin_set_display(cs.skin, "Drum.Pad", dim) // (for tools that draw the device)
	kit.skin_set_display(cs.skin, "Drum.Hit", c)
	kit.skin_set_display(cs.skin, "Keyboard.Root", c)
}

invalidate :: proc(cs: ^kit.Control_Surface) {
	kit.display_invalidate(kit.display(cs, 0))
}

// The display: a column a track, and a line at the bottom.
draw_screen :: proc(d: ^kit.Display, cv: ^draw.Canvas) {
	// (Open Sans and smooth shapes: the display is small, and dim on USB
	// power alone.)
	cs := d.cs
	p := (^Push2)(cs.user)
	sans, semi := draw.open_sans(), draw.open_sans(.Semibold)
	draw.clear(cv, 0x000000)
	if cs.daw == nil {
		draw.type_text_in(cv, sans, 28, {0, 0, cv.width, cv.height}, "No host DAW", draw.WHITE, .Center)
		return
	}
	device_mode := kit.modes_current(p.encoders) == "device"
	COL :: 120
	n_params := int(kit.daw_get(cs, .Param_Count))
	for i in 0 ..< 8 {
		x := i * COL
		fx := f32(x)
		if device_mode {
			// The selected device's parameter: its name, a knob, its value.
			k := p.device.bank * 8 + i
			if k >= n_params do continue
			v := f32(kit.daw_get(cs, .Param_Value, k))
			draw.type_text_in(cv, sans, 17, {x + 4, 4, COL - 8, 24}, kit.daw_text(cs, .Param_Name, k), 0xC8C8D0, .Center)
			draw.aa_knob(cv, fx + COL / 2, 70, 30, v, 0xFFB030, 0x34343C, 6)
			draw.type_text_in(cv, semi, 18, {x + 4, 104, COL - 8, 24}, kit.daw_text(cs, .Param_Value, k), draw.WHITE, .Center)
			continue
		}
		t, ok := kit.mixer_strip_track(p.volumes, i)
		if !ok do continue
		colour := u32(kit.daw_get(cs, .Track_Color, t))
		if colour == 0 do colour = 0x5080ff
		sel := t == kit.selected_track(cs)
		// Its name over a band of its colour (the selected one bright).
		draw.aa_round_rect(cv, fx + 4, 3, COL - 8, 28, 6, colour if sel else draw.mix(0x000000, colour, 120))
		draw.type_text_in(cv, semi, 18, {x + 8, 3, COL - 16, 28}, kit.daw_text(cs, .Track_Name, t), draw.WHITE, .Center)
		// Its volume: a bar filling up, and in dB.
		vol := clamp(f32(kit.daw_get(cs, .Track_Volume, t)), 0, 1)
		bx := fx + COL / 2 - 14
		draw.aa_round_rect(cv, bx, 38, 28, 64, 5, 0x26262C)
		if vol > 0.01 do draw.aa_round_rect(cv, bx, 38 + 64 * (1 - vol), 28, 64 * vol, 5, colour)
		draw.type_text_in(cv, sans, 16, {x + 2, 104, COL - 4, 24}, kit.daw_text(cs, .Track_Volume, t), 0xE0E0E6, .Center)
		if kit.daw_flag(cs, .Track_Mute, t) do draw.type_text_in(cv, semi, 16, {x + 8, 40, 26, 22}, "M", 0xFF9020, .Left)
	}
	// The bottom line: the transport, the selected track and device, the modes.
	draw.fill_rect(cv, {0, 132, cv.width, 28}, 0x18181C)
	playing := kit.daw_flag(cs, .Playing)
	draw.aa_circle(cv, 16, 146, 7, 0x30E040 if playing else 0x505058)
	if kit.daw_flag(cs, .Recording) do draw.aa_circle(cv, 36, 146, 7, 0xFF3030)
	draw.type_text_in(cv, semi, 17, {52, 132, 160, 28}, fmt.tprintf("%.1f BPM", kit.daw_get(cs, .Tempo)), draw.WHITE)
	t := kit.selected_track(cs)
	shown := kit.daw_text(cs, .Track_Name, t)
	if device_mode do shown = fmt.tprintf("%s  ›  %s", shown, kit.daw_text(cs, .Device_Name, p.device.device))
	draw.type_text_in(cv, sans, 17, {260, 132, 400, 28}, shown, draw.WHITE, .Center)
	modes := fmt.tprintf("%s · %s", kit.modes_current(p.encoders), kit.modes_current(p.pads))
	if kit.modes_current(p.pads) == "note" do modes = fmt.tprintf("%s · octave %d", modes, p.keyboard.octave)
	draw.type_text_in(cv, sans, 16, {660, 132, 290, 28}, modes, 0xA0A0A8, .Right)
}
