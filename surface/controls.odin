package surface

// ── Bindings ──────────────────────────────────────────────────────────

// What a control sends: its MIDI binding.
Binding_Kind :: enum u8 {
	None,
	Note,             // note on/off (and its polyphonic pressure)
	CC,               // a 7-bit control change
	CC14,             // a 14-bit pair: `number` (MSB) and `number + 32` (LSB)
	Pitch_Bend,
	Channel_Pressure,
	Program,
	Sysex,            // a SysEx beginning with `sysex`
}

// A control's MIDI binding: its kind, channel (0-15), number, and the port
// (index in the spec's ports).
Binding :: struct {
	kind:    Binding_Kind,
	channel: u8,
	number:  u8,
	port:    int,
	sysex:   []u8,
}

// A note binding.
bind_note :: proc(number: u8, channel: u8 = 0, port := 0) -> Binding { return {.Note, channel, number, port, nil} }
// A CC binding.
bind_cc :: proc(number: u8, channel: u8 = 0, port := 0) -> Binding { return {.CC, channel, number, port, nil} }
// A 14-bit CC binding (MSB `number`, LSB `number + 32`).
bind_cc14 :: proc(number: u8, channel: u8 = 0, port := 0) -> Binding { return {.CC14, channel, number, port, nil} }
// A pitch-bend binding.
bind_pitch_bend :: proc(channel: u8 = 0, port := 0) -> Binding { return {.Pitch_Bend, channel, 0, port, nil} }
// A channel-pressure binding.
bind_channel_pressure :: proc(channel: u8 = 0, port := 0) -> Binding { return {.Channel_Pressure, channel, 0, port, nil} }
// A program-change binding (any program on the channel).
bind_program :: proc(channel: u8 = 0, port := 0) -> Binding { return {.Program, channel, 0, port, nil} }
// A SysEx binding: messages beginning with `prefix` (F0 ...).
bind_sysex :: proc(prefix: []u8, port := 0) -> Binding { return {.Sysex, 0, 0, port, prefix} }

@(private)
Lookup_Part :: enum u8 { Main, Touch, Lsb }

@(private)
Lookup :: struct {
	control: ^Control,
	part:    Lookup_Part,
}

@(private)
key_of :: proc(port: int, kind: Binding_Kind, channel, number: u8) -> u64 {
	k := kind
	if k == .CC14 do k = .CC
	return u64(port) << 32 | u64(k) << 16 | u64(channel & 0x0F) << 8 | u64(number)
}

// ── Controls ──────────────────────────────────────────────────────────

// What a control is.
Control_Kind :: enum u8 {
	Button,     // pressed and released (a note or a CC): momentary or toggle; hold, double press
	Pad,        // velocity, pressure
	Encoder,    // absolute, or relative steps
	Fader,      // a position, 7- or 14-bit (also sliders, pitch and mod wheels, touch strips)
	Sysex,      // a SysEx message
}

// How a relative encoder sends its steps.
Encoding :: enum u8 {
	Absolute,        // a position, 0-127
	Twos_Complement, // 1..63 up, 127..65 down (127 = -1)
	Signed_Bit,      // 1..63 up, 65..127 down (65 = -1): bit 6 is the sign
	Binary_Offset,   // 64 = none, 65 = +1, 63 = -1
}

// Where a control's messages go while its owner has it (the claim table).
Route_Mode :: enum u8 {
	Claim,   // to the surface only (the default)
	Observe, // to the host and the surface
	Remap,   // to the host as `remap_note` on `remap_channel`, and a copy to the surface
	Pass,    // to the host only
}

// One piece of hardware. Made by `button`, `pad`, `encoder`, `fader`...;
// the surface frees it. Fields are read-only but the settings.
Control :: struct {
	cs:       ^Control_Surface,
	name:     string,
	kind:     Control_Kind,
	binding:  Binding,
	touch:    Binding, // a touch sensor's note (encoders, faders, strips); kind None = none
	feedback: Binding, // where its light/ring/motor is sent; kind None = its binding
	grid:   ^Matrix,
	row, col: int,

	// Settings.
	toggle:       bool, // Button: a press flips it on and off
	hold_ms:      u32, // Button: Hold after this long (0 = 500)
	double_ms:    u32, // Button: Double_Press within this (0 = 300)
	encoding:     Encoding, // Encoder
	acceleration: f32, // Encoder: steps that come within 40 ms are multiplied by this (0 or 1 = none)
	pickup:       bool, // Fader: ignored until it reaches the value `set_value` gave (soft takeover)
	ring:         bool, // shows a value (an LED ring, a motor): components send it theirs with `set_position`

	// State.
	pressed:    bool,
	on:         bool, // a toggle's state
	touched:    bool,
	value:      f32, // a fader's or absolute encoder's position, 0-1
	raw:        int, // its last raw value (7 or 14 bits)
	picked:     bool, // Fader with pickup: it has reached its target
	target:     f32,
	press_ns:   u64,
	last_press_ns: u64,
	last_step_ns: u64,
	stepped:    bool, // last_step_ns is set
	pressed_once: bool, // last_press_ns is set
	msb:        u8, // CC14: the MSB waiting for its LSB
	hold_task:  u32,
	pressed_by: ^Component, // the release goes where the press went
	// A light held (`light_hold`): it shows `held` whatever its owners
	// send; what they sent meanwhile is kept, and shown on `light_release`.
	held_light: bool,
	wanted:     [3]u8,
	wanted_len: int,
	has_wanted: bool,

	// Ownership (layers.odin) and routing.
	owners:        [dynamic]Ownership,
	route:         Route_Mode,
	remap_note:    u8,
	remap_channel: u8, // 1-16, 0 = its own
	velocity_map:  ^[128]u8, // Remap: the host's velocities (nil = as played)

	// Its place on the device (`place`), for tools.
	x, y, w, h: f32,
	// What it shows, for tools: its ring or motor's position, its colour.
	position:     f32,
	has_position: bool,
	rgb:          u32,
	has_rgb:      bool,

	// Feedback sent, to send only changes.
	last:     [3]u8,
	last_len: int,
	has_last: bool,
}

// A grid of controls (pads, buttons), addressed by row and column (row 0
// at the top).
Matrix :: struct {
	name:       string,
	rows, cols: int,
	controls:   []^Control, // row-major
}

// The control at a row and column, or nil.
matrix_at :: proc(m: ^Matrix, row, col: int) -> ^Control {
	if row < 0 || col < 0 || row >= m.rows || col >= m.cols do return nil
	return m.controls[row * m.cols + col]
}

@(private)
control_add :: proc(cs: ^Control_Surface, name: string, kind: Control_Kind, b: Binding, touch := Binding{}) -> ^Control {
	c := new(Control)
	c^ = {cs = cs, name = name, kind = kind, binding = b, touch = touch, picked = true}
	c.owners = make([dynamic]Ownership)
	append(&cs.controls, c)
	switch b.kind {
	case .None:
	case .Sysex:
		c.binding.sysex = clone_bytes(b.sysex)
		append(&cs.sysex_controls, c)
	case .CC14:
		cs.lookup[key_of(b.port, .CC, b.channel, b.number)] = {c, .Main}
		cs.lookup[key_of(b.port, .CC, b.channel, b.number + 32)] = {c, .Lsb}
	case .Note, .CC, .Pitch_Bend, .Channel_Pressure, .Program:
		cs.lookup[key_of(b.port, b.kind, b.channel, b.number)] = {c, .Main}
	}
	if touch.kind != .None do cs.lookup[key_of(touch.port, touch.kind, touch.channel, touch.number)] = {c, .Touch}
	cs.rules_dirty = true
	return c
}

@(private)
control_free :: proc(c: ^Control) {
	if c.binding.kind == .Sysex do delete(c.binding.sysex)
	delete(c.owners)
	free(c)
}

// A button (a note or a CC: pressed above 0, released at 0).
button :: proc(cs: ^Control_Surface, name: string, b: Binding, toggle := false) -> ^Control {
	c := control_add(cs, name, .Button, b)
	c.toggle = toggle
	return c
}

// A velocity-sensitive pad (a note; its polyphonic pressure too).
pad :: proc(cs: ^Control_Surface, name: string, b: Binding) -> ^Control {
	return control_add(cs, name, .Pad, b)
}

// An encoder (a CC): absolute or relative.
encoder :: proc(cs: ^Control_Surface, name: string, b: Binding, encoding := Encoding.Twos_Complement) -> ^Control {
	c := control_add(cs, name, .Encoder, b)
	c.encoding = encoding
	return c
}

// An encoder that is touch-sensitive: its touch sends a note.
touch_encoder :: proc(cs: ^Control_Surface, name: string, b: Binding, touch: Binding, encoding := Encoding.Twos_Complement) -> ^Control {
	c := control_add(cs, name, .Encoder, b, touch)
	c.encoding = encoding
	return c
}

// A jog wheel: a relative encoder.
jog_wheel :: proc(cs: ^Control_Surface, name: string, b: Binding, encoding := Encoding.Twos_Complement) -> ^Control {
	return encoder(cs, name, b, encoding)
}

// A fader or slider (a CC, a 14-bit CC pair, or pitch bend), optionally
// touch-sensitive; with `pickup`, soft takeover.
fader :: proc(cs: ^Control_Surface, name: string, b: Binding, pickup := false, touch := Binding{}) -> ^Control {
	c := control_add(cs, name, .Fader, b, touch)
	c.pickup = pickup
	return c
}

// A touch strip: a position (pitch bend or a CC) and the note its touch sends.
touch_strip :: proc(cs: ^Control_Surface, name: string, b: Binding, touch: Binding) -> ^Control {
	return control_add(cs, name, .Fader, b, touch)
}

// A pitch wheel (pitch bend; centre 0.5).
pitch_wheel :: proc(cs: ^Control_Surface, name: string, channel: u8 = 0, port := 0) -> ^Control {
	return control_add(cs, name, .Fader, bind_pitch_bend(channel, port))
}

// A mod wheel (CC 1).
mod_wheel :: proc(cs: ^Control_Surface, name: string, channel: u8 = 0, port := 0) -> ^Control {
	return control_add(cs, name, .Fader, bind_cc(1, channel, port))
}

// A pedal: a switch (a button) or a continuous one (a fader).
pedal :: proc(cs: ^Control_Surface, name: string, b: Binding, continuous := false) -> ^Control {
	return control_add(cs, name, .Fader if continuous else .Button, b)
}

// A control that is a SysEx message by its leading bytes.
sysex_control :: proc(cs: ^Control_Surface, name: string, prefix: []u8, port := 0) -> ^Control {
	return control_add(cs, name, .Sysex, bind_sysex(prefix, port))
}

// A grid of pads (or buttons), `binding(row, col)` for each.
matrix_make :: proc(cs: ^Control_Surface, name: string, rows, cols: int, binding: proc(row, col: int) -> Binding, kind := Control_Kind.Pad) -> ^Matrix {
	m := new(Matrix)
	m^ = {name = name, rows = rows, cols = cols}
	m.controls = make([]^Control, rows * cols)
	for r in 0 ..< rows do for c in 0 ..< cols {
		ctl := control_add(cs, name, kind, binding(r, c))
		ctl.grid = m
		ctl.row = r
		ctl.col = c
		m.controls[r * cols + c] = ctl
	}
	append(&cs.matrices, m)
	return m
}

// Gives a fader (or absolute encoder) the value of what it controls: with
// pickup, it waits until the hardware reaches it.
set_value :: proc(c: ^Control, v: f32) {
	c.target = clamp(v, 0, 1)
	if c.pickup do c.picked = abs(c.value - c.target) < 1.0 / 127
}

// ── Events ────────────────────────────────────────────────────────────

// What happened to a control.
Event_Kind :: enum u8 {
	Press,        // a button or pad (velocity), a toggle (value: 1 on, 0 off)
	Release,
	Hold,         // held for its hold_ms
	Double_Press, // pressed again within its double_ms (after its Press)
	Value,        // a position: value 0-1, raw 7 or 14 bits
	Delta,        // a relative encoder's steps
	Pressure,     // a pad's pressure: value 0-1
	Touch,
	Untouch,
	Sysex,        // bytes
}

// An event, for the component that owns the control.
Event :: struct {
	kind:     Event_Kind,
	control:  ^Control,
	slot:     string, // the owner's name for it
	row, col: int, // a matrix's
	value:    f32,
	raw:      int,
	delta:    int,
	velocity: u8,
	bytes:    []u8,
	time_ns:  u64,
}

@(private)
dispatch :: proc(cs: ^Control_Surface, port: int, m: Message, time_ns: u64) {
	if m.kind == .Sysex {
		best: ^Control
		for c in cs.sysex_controls do if c.binding.port == port && has_prefix(m.bytes, c.binding.sysex) {
			if best == nil || len(c.binding.sysex) > len(best.binding.sysex) do best = c
		}
		if best != nil do deliver(best, {kind = .Sysex, bytes = m.bytes, time_ns = time_ns})
		return
	}
	kind: Binding_Kind
	number := m.data1
	#partial switch m.kind {
	case .Note_On, .Note_Off, .Poly_Pressure: kind = .Note
	case .Control: kind = .CC
	case .Pitch_Bend: kind = .Pitch_Bend; number = 0
	case .Channel_Pressure: kind = .Channel_Pressure; number = 0
	case .Program: kind = .Program; number = 0
	case: return
	}
	l, ok := cs.lookup[key_of(port, kind, m.channel, number)]
	if !ok do return
	control_input(l.control, l.part, m, time_ns)
}

@(private)
control_input :: proc(c: ^Control, part: Lookup_Part, m: Message, t: u64) {
	if part == .Touch {
		#partial switch m.kind {
		case .Note_On: c.touched = true; deliver(c, {kind = .Touch, time_ns = t})
		case .Note_Off: c.touched = false; deliver(c, {kind = .Untouch, time_ns = t})
		case .Control:
			c.touched = m.data2 > 0
			deliver(c, {kind = .Touch if c.touched else .Untouch, time_ns = t})
		}
		return
	}
	switch c.kind {
	case .Button, .Pad:
		down, up: bool
		#partial switch m.kind {
		case .Note_On: down = true
		case .Note_Off: up = true
		case .Control: down = m.data2 > 0; up = !down
		case .Poly_Pressure:
			deliver(c, {kind = .Pressure, value = f32(m.data2) / 127, raw = int(m.data2), time_ns = t})
			return
		case .Channel_Pressure:
			deliver(c, {kind = .Pressure, value = f32(m.data1) / 127, raw = int(m.data1), time_ns = t})
			return
		case: return
		}
		if down {
			if c.pressed do return // a repeat: not a new press
			c.pressed = true
			had := c.pressed_once
			c.last_press_ns = c.press_ns
			c.press_ns = t
			c.pressed_once = true
			vel := m.data2 if m.kind != .Control else 127
			e := Event{kind = .Press, velocity = vel, value = f32(vel) / 127, raw = int(vel), time_ns = t}
			if c.toggle {
				c.on = !c.on
				e.value = 1 if c.on else 0
			}
			owner := deliver(c, e)
			c.pressed_by = owner
			if c.kind == .Button {
				double := u64(c.double_ms if c.double_ms > 0 else 300) * 1_000_000
				if had && t - c.last_press_ns <= double do deliver(c, {kind = .Double_Press, time_ns = t})
				hold := c.hold_ms if c.hold_ms > 0 else 500
				task_cancel(c.cs, c.hold_task)
				c.hold_task = task_after(c.cs, hold, proc(data: rawptr) {
					c := (^Control)(data)
					c.hold_task = 0
					if c.pressed do deliver(c, {kind = .Hold, time_ns = now_ns(c.cs)})
				}, c)
			}
		} else if up {
			if !c.pressed do return
			c.pressed = false
			task_cancel(c.cs, c.hold_task)
			c.hold_task = 0
			to := c.pressed_by
			c.pressed_by = nil
			e := Event{kind = .Release, value = 1 if c.on else 0, time_ns = t}
			if to != nil && to.active {
				deliver_to(c, to, e)
			} else {
				deliver(c, e)
			}
		}
	case .Encoder:
		if m.kind != .Control do return
		v := int(m.data2)
		if c.encoding == .Absolute {
			c.raw = v
			c.value = f32(v) / 127
			deliver(c, {kind = .Value, value = c.value, raw = v, time_ns = t})
			return
		}
		d: int
		switch c.encoding {
		case .Absolute:
		case .Twos_Complement: d = v if v < 64 else v - 128
		case .Signed_Bit: d = v if v < 64 else -(v - 64)
		case .Binary_Offset: d = v - 64
		}
		if d == 0 do return
		if c.acceleration > 1 && c.stepped && t - c.last_step_ns < 40_000_000 do d = int(f32(d) * c.acceleration)
		c.last_step_ns = t
		c.stepped = true
		deliver(c, {kind = .Delta, delta = d, raw = v, time_ns = t})
	case .Fader:
		raw: int
		bits: f32 = 127
		#partial switch m.kind {
		case .Pitch_Bend: raw = int(m.value14); bits = 16383
		case .Control:
			if c.binding.kind == .CC14 {
				if part == .Lsb {
					raw = int(join14(c.msb, m.data2))
				} else {
					c.msb = m.data2
					raw = int(join14(m.data2, 0))
				}
				bits = 16383
			} else {
				raw = int(m.data2)
			}
		case .Channel_Pressure: raw = int(m.data1)
		case .Note_On, .Note_Off: // a switch pedal bound as a note
			raw = int(m.data2) if m.kind == .Note_On else 0
		case: return
		}
		prev := c.value
		c.raw = raw
		c.value = f32(raw) / bits
		if !c.picked {
			eps := f32(1.0 / 127)
			crossed := (prev <= c.target && c.value >= c.target) || (prev >= c.target && c.value <= c.target)
			if !crossed && abs(c.value - c.target) > eps do return
			c.picked = true
		}
		deliver(c, {kind = .Value, value = c.value, raw = raw, time_ns = t})
	case .Sysex:
	}
}

// Gives the event to the control's owner (if it has one); returns it.
@(private)
deliver :: proc(c: ^Control, e: Event) -> ^Component {
	o := top_owner(c)
	if o == nil do return nil
	deliver_to(c, o.layer.component, e, o.slot)
	return o.layer.component
}

@(private)
deliver_to :: proc(c: ^Control, comp: ^Component, e: Event, slot := "") {
	ev := e
	ev.control = c
	ev.row = c.row
	ev.col = c.col
	ev.slot = slot
	if ev.slot == "" do for o in c.owners do if o.layer.component == comp { ev.slot = o.slot; break }
	if comp.on_event != nil do comp.on_event(comp, ev)
}

// ── Feedback ──────────────────────────────────────────────────────────

@(private)
out_binding :: proc(c: ^Control) -> Binding {
	return c.feedback if c.feedback.kind != .None else c.binding
}

// Sends a control's light (or ring, or motor) a 7-bit value: a note on or
// CC of that value on its feedback binding (on `channel` instead of its own
// when >= 0: many devices blink or pulse on other channels). Only when it
// changed.
light_value :: proc(c: ^Control, value: u8, channel := -1) {
	b := out_binding(c)
	ch := u8(channel) if channel >= 0 else b.channel
	msg: [3]u8
	n := 3
	#partial switch b.kind {
	case .Note: msg = note_on(ch, b.number, value)
	case .CC, .CC14: msg = control_change(ch, b.number, value)
	case .Pitch_Bend: msg = pitch_bend(ch, u16(value) << 7)
	case .Channel_Pressure: msg = {0xD0 | ch, value & 0x7F, 0}; n = 2
	case: return
	}
	send_feedback(c, msg, n)
}

// Sends a fader's motor or an encoder's ring a position (0-1), at its
// binding's resolution (14 bits for CC14 and pitch bend).
set_position :: proc(c: ^Control, v: f32) {
	b := out_binding(c)
	x := clamp(v, 0, 1)
	c.position = x
	c.has_position = true
	#partial switch b.kind {
	case .Pitch_Bend:
		send_feedback(c, pitch_bend(b.channel, u16(x * 16383 + 0.5)), 3)
	case .CC14:
		msb, lsb := split14(u16(x * 16383 + 0.5))
		send_feedback(c, control_change(b.channel, b.number, msb), 3)
		m := control_change(b.channel, b.number + 32, lsb)
		send(c.cs, m[:], b.port)
	case:
		light_value(c, u8(x * 127 + 0.5))
	}
}

@(private)
send_feedback :: proc(c: ^Control, msg: [3]u8, n: int) {
	c.wanted, c.wanted_len, c.has_wanted = msg, n, true
	if c.held_light do return
	feedback_out(c, msg, n)
}

@(private)
feedback_out :: proc(c: ^Control, msg: [3]u8, n: int) {
	if c.has_last && c.last_len == n && c.last == msg do return
	if !c.cs.active do return
	m := msg
	if send(c.cs, m[:n], out_binding(c).port) {
		c.last = msg
		c.last_len = n
		c.has_last = true
	}
}

// Lights a control with a skin's value by name ("Transport.Play.On").
light :: proc(c: ^Control, name: string) {
	v := skin_value(c.cs, name)
	c.has_rgb = v.has_rgb
	c.rgb = v.rgb
	if len(v.sysex) > 0 {
		c.has_last = false
		send(c.cs, v.sysex, out_binding(c).port)
		return
	}
	light_value(c, v.value, int(v.channel))
}

// Turns a control's light off (value 0).
light_off :: proc(c: ^Control) {
	b := out_binding(c)
	if b.kind == .None || b.kind == .Sysex || b.kind == .Program do return
	c.has_rgb = false
	light_value(c, 0)
}

// Forgets what was sent to a control, so the next light is sent even if
// the same.
light_reset :: proc(c: ^Control) { c.has_last = false }

// Holds control `c`'s light at `value` (a hint while a modifier is held:
// what a button does with it), whatever its owners send until
// `light_release`.
light_hold :: proc(c: ^Control, value: u8) {
	b := out_binding(c)
	msg: [3]u8
	#partial switch b.kind {
	case .Note: msg = note_on(b.channel, b.number, value)
	case .CC, .CC14: msg = control_change(b.channel, b.number, value)
	case: return
	}
	c.held_light = true
	feedback_out(c, msg, 3)
}

// Lets go of `light_hold`: the light shows what its owners last sent.
light_release :: proc(c: ^Control) {
	if !c.held_light do return
	c.held_light = false
	if c.has_wanted do feedback_out(c, c.wanted, c.wanted_len)
}
