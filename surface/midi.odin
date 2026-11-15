package surface

import abi "../abi"

// ── Messages ──────────────────────────────────────────────────────────

// One MIDI message, parsed. `kind` uses the claim table's kinds: a note on
// of velocity 0 is a Note_Off.
Message :: struct {
	kind:    abi.Message,
	channel: u8, // 0-15 (channel messages)
	data1:   u8, // a note, CC or program number; channel pressure's value
	data2:   u8, // velocity, CC value, pressure
	value14: u16, // pitch bend's 0-16383 (8192 = centre)
	bytes:   []u8, // as it came (a SysEx whole)
}

// Parses one whole message (a status byte first). False for what isn't one.
parse :: proc(bytes: []u8) -> (m: Message, ok: bool) {
	if len(bytes) == 0 || bytes[0] < 0x80 do return {}, false
	s := bytes[0]
	m.bytes = bytes
	m.channel = s & 0x0F
	need := 1
	switch s & 0xF0 {
	case 0x80: m.kind = .Note_Off; need = 3
	case 0x90: m.kind = .Note_On; need = 3
	case 0xA0: m.kind = .Poly_Pressure; need = 3
	case 0xB0: m.kind = .Control; need = 3
	case 0xC0: m.kind = .Program; need = 2
	case 0xD0: m.kind = .Channel_Pressure; need = 2
	case 0xE0: m.kind = .Pitch_Bend; need = 3
	case:
		m.channel = 0
		if s == 0xF0 {
			m.kind = .Sysex
			return m, true
		}
		m.kind = .System
		need = system_size(s)
	}
	if len(bytes) < need do return {}, false
	if need >= 2 do m.data1 = bytes[1] & 0x7F
	if need >= 3 do m.data2 = bytes[2] & 0x7F
	if m.kind == .Note_On && m.data2 == 0 do m.kind = .Note_Off
	if m.kind == .Pitch_Bend do m.value14 = u16(m.data1) | u16(m.data2) << 7
	return m, true
}

// The size of a system message by its status (F1: 2, F2: 3, F3: 2, the rest 1).
system_size :: proc(status: u8) -> int {
	switch status {
	case 0xF1, 0xF3: return 2
	case 0xF2: return 3
	}
	return 1
}

// The size of a channel message by its status byte (0 for others).
channel_size :: proc(status: u8) -> int {
	switch status & 0xF0 {
	case 0x80, 0x90, 0xA0, 0xB0, 0xE0: return 3
	case 0xC0, 0xD0: return 2
	}
	return 0
}

// A note on (channel 0-15).
note_on :: proc(channel, note, velocity: u8) -> [3]u8 { return {0x90 | channel & 0x0F, note & 0x7F, velocity & 0x7F} }
// A note off.
note_off :: proc(channel, note: u8, velocity: u8 = 0) -> [3]u8 { return {0x80 | channel & 0x0F, note & 0x7F, velocity & 0x7F} }
// A control change.
control_change :: proc(channel, number, value: u8) -> [3]u8 { return {0xB0 | channel & 0x0F, number & 0x7F, value & 0x7F} }
// A program change.
program_change :: proc(channel, program: u8) -> [2]u8 { return {0xC0 | channel & 0x0F, program & 0x7F} }
// Channel pressure.
channel_pressure :: proc(channel, value: u8) -> [2]u8 { return {0xD0 | channel & 0x0F, value & 0x7F} }
// Polyphonic pressure.
poly_pressure :: proc(channel, note, value: u8) -> [3]u8 { return {0xA0 | channel & 0x0F, note & 0x7F, value & 0x7F} }
// Pitch bend, 0-16383 (8192 = centre).
pitch_bend :: proc(channel: u8, value: u16) -> [3]u8 {
	v := min(value, 16383)
	return {0xE0 | channel & 0x0F, u8(v & 0x7F), u8(v >> 7)}
}

// ── Running status ────────────────────────────────────────────────────

// Turns a byte stream (with running status, real-time bytes in the
// middle, SysEx in pieces) into whole messages. The app's MIDI layer
// usually does this; a surface reading a raw stream (a serial port, a
// device's bulk endpoint) can use it.
Parser :: struct {
	status:  u8,
	data:    [2]u8,
	have:    int,
	sysex:   [dynamic]u8,
	in_sysex: bool,
}

// Frees the parser's SysEx buffer.
parser_destroy :: proc(p: ^Parser) { delete(p.sysex) }

// Feeds bytes; `emit` is called with each whole message (valid during the
// call).
parser_feed :: proc(p: ^Parser, bytes: []u8, emit: proc(user: rawptr, msg: []u8), user: rawptr) {
	for b in bytes {
		switch {
		case b >= 0xF8: // real-time: anywhere, even inside a SysEx
			one := [1]u8{b}
			emit(user, one[:])
		case b == 0xF0:
			clear(&p.sysex)
			append(&p.sysex, b)
			p.in_sysex = true
			p.status = 0
		case b == 0xF7:
			if p.in_sysex {
				append(&p.sysex, b)
				emit(user, p.sysex[:])
				p.in_sysex = false
			}
		case b >= 0x80:
			p.in_sysex = false
			p.have = 0
			if b >= 0xF0 { // system common: cancels running status
				p.status = 0
				if system_size(b) == 1 {
					one := [1]u8{b}
					emit(user, one[:])
				} else {
					p.status = b
				}
			} else {
				p.status = b
			}
		case p.in_sysex:
			append(&p.sysex, b)
		case p.status != 0:
			p.data[p.have] = b
			p.have += 1
			size := channel_size(p.status) if p.status < 0xF0 else system_size(p.status)
			if p.have == size - 1 {
				msg := [3]u8{p.status, p.data[0], p.data[1]}
				emit(user, msg[:size])
				p.have = 0
				if p.status >= 0xF0 do p.status = 0 // no running status for system messages
			}
		}
	}
}

// ── 14 bits, RPN and NRPN ─────────────────────────────────────────────

// A 14-bit value from its MSB and LSB.
join14 :: proc(msb, lsb: u8) -> u16 { return u16(msb & 0x7F) << 7 | u16(lsb & 0x7F) }
// A 14-bit value's MSB and LSB.
split14 :: proc(v: u16) -> (msb, lsb: u8) { return u8((v >> 7) & 0x7F), u8(v & 0x7F) }

// The four CCs that set a registered parameter (101, 100, 6, 38).
rpn :: proc(channel: u8, parameter: u16, value: u16) -> [4][3]u8 {
	pm, pl := split14(parameter)
	vm, vl := split14(value)
	return {control_change(channel, 101, pm), control_change(channel, 100, pl), control_change(channel, 6, vm), control_change(channel, 38, vl)}
}

// The four CCs that set a non-registered parameter (99, 98, 6, 38).
nrpn :: proc(channel: u8, parameter: u16, value: u16) -> [4][3]u8 {
	pm, pl := split14(parameter)
	vm, vl := split14(value)
	return {control_change(channel, 99, pm), control_change(channel, 98, pl), control_change(channel, 6, vm), control_change(channel, 38, vl)}
}

// Reads (N)RPN values from a channel's CCs, as they arrive.
Parameter_Reader :: struct {
	parameter: [16]u16,
	nrpn:      [16]bool,
	set:       [16]bool,
	msb:       [16]u8,
}

// Feeds a CC. A value comes out (ok) with its data entry MSB (6), and again
// with its LSB (38), the finer value.
parameter_feed :: proc(r: ^Parameter_Reader, channel, number, value: u8) -> (parameter: u16, v: u16, is_nrpn, ok: bool) {
	c := channel & 0x0F
	switch number {
	case 99, 101: r.parameter[c] = u16(value & 0x7F) << 7 | (r.parameter[c] & 0x7F); r.nrpn[c] = number == 99; r.set[c] = true
	case 98, 100: r.parameter[c] = (r.parameter[c] & 0x3F80) | u16(value & 0x7F); r.nrpn[c] = number == 98; r.set[c] = true
	case 6:
		if !r.set[c] do return
		r.msb[c] = value & 0x7F
		return r.parameter[c], u16(r.msb[c]) << 7, r.nrpn[c], true
	case 38:
		if !r.set[c] do return
		return r.parameter[c], join14(r.msb[c], value), r.nrpn[c], true
	}
	return
}

// ── SysEx ─────────────────────────────────────────────────────────────

// A SysEx: F0, the manufacturer id (1 or 3 bytes), the payload, F7. Into
// `out` (cleared first).
sysex :: proc(out: ^[dynamic]u8, manufacturer: []u8, payload: []u8) {
	clear(out)
	append(out, 0xF0)
	append(out, ..manufacturer)
	for b in payload do append(out, b & 0x7F)
	append(out, 0xF7)
}

// The id for non-commercial and educational use (prototypes, tests).
MANUFACTURER_NON_COMMERCIAL :: [1]u8{0x7D}
// Universal non-real-time messages' id (identity requests and replies).
UNIVERSAL_NON_REAL_TIME :: [1]u8{0x7E}
// Universal real-time messages' id.
UNIVERSAL_REAL_TIME :: [1]u8{0x7F}

// Packs 8-bit bytes into 7-bit ones: each group of seven is sent as a
// byte of their high bits (bit i for byte i), then the seven with their
// high bits cleared. Appends to `out`.
pack7 :: proc(out: ^[dynamic]u8, data: []u8) {
	for i := 0; i < len(data); i += 7 {
		group := data[i:min(i + 7, len(data))]
		high: u8
		for b, k in group do if b & 0x80 != 0 do high |= 1 << u8(k)
		append(out, high)
		for b in group do append(out, b & 0x7F)
	}
}

// Undoes `pack7`. Appends to `out`.
unpack7 :: proc(out: ^[dynamic]u8, data: []u8) {
	for i := 0; i < len(data); i += 8 {
		high := data[i]
		for k in 1 ..< min(8, len(data) - i) do append(out, data[i + k] | (0x80 if high & (1 << u8(k - 1)) != 0 else 0))
	}
}

// A byte as two nibbles (high first), and back.
nibbles :: proc(b: u8) -> [2]u8 { return {b >> 4, b & 0x0F} }
// Two nibbles (high first) as a byte.
from_nibbles :: proc(high, low: u8) -> u8 { return (high & 0x0F) << 4 | (low & 0x0F) }

// Roland's checksum: what makes the bytes' sum a multiple of 128.
roland_checksum :: proc(data: []u8) -> u8 {
	sum: int
	for b in data do sum += int(b)
	return u8((128 - sum % 128) % 128)
}

// Whether a SysEx begins with these bytes.
has_prefix :: proc(bytes, prefix: []u8) -> bool {
	if len(bytes) < len(prefix) do return false
	for b, i in prefix do if bytes[i] != b do return false
	return true
}
