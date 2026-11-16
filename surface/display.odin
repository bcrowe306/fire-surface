package surface

import abi "../abi"
import "../draw"

/*
Displays. A spec's displays (`Spec.displays`) each get a `Display` with a
canvas in the draw kit. A component draws on it when what it shows
changes: set `draw` and call `display_invalidate`. At the display's frame
rate the host asks for a frame; the kit calls `draw` if the display was
invalidated, and sends what changed: over its device (a USB bulk transfer
or HID report: `prefix`, then the canvas in the display's format, in
`chunk`-sized writes; `send` to do it otherwise, `display_send_push2` for
a Push 2), and to the host to mirror (a virtual controller shows it). When
the device opens (again), everything is sent.

A text display (format Text: `width` characters by `height` lines, as a
character LCD) is written with `display_text`; the kit sends the lines
that changed, each as `text_line` makes it (a SysEx, on the first port).
*/

// A device other than MIDI (abi.Device_Spec).
Device_Def :: struct {
	role:                  string,
	transport:             abi.Device_Transport,
	vendor_id, product_id: u16,
	interface:             int, // USB: its interface (-1 = any)
	endpoint_out:          u8, // USB bulk: the OUT endpoint's address
	endpoint_in:           u8, // 0 = none
	usage_page, usage:     u16, // HID
	optional:              bool,
}

// A display (abi.Display_Spec).
Display_Def :: struct {
	name:          string,
	width, height: int, // pixels (Text: characters and lines)
	format:        abi.Pixel_Format,
	fps:           int, // frames a second the host asks for
	device:        int, // the device it goes over; -1 = MIDI (Text displays, or `send` of your own)
}

// A display of the surface. Fields are the kit's but the settings.
Display :: struct {
	cs:        ^Control_Surface,
	index:     int,
	def:       Display_Def,
	canvas:    draw.Canvas,
	// Settings.
	draw:      proc(d: ^Display, cv: ^draw.Canvas), // draws it (after `display_invalidate`)
	send:      proc(d: ^Display) -> bool, // sends what changed (nil: the kit's)
	text_line: proc(d: ^Display, row: int, text: string, out: ^[dynamic]u8), // Text: a line's message
	prefix:    []u8, // sent before each frame's pixels (a header; not copied: keep it alive)
	chunk:     int, // the most bytes a write (0: a frame a write)
	// Sent each time the host asks (at the display's rate), changed or not:
	// for a device that wants a steady stream (Push 2 turns its display off
	// without frames).
	resend:    bool,
	user:      rawptr,
	// State.
	invalid:   bool,
	full:      bool,
	text:      [dynamic]u8, // Text: width x height characters
	sent_text: [dynamic]u8,
	frames:    int, // frames sent
	x, y, w, h: f32, // its place on the device (`place_display`), for tools
}

// The surface's display `index` (in the spec's displays), or nil.
display :: proc(cs: ^Control_Surface, index: int) -> ^Display {
	return cs.displays[index] if index >= 0 && index < len(cs.displays) else nil
}

// Asks for the display to be drawn again (its `draw`) at its next frame.
display_invalidate :: proc(d: ^Display) {
	if d != nil do d.invalid = true
}

// Writes text on a text display at a line and column (cut at its end).
display_text :: proc(d: ^Display, row, col: int, s: string) {
	if d.def.format != .Text || row < 0 || row >= d.def.height do return
	c := col
	for ch in transmute([]u8)s {
		if c >= d.def.width do break
		if c >= 0 do d.text[row * d.def.width + c] = ch
		c += 1
	}
	d.invalid = true
}

// Clears a text display's line (to spaces).
display_text_clear :: proc(d: ^Display, row: int) {
	if d.def.format != .Text || row < 0 || row >= d.def.height do return
	for i in 0 ..< d.def.width do d.text[row * d.def.width + i] = ' '
	d.invalid = true
}

// Places a display on the device, for tools.
place_display :: proc(d: ^Display, x, y, w, h: f32) {
	d.x, d.y, d.w, d.h = x, y, w, h
}

@(private)
displays_make :: proc(cs: ^Control_Surface) {
	for def, i in cs.spec.displays {
		d := new(Display)
		d^ = {cs = cs, index = i, def = def, invalid = true, full = true}
		if def.format == .Text {
			d.text = make([dynamic]u8, def.width * def.height)
			d.sent_text = make([dynamic]u8, def.width * def.height)
			for &ch in d.text do ch = ' '
			for &ch in d.sent_text do ch = 0
			d.canvas = draw.canvas_make(def.width * draw.FONT_5X7.advance + 2, def.height * draw.FONT_5X7.line + 2)
		} else {
			d.canvas = draw.canvas_make(def.width, def.height)
		}
		append(&cs.displays, d)
	}
}

@(private)
displays_free :: proc(cs: ^Control_Surface) {
	for d in cs.displays {
		draw.canvas_destroy(&d.canvas)
		delete(d.text)
		delete(d.sent_text)
		free(d)
	}
	delete(cs.displays)
}

@(private)
c_on_display_frame :: proc "c" (s: ^abi.Surface, index: u32) {
	cs := from(s)
	context = enter(cs)
	defer leave(cs)
	d := display(cs, int(index))
	if d == nil || !cs.active do return
	if d.def.format == .Text {
		text_frame(d)
	} else {
		if d.invalid && d.draw != nil do d.draw(d, &d.canvas)
		d.invalid = false
		if d.canvas.dirty.w > 0 || d.full || d.resend {
			if d.full do draw.dirty_all(&d.canvas)
			ok := d.send(d) if d.send != nil else display_send(d)
			d.frames += 1 if ok else 0
			d.full = !ok // (not sent: all of it when it can be)
			mirror(d) // mirrored either way: a virtual controller shows it without the device
			draw.dirty_clear(&d.canvas)
		}
	}
	flush(cs)
}

// Sends the lines that changed, and mirrors them.
@(private)
text_frame :: proc(d: ^Display) {
	if !d.invalid && !d.full do return
	d.invalid = false
	w := d.def.width
	msg := make([dynamic]u8, context.temp_allocator)
	sent := false
	for row in 0 ..< d.def.height {
		line := d.text[row * w:][:w]
		if !d.full && string(line) == string(d.sent_text[row * w:][:w]) do continue
		if d.text_line != nil {
			clear(&msg)
			d.text_line(d, row, string(line), &msg)
			if len(msg) > 0 && !send(d.cs, msg[:]) do continue
		}
		copy(d.sent_text[row * w:][:w], line)
		sent = true
	}
	if !sent && !d.full do return
	d.full = false
	d.frames += 1
	cv := &d.canvas
	draw.clear(cv, 0x10301a)
	for row in 0 ..< d.def.height do draw.text(cv, &draw.FONT_5X7, 1, 1 + row * draw.FONT_5X7.line, string(d.text[row * w:][:w]), 0xb8ffc8)
	mirror(d)
	draw.dirty_clear(cv)
}

// The kit's way to send a frame: the prefix, then the whole canvas in the
// display's format, over its device, in `chunk`-sized writes.
display_send :: proc(d: ^Display) -> bool {
	if d.def.device < 0 do return true // nowhere to send it: mirrored only
	formats := [abi.Pixel_Format]draw.Format{.Rgb565 = .Rgb565, .Bgr565 = .Bgr565, .Rgb888 = .Rgb888, .Mono = .Mono, .Mono_Pages = .Mono_Pages, .Text = .Mono}
	frame := make([dynamic]u8, context.temp_allocator)
	append(&frame, ..d.prefix)
	draw.encode(&d.canvas, formats[d.def.format], &frame)
	return device_write(d.cs, d.def.device, frame[:], d.chunk)
}

// Sends a frame as Push 2's display wants it (a 960 x 160 display): the
// header, then the masked lines in 16 KiB writes (draw.encode_push2).
display_send_push2 :: proc(d: ^Display) -> bool {
	frame := make([dynamic]u8, context.temp_allocator)
	draw.encode_push2(&d.canvas, &frame)
	if !device_write(d.cs, d.def.device, frame[:16]) do return false
	return device_write(d.cs, d.def.device, frame[16:], 16384)
}

// Writes to one of the surface's devices (by its index in the spec), in
// writes of at most `chunk` bytes (0: one). False if any failed.
device_write :: proc(cs: ^Control_Surface, device: int, bytes: []u8, chunk := 0) -> bool {
	if cs.host.device_write == nil || device < 0 || len(bytes) == 0 do return false
	n := chunk if chunk > 0 else len(bytes)
	for i := 0; i < len(bytes); i += n {
		part := bytes[i:min(i + n, len(bytes))]
		if !cs.host.device_write(cs.host, u32(device), raw_data(part), u32(len(part))) do return false
	}
	return true
}

@(private)
mirror :: proc(d: ^Display) {
	if d.cs.host.display_mirror == nil do return
	px := make([dynamic]u8, context.temp_allocator)
	draw.rgba(&d.canvas, &px)
	d.cs.host.display_mirror(d.cs.host, u32(d.index), raw_data(px), u32(d.canvas.width), u32(d.canvas.height))
}

@(private)
c_on_device :: proc "c" (s: ^abi.Surface, device: u32, open: bool) {
	cs := from(s)
	context = enter(cs)
	defer leave(cs)
	if open {
		// It knows nothing: send it all.
		for d in cs.displays do if d.def.device == int(device) {
			d.full = true
			d.invalid = true
		}
	}
	if cs.spec.on_device != nil do cs.spec.on_device(cs, int(device), open)
	flush(cs)
}

@(private)
c_on_device_read :: proc "c" (s: ^abi.Surface, device: u32, bytes: [^]u8, size: u32) {
	cs := from(s)
	context = enter(cs)
	defer leave(cs)
	if cs.spec.on_device_read != nil do cs.spec.on_device_read(cs, int(device), bytes[:size])
	flush(cs)
}

