/*
A surface made with the kit, for a pretend controller "Grid": 4x4 pads,
four encoders, a fader, and buttons (Shift, Play, Drum, Keys, Octave
up/down). It shows the kit's parts working together:

- Modes: Drum (the pads as drum pads) and Keys (a keyboard in a scale),
  their buttons latching when tapped and momentary when held (Hybrid).
  The pads are remapped by the claim table, so they play with no added
  latency, and light as they're played.
- Shift (a Modifier): while held, the encoders are fine (a layer of
  higher priority over the normal one).
- Play toggles, the fader picks up the value it was given, the octave
  buttons only work in Keys mode.

Without the standard extension yet (stage 4), what it would change in a
host it notifies ("Play", "Knob 1: 64").

	odin build examples/grid_odin -build-mode:dll -out:grid.fsurf
*/
package grid_odin

import "core:fmt"

import abi "../../abi"
import kit "../../surface"

PAD_CHANNEL :: 9
CC_SHIFT :: 80
CC_PLAY :: 85
CC_DRUM :: 90
CC_KEYS :: 91
CC_OCTAVE_UP :: 92
CC_OCTAVE_DOWN :: 93
CC_KNOB :: 70 // 70-73
CC_FADER :: 7 // and 39: 14 bits

// The surface's own state.
Grid :: struct {
	knobs:    [4]f32, // 0-127
	fader:    f32,
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
	version     = "0.3.0",
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

// The library's one export.
@(export, link_name = abi.ENTRY_SYMBOL)
fsurf_entry := abi.Entry{
	fsurf_version = abi.VERSION,
	init          = proc "c" (path: cstring) -> bool { return kit.library_init(&library) },
	deinit        = proc "c" () { kit.library_deinit(&library) },
	get_factory   = proc "c" (id: cstring) -> rawptr { return kit.library_factory(&library, id) },
}

setup :: proc(cs: ^kit.Control_Surface) -> bool {
	g := new(Grid)
	cs.user = g
	g.knobs = 64

	// What lights show: velocities of the pretend device.
	skin := kit.skin_make()
	kit.skin_set(skin, "Transport.Play.On", 127)
	kit.skin_set(skin, "Transport.Play.Off", 5)
	kit.skin_set(skin, "Mode.On", 127)
	kit.skin_set(skin, "Mode.Off", 5)
	kit.skin_set(skin, "Shift.On", 127)
	kit.skin_set(skin, "Shift.Off", 5)
	kit.skin_set(skin, "Drum.Pad", 10)
	kit.skin_set(skin, "Drum.Hit", 127)
	kit.skin_set(skin, "Keyboard.Root", 60)
	kit.skin_set(skin, "Keyboard.In_Scale", 20)
	kit.skin_set(skin, "Keyboard.Out_Of_Scale", 0)
	kit.skin_set(skin, "Keyboard.Playing", 127)
	kit.set_skin(cs, skin)

	// The hardware.
	pads := kit.matrix_make(cs, "Pads", 4, 4, proc(row, col: int) -> kit.Binding {
		return kit.bind_note(u8(36 + (3 - row) * 4 + col), PAD_CHANNEL) // 36 at the bottom left
	})
	shift := kit.button(cs, "Shift", kit.bind_cc(CC_SHIFT))
	play := kit.button(cs, "Play", kit.bind_cc(CC_PLAY), toggle = true)
	drum_button := kit.button(cs, "Drum", kit.bind_cc(CC_DRUM))
	keys_button := kit.button(cs, "Keys", kit.bind_cc(CC_KEYS))
	up := kit.button(cs, "Octave Up", kit.bind_cc(CC_OCTAVE_UP))
	down := kit.button(cs, "Octave Down", kit.bind_cc(CC_OCTAVE_DOWN))
	knobs: [4]^kit.Control
	NAMES :: [4]string{"Knob 1", "Knob 2", "Knob 3", "Knob 4"}
	SLOTS :: [4]string{"0", "1", "2", "3"}
	names, slots := NAMES, SLOTS
	for i in 0 ..< 4 do knobs[i] = kit.encoder(cs, names[i], kit.bind_cc(u8(CC_KNOB + i)))
	fader := kit.fader(cs, "Fader", kit.bind_cc14(CC_FADER), pickup = true)

	// Transport: Play.
	transport := kit.component_make(cs, "Transport")
	kit.layer_bind(transport.layer, "play", play)
	transport.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		kit.light(control, "Transport.Play.On" if control.on else "Transport.Play.Off")
	}
	transport.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		kit.notify(c.cs, "Play" if e.control.on else "Stop")
		kit.light(e.control, "Transport.Play.On" if e.control.on else "Transport.Play.Off")
	}

	// The encoders, coarse; and fine under Shift (priority 1 covers 0).
	coarse := kit.component_make(cs, "Knobs")
	fine := kit.component_make(cs, "Fine Knobs", priority = 1)
	for k, i in knobs {
		kit.layer_bind(coarse.layer, slots[i], k)
		kit.layer_bind(fine.layer, slots[i], k)
	}
	knob_turned :: proc(c: ^kit.Component, e: kit.Event, scale: f32, label: string) {
		if e.kind != .Delta do return
		g := (^Grid)(c.cs.user)
		i := int(e.control.binding.number) - CC_KNOB
		g.knobs[i] = clamp(g.knobs[i] + f32(e.delta) * scale, 0, 127)
		kit.notify(c.cs, fmt.tprintf("%s %d: %.1f", label, i + 1, g.knobs[i]))
	}
	coarse.on_event = proc(c: ^kit.Component, e: kit.Event) { knob_turned(c, e, 1, "Knob") }
	fine.on_event = proc(c: ^kit.Component, e: kit.Event) { knob_turned(c, e, 0.1, "Fine") }
	shift_mod := kit.modifier_make(cs, "Shift", shift, {fine})

	// The fader: soft takeover from the value it was given.
	faders := kit.component_make(cs, "Fader")
	kit.layer_bind(faders.layer, "fader", fader)
	faders.on_activate = proc(c: ^kit.Component) {
		kit.set_value(kit.layer_control(c.layer, "fader"), 0.5) // what a host would give it
	}
	faders.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Value do return
		(^Grid)(c.cs.user).fader = e.value
		kit.notify(c.cs, fmt.tprintf("Fader: %.3f", e.value))
	}

	// The pads: drum pads or a keyboard; octave buttons with the keyboard.
	drums := kit.drum_pads_make(cs, "Drum", pads)
	g.keyboard = kit.keyboard_make(cs, "Keys", pads, kit.scale_named("Minor"), root = 0, octave = 3)
	octave := kit.component_make(cs, "Octave")
	octave.user = g
	kit.layer_bind(octave.layer, "up", up)
	kit.layer_bind(octave.layer, "down", down)
	octave.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) { kit.light_value(control, 20) }
	octave.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		k := (^Grid)(c.user).keyboard
		o := clamp(k.octave + (1 if e.slot == "up" else -1), -1, 8)
		kit.keyboard_set(k, k.scale, k.root, o, k.in_key)
		kit.notify(c.cs, fmt.tprintf("Octave %d", o))
	}
	modes := kit.modes_make(cs, "Pads")
	kit.modes_add(modes, "drum", {drums}, drum_button, .Hybrid)
	kit.modes_add(modes, "keys", {g.keyboard, octave}, keys_button, .Hybrid)
	modes.on_change = proc(m: ^kit.Modes, from, to: int) { kit.notify(m.cs, kit.modes_current(m)) }

	for c in ([?]^kit.Component{transport, coarse, &shift_mod.component, faders, &modes.component}) do kit.surface_add(cs, c)
	return true
}
