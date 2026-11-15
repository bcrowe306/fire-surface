// The kit's fsurf.layout, through the test host: controls by name, what
// they show, the device as SVG, the monitor naming them.
package kit_test

import "core:os"
import "core:strings"
import "core:testing"

import grid "../../examples/grid_odin"
import keys "../../examples/keys_odin"
import host "../../host"
import fst "../../testing"

@(test)
a_surface_is_played_by_its_controls_names :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	r, ok := fst.press(&th, "Play")
	testing.expect(t, ok && r.surface)
	fst.release(&th, "Play")
	testing.expect(t, th.daw.playing)
	st, _ := fst.shows(&th, "Play")
	testing.expect_value(t, st.value, 127)
	fst.turn(&th, "Knob", 4)
	testing.expect(t, near(th.daw.tracks[0].devices[0].params[0].value, 0.52))
	fst.move(&th, "Fader", 0.8) // the selected track's 0.8: picked up at once
	fst.move(&th, "Fader", 0.25)
	testing.expect(t, abs(th.daw.tracks[0].volume - 0.25) < 1e-3)
	testing.expect(t, fst.click(&th, "Keys"))
	r, ok = fst.press(&th, "Pads 3,0", 90)
	testing.expect(t, ok && r.host != nil && r.host[1] == 48)
	st, _ = fst.shows(&th, "Pads 3,0")
	testing.expect(t, st.pressed && st.has_rgb && st.rgb == 0x90ff90)
	_, ok = fst.press(&th, "Nothing")
	testing.expect(t, !ok)
	svg := fst.svg(&th)
	testing.expect(t, strings.contains(svg, "Pads 3,0") && strings.contains(svg, "#90FF90"))
}

@(test)
the_monitor_names_the_controls_and_their_owners :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !grid_start(t, &th) do return
	defer fst.stop(&th)
	host.monitor_enable(&th.h, true)
	fst.midi_in(&th, cc(grid.CC_SHIFT, 127))
	fst.turn(&th, "Knob", 1)
	es := host.monitor_entries(&th.h)
	found_in, found_out := false, false
	for e in es {
		if e.kind == .In && e.control == "Knob" do found_in = e.owner == "Volumes" // under Shift
		if e.kind == .Out && e.control == "Shift" do found_out = e.owner == "Shift"
	}
	testing.expect(t, found_in && found_out)
}

@(test)
the_keyboard_draws_itself :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !keys_start(t, &th) do return
	defer fst.stop(&th)
	testing.expect(t, fst.click(&th, "Play"))
	fst.move(&th, "Fader", 0.8)
	svg := fst.svg(&th)
	testing.expect(t, strings.contains(svg, "Keys 25 (kit example)"))
	_ = os.write_entire_file(".build/keys.svg", transmute([]u8)svg) // to look at
	v := fst.virtual(&th)
	testing.expect_value(t, len(v.controls), 5 + 8 * 3 + 6)
	_ = keys.CC_PLAY
}
