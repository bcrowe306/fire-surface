/*
A surface for a pretend keyboard controller, "Keys 25", in any host that
offers fsurf.daw: its keys, wheels and pedal go straight to the host (no
rule for them: they pass), and the rest works the host:

- Transport buttons (Loop, Stop, Play, Record, Metronome).
- Eight faders: the volumes of eight tracks (the ring), picked up where
  each track is; eight buttons under them mute those tracks; Bank < and >
  move the ring by eight.
- Eight knobs (relative): the selected device's parameters, eight at a
  time; Device < and > page through them; Undo and Redo.

	odin build examples/keys_odin -build-mode:dll -out:keys.fsurf
*/
package keys_odin

import abi "../../abi"
import kit "../../surface"

CC_FADER :: 20 // 20-27
CC_MUTE :: 28 // 28-35
CC_KNOB :: 40 // 40-47
CC_LOOP :: 115
CC_STOP :: 116
CC_PLAY :: 117
CC_RECORD :: 118
CC_METRONOME :: 119
CC_BANK_LEFT :: 104
CC_BANK_RIGHT :: 105
CC_PARAMS_LEFT :: 106
CC_PARAMS_RIGHT :: 107
CC_UNDO :: 108
CC_REDO :: 109

spec := kit.Spec{
	id          = "org.fsurf.example.keys",
	name        = "Keys 25 (kit example)",
	vendor      = "fire-surface",
	version     = "0.4.0",
	url         = "https://github.com/bcrowe306/fire-surface",
	description = "A pretend keyboard with transport, faders and knobs, for any fsurf.daw host",
	ports       = {{role = "main", inputs = {"Keys 25*"}, outputs = {"Keys 25*"}}},
	required_extensions = {abi.DAW_ID},
	setup       = setup,
	on_destroy  = proc(cs: ^kit.Control_Surface) { kit.skin_destroy(cs.skin) },
}

library := kit.Library{specs = {&spec}}

// The entry's symbol: fsurf_entry in a .fsurf, its own name linked in (two
// surfaces linked into one app can't both be fsurf_entry).
ENTRY_NAME :: abi.ENTRY_SYMBOL when ODIN_BUILD_MODE == .Dynamic else "keys_odin_entry"

// The library's entry: its one export when built as a .fsurf; linked into an
// app (or a test), used by name with `host.library_static(&fsurf_entry)`.
@(export = ODIN_BUILD_MODE == .Dynamic, link_name = ENTRY_NAME)
fsurf_entry := abi.Entry{
	fsurf_version = abi.VERSION,
	init          = proc "c" (path: cstring) -> bool { return kit.library_init(&library) },
	deinit        = proc "c" () { kit.library_deinit(&library) },
	get_factory   = proc "c" (id: cstring) -> rawptr { return kit.library_factory(&library, id) },
}

setup :: proc(cs: ^kit.Control_Surface) -> bool {
	// Its buttons have one LED each: on 127, off 0 (and 0 is the default).
	skin := kit.skin_make()
	lit := []string{
		"Transport.Play.On", "Transport.Stop.On", "Transport.Record.On", "Transport.Loop.On", "Transport.Metronome.On",
		"Mixer.Mute.On", "Navigation.On", "Device.Bank.On", "App.On",
	}
	for name in lit do kit.skin_set(skin, name, 127)
	kit.set_skin(cs, skin)

	transport := kit.transport_make(cs)
	Button :: struct { slot: string, cc: u8 }
	buttons := []Button{{"loop", CC_LOOP}, {"stop", CC_STOP}, {"play", CC_PLAY}, {"record", CC_RECORD}, {"metronome", CC_METRONOME}}
	for b in buttons do kit.layer_bind(transport.layer, b.slot, kit.button(cs, b.slot, kit.bind_cc(b.cc)))

	mixer := kit.mixer_make(cs, "Mixer", 8)
	device := kit.device_make(cs, "Device", 8)
	for i in 0 ..< 8 {
		kit.mixer_bind(mixer, i, .Volume, kit.fader(cs, "Fader", kit.bind_cc(u8(CC_FADER + i)), pickup = true))
		kit.mixer_bind(mixer, i, .Mute, kit.button(cs, "Mute", kit.bind_cc(u8(CC_MUTE + i))))
		kit.device_bind_param(device, i, kit.encoder(cs, "Knob", kit.bind_cc(u8(CC_KNOB + i)), .Binary_Offset))
	}
	kit.layer_bind(device.layer, "prev_bank", kit.button(cs, "Device <", kit.bind_cc(CC_PARAMS_LEFT)))
	kit.layer_bind(device.layer, "next_bank", kit.button(cs, "Device >", kit.bind_cc(CC_PARAMS_RIGHT)))

	nav := kit.navigation_make(cs)
	kit.layer_bind(nav.layer, "left", kit.button(cs, "Bank <", kit.bind_cc(CC_BANK_LEFT)))
	kit.layer_bind(nav.layer, "right", kit.button(cs, "Bank >", kit.bind_cc(CC_BANK_RIGHT)))

	app := kit.app_make(cs)
	kit.layer_bind(app.layer, "undo", kit.button(cs, "Undo", kit.bind_cc(CC_UNDO)))
	kit.layer_bind(app.layer, "redo", kit.button(cs, "Redo", kit.bind_cc(CC_REDO)))

	for c in ([]^kit.Component{transport, mixer, device, nav, app}) do kit.surface_add(cs, c)
	return true
}
