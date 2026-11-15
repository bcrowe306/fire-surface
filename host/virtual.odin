package fsurf_host

import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:strings"

import abi "../abi"
import "../draw"

/*
A virtual controller: an on-screen stand-in for a surface's device, from
its fsurf.layout extension. The app draws the controls where they are
(`Virtual.controls`, `virtual_state`, or the whole device as SVG with
`virtual_svg`), and turns the mouse into the MIDI the device would send
(`virtual_press`, `virtual_release`, `virtual_turn`, `virtual_move`), which
it gives to `route` on the surface's input as if it came from the device.

	v, ok := host.virtual_open(s)
	m := host.virtual_press(&v, host.virtual_find(&v, "Play"))
	for i in 0 ..< m.count do host.route(&h, m.port, m.bytes[i][:m.sizes[i]], now, &out)

Surface thread.
*/

// A surface's controls, as its layout describes them.
Virtual :: struct {
	s:             ^Instance,
	layout:        ^abi.Layout,
	width, height: f32, // the device's (or the controls' extent)
	controls:      [dynamic]Virtual_Control,
}

// One control: its description (the name copied).
Virtual_Control :: struct {
	using desc: abi.Layout_Control,
	label:      string,
}

// What a mouse action sends: up to two messages, on the surface's input.
Virtual_Messages :: struct {
	port:  u32,
	bytes: [2][3]u8,
	sizes: [2]int,
	count: int,
}

// Reads a surface's layout. False when it has none (no fsurf.layout).
// Free with `virtual_close`.
virtual_open :: proc(s: ^Instance, allocator := context.allocator) -> (v: Virtual, ok: bool) {
	l := (^abi.Layout)(instance_extension(s, abi.LAYOUT_ID))
	if l == nil || l.struct_size < size_of(abi.Layout) || l.count == nil || l.get == nil || l.state == nil do return {}, false
	v = {s = s, layout = l, width = l.width, height = l.height}
	v.controls = make([dynamic]Virtual_Control, allocator)
	n := l.count(s.surface)
	for i in 0 ..< n {
		c := Virtual_Control{}
		c.struct_size = size_of(abi.Layout_Control)
		if !l.get(s.surface, i, &c.desc) do break
		c.label = strings.clone(string(c.name), allocator) if c.name != nil else ""
		c.name = nil
		append(&v.controls, c)
	}
	if v.width <= 0 || v.height <= 0 {
		for c in v.controls do if c.w > 0 && c.h > 0 {
			v.width = max(v.width, c.x + c.w + 4)
			v.height = max(v.height, c.y + c.h + 4)
		}
	}
	return v, true
}

// Frees what `virtual_open` made.
virtual_close :: proc(v: ^Virtual) {
	for c in v.controls do delete(c.label, v.controls.allocator)
	delete(v.controls)
	v^ = {}
}

// A control's index by its name, or -1.
virtual_find :: proc(v: ^Virtual, name: string) -> int {
	for c, i in v.controls do if c.label == name do return i
	return -1
}

// What a control shows now.
virtual_state :: proc(v: ^Virtual, i: int) -> abi.Layout_State {
	st := abi.Layout_State{struct_size = size_of(abi.Layout_State), channel = -1}
	if i >= 0 && i < len(v.controls) do v.layout.state(v.s.surface, u32(i), &st)
	return st
}

@(private)
virtual_port :: proc(v: ^Virtual, c: Virtual_Control) -> u32 {
	if int(c.port) < len(v.s.ports) do return v.s.ports[c.port].input
	return abi.NO_PORT
}

@(private)
one :: proc(v: ^Virtual, c: Virtual_Control, b: [3]u8, n: int) -> Virtual_Messages {
	return {port = virtual_port(v, c), bytes = {b, {}}, sizes = {n, 0}, count = 1}
}

// A button or pad pressed (a note on, or a CC of 127).
virtual_press :: proc(v: ^Virtual, i: int, velocity: u8 = 127) -> Virtual_Messages {
	if i < 0 || i >= len(v.controls) do return {}
	c := v.controls[i]
	switch {
	case .Note_On in c.message: return one(v, c, {0x90 | c.channel, c.number, max(velocity, 1)}, 3)
	case .Control in c.message: return one(v, c, {0xB0 | c.channel, c.number, 127}, 3)
	}
	return {}
}

// A button or pad released (a note off, or a CC of 0).
virtual_release :: proc(v: ^Virtual, i: int) -> Virtual_Messages {
	if i < 0 || i >= len(v.controls) do return {}
	c := v.controls[i]
	switch {
	case .Note_On in c.message: return one(v, c, {0x80 | c.channel, c.number, 0}, 3)
	case .Control in c.message: return one(v, c, {0xB0 | c.channel, c.number, 0}, 3)
	}
	return {}
}

// An encoder turned by `steps` (up positive), in its encoding.
virtual_turn :: proc(v: ^Virtual, i: int, steps: int) -> Virtual_Messages {
	if i < 0 || i >= len(v.controls) || steps == 0 do return {}
	c := v.controls[i]
	if .Control not_in c.message do return {}
	d := clamp(steps, -63, 63)
	value: int
	switch c.encoding {
	case .Absolute: value = clamp(int(math.round(virtual_state(v, i).position * 127)) + steps, 0, 127)
	case .Twos_Complement: value = d if d > 0 else 128 + d
	case .Signed_Bit: value = d if d > 0 else 64 - d
	case .Binary_Offset: value = 64 + d
	}
	return one(v, c, {0xB0 | c.channel, c.number, u8(value)}, 3)
}

// A fader (or absolute encoder) moved to `value` (0-1), at its resolution.
virtual_move :: proc(v: ^Virtual, i: int, value: f32) -> Virtual_Messages {
	if i < 0 || i >= len(v.controls) do return {}
	c := v.controls[i]
	x := clamp(value, 0, 1)
	switch {
	case .Pitch_Bend in c.message:
		n := u16(math.round(x * 16383))
		return one(v, c, {0xE0 | c.channel, u8(n & 0x7F), u8(n >> 7)}, 3)
	case .Channel_Pressure in c.message:
		return one(v, c, {0xD0 | c.channel, u8(math.round(x * 127)), 0}, 2)
	case .Control in c.message:
		if .Fourteen_Bit in c.flags {
			n := u16(math.round(x * 16383))
			m := one(v, c, {0xB0 | c.channel, c.number, u8(n >> 7)}, 3)
			m.bytes[1] = {0xB0 | c.channel, c.number + 32, u8(n & 0x7F)}
			m.sizes[1] = 3
			m.count = 2
			return m
		}
		return one(v, c, {0xB0 | c.channel, c.number, u8(math.round(x * 127))}, 3)
	}
	return {}
}

// The device as an SVG picture (in the temp allocator by default): its
// controls where they are, lit as the surface lit them (their colour when it
// says, else brighter with a higher value), held ones outlined, faders and
// encoders at their position.
virtual_svg :: proc(v: ^Virtual, scale: f32 = 4, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	w, h := max(v.width, 10), max(v.height, 10)
	fmt.sbprintf(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %.1f %.1f" width="%.0f" height="%.0f" font-family="sans-serif">`, w, h, w * scale, h * scale)
	fmt.sbprintf(&b, `<rect x="0" y="0" width="%.1f" height="%.1f" rx="3" fill="#1b1c20"/>`, w, h)
	fmt.sbprintf(&b, `<text x="2" y="4" font-size="2.6" fill="#888">%s</text>`, xml(string(v.s.descriptor.name)))
	for c, i in v.controls {
		if c.w <= 0 || c.h <= 0 || c.kind == .Other do continue
		st := virtual_state(v, i)
		fill := lit(st)
		stroke := "#ffffff" if st.pressed else "#4a4b52"
		switch c.kind {
		case .Button, .Pad, .Other:
			fmt.sbprintf(&b, `<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f" fill="%s" stroke="%s" stroke-width="0.4"/>`,
				c.x, c.y, c.w, c.h, min(c.w, c.h) * (0.15 if c.kind == .Pad else 0.25), fill, stroke)
		case .Encoder:
			r := min(c.w, c.h) / 2
			cx, cy := c.x + c.w / 2, c.y + c.h / 2
			fmt.sbprintf(&b, `<circle cx="%.2f" cy="%.2f" r="%.2f" fill="#2c2d33" stroke="%s" stroke-width="0.4"/>`, cx, cy, r, stroke)
			a := (-135 + 270 * f64(clamp(st.position, 0, 1)) - 90) * math.PI / 180
			fmt.sbprintf(&b, `<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="%s" stroke-width="0.8" stroke-linecap="round"/>`,
				cx, cy, cx + f32(math.cos(a)) * r * 0.85, cy + f32(math.sin(a)) * r * 0.85, fill if fill != DARK else "#9a9ba3")
		case .Display:
			virtual_svg_display(v, &b, c)
		case .Fader:
			fmt.sbprintf(&b, `<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="0.6" fill="#141418" stroke="%s" stroke-width="0.4"/>`, c.x, c.y, c.w, c.h, stroke)
			p := clamp(st.position, 0, 1)
			if c.h >= c.w {
				th := min(c.h * 0.15, c.w)
				fmt.sbprintf(&b, `<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="0.4" fill="#c9cad1"/>`, c.x, c.y + (c.h - th) * (1 - p), c.w, th)
			} else {
				tw := min(c.w * 0.15, c.h)
				fmt.sbprintf(&b, `<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="0.4" fill="#c9cad1"/>`, c.x + (c.w - tw) * p, c.y, tw, c.h)
			}
		}
		// Pads (in grids, as a rule) are labelled inside; the rest below.
		if c.kind == .Display do continue // (no label)
		size := clamp(min(c.w, c.h) * 0.22, 1.2, 2.4)
		ty := c.y + c.h - size * 0.6 if c.kind == .Pad else c.y + c.h + size + 0.4
		ink := "#1b1c20" if c.kind == .Pad && bright(fill) else "#9a9ba3"
		fmt.sbprintf(&b, `<text x="%.2f" y="%.2f" font-size="%.2f" fill="%s" text-anchor="middle">%s</text>`, c.x + c.w / 2, ty, size, ink, xml(c.label))
	}
	strings.write_string(&b, "</svg>\n")
	return strings.to_string(b)
}

@(private)
DARK :: "#2a2b30"

@(private)
lit :: proc(st: abi.Layout_State) -> string {
	if st.has_rgb do return fmt.tprintf("#%06X", st.rgb & 0xFFFFFF)
	if st.value == 0 do return DARK
	k := f32(st.value) / 127
	lerp :: proc(a, b: f32, k: f32) -> u8 { return u8(a + (b - a) * k) }
	return fmt.tprintf("#%02X%02X%02X", lerp(0x2a, 0xff, k), lerp(0x2b, 0xb0, k), lerp(0x30, 0x30, k))
}

// Whether a "#RRGGBB" colour is light (dark text on it).
@(private)
bright :: proc(hex: string) -> bool {
	if len(hex) != 7 do return false
	v := [3]f32{}
	for i in 0 ..< 3 {
		n: u8
		for c in transmute([]u8)hex[1 + i * 2:][:2] do n = n * 16 + (c - '0' if c <= '9' else c - 'A' + 10)
		v[i] = f32(n) / 255
	}
	return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2] > 0.5
}

@(private)
xml :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	out, _ = strings.replace_all(out, "<", "&lt;", context.temp_allocator)
	out, _ = strings.replace_all(out, ">", "&gt;", context.temp_allocator)
	return out
}

// What a display shows (RGBA), from the surface's display_mirror: nil
// before its first frame. A display control's `number` is its index.
virtual_display :: proc(v: ^Virtual, i: int) -> ^Mirror {
	if i < 0 || i >= len(v.controls) || v.controls[i].kind != .Display do return nil
	return instance_display(v.s, int(v.controls[i].number))
}

@(private)
virtual_svg_display :: proc(v: ^Virtual, b: ^strings.Builder, c: Virtual_Control) {
	fmt.sbprintf(b, `<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="#000"/>`, c.x, c.y, c.w, c.h)
	m := instance_display(v.s, int(c.number))
	if m == nil do return
	file := make([dynamic]u8, context.temp_allocator)
	draw.png_rgba(m.rgba[:], m.width, m.height, &file)
	data, _ := base64.encode(file[:], allocator = context.temp_allocator)
	fmt.sbprintf(b, `<image x="%.2f" y="%.2f" width="%.2f" height="%.2f" preserveAspectRatio="none" style="image-rendering:pixelated" href="data:image/png;base64,%s"/>`, c.x, c.y, c.w, c.h, data)
}
