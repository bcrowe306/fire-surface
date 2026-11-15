package fsurf_host

import "core:slice"
import "core:strings"

import abi "../abi"

// A MIDI port of the system, as the app's MIDI layer names it. `id` is the
// app's own (what `instance_midi`, `route` and `Host_Config.send_midi` use).
Port_Info :: struct {
	id:   u32,
	name: string,
}

// Whether a port name matches one of a descriptor's patterns: `*` matches
// any run of characters, case is ignored (ASCII), and a pattern beginning
// "mac:", "win:" or "linux:" applies on that system only.
name_matches :: proc(pattern, name: string) -> bool {
	p := pattern
	for prefix in ([3]string{"mac:", "win:", "linux:"}) {
		if len(p) >= len(prefix) && strings.equal_fold(p[:len(prefix)], prefix) {
			if prefix != OS_PREFIX do return false
			p = p[len(prefix):]
			break
		}
	}
	return glob(p, name)
}

@(private)
OS_PREFIX :: "mac:" when ODIN_OS == .Darwin else "win:" when ODIN_OS == .Windows else "linux:"

@(private)
lower :: #force_inline proc(c: u8) -> u8 { return c + 32 if c >= 'A' && c <= 'Z' else c }

// `*` globbing without recursion: on a mismatch, the last star takes one
// more character.
@(private)
glob :: proc(p, s: string) -> bool {
	pi, si := 0, 0
	star, mark := -1, 0
	for si < len(s) {
		if pi < len(p) && p[pi] == '*' {
			star = pi; mark = si; pi += 1
		} else if pi < len(p) && lower(p[pi]) == lower(s[si]) {
			pi += 1; si += 1
		} else if star >= 0 {
			pi = star + 1; mark += 1; si = mark
		} else {
			return false
		}
	}
	for pi < len(p) && p[pi] == '*' do pi += 1
	return pi == len(p)
}

@(private)
any_matches :: proc(patterns: [^]cstring, name: string) -> bool {
	if patterns == nil do return false
	for i := 0; patterns[i] != nil; i += 1 do if name_matches(string(patterns[i]), name) do return true
	return false
}

// One controller found on the system's ports for a descriptor: a port
// pair for each of its port specs (in the descriptor's order; NO_PORT and
// "" where an optional one, or a side the spec doesn't use, is missing).
Match :: struct {
	descriptor: ^abi.Descriptor,
	index:      int, // the n-th of this model (two of the same controller: 0 and 1)
	ports:      []Port_Assignment, // the names point into the Port_Infos given
}

// The controllers of a descriptor's model among the system's ports. For
// each port spec, each input that matches its input patterns is paired
// with an output that matches its output patterns: one of the same name if
// there is one, else the next in order. The n-th pair of every spec makes
// the n-th controller; one that lacks a required spec's pair isn't there.
// Ports are taken in the order given (sort them by name for a stable
// order). Free with `matches_destroy`.
find_matches :: proc(d: ^abi.Descriptor, inputs, outputs: []Port_Info, allocator := context.allocator) -> []Match {
	if d.port_count == 0 do return nil
	pairs := make([][dynamic]Port_Assignment, d.port_count, context.temp_allocator)
	most := 0
	for i in 0 ..< int(d.port_count) {
		spec := d.ports[i]
		pairs[i] = make([dynamic]Port_Assignment, context.temp_allocator)
		ins := make([dynamic]Port_Info, context.temp_allocator)
		outs := make([dynamic]Port_Info, context.temp_allocator)
		if .Input in spec.flags do for p in inputs do if any_matches(spec.input_names, p.name) do append(&ins, p)
		if .Output in spec.flags do for p in outputs do if any_matches(spec.output_names, p.name) do append(&outs, p)
		used := make([]bool, len(outs), context.temp_allocator)
		if .Input in spec.flags {
			for p in ins {
				a := Port_Assignment{input = p.id, output = abi.NO_PORT, input_name = p.name}
				if .Output in spec.flags {
					pick := -1
					for o, k in outs do if !used[k] && strings.equal_fold(o.name, p.name) { pick = k; break }
					if pick < 0 do for _, k in outs do if !used[k] { pick = k; break }
					if pick < 0 do continue // an input without an output: not a whole pair
					used[pick] = true
					a.output = outs[pick].id
					a.output_name = outs[pick].name
				}
				append(&pairs[i], a)
			}
		} else {
			for o in outs do append(&pairs[i], Port_Assignment{input = abi.NO_PORT, output = o.id, output_name = o.name})
		}
		most = max(most, len(pairs[i]))
	}
	out := make([dynamic]Match, allocator)
	devices: for n in 0 ..< most {
		ports := make([]Port_Assignment, d.port_count, allocator)
		for i in 0 ..< int(d.port_count) {
			if n < len(pairs[i]) {
				ports[i] = pairs[i][n]
			} else if .Optional in d.ports[i].flags {
				ports[i] = {input = abi.NO_PORT, output = abi.NO_PORT}
			} else {
				delete(ports, allocator)
				continue devices
			}
		}
		append(&out, Match{descriptor = d, index = len(out), ports = ports})
	}
	return out[:]
}

// Frees what `find_matches` returned.
matches_destroy :: proc(ms: []Match, allocator := context.allocator) {
	for m in ms do delete(m.ports, allocator)
	delete(ms, allocator)
}

// Ports sorted by name, then id: the order `find_matches` should see them
// in, so the n-th controller is the same one from run to run. Sorts in place.
sort_ports :: proc(ports: []Port_Info) {
	slice.sort_by(ports, proc(a, b: Port_Info) -> bool {
		if a.name != b.name do return a.name < b.name
		return a.id < b.id
	})
}

// Whether an identity reply matches: for each i < match_size,
// (reply[i] & mask[i]) == (match[i] & mask[i]).
identity_matches :: proc(id: ^abi.Identity, reply: []u8) -> bool {
	if id.match == nil || int(id.match_size) > len(reply) do return false
	for i in 0 ..< int(id.match_size) {
		m := id.mask[i] if id.mask != nil else 0xFF
		if reply[i] & m != id.match[i] & m do return false
	}
	return true
}

// How specific an identification is, to pick between surfaces that match
// the same ports: an identity reply's masked bits, above the surface's own
// identification, above port names alone.
@(private)
identity_score :: proc(d: ^abi.Descriptor) -> int {
	id := d.identity
	if id == nil || id.method == .Names do return 0
	if id.method == .Surface do return 1
	bits := 0
	for i in 0 ..< int(id.match_size) {
		m := id.mask[i] if id.mask != nil else 0xFF
		bits += int(card(transmute(bit_set[0 ..< 8; u8])m))
	}
	return 2 + bits
}
