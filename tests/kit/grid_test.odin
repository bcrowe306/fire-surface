// The kit example (examples/grid_odin) through the test host, on a fake
// fsurf.daw: what a user of the pretend controller would see.
package kit_test

import "core:testing"

import abi "../../abi"
import grid "../../examples/grid_odin"
import fst "../../testing"

GRID :: "org.fsurf.example.grid"
PADS :: grid.PAD_CHANNEL

grid_start :: proc(t: ^testing.T, th: ^fst.Test_Host, daw := true, tracks := 6, scenes := 6) -> bool {
	if daw do fst.daw_enable(th, tracks = tracks, scenes = scenes)
	return testing.expect(t, fst.start(th, &grid.fsurf_entry, GRID))
}

cc :: proc(n, v: u8) -> []u8 {
	b := make([]u8, 3, context.temp_allocator)
	b[0], b[1], b[2] = 0xB0, n, v
	return b
}

nt :: proc(status, n, v: u8) -> []u8 {
	b := make([]u8, 3, context.temp_allocator)
	b[0], b[1], b[2] = status, n, v
	return b
}

tap :: proc(th: ^fst.Test_Host, n: u8) {
	fst.midi_in(th, cc(n, 127))
	fst.midi_in(th, cc(n, 0))
}

near :: proc(a, b: f64) -> bool { return abs(a - b) < 1e-6 }

@(test)
the_grid_starts_with_its_hello_and_lights :: proc(t: ^testing.T) {
	for daw in ([2]bool{false, true}) {
		th: fst.Test_Host
		if !grid_start(t, &th, daw) do continue
		testing.expect(t, fst.sent_has(&th, {0xF0, 0x7D, 0x20, 0x01, 0xF7}))
		testing.expect(t, fst.sent_has(&th, cc(grid.CC_PLAY, 5)))   // stopped
		testing.expect(t, fst.sent_has(&th, cc(grid.CC_DRUM, 127))) // Drum mode on
		testing.expect(t, fst.sent_has(&th, cc(grid.CC_KEYS, 5)))
		testing.expect(t, fst.sent_has(&th, cc(grid.CC_SESSION, 5)))
		testing.expect(t, fst.sent_has(&th, cc(grid.CC_SHIFT, 5)))
		for n in u8(36) ..< 52 do testing.expectf(t, fst.sent_has(&th, nt(0x90 | PADS, n, 10)), "pad %d lit", n)
		testing.expect(t, !fst.sent_has(&th, cc(grid.CC_OCTAVE_UP, 20))) // the keyboard's: dark now
		if daw {
			testing.expect_value(t, th.daw.ring, [4]int{0, 4, 0, 4}) // the ring: four tracks, four scenes
			testing.expect_value(t, th.daw.topics, abi.Daw_Topics{.Transport, .Tracks, .Mixer, .Devices, .Parameters, .Launcher})
			testing.expect(t, fst.sent_has(&th, cc(grid.CC_LEFT + 1, 127))) // right: there are tracks there
			testing.expect(t, fst.sent_has(&th, cc(grid.CC_LEFT, 0)))
		}
		fst.stop(&th)
	}
}

@(test)
drum_pads_play_through_and_light_as_they_are_hit :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th, daw = false) do return
	defer fst.stop(&th)
	fst.clear_sent(&th)
	r := fst.midi_in(&th, nt(0x90 | PADS, 36, 100))
	testing.expect_value(t, r.action, abi.Rule_Action.Remap)
	testing.expect_value(t, string(r.host), string(nt(0x90 | PADS, 36, 100))) // drum 36 is the bottom-left
	testing.expect(t, r.surface)
	testing.expect(t, fst.sent_has(&th, nt(0x90 | PADS, 36, 127))) // lit while hit
	r = fst.midi_in(&th, nt(0x80 | PADS, 36, 0))
	testing.expect(t, r.host != nil)
	testing.expect(t, fst.sent_has(&th, nt(0x90 | PADS, 36, 10)))
	r = fst.midi_in(&th, nt(0x90, 36, 100)) // not a pad: the host's
	testing.expect(t, r.host != nil && !r.surface)
	r = fst.midi_in(&th, cc(1, 64))
	testing.expect(t, r.host != nil && !r.surface)
}

@(test)
the_transport_buttons_play_and_stop_the_host :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	r := fst.midi_in(&th, cc(grid.CC_PLAY, 127))
	testing.expect(t, r.surface && r.host == nil)
	testing.expect(t, th.daw.playing)
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_PLAY, 127))) // lit by the host's event
	fst.midi_in(&th, cc(grid.CC_PLAY, 0))
	th.daw.position = 12
	tap(&th, grid.CC_STOP)
	testing.expect(t, !th.daw.playing)
	testing.expect(t, near(th.daw.position, 12))
	tap(&th, grid.CC_STOP) // stopped: back to the start
	testing.expect(t, near(th.daw.position, 0))
	tap(&th, grid.CC_RECORD)
	testing.expect(t, th.daw.recording)
	// Changed in the host: the lights follow.
	fst.clear_sent(&th)
	th.daw.recording = false
	fst.daw_changed(&th, {.Transport}, .Recording)
	fst.update(&th)
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_RECORD, 5)))
	// The octave buttons, nobody's in drum mode: still the surface's (they don't play).
	r = fst.midi_in(&th, cc(grid.CC_OCTAVE_UP, 127))
	testing.expect(t, r.surface && r.host == nil)
}

@(test)
the_knobs_turn_parameters_and_with_shift_volumes :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	p := &th.daw.tracks[0].devices[0].params
	fst.midi_in(&th, cc(grid.CC_KNOB, 1))
	testing.expect(t, near(p[0].value, 0.505))
	fst.midi_in(&th, cc(grid.CC_KNOB + 2, 1)) // P3 has 3 steps: one a tick
	testing.expect(t, near(p[2].value, 1))
	fst.midi_in(&th, cc(grid.CC_SHIFT, 127))
	fst.midi_in(&th, cc(grid.CC_KNOB + 1, 127)) // -1: the second track's volume
	testing.expect(t, near(th.daw.tracks[1].volume, 0.79))
	testing.expect(t, near(p[1].value, 0.5))
	fst.midi_in(&th, cc(grid.CC_SHIFT, 0))
	fst.midi_in(&th, cc(grid.CC_KNOB + 1, 127))
	testing.expect(t, near(p[1].value, 0.495))
}

@(test)
the_fader_picks_up_the_selected_tracks_volume :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	th.daw.selected_track = 2
	fst.daw_changed(&th, {.Tracks}, .Selected_Track)
	fst.update(&th)
	fst.midi_in(&th, cc(grid.CC_FADER, 10)) // far below its 0.8: ignored
	fst.midi_in(&th, cc(grid.CC_FADER, 90))
	testing.expect(t, near(th.daw.tracks[2].volume, 0.8))
	fst.midi_in(&th, cc(grid.CC_FADER, 110)) // past it: picked up
	testing.expect(t, abs(th.daw.tracks[2].volume - 110.0 * 128 / 16383) < 1e-6)
	fst.midi_in(&th, cc(grid.CC_FADER, 64))
	fst.midi_in(&th, cc(grid.CC_FADER + 32, 64)) // 14 bits
	testing.expect(t, abs(th.daw.tracks[2].volume - 8256.0 / 16383) < 1e-6)
	testing.expect(t, near(th.daw.tracks[0].volume, 0.8))
}

@(test)
keys_mode_plays_the_hosts_scale :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	fst.clear_sent(&th)
	tap(&th, grid.CC_KEYS)
	testing.expect_value(t, fst.last_notified(&th), "keys")
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_KEYS, 127)))
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_DRUM, 5)))
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_OCTAVE_UP, 20))) // its buttons, lit
	testing.expect(t, fst.sent_has(&th, nt(0x90 | PADS, 36, 60)))  // the bottom-left: the root
	// The host's C minor from C3 (48): along the row by degree, each row up a fourth.
	Case :: struct { pad, note: u8 }
	for c in ([]Case{{36, 48}, {37, 50}, {38, 51}, {39, 53}, {40, 53}, {44, 58}}) {
		r := fst.midi_in(&th, nt(0x90 | PADS, c.pad, 90))
		testing.expectf(t, r.host != nil && r.host[1] == c.note, "pad %d: %v, want note %d", c.pad, r.host, c.note)
		fst.midi_in(&th, nt(0x80 | PADS, c.pad, 0))
	}
	// Both pads of a note light while one is held (39 and 40 are F).
	fst.clear_sent(&th)
	fst.midi_in(&th, nt(0x90 | PADS, 39, 90))
	testing.expect(t, fst.sent_has(&th, nt(0x90 | PADS, 39, 127)) && fst.sent_has(&th, nt(0x90 | PADS, 40, 127)))
	fst.midi_in(&th, nt(0x80 | PADS, 39, 0))
	testing.expect(t, fst.sent_has(&th, nt(0x90 | PADS, 40, 20)))

	// The host's scale changes: D major.
	th.daw.scale_root = 2
	th.daw.scale_mask = 0b1010_1011_0101
	fst.daw_changed(&th, {.Notes})
	fst.update(&th)
	r := fst.midi_in(&th, nt(0x90 | PADS, 38, 90)) // the third degree: F#
	testing.expect_value(t, r.host[1], 54)
	fst.midi_in(&th, nt(0x80 | PADS, 38, 0))

	tap(&th, grid.CC_OCTAVE_UP)
	testing.expect_value(t, fst.last_notified(&th), "Octave Up")
	r = fst.midi_in(&th, nt(0x90 | PADS, 36, 90))
	testing.expect_value(t, r.host[1], 62)
}

@(test)
a_mode_button_held_is_momentary :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th, daw = false) do return
	defer fst.stop(&th)
	tap(&th, grid.CC_KEYS)
	fst.midi_in(&th, cc(grid.CC_DRUM, 127))
	testing.expect_value(t, fst.last_notified(&th), "drum")
	fst.advance(&th, 400) // held: back to keys when released
	fst.midi_in(&th, cc(grid.CC_DRUM, 0))
	testing.expect_value(t, fst.last_notified(&th), "keys")
	r := fst.midi_in(&th, nt(0x90 | PADS, 36, 90))
	testing.expect_value(t, r.host[1], 48)
}

@(test)
a_note_held_across_a_mode_change_ends_where_it_began :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th, daw = false) do return
	defer fst.stop(&th)
	tap(&th, grid.CC_KEYS)
	r := fst.midi_in(&th, nt(0x90 | PADS, 37, 90)) // D3 (50)
	testing.expect_value(t, r.host[1], 50)
	tap(&th, grid.CC_DRUM) // the pad is drum 37 now
	r = fst.midi_in(&th, nt(0x80 | PADS, 37, 0))
	testing.expect_value(t, r.host[1], 50) // the host's D3 ends
}

@(test)
session_mode_launches_clips_in_the_ring :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	d := th.daw
	d.tracks[0].clips[0].state = .Stopped
	d.tracks[1].clips[0].state = .Playing
	d.tracks[4].clips[1].state = .Stopped
	fst.clear_sent(&th)
	tap(&th, grid.CC_SESSION)
	testing.expect_value(t, fst.last_notified(&th), "session")
	// Row 0 (top: notes 48-51) is scene 1; columns are tracks.
	testing.expect(t, fst.sent_has(&th, nt(0x90 | PADS, 48, 30)))  // stopped
	testing.expect(t, fst.sent_has(&th, nt(0x90 | PADS, 49, 127))) // playing
	testing.expect(t, fst.sent_has(&th, nt(0x90 | PADS, 50, 0)))   // empty
	r := fst.midi_in(&th, nt(0x90 | PADS, 48, 100)) // the surface's now, not a note
	testing.expect(t, r.surface && r.host == nil)
	testing.expect_value(t, fst.last_action(&th), "launch_clip 0 0")
	testing.expect_value(t, d.tracks[0].clips[0].state, abi.Clip_State.Playing)
	testing.expect(t, fst.sent_has(&th, nt(0x90 | PADS, 48, 127)))
	fst.midi_in(&th, nt(0x80 | PADS, 48, 0))

	// Right three tracks, down one scene: track 4's clip at the top left.
	fst.clear_sent(&th)
	for _ in 0 ..< 3 do tap(&th, grid.CC_LEFT + 1)
	tap(&th, grid.CC_LEFT + 3)
	testing.expect_value(t, d.ring, [4]int{3, 4, 1, 4})
	testing.expect(t, fst.sent_has(&th, nt(0x90 | PADS, 49, 30))) // track 4, scene 2
	testing.expect(t, fst.sent_has(&th, nt(0x90 | PADS, 48, 0)))  // track 3, scene 2: empty (was the playing clip)
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_LEFT, 127)))   // left: lit now
}

@(test)
repeat_held_repeats_the_drum_pads_in_time :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	fst.midi_in(&th, cc(grid.CC_REPEAT, 127))
	r := fst.midi_in(&th, nt(0x90 | PADS, 37, 100))
	testing.expect(t, r.surface && r.host == nil) // claimed: the repeats come from the surface
	testing.expect_value(t, len(th.injected), 1)
	testing.expect_value(t, string(th.injected[0]), string(nt(0x90 | PADS, 37, 100)))
	fst.advance(&th, 255) // 120 bpm, sixteenths: every 125 ms
	testing.expect_value(t, len(th.injected), 5) // off and on, twice
	fst.midi_in(&th, nt(0x80 | PADS, 37, 0))
	testing.expect_value(t, string(th.injected[len(th.injected) - 1]), string(nt(0x80 | PADS, 37, 0)))
	n := len(th.injected)
	fst.advance(&th, 300)
	testing.expect_value(t, len(th.injected), n)
	fst.midi_in(&th, cc(grid.CC_REPEAT, 0))
	r = fst.midi_in(&th, nt(0x90 | PADS, 37, 100)) // drum pads again
	testing.expect_value(t, r.action, abi.Rule_Action.Remap)
}

@(test)
reconnecting_sends_everything_again_and_stopping_says_goodbye :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	fst.midi_in(&th, cc(grid.CC_PLAY, 127))
	fst.clear_sent(&th)
	testing.expect(t, fst.reconnect(&th))
	testing.expect(t, fst.sent_has(&th, {0xF0, 0x7D, 0x20, 0x00, 0xF7})) // goodbye
	testing.expect(t, fst.sent_has(&th, {0xF0, 0x7D, 0x20, 0x01, 0xF7})) // hello
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_PLAY, 127)))         // as it is
	testing.expect(t, fst.sent_has(&th, nt(0x90 | PADS, 51, 10)))
}
