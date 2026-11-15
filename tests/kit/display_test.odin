// Displays through the kit: the screen example (a colour display over USB,
// a character LCD over SysEx) on the fake DAW, Push 2 frames, 1-bit pages.
// Writes .build/screen.svg and .build/screen_main.png to look at.
package kit_test

import "core:os"
import "core:strings"
import "core:testing"

import abi "../../abi"
import "../../draw"
import host "../../host"
import screen "../../examples/screen_odin"
import kit "../../surface"
import fst "../../testing"

SCREEN :: "org.fsurf.example.screen"

screen_start :: proc(t: ^testing.T, th: ^fst.Test_Host) -> bool {
	fst.daw_enable(th, tracks = 3, scenes = 1)
	th.daw.tracks[0].name = "Bass"
	th.daw.tracks[0].color = 0x3070ff
	return testing.expect(t, fst.start(th, &screen.fsurf_entry, SCREEN))
}

lcd_line :: proc(row: int, text: string) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, 0xF0, 0x7D, 0x30, u8(row))
	for i in 0 ..< 16 do append(&out, text[i] if i < len(text) else ' ')
	append(&out, 0xF7)
	return out[:]
}

@(test)
the_displays_show_the_track_and_its_parameters :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !screen_start(t, &th) do return
	defer fst.stop(&th)
	fst.advance(&th, 40)
	// Main: one frame, the whole display in RGB565, in one write.
	bytes, writes := fst.written(&th, 0)
	testing.expect_value(t, writes, 1)
	testing.expect_value(t, len(bytes), 256 * 64 * 2)
	// LCD: its two lines.
	testing.expect(t, fst.sent_has(&th, lcd_line(0, "Bass")))
	testing.expect(t, fst.sent_has(&th, lcd_line(1, "Bank 1 of 4")))
	// Mirrored for the host: the track's name drawn in white on its colour.
	v := fst.virtual(&th)
	m := host.virtual_display(v, host.virtual_find(v, "Main"))
	testing.expect(t, m != nil && m.width == 256 && m.height == 64)
	_ = os.write_entire_file(".build/screen_main.png", fst.display_png(&th, 0)) // to look at

	// Nothing changes: nothing is sent.
	fst.clear_writes(&th)
	fst.clear_sent(&th)
	fst.advance(&th, 100)
	_, writes = fst.written(&th, 0)
	testing.expect_value(t, writes, 0)
	testing.expect_value(t, fst.sent_count(&th), 0)

	// A knob turned: the host's event, then a frame (and only Main: the LCD's lines are the same).
	fst.turn(&th, "Knob", 10)
	fst.advance(&th, 40)
	_, writes = fst.written(&th, 0)
	testing.expect_value(t, writes, 1)
	testing.expect_value(t, fst.sent_count(&th), 0)

	// The next bank: its line again; the next track: its name.
	fst.click(&th, "Bank >")
	fst.advance(&th, 120)
	testing.expect(t, fst.sent_has(&th, lcd_line(1, "Bank 2 of 4")))
	testing.expect(t, !fst.sent_has(&th, lcd_line(0, "Bass")))
	fst.click(&th, "Track >")
	fst.advance(&th, 120)
	testing.expect_value(t, th.daw.selected_track, 1)
	testing.expect(t, fst.sent_has(&th, lcd_line(0, "2")))

	svg := fst.svg(&th)
	testing.expect(t, strings.count(svg, "data:image/png;base64,") == 2)
	_ = os.write_entire_file(".build/screen.svg", transmute([]u8)svg)
}

@(test)
an_unplugged_display_is_sent_whole_when_it_is_back :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !screen_start(t, &th) do return
	defer fst.stop(&th)
	fst.advance(&th, 40)
	fst.device_state(&th, 0, false)
	fst.clear_writes(&th)
	fst.turn(&th, "Knob", 5)
	fst.advance(&th, 100)
	_, writes := fst.written(&th, 0)
	testing.expect_value(t, writes, 0) // gone: nothing written
	fst.device_state(&th, 0, true)
	fst.advance(&th, 40)
	bytes, w2 := fst.written(&th, 0)
	testing.expect_value(t, w2, 1)
	testing.expect_value(t, len(bytes), 256 * 64 * 2)
}

@(test)
displays_mirror_without_their_device :: proc(t: ^testing.T) {
	th: fst.Test_Host
	th.devices_fail = true // none opens (it's optional: the surface runs)
	if !screen_start(t, &th) do return
	defer fst.stop(&th)
	fst.advance(&th, 40)
	testing.expect_value(t, len(th.writes), 0)
	testing.expect(t, fst.display_png(&th, 0) != nil)
}

// ── Other displays: Push 2, a 1-bit OLED over HID ─────────────────────

push_spec := kit.Spec{
	id = "t.push", name = "push", ports = ports_main,
	devices = {{role = "display", transport = .Usb_Bulk, vendor_id = 0x2982, product_id = 0x1967, endpoint_out = 0x01}},
	displays = {{name = "Push", width = draw.PUSH2_WIDTH, height = draw.PUSH2_HEIGHT, format = .Bgr565, fps = 60, device = 0}},
	setup = proc(cs: ^kit.Control_Surface) -> bool {
		d := kit.display(cs, 0)
		d.send = kit.display_send_push2
		d.draw = proc(d: ^kit.Display, cv: ^draw.Canvas) { draw.fill_rect(cv, {0, 0, 10, 10}, 0xFF0000) }
		return true
	},
}

oled_report := [1]u8{0x01}

oled_spec := kit.Spec{
	id = "t.oled", name = "oled", ports = ports_main,
	devices = {{role = "oled", transport = .Hid, vendor_id = 0x1209, product_id = 0x0002, usage_page = 0xFF00}},
	displays = {{name = "OLED", width = 128, height = 64, format = .Mono_Pages, fps = 20, device = 0}},
	setup = proc(cs: ^kit.Control_Surface) -> bool {
		d := kit.display(cs, 0)
		d.prefix = oled_report[:] // its report id
		d.chunk = 65 // (its report size)
		d.draw = proc(d: ^kit.Display, cv: ^draw.Canvas) { draw.set(cv, 0, 0, draw.WHITE) }
		return true
	},
}

display_library := kit.Library{specs = {&push_spec, &oled_spec}}

display_entry := abi.Entry{
	fsurf_version = abi.VERSION,
	init          = proc "c" (path: cstring) -> bool { return kit.library_init(&display_library) },
	deinit        = proc "c" () { kit.library_deinit(&display_library) },
	get_factory   = proc "c" (id: cstring) -> rawptr { return kit.library_factory(&display_library, id) },
}

@(test)
a_push2_display_gets_its_header_and_16k_writes :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !testing.expect(t, fst.start(&th, &display_entry, "t.push")) do return
	defer fst.stop(&th)
	testing.expect_value(t, th.s.descriptor.displays[0].fps, 60)
	fst.advance(&th, 10)
	testing.expect_value(t, len(th.writes), 1 + 20)
	testing.expect_value(t, len(th.writes[0].bytes), 16)
	testing.expect_value(t, th.writes[0].bytes[0], 0xFF)
	testing.expect_value(t, len(th.writes[1].bytes), 16384)
	// The first pixel: red, BGR565 (001F), masked (E7 F3): 1F^E7, 00^F3.
	testing.expect_value(t, len(th.writes[1].bytes), 16384)
	testing.expect_value(t, th.writes[1].bytes[0], 0x1F ~ 0xE7)
	testing.expect_value(t, th.writes[1].bytes[1], 0x00 ~ 0xF3)
}

@(test)
a_one_bit_display_is_sent_in_pages :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !testing.expect(t, fst.start(&th, &display_entry, "t.oled")) do return
	defer fst.stop(&th)
	fst.advance(&th, 10)
	bytes, writes := fst.written(&th, 0)
	testing.expect_value(t, len(bytes), 1 + 128 * 8)
	testing.expect_value(t, writes, (1 + 128 * 8 + 64) / 65)
	testing.expect_value(t, bytes[0], 0x01) // its report id
	testing.expect_value(t, bytes[1], 0x01) // the top left pixel: page 0, column 0, bit 0
	testing.expect_value(t, bytes[2], 0x00)
}
