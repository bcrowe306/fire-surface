// The kit example (examples/grid_odin) through the test host: what a user
// of the pretend controller would see.
package kit_test

import "core:testing"

import abi "../../abi"
import grid "../../examples/grid_odin"
import fst "../../testing"

GRID :: "org.fsurf.example.grid"
PADS :: grid.PAD_CHANNEL

grid_start :: proc(t: ^testing.T, th: ^fst.Test_Host) -> bool {
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

@(test)
the_grid_starts_with_its_hello_and_lights :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	testing.expect(t, fst.sent_has(&th, {0xF0, 0x7D, 0x20, 0x01, 0xF7}))
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_PLAY, 5)))   // Play off
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_DRUM, 127))) // Drum mode on
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_KEYS, 5)))
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_SHIFT, 5)))
	for n in u8(36) ..< 52 do testing.expectf(t, fst.sent_has(&th, nt(0x90 | PADS, n, 10)), "pad %d lit", n)
	// The octave buttons are only the keyboard's: dark in drum mode.
	testing.expect(t, !fst.sent_has(&th, cc(grid.CC_OCTAVE_UP, 20)))
}

@(test)
drum_pads_play_through_and_light_as_they_are_hit :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
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
	// Not a pad: the host's.
	r = fst.midi_in(&th, nt(0x90, 36, 100))
	testing.expect(t, r.host != nil && !r.surface)
	r = fst.midi_in(&th, cc(1, 64))
	testing.expect(t, r.host != nil && !r.surface)
}

@(test)
play_toggles_and_buttons_are_the_surfaces :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	r := fst.midi_in(&th, cc(grid.CC_PLAY, 127))
	testing.expect(t, r.surface && r.host == nil)
	testing.expect_value(t, fst.last_notified(&th), "Play")
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_PLAY, 127)))
	fst.midi_in(&th, cc(grid.CC_PLAY, 0))
	fst.midi_in(&th, cc(grid.CC_PLAY, 127))
	testing.expect_value(t, fst.last_notified(&th), "Stop")
	// The octave buttons, unowned in drum mode: still the surface's (they don't play).
	r = fst.midi_in(&th, cc(grid.CC_OCTAVE_UP, 127))
	testing.expect(t, r.surface && r.host == nil)
	testing.expect_value(t, fst.last_notified(&th), "Stop")
}

@(test)
shift_makes_the_knobs_fine :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	fst.midi_in(&th, cc(grid.CC_KNOB, 1))
	testing.expect_value(t, fst.last_notified(&th), "Knob 1: 65.0")
	fst.midi_in(&th, cc(grid.CC_KNOB + 2, 127)) // -1
	testing.expect_value(t, fst.last_notified(&th), "Knob 3: 63.0")
	fst.clear_sent(&th)
	fst.midi_in(&th, cc(grid.CC_SHIFT, 127))
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_SHIFT, 127)))
	fst.midi_in(&th, cc(grid.CC_KNOB, 1))
	testing.expect_value(t, fst.last_notified(&th), "Fine 1: 65.1")
	fst.midi_in(&th, cc(grid.CC_SHIFT, 0))
	fst.midi_in(&th, cc(grid.CC_KNOB, 1))
	testing.expect_value(t, fst.last_notified(&th), "Knob 1: 66.1")
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_SHIFT, 5)))
}

@(test)
the_fader_picks_up_where_its_value_is :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	n := len(th.notified)
	fst.midi_in(&th, cc(grid.CC_FADER, 10)) // far below 0.5: ignored
	fst.midi_in(&th, cc(grid.CC_FADER + 32, 0))
	fst.midi_in(&th, cc(grid.CC_FADER, 40))
	testing.expect_value(t, len(th.notified), n)
	fst.midi_in(&th, cc(grid.CC_FADER, 70)) // past 0.5: picked up
	testing.expect(t, len(th.notified) > n)
	fst.midi_in(&th, cc(grid.CC_FADER, 64))
	fst.midi_in(&th, cc(grid.CC_FADER + 32, 64)) // 14 bits
	testing.expect_value(t, fst.last_notified(&th), "Fader: 0.504")
}

@(test)
keys_mode_remaps_the_pads_to_a_scale :: proc(t: ^testing.T) {
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
	// C minor from C3 (48): along the row by degree, each row up a fourth.
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

	tap(&th, grid.CC_OCTAVE_UP)
	testing.expect_value(t, fst.last_notified(&th), "Octave 4")
	r := fst.midi_in(&th, nt(0x90 | PADS, 36, 90))
	testing.expect_value(t, r.host[1], 60)
}

@(test)
a_mode_button_held_is_momentary :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
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
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	tap(&th, grid.CC_KEYS)
	r := fst.midi_in(&th, nt(0x90 | PADS, 37, 90)) // D3 (50)
	testing.expect_value(t, r.host[1], 50)
	tap(&th, grid.CC_DRUM) // the pad is drum 37 now
	r = fst.midi_in(&th, nt(0x80 | PADS, 37, 0))
	testing.expect_value(t, r.host[1], 50) // the host's D3 ends
}

@(test)
reconnecting_sends_everything_again_and_stopping_says_goodbye :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	fst.midi_in(&th, cc(grid.CC_PLAY, 127)) // Play on
	fst.clear_sent(&th)
	testing.expect(t, fst.reconnect(&th))
	testing.expect(t, fst.sent_has(&th, {0xF0, 0x7D, 0x20, 0x00, 0xF7})) // goodbye
	testing.expect(t, fst.sent_has(&th, {0xF0, 0x7D, 0x20, 0x01, 0xF7})) // hello
	testing.expect(t, fst.sent_has(&th, cc(grid.CC_PLAY, 127)))         // as it was
	testing.expect(t, fst.sent_has(&th, nt(0x90 | PADS, 51, 10)))
	fst.clear_sent(&th)
	host_th := &th
	fst.stop(host_th)
}
