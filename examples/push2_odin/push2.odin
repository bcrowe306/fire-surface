/*
A surface for Ableton Push 2, made with the kit, on the host's fsurf.daw:
its display over USB, its pads, encoders and buttons over MIDI. From
Ableton's published interface (github.com/Ableton/push-interface).

- **Ports:** the User Port (Ableton Live keeps the Live Port; turn Live's
  Track/Sync/Remote switches for Push 2's User Port off to run both).
  When it starts it sets its colours and puts Push 2 in User mode; when
  it stops, back in Live mode.
- **The display** (960 x 160, USB bulk): a column for each of the ring's
  eight tracks (its name in its colour, and its volume; or the selected
  device's parameters), and a line for the transport and the mode. Sent
  when what it shows changes, and at least each second (Push 2 turns its
  display off after two without a frame).
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
OFF :: 0
DIM_WHITE :: 1
ORANGE :: 2
DIM_ORANGE :: 3
GREEN :: 4
DIM_GREEN :: 5
RED :: 6
DIM_RED :: 7
BLUE :: 8
DIM_BLUE :: 9
YELLOW :: 10
PURPLE :: 11
WHITE :: 13

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

// The surface's state.
Push2 :: struct {
	keyboard:      ^kit.Keyboard,
	device:        ^kit.Device,
	volumes, pans: ^kit.Mixer,
	encoders:      ^kit.Modes,
	pads:          ^kit.Modes,
	shift:         ^kit.Modifier,
	x, y:          f32, // setup: where the next side button goes
}

// Hello: the palette, then User mode (the one command with a reply, last).
hello_messages: [len(PALETTE) + 2][]u8
hello_bytes: [len(PALETTE)][17]u8
live := MIDI_MODE_LIVE
user := MIDI_MODE_USER
reapply := REAPPLY_PALETTE

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
		// The hello: each palette entry (Set LED Color Palette Entry), reapplied, User mode.
		for p, i in PALETTE {
			r, g, b := u8(p.rgb >> 16), u8(p.rgb >> 8), u8(p.rgb)
			hello_bytes[i] = {0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x03, p.index, r & 0x7F, r >> 7, g & 0x7F, g >> 7, b & 0x7F, b >> 7, p.white & 0x7F, p.white >> 7, 0xF7}
			hello_messages[i] = hello_bytes[i][:]
		}
		hello_messages[len(PALETTE)] = reapply[:]
		hello_messages[len(PALETTE) + 1] = user[:]
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
	{"Drum.Pad", DIM_BLUE}, {"Drum.Hit", BLUE}, {"Repeat.Pad", PURPLE}, {"Repeat.Hit", WHITE},
	{"Keyboard.Root", BLUE}, {"Keyboard.In_Scale", DIM_WHITE}, {"Keyboard.Out_Of_Scale", OFF}, {"Keyboard.Playing", GREEN},
	{"Session.Clip.Empty", OFF}, {"Session.Clip.Stopped", DIM_ORANGE}, {"Session.Clip.Playing", GREEN},
	{"Session.Clip.Queued", YELLOW}, {"Session.Clip.Recording", RED}, {"Session.Clip.Record_Queued", DIM_RED},
	{"Session.Clip.Stopping", ORANGE},
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
	_ = swing; _ = strip; _ = scenes

	// ── The display ──
	screen := kit.component_make(cs, "Screen")
	screen.daw_topics = {.Transport, .Tracks, .Mixer, .Devices, .Parameters}
	screen.on_daw = proc(c: ^kit.Component, e: abi.Daw_Event) { invalidate(c.cs) }
	screen.on_activate = proc(c: ^kit.Component) {
		invalidate(c.cs)
		// Push 2 turns its display off after two seconds without a frame.
		kit.task_every(c.cs, 1000, proc(data: rawptr) { invalidate((^kit.Control_Surface)(data)) }, c.cs, c)
	}
	d := kit.display(cs, 0)
	d.draw = draw_screen
	d.send = kit.display_send_push2
	kit.place_display(d, 66, 30, 234, 39)

	kit.ring_setup(cs, 8, 8)
	for c in ([?]^kit.Component{transport, app, &p.shift.component, tempo_c, selected, rows, nav, &p.encoders.component, &p.pads.component, screen}) do kit.surface_add(cs, c)
	return true
}

SCENE_NAMES := [8]string{"1/32t", "1/32", "1/16t", "1/16", "1/8t", "1/8", "1/4t", "1/4"}

invalidate :: proc(cs: ^kit.Control_Surface) {
	kit.display_invalidate(kit.display(cs, 0))
}

// The display: a column a track, and a line at the bottom.
draw_screen :: proc(d: ^kit.Display, cv: ^draw.Canvas) {
	cs := d.cs
	p := (^Push2)(cs.user)
	f := &draw.FONT_5X7
	draw.clear(cv, 0x000000)
	if cs.daw == nil {
		draw.text_in(cv, f, {0, 0, cv.width, cv.height}, "No host DAW", draw.GREY, .Center, 3)
		return
	}
	device_mode := kit.modes_current(p.encoders) == "device"
	COL :: 120
	n_params := int(kit.daw_get(cs, .Param_Count))
	for i in 0 ..< 8 {
		x := i * COL
		if device_mode {
			// The selected device's parameter.
			k := p.device.bank * 8 + i
			if k >= n_params do continue
			v := f32(kit.daw_get(cs, .Param_Value, k))
			draw.text_in(cv, f, {x + 4, 6, COL - 8, 16}, kit.daw_text(cs, .Param_Name, k), draw.GREY, .Center, 2)
			draw.knob(cv, x + COL / 2, 70, 30, v, draw.ORANGE, thickness = 5)
			draw.text_in(cv, f, {x + 4, 108, COL - 8, 16}, kit.daw_text(cs, .Param_Value, k), draw.WHITE, .Center, 2)
			continue
		}
		t, ok := kit.mixer_strip_track(p.volumes, i)
		if !ok do continue
		colour := u32(kit.daw_get(cs, .Track_Color, t))
		sel := t == kit.selected_track(cs)
		draw.fill_rect(cv, {x + 2, 0, COL - 4, 24}, colour if sel else draw.mix(0x000000, colour, 90))
		draw.text_in(cv, f, {x + 6, 4, COL - 12, 16}, kit.daw_text(cs, .Track_Name, t), draw.WHITE if sel else 0xd0d0d0, .Center, 2)
		vol := f32(kit.daw_get(cs, .Track_Volume, t))
		draw.bar(cv, {x + COL / 2 - 10, 34, 20, 70}, vol, colour)
		draw.text_in(cv, f, {x + 4, 108, COL - 8, 16}, kit.daw_text(cs, .Track_Volume, t), draw.WHITE, .Center, 2)
		if kit.daw_flag(cs, .Track_Mute, t) do draw.text_in(cv, f, {x + 4, 108, 24, 16}, "M", draw.ORANGE, .Left, 2)
	}
	// The bottom line: the transport, the selected track and device, the modes.
	draw.hline(cv, 0, cv.width - 1, 132, 0x303030)
	playing := kit.daw_flag(cs, .Playing)
	draw.fill_circle(cv, 14, 146, 6, draw.GREEN if playing else 0x404040)
	if kit.daw_flag(cs, .Recording) do draw.fill_circle(cv, 32, 146, 6, draw.RED)
	tempo := fmt.tprintf("%.1f BPM", kit.daw_get(cs, .Tempo))
	draw.text(cv, f, 48, 139, tempo, draw.WHITE, 2)
	t := kit.selected_track(cs)
	shown := kit.daw_text(cs, .Track_Name, t)
	if device_mode do shown = fmt.tprintf("%s / %s", shown, kit.daw_text(cs, .Device_Name, p.device.device))
	draw.text_in(cv, f, {200, 138, 520, 16}, shown, draw.GREY, .Center, 2)
	modes := fmt.tprintf("%s  %s", kit.modes_current(p.encoders), kit.modes_current(p.pads))
	if kit.modes_current(p.pads) == "note" do modes = fmt.tprintf("%s (octave %d)", modes, p.keyboard.octave)
	draw.text_in(cv, f, {720, 138, 232, 16}, modes, draw.GREY, .Right, 2)
}
