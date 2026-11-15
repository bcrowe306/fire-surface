// fsurf.daw through the kit: the keyboard example (examples/keys_odin) on
// the fake DAW, and the parts it doesn't use.
package kit_test

import "core:testing"

import abi "../../abi"
import keys "../../examples/keys_odin"
import kit "../../surface"
import fst "../../testing"

KEYS :: "org.fsurf.example.keys"

keys_start :: proc(t: ^testing.T, th: ^fst.Test_Host, daw := true) -> bool {
	if daw do fst.daw_enable(th, tracks = 10, scenes = 2)
	return testing.expect(t, fst.start(th, &keys.fsurf_entry, KEYS))
}

@(test)
the_keys_go_to_the_host_and_the_rest_to_the_surface :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !keys_start(t, &th) do return
	defer fst.stop(&th)
	for m in ([][]u8{{0x90, 60, 100}, {0x80, 60, 0}, {0xE0, 0, 70}, {0xB0, 1, 30}, {0xB0, 64, 127}, {0xD0, 40}}) {
		r := fst.midi_in(&th, m)
		testing.expectf(t, r.host != nil && !r.surface, "%v: the host's", m)
	}
	r := fst.midi_in(&th, cc(keys.CC_PLAY, 127))
	testing.expect(t, r.surface && r.host == nil)
	testing.expect_value(t, th.daw.topics, abi.Daw_Topics{.Transport, .Tracks, .Mixer, .Devices, .Parameters, .Launcher})
	testing.expect_value(t, th.daw.ring, [4]int{0, 8, 0, 0})
}

@(test)
the_transport_buttons_light_with_the_host :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !keys_start(t, &th) do return
	defer fst.stop(&th)
	testing.expect(t, fst.sent_has(&th, cc(keys.CC_STOP, 127))) // stopped
	testing.expect(t, fst.sent_has(&th, cc(keys.CC_PLAY, 0)))
	tap(&th, keys.CC_PLAY)
	testing.expect(t, th.daw.playing)
	testing.expect(t, fst.sent_has(&th, cc(keys.CC_PLAY, 127)) && fst.sent_has(&th, cc(keys.CC_STOP, 0)))
	tap(&th, keys.CC_PLAY) // toggles
	testing.expect(t, !th.daw.playing)
	tap(&th, keys.CC_LOOP)
	tap(&th, keys.CC_METRONOME)
	testing.expect(t, th.daw.loop && th.daw.metronome)
	testing.expect(t, fst.sent_has(&th, cc(keys.CC_LOOP, 127)))
}

@(test)
the_faders_pick_up_their_tracks_and_the_buttons_mute :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !keys_start(t, &th) do return
	defer fst.stop(&th)
	d := th.daw
	fst.midi_in(&th, cc(keys.CC_FADER + 1, 0)) // its 0.8 is far: ignored
	testing.expect(t, near(d.tracks[1].volume, 0.8))
	fst.midi_in(&th, cc(keys.CC_FADER + 1, 100))
	fst.midi_in(&th, cc(keys.CC_FADER + 1, 105)) // past it
	testing.expect(t, near(d.tracks[1].volume, 105.0 / 127))
	tap(&th, keys.CC_MUTE + 3)
	testing.expect(t, d.tracks[3].mute)
	testing.expect(t, fst.sent_has(&th, cc(keys.CC_MUTE + 3, 127)))
	// The host mutes track 5: its button lights.
	d.tracks[5].mute = true
	fst.daw_changed(&th, {.Mixer}, .Track_Mute, 5)
	fst.update(&th)
	testing.expect(t, fst.sent_has(&th, cc(keys.CC_MUTE + 5, 127)))
}

@(test)
banks_move_the_faders_onto_the_next_tracks :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !keys_start(t, &th) do return
	defer fst.stop(&th)
	d := th.daw
	testing.expect(t, fst.sent_has(&th, cc(keys.CC_BANK_LEFT, 0)))
	testing.expect(t, fst.sent_has(&th, cc(keys.CC_BANK_RIGHT, 127)))
	d.tracks[9].mute = true
	fst.clear_sent(&th)
	tap(&th, keys.CC_BANK_RIGHT)
	testing.expect_value(t, d.ring, [4]int{8, 8, 0, 0})
	testing.expect(t, fst.sent_has(&th, cc(keys.CC_MUTE + 1, 127))) // track 9
	testing.expect(t, fst.sent_has(&th, cc(keys.CC_BANK_LEFT, 127)))
	testing.expect(t, fst.sent_has(&th, cc(keys.CC_BANK_RIGHT, 0)))
	fst.midi_in(&th, cc(keys.CC_FADER + 2, 127)) // past the last track: nothing
	tap(&th, keys.CC_MUTE + 2)
	for tr in d.tracks[:8] do testing.expect(t, !tr.mute) // (track 2 past the last: none muted)
	fst.midi_in(&th, cc(keys.CC_FADER, 100)) // track 8, picked up from 0.8
	fst.midi_in(&th, cc(keys.CC_FADER, 110))
	testing.expect(t, near(d.tracks[8].volume, 110.0 / 127))
}

@(test)
the_knobs_play_the_devices_parameters_a_bank_at_a_time :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !keys_start(t, &th) do return
	defer fst.stop(&th)
	p := &th.daw.tracks[0].devices[0].params
	fst.midi_in(&th, cc(keys.CC_KNOB, 66)) // binary offset: +2
	testing.expect(t, near(p[0].value, 0.51))
	fst.midi_in(&th, cc(keys.CC_KNOB + 2, 63)) // stepped: down a step
	testing.expect(t, near(p[2].value, 0))
	tap(&th, keys.CC_PARAMS_RIGHT)
	testing.expect_value(t, fst.last_notified(&th), "Device 1: Bank 2")
	fst.midi_in(&th, cc(keys.CC_KNOB, 65))
	testing.expect(t, near(p[8].value, 0.505))
	tap(&th, keys.CC_PARAMS_RIGHT) // 16 parameters: no third bank
	testing.expect_value(t, fst.last_notified(&th), "Device 1: Bank 2")
	// Another track selected: its device, from bank 1.
	th.daw.selected_track = 1
	fst.daw_changed(&th, {.Tracks}, .Selected_Track)
	fst.daw_changed(&th, {.Devices})
	fst.update(&th)
	fst.midi_in(&th, cc(keys.CC_KNOB, 65))
	testing.expect(t, near(th.daw.tracks[1].devices[0].params[8].value, 0.505)) // (the same device index: bank kept)
	tap(&th, keys.CC_UNDO)
	testing.expect_value(t, fst.last_action(&th), "undo 0 0")
}

@(test)
without_the_extension_it_still_runs :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !keys_start(t, &th, daw = false) do return
	defer fst.stop(&th)
	testing.expect(t, fst.kit_surface(&th).daw == nil)
	tap(&th, keys.CC_PLAY)
	fst.midi_in(&th, cc(keys.CC_FADER, 100))
	tap(&th, keys.CC_BANK_RIGHT)
	r := fst.midi_in(&th, {0x90, 60, 100})
	testing.expect(t, r.host != nil)
}

// ── Tap tempo, the app's actions ──────────────────────────────────────

daw_spec := kit.Spec{
	id = "t.daw", name = "daw", ports = ports_main,
	setup = proc(cs: ^kit.Control_Surface) -> bool {
		tr := kit.transport_make(cs)
		kit.layer_bind(tr.layer, "tap", kit.button(cs, "Tap", kit.bind_cc(1)))
		app := kit.app_make(cs)
		kit.layer_bind(app.layer, "redo", kit.button(cs, "Redo", kit.bind_cc(2)))
		kit.layer_bind(app.layer, "mixer", kit.button(cs, "Mixer", kit.bind_cc(3)))
		kit.surface_add(cs, tr)
		kit.surface_add(cs, app)
		return true
	},
}

daw_library := kit.Library{specs = {&daw_spec}}

daw_entry := abi.Entry{
	fsurf_version = abi.VERSION,
	init          = proc "c" (path: cstring) -> bool { return kit.library_init(&daw_library) },
	deinit        = proc "c" () { kit.library_deinit(&daw_library) },
	get_factory   = proc "c" (id: cstring) -> rawptr { return kit.library_factory(&daw_library, id) },
}

@(test)
tap_tempo_is_the_hosts_or_the_kits :: proc(t: ^testing.T) {
	for own in ([2]bool{false, true}) {
		th: fst.Test_Host
		fst.daw_enable(&th)
		th.daw.tap_tempo = own
		if !testing.expect(t, fst.start(&th, &daw_entry, "t.daw")) do continue
		for _ in 0 ..< 4 {
			tap(&th, 1)
			fst.advance(&th, 400) // 150 bpm
		}
		if own {
			testing.expect_value(t, fst.last_action(&th), "tap_tempo 0 0")
			testing.expect(t, near(th.daw.tempo, 120))
		} else {
			testing.expect(t, near(th.daw.tempo, 150))
		}
		tap(&th, 2)
		tap(&th, 3)
		testing.expect_value(t, fst.last_action(&th), "show_view 0 0")
		testing.expect_value(t, th.daw.actions[len(th.daw.actions) - 2], "redo 0 0")
		fst.stop(&th)
	}
}
