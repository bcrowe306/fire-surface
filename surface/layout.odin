package surface

import "base:runtime"
import "core:fmt"

import abi "../abi"

/*
fsurf.layout (include/fsurf_layout.h): the kit describes the surface's
hardware to the host, for its tools. A virtual controller draws the
controls where `place` put them (in the device's units, millimetres as a
rule, from the top left; the spec's `width` and `height` are the whole
device), lit as the surface lights them (a skin value's display colour,
`skin_set_display`, when it has one); a MIDI monitor names each message's
control and the component that has it.

	kit.place(play, 10, 80, 12, 8)
	kit.place_matrix(pads, 40, 10, 18, 18, gap = 2)
*/

// Places a control on the device: its top left and size.
place :: proc(c: ^Control, x, y, w, h: f32) {
	c.x, c.y, c.w, c.h = x, y, w, h
}

// Places a matrix's controls: the top left of the first, each cell's size,
// and the gap between cells.
place_matrix :: proc(m: ^Matrix, x, y, w, h: f32, gap: f32 = 0) {
	for c in m.controls do place(c, x + f32(c.col) * (w + gap), y + f32(c.row) * (h + gap), w, h)
}

@(private)
layout_init :: proc(cs: ^Control_Surface) {
	cs.layout = {
		struct_size = size_of(abi.Layout), width = cs.spec.width, height = cs.spec.height,
		count = layout_count, get = layout_get, find = layout_find, owner = layout_owner, state = layout_state,
	}
}

@(private)
c_get_extension :: proc "c" (s: ^abi.Surface, id: cstring) -> rawptr {
	cs := from(s)
	return &cs.layout if id == abi.LAYOUT_ID else nil
}

@(private)
layout_count :: proc "c" (s: ^abi.Surface) -> u32 { return u32(len(from(s).controls) + len(from(s).displays)) }

@(private)
layout_get :: proc "c" (s: ^abi.Surface, i: u32, out: ^abi.Layout_Control) -> bool {
	cs := from(s)
	if out == nil do return false
	context = runtime.default_context()
	if int(i) >= len(cs.controls) {
		k := int(i) - len(cs.controls)
		if k >= len(cs.displays) do return false
		d := cs.displays[k]
		name := fmt.bprintf(cs.layout_name[:len(cs.layout_name) - 1], "%s", d.def.name)
		cs.layout_name[len(name)] = 0
		o := abi.Layout_Control{
			struct_size = out.struct_size if out.struct_size > 0 else size_of(abi.Layout_Control),
			name = cstring(&cs.layout_name[0]), kind = .Display, x = d.x, y = d.y, w = d.w, h = d.h, number = u8(k),
		}
		size := min(int(out.struct_size) if out.struct_size > 0 else size_of(abi.Layout_Control), size_of(abi.Layout_Control))
		runtime.mem_copy_non_overlapping(out, &o, size)
		return true
	}
	c := cs.controls[i]
	name := c.name
	if c.grid != nil do name = fmt.bprintf(cs.layout_name[:len(cs.layout_name) - 1], "%s %d,%d", c.name, c.row, c.col)
	else do name = fmt.bprintf(cs.layout_name[:len(cs.layout_name) - 1], "%s", c.name)
	cs.layout_name[len(name)] = 0
	kinds := [Control_Kind]abi.Layout_Kind{.Button = .Button, .Pad = .Pad, .Encoder = .Encoder, .Fader = .Fader, .Sysex = .Other}
	encodings := [Encoding]abi.Layout_Encoding{.Absolute = .Absolute, .Twos_Complement = .Twos_Complement, .Signed_Bit = .Signed_Bit, .Binary_Offset = .Binary_Offset}
	o := abi.Layout_Control{
		struct_size = out.struct_size if out.struct_size > 0 else size_of(abi.Layout_Control),
		name = cstring(&cs.layout_name[0]), kind = kinds[c.kind],
		x = c.x, y = c.y, w = c.w, h = c.h, port = u32(c.binding.port),
		channel = c.binding.channel, number = c.binding.number, encoding = encodings[c.encoding],
	}
	switch c.binding.kind {
	case .None:
	case .Note: o.message = {.Note_On}
	case .CC: o.message = {.Control}
	case .CC14: o.message = {.Control}; o.flags += {.Fourteen_Bit}
	case .Pitch_Bend: o.message = {.Pitch_Bend}
	case .Channel_Pressure: o.message = {.Channel_Pressure}
	case .Program: o.message = {.Program}
	case .Sysex: o.message = {.Sysex}
	}
	if c.toggle do o.flags += {.Toggle}
	size := min(int(out.struct_size) if out.struct_size > 0 else size_of(abi.Layout_Control), size_of(abi.Layout_Control))
	runtime.mem_copy_non_overlapping(out, &o, size)
	return true
}

@(private)
layout_find :: proc "c" (s: ^abi.Surface, output: bool, port: u32, b: [^]u8, size: u32) -> i32 {
	cs := from(s)
	context = runtime.default_context()
	role := -1
	for p, i in cs.ports do if (p.output if output else p.input) == port { role = i; break }
	m, ok := parse(b[:size])
	if role < 0 || !ok do return -1
	matches :: proc(bd: Binding, role: int, m: Message) -> bool {
		if bd.kind == .None || bd.port != role do return false
		#partial switch m.kind {
		case .Note_On, .Note_Off, .Poly_Pressure: return bd.kind == .Note && bd.channel == m.channel && bd.number == m.data1
		case .Control:
			if bd.channel != m.channel do return false
			return (bd.kind == .CC && bd.number == m.data1) || (bd.kind == .CC14 && (bd.number == m.data1 || bd.number + 32 == m.data1))
		case .Pitch_Bend: return bd.kind == .Pitch_Bend && bd.channel == m.channel
		case .Channel_Pressure: return bd.kind == .Channel_Pressure && bd.channel == m.channel
		case .Program: return bd.kind == .Program && bd.channel == m.channel
		case .Sysex: return bd.kind == .Sysex && has_prefix(m.bytes, bd.sysex)
		}
		return false
	}
	for c, i in cs.controls {
		if output {
			if matches(out_binding(c), role, m) do return i32(i)
		} else if matches(c.binding, role, m) || matches(c.touch, role, m) {
			return i32(i)
		}
	}
	return -1
}

@(private)
layout_owner :: proc "c" (s: ^abi.Surface, i: u32) -> cstring {
	cs := from(s)
	if int(i) >= len(cs.controls) do return nil // (displays have none)
	context = runtime.default_context()
	o := top_owner(cs.controls[i])
	if o == nil do return nil
	name := o.layer.component.name
	n := min(len(name), len(cs.layout_owner) - 1)
	copy(cs.layout_owner[:n], name)
	cs.layout_owner[n] = 0
	return cstring(&cs.layout_owner[0])
}

@(private)
layout_state :: proc "c" (s: ^abi.Surface, i: u32, out: ^abi.Layout_State) -> bool {
	cs := from(s)
	if out == nil || int(i) >= len(cs.controls) + len(cs.displays) do return false
	if int(i) >= len(cs.controls) {
		st := abi.Layout_State{struct_size = size_of(abi.Layout_State), channel = -1}
		size := min(int(out.struct_size) if out.struct_size > 0 else size_of(abi.Layout_State), size_of(abi.Layout_State))
		runtime.mem_copy_non_overlapping(out, &st, size)
		return true
	}
	c := cs.controls[i]
	st := abi.Layout_State{struct_size = size_of(abi.Layout_State), channel = -1, pressed = c.pressed, position = c.value}
	if c.has_position do st.position = c.position
	if c.has_last {
		st.channel = i32(c.last[0] & 0x0F)
		st.value = u32(c.last[c.last_len - 1]) if c.last_len >= 2 else 0
		if c.last[0] & 0xF0 == 0xE0 do st.value = u32(c.last[2]) // pitch bend: its MSB
	}
	if c.has_rgb {
		st.has_rgb = true
		st.rgb = c.rgb
	}
	size := min(int(out.struct_size) if out.struct_size > 0 else size_of(abi.Layout_State), size_of(abi.Layout_State))
	runtime.mem_copy_non_overlapping(out, &st, size)
	return true
}
