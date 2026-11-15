/*
A surface made with the kit, for a pretend controller "Grid": 4x4 pads,
four encoders, a fader, and buttons. It shows the kit's parts working
together, on the host's fsurf.daw when it has it:

- Modes for the pads, their buttons latching when tapped and momentary
  when held (Hybrid):
  - Drum: the pads as drum pads, remapped by the claim table (no added
    latency), lit as they're hit. Held, Repeat repeats them in time.
  - Keys: a keyboard in the host's scale; the octave buttons work here.
  - Session: a 4x4 window of the host's clips (the ring), launched by
    the pads; the arrows move the window.
- Play, Stop and Record: the host's transport.
- The encoders: the selected device's parameters; with Shift held, the
  volumes of the ring's four tracks (a layer of higher priority).
- The fader: the selected track's volume, picked up where it is.

Without fsurf.daw, the drum and keys modes still play.

	odin build examples/grid_odin -build-mode:dll -out:grid.fsurf
*/
package grid_odin

import abi "../../abi"
import kit "../../surface"

PAD_CHANNEL :: 9
CC_SHIFT :: 80
CC_PLAY :: 85
CC_STOP :: 86
CC_RECORD :: 87
CC_REPEAT :: 88
CC_SESSION :: 89
CC_DRUM :: 90
CC_KEYS :: 91
CC_OCTAVE_UP :: 92
CC_OCTAVE_DOWN :: 93
CC_LEFT :: 100 // 100-103: left, right, up, down
CC_KNOB :: 70 // 70-73
CC_FADER :: 7 // and 39: 14 bits

// The surface's own state.
Grid :: struct {
	keyboard: ^kit.Keyboard,
}

identity := kit.Identity_Def{
	method = .Request,
	match  = {0xF0, 0x7E, 0x00, 0x06, 0x02, 0x7D, 0x20},
	mask   = {0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0xFF},
}

spec := kit.Spec{
	id          = "org.fsurf.example.grid",
	name        = "Grid (kit example)",
	vendor      = "fire-surface",
	version     = "0.4.0",
	url         = "https://github.com/bcrowe306/fire-surface",
	description = "A pretend grid controller, made with the Odin kit",
	ports       = {{role = "main", inputs = {"Grid*"}, outputs = {"Grid*"}}},
	identity    = &identity,
	hello       = {{0xF0, 0x7D, 0x20, 0x01, 0xF7}},
	goodbye     = {{0xF0, 0x7D, 0x20, 0x00, 0xF7}},
	setup       = setup,
	on_destroy  = proc(cs: ^kit.Control_Surface) {
		kit.skin_destroy(cs.skin)
		free(cs.user)
	},
}

library := kit.Library{specs = {&spec}}

// The entry's symbol: fsurf_entry in a .fsurf, its own name linked in (two
// surfaces linked into one app can't both be fsurf_entry).
ENTRY_NAME :: abi.ENTRY_SYMBOL when ODIN_BUILD_MODE == .Dynamic else "grid_odin_entry"

// The library's entry: its one export when built as a .fsurf; linked into an
// app (or a test), used by name with `host.library_static(&fsurf_entry)`.
@(export = ODIN_BUILD_MODE == .Dynamic, link_name = ENTRY_NAME)
fsurf_entry := abi.Entry{
	fsurf_version = abi.VERSION,
	init          = proc "c" (path: cstring) -> bool { return kit.library_init(&library) },
	deinit        = proc "c" () { kit.library_deinit(&library) },
	get_factory   = proc "c" (id: cstring) -> rawptr { return kit.library_factory(&library, id) },
}

// What lights show: velocities of the pretend device.
SKIN :: []struct { name: string, value: u8 }{
	{"Transport.Play.On", 127}, {"Transport.Play.Off", 5}, {"Transport.Stop.On", 20}, {"Transport.Stop.Off", 5},
	{"Transport.Record.On", 127}, {"Transport.Record.Off", 5},
	{"Mode.On", 127}, {"Mode.Off", 5}, {"Shift.On", 127}, {"Shift.Off", 5}, {"Repeat.On", 127}, {"Repeat.Off", 5},
	{"Drum.Pad", 10}, {"Drum.Hit", 127}, {"Repeat.Pad", 15}, {"Repeat.Hit", 127},
	{"Keyboard.Root", 60}, {"Keyboard.In_Scale", 20}, {"Keyboard.Out_Of_Scale", 0}, {"Keyboard.Playing", 127},
	{"Session.Clip.Empty", 0}, {"Session.Clip.Stopped", 30}, {"Session.Clip.Playing", 127}, {"Session.Clip.Queued", 90},
	{"Session.Clip.Recording", 110}, {"Session.Clip.Record_Queued", 100}, {"Session.Clip.Stopping", 40},
	{"Navigation.On", 127}, {"Navigation.Off", 0},
}

setup :: proc(cs: ^kit.Control_Surface) -> bool {
	g := new(Grid)
	cs.user = g
	skin := kit.skin_make()
	for v in SKIN do kit.skin_set(skin, v.name, v.value)
	kit.set_skin(cs, skin)

	// The hardware.
	pads := kit.matrix_make(cs, "Pads", 4, 4, proc(row, col: int) -> kit.Binding {
		return kit.bind_note(u8(36 + (3 - row) * 4 + col), PAD_CHANNEL) // 36 at the bottom left
	})
	button :: proc(cs: ^kit.Control_Surface, name: string, cc: u8) -> ^kit.Control { return kit.button(cs, name, kit.bind_cc(cc)) }
	knobs: [4]^kit.Control
	for i in 0 ..< 4 do knobs[i] = kit.encoder(cs, "Knob", kit.bind_cc(u8(CC_KNOB + i)))
	fader := kit.fader(cs, "Fader", kit.bind_cc14(CC_FADER), pickup = true)

	// The transport.
	transport := kit.transport_make(cs)
	kit.layer_bind(transport.layer, "play", button(cs, "Play", CC_PLAY))
	kit.layer_bind(transport.layer, "stop", button(cs, "Stop", CC_STOP))
	kit.layer_bind(transport.layer, "record", button(cs, "Record", CC_RECORD))

	// The knobs: the device's parameters; under Shift, the ring's volumes.
	device := kit.device_make(cs, "Device", 4)
	volumes := kit.mixer_make(cs, "Volumes", 4, priority = 1)
	for k, i in knobs {
		kit.device_bind_param(device, i, k)
		kit.mixer_bind(volumes, i, .Volume, k)
	}
	shift := kit.modifier_make(cs, "Shift", button(cs, "Shift", CC_SHIFT), {volumes})

	// The fader: the selected track's volume.
	strip := kit.mixer_make(cs, "Strip", 1, follow_selection = true)
	kit.mixer_bind(strip, 0, .Volume, fader)

	// The pads' modes.
	drums := kit.drum_pads_make(cs, "Drum", pads)
	repeat := kit.note_repeat_make(cs, "Note Repeat", pads, rate = 0.25, priority = 1)
	repeat_button := kit.modifier_make(cs, "Repeat", button(cs, "Repeat", CC_REPEAT), {repeat})

	g.keyboard = kit.keyboard_make(cs, "Keys", pads, kit.scale_named("Minor"), root = 0, octave = 3)
	kit.keyboard_follow_host(g.keyboard)
	octave := kit.component_make(cs, "Octave")
	octave.user = g
	kit.layer_bind(octave.layer, "up", button(cs, "Octave Up", CC_OCTAVE_UP))
	kit.layer_bind(octave.layer, "down", button(cs, "Octave Down", CC_OCTAVE_DOWN))
	octave.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) { kit.light_value(control, 20) }
	octave.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		k := (^Grid)(c.user).keyboard
		o := clamp(k.octave + (1 if e.slot == "up" else -1), -1, 8)
		kit.keyboard_set(k, k.scale, k.root, o, k.in_key)
		kit.notify(c.cs, "Octave Up" if e.slot == "up" else "Octave Down")
	}

	session := kit.launcher_make(cs, "Session", pads)
	nav := kit.navigation_make(cs, tracks = 1, scenes = 1)
	for slot, i in ([4]string{"left", "right", "up", "down"}) do kit.layer_bind(nav.layer, slot, button(cs, slot, u8(CC_LEFT + i)))

	modes := kit.modes_make(cs, "Pads")
	kit.modes_add(modes, "drum", {drums, &repeat_button.component}, button(cs, "Drum", CC_DRUM), .Hybrid)
	kit.modes_add(modes, "keys", {g.keyboard, octave}, button(cs, "Keys", CC_KEYS), .Hybrid)
	kit.modes_add(modes, "session", {session}, button(cs, "Session", CC_SESSION), .Hybrid)
	modes.on_change = proc(m: ^kit.Modes, from, to: int) { kit.notify(m.cs, kit.modes_current(m)) }

	kit.ring_setup(cs, 4, 4) // the host's tracks and scenes it shows at once
	for c in ([?]^kit.Component{transport, device, &shift.component, strip, nav, &modes.component}) do kit.surface_add(cs, c)
	return true
}
