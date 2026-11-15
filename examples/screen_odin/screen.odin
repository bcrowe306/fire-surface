/*
A surface with displays, made with the kit, for a pretend controller
"Screen": four encoders on the selected device's parameters, buttons for
their banks, the selected track and Play, and two displays:

- Main: 256 x 64 pixels, RGB565, over USB (a bulk endpoint): the track's
  name in its colour, the device's, and the bank's four parameters as
  knobs with their names and values; a dot while playing. Drawn again
  whenever the host says something it shows changed (fsurf.daw), sent at
  up to 30 frames a second, only when it changed.
- LCD: a 16 x 2 character display over MIDI SysEx (F0 7D 30 <line>
  <16 characters> F7): the track, and the bank.

	odin build examples/screen_odin -build-mode:dll -out:screen.fsurf
*/
package screen_odin

import "core:fmt"

import abi "../../abi"
import "../../draw"
import kit "../../surface"

CC_KNOB :: 20 // 20-23
CC_BANK_LEFT :: 28
CC_BANK_RIGHT :: 29
CC_PLAY :: 30
CC_TRACK_LEFT :: 31
CC_TRACK_RIGHT :: 32

MAIN :: 0
LCD :: 1

// The surface's state.
Screen :: struct {
	device: ^kit.Device,
}

spec := kit.Spec{
	id          = "org.fsurf.example.screen",
	name        = "Screen (kit example)",
	vendor      = "fire-surface",
	version     = "0.6.0",
	url         = "https://github.com/bcrowe306/fire-surface",
	description = "A pretend controller with a colour display over USB and a character LCD",
	ports       = {{role = "main", inputs = {"Screen*"}, outputs = {"Screen*"}}},
	// The display's USB interface: pid.codes' test ids (no real device).
	devices     = {{role = "display", transport = .Usb_Bulk, vendor_id = 0x1209, product_id = 0x0001, interface = 0, endpoint_out = 0x01, optional = true}},
	displays    = {
		{name = "Main", width = 256, height = 64, format = .Rgb565, fps = 30, device = 0},
		{name = "LCD", width = 16, height = 2, format = .Text, fps = 10, device = -1},
	},
	width       = 170,
	height      = 74,
	setup       = setup,
	on_destroy  = proc(cs: ^kit.Control_Surface) { free(cs.user) },
}

library := kit.Library{specs = {&spec}}

// The entry's symbol: fsurf_entry in a .fsurf, its own name linked in.
ENTRY_NAME :: abi.ENTRY_SYMBOL when ODIN_BUILD_MODE == .Dynamic else "screen_odin_entry"

// The library's entry.
@(export = ODIN_BUILD_MODE == .Dynamic, link_name = ENTRY_NAME)
fsurf_entry := abi.Entry{
	fsurf_version = abi.VERSION,
	init          = proc "c" (path: cstring) -> bool { return kit.library_init(&library) },
	deinit        = proc "c" () { kit.library_deinit(&library) },
	get_factory   = proc "c" (id: cstring) -> rawptr { return kit.library_factory(&library, id) },
}

setup :: proc(cs: ^kit.Control_Surface) -> bool {
	s := new(Screen)
	cs.user = s

	// The parameters, and their banks.
	s.device = kit.device_make(cs, "Device", 4)
	for i in 0 ..< 4 {
		k := kit.encoder(cs, "Knob", kit.bind_cc(u8(CC_KNOB + i)))
		kit.place(k, 14 + f32(i) * 24, 40, 14, 14)
		kit.device_bind_param(s.device, i, k)
	}
	button :: proc(cs: ^kit.Control_Surface, name: string, cc: u8, x, y: f32) -> ^kit.Control {
		b := kit.button(cs, name, kit.bind_cc(cc))
		kit.place(b, x, y, 16, 7)
		return b
	}
	kit.layer_bind(s.device.layer, "prev_bank", button(cs, "Bank <", CC_BANK_LEFT, 112, 40))
	kit.layer_bind(s.device.layer, "next_bank", button(cs, "Bank >", CC_BANK_RIGHT, 132, 40))
	s.device.on_change = proc(d: ^kit.Device) { invalidate(d.cs) }

	transport := kit.transport_make(cs)
	kit.layer_bind(transport.layer, "play", button(cs, "Play", CC_PLAY, 152, 40))

	// Track < and >: the host's selected track.
	tracks := kit.component_make(cs, "Tracks")
	kit.layer_bind(tracks.layer, "left", button(cs, "Track <", CC_TRACK_LEFT, 112, 54))
	kit.layer_bind(tracks.layer, "right", button(cs, "Track >", CC_TRACK_RIGHT, 132, 54))
	tracks.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		t := kit.selected_track(c.cs) + (1 if e.slot == "right" else -1)
		if t >= 0 && t < kit.track_count(c.cs) do kit.daw_set(c.cs, .Selected_Track, 0, 0, f64(t))
	}
	tracks.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) { kit.light_value(control, 30) }

	// The displays follow what they show.
	screens := kit.component_make(cs, "Screens")
	screens.daw_topics = {.Tracks, .Devices, .Parameters, .Transport}
	screens.on_daw = proc(c: ^kit.Component, e: abi.Daw_Event) { invalidate(c.cs) }
	screens.on_activate = proc(c: ^kit.Component) { invalidate(c.cs) }

	main := kit.display(cs, MAIN)
	main.draw = draw_main
	kit.place_display(main, 8, 8, 96, 24)
	lcd := kit.display(cs, LCD)
	lcd.text_line = proc(d: ^kit.Display, row: int, text: string, out: ^[dynamic]u8) {
		append(out, 0xF0, 0x7D, 0x30, u8(row))
		for ch in transmute([]u8)text do append(out, ch & 0x7F)
		append(out, 0xF7)
	}
	kit.place_display(lcd, 112, 8, 52, 11) // (the shape of its 98 x 20 pixels)

	for c in ([]^kit.Component{s.device, transport, tracks, screens}) do kit.surface_add(cs, c)
	return true
}

// What the host shows changed: both displays again.
invalidate :: proc(cs: ^kit.Control_Surface) {
	kit.display_invalidate(kit.display(cs, MAIN))
	lcd := kit.display(cs, LCD)
	s := (^Screen)(cs.user)
	kit.display_text_clear(lcd, 0)
	kit.display_text_clear(lcd, 1)
	if cs.daw == nil {
		kit.display_text(lcd, 0, 0, "No host DAW")
		return
	}
	kit.display_text(lcd, 0, 0, kit.daw_text(cs, .Track_Name, kit.selected_track(cs)))
	n := int(kit.daw_get(cs, .Param_Count))
	kit.display_text(lcd, 1, 0, fmt.tprintf("Bank %d of %d", s.device.bank + 1, max((n + 3) / 4, 1)))
}

draw_main :: proc(d: ^kit.Display, cv: ^draw.Canvas) {
	cs := d.cs
	s := (^Screen)(cs.user)
	f := &draw.FONT_5X7
	draw.clear(cv, 0x0c0e12)
	if cs.daw == nil {
		draw.text_in(cv, f, {0, 0, cv.width, cv.height}, "No host DAW", draw.GREY, .Center)
		return
	}
	// The track, in its colour; the device; playing.
	t := kit.selected_track(cs)
	colour := u32(kit.daw_get(cs, .Track_Color, t))
	draw.fill_rect(cv, {0, 0, cv.width, 11}, draw.mix(0x0c0e12, colour, 110))
	draw.text_in(cv, f, {3, 0, 120, 11}, kit.daw_text(cs, .Track_Name, t), draw.WHITE)
	draw.text_in(cv, f, {120, 0, cv.width - 134, 11}, kit.daw_text(cs, .Device_Name, s.device.device), draw.GREY, .Right)
	draw.fill_circle(cv, cv.width - 6, 5, 3, draw.GREEN if kit.daw_flag(cs, .Playing) else draw.DARK_GREY)
	// The bank's four parameters.
	n := int(kit.daw_get(cs, .Param_Count))
	for i in 0 ..< 4 {
		p := s.device.bank * 4 + i
		x := i * 64
		if p >= n do continue
		v := f32(kit.daw_get(cs, .Param_Value, p))
		draw.knob(cv, x + 32, 30, 12, v, draw.ORANGE)
		draw.text_in(cv, f, {x, 45, 64, 9}, kit.daw_text(cs, .Param_Name, p), draw.GREY, .Center)
		draw.text_in(cv, f, {x, 54, 64, 9}, kit.daw_text(cs, .Param_Value, p), draw.WHITE, .Center)
	}
}
