// The Push 2 example (examples/push2_odin) on the fake DAW: its hello, its
// display sent as a steady stream, what's claimed and what plays.
// Writes .build/push2_main.png to look at.
package kit_test

import "core:os"
import "core:testing"

import push2 "../../examples/push2_odin"
import fst "../../testing"

PUSH2 :: "org.fsurf.example.push2"

@(test)
push2_starts_in_user_mode_and_streams_its_display :: proc(t: ^testing.T) {
	th: fst.Test_Host
	fst.daw_enable(&th, tracks = 10, scenes = 2)
	if !testing.expect(t, fst.start(&th, &push2.fsurf_entry, PUSH2)) do return
	defer fst.stop(&th)
	// Its hello: the backlight on, and User mode last.
	testing.expect(t, fst.sent_has(&th, {0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x08, 0x7F, 0x01, 0xF7}))
	testing.expect(t, fst.sent_has(&th, {0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x0A, 0x01, 0xF7}))
	// Frames at 30 a second, whole (header and 20 writes of 16 KiB), changed or not.
	fst.advance(&th, 40)
	_ = os.write_entire_file(".build/push2_main.png", fst.display_png(&th, 0)) // to look at
	fst.clear_writes(&th)
	fst.advance(&th, 200)
	bytes, writes := fst.written(&th, 0)
	testing.expectf(t, writes >= 5 * 21, "%d writes in 200 ms", writes)
	testing.expect_value(t, len(bytes) % (16 + 160 * 2048), 0)
	// Pads play (the keyboard: remapped to the host); an encoder's touch
	// and the buttons are the surface's.
	r := fst.midi_in(&th, {0x90, 36, 100})
	testing.expect(t, r.host != nil) // (and the surface sees it, to light it)
	fst.midi_in(&th, {0x80, 36, 0})
	r = fst.midi_in(&th, {0x90, 0, 127}) // track encoder 1 touched
	testing.expect(t, r.host == nil)
	r = fst.midi_in(&th, {0xB0, 49, 127}) // Shift
	testing.expect(t, r.host == nil)
	fst.midi_in(&th, {0xB0, 49, 0})
	// Track encoder 1 turned left: the first track's volume, down.
	before := th.daw.tracks[0].volume
	for _ in 0 ..< 10 do fst.midi_in(&th, {0xB0, 71, 0x7F})
	testing.expectf(t, th.daw.tracks[0].volume < before, "%v -> %v", before, th.daw.tracks[0].volume)
}
