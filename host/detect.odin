package fsurf_host

import "core:strings"

import abi "../abi"

/*
Finding controllers: the app gives the host its libraries
(`host_add_library`) and the system's MIDI ports whenever they change
(`host_set_ports`); the host matches the ports against every descriptor,
identifies what it found (an identity request and its reply, or the
surface's own handshake, or the names alone), and starts the surface that
fits best. A controller unplugged deactivates its surface, which is kept
and started again when it is back.

	host.host_add_library(&h, lib)
	host.host_set_ports(&h, inputs, outputs) // at start, and on every change
	// MIDI in, on the MIDI thread:   r := host.route(&h, port, bytes, now, &buf)
	// once a frame:                  host.host_update(&h)  (probes, replies, timers)
*/

// Where a found controller is.
Device_State :: enum {
	Identifying,    // its identity request sent (or its surface identifying it), waiting for the answer
	Waiting,        // identified; waiting for other surfaces on the same ports to answer
	Active,         // its surface is running
	Not_Identified, // it didn't answer as this surface's device
	Passed_Over,    // identified, but a more specific surface (or one assigned by hand) has its ports
	Failed,         // its surface couldn't be made or started
	Gone,           // its ports went away; its surface is kept for when they're back
}

// A controller the host found on the system's ports (or the app assigned
// by hand), and the surface for it. Fields are read-only.
Device :: struct {
	library:    ^Library,
	descriptor: ^abi.Descriptor,
	index:      int, // the n-th of its model on this system
	ports:      []Port_Assignment, // in the descriptor's order (names owned)
	state:      Device_State,
	instance:   ^Instance, // its surface, once made
	manual:     bool, // assigned by hand (`host_assign`)
	score:      int, // how specific its identification was
	sent:       u32, // identity requests sent
	next_ns:    u64, // when the next is due (or, after the last, the deadline)
}

// Adds a library whose surfaces the host may start for the controllers it
// finds. The host doesn't own it: remove it (`host_remove_library`) before
// unloading it.
host_add_library :: proc(h: ^Host, l: ^Library) {
	for x in h.libraries do if x == l do return
	append(&h.libraries, l)
	rematch(h)
}

// Stops and forgets every controller found for a library's surfaces (their
// surfaces destroyed), and stops using it.
host_remove_library :: proc(h: ^Host, l: ^Library) {
	for i := len(h.devices) - 1; i >= 0; i -= 1 do if h.devices[i].library == l do device_remove(h, i)
	for x, i in h.libraries do if x == l { ordered_remove(&h.libraries, i); break }
	rematch(h)
}

// The system's MIDI ports, all of them, whenever they change (at start, a
// controller plugged in or out). The host copies them.
host_set_ports :: proc(h: ^Host, inputs, outputs: []Port_Info) {
	set :: proc(h: ^Host, dst: ^[dynamic]Port_Info, src: []Port_Info) {
		for p in dst do delete(p.name, h.allocator)
		clear(dst)
		for p in src do append(dst, Port_Info{id = p.id, name = strings.clone(p.name, h.allocator)})
		sort_ports(dst[:])
	}
	set(h, &h.inputs, inputs)
	set(h, &h.outputs, outputs)
	rematch(h)
}

// Turns detection of one surface (by id) on or off. Off stops and forgets
// the controllers found for it (not those assigned by hand).
host_set_auto_detect :: proc(h: ^Host, surface_id: string, on: bool) {
	at := -1
	for x, i in h.disabled do if x == surface_id do at = i
	if on && at >= 0 {
		delete(h.disabled[at], h.allocator)
		ordered_remove(&h.disabled, at)
	} else if !on && at < 0 {
		append(&h.disabled, strings.clone(surface_id, h.allocator))
		for i := len(h.devices) - 1; i >= 0; i -= 1 {
			d := h.devices[i]
			if !d.manual && string(d.descriptor.id) == surface_id do device_remove(h, i)
		}
	}
	rematch(h)
}

// Whether the host detects a surface (`host_set_auto_detect`).
host_auto_detect :: proc(h: ^Host, surface_id: string) -> bool {
	for x in h.disabled do if x == surface_id do return false
	return true
}

// Starts a library's surface on ports the app (its user) chose, whatever
// their names: it takes them from any surface detection found there, and
// keeps them until `host_unassign`. Its ports are names: when they go away
// it is Gone, and when ports of those names are back it starts again.
host_assign :: proc(h: ^Host, l: ^Library, surface_id: string, ports: []Port_Assignment) -> (^Device, Instance_Error) {
	desc := library_find(l, surface_id)
	if desc == nil do return nil, .No_Such_Surface
	if len(ports) != int(desc.port_count) do return nil, .Create_Failed
	d := new(Device, h.allocator)
	d^ = {library = l, descriptor = desc, manual = true, score = max(int), state = .Waiting}
	d.ports = clone_ports(h, ports)
	d.index = 0
	for x in h.devices do if x.descriptor == desc do d.index = max(d.index, x.index + 1)
	append(&h.devices, d)
	h.routes_dirty = true
	resolve(h)
	publish_routes(h)
	if d.state != .Active do return d, .Init_Failed if d.state == .Failed else .None
	return d, .None
}

// Stops and forgets a surface started by `host_assign`; detection may then
// start another on its ports.
host_unassign :: proc(h: ^Host, d: ^Device) {
	for x, i in h.devices do if x == d { device_remove(h, i); break }
	rematch(h)
}

// ── Internals ─────────────────────────────────────────────────────────

@(private)
clone_ports :: proc(h: ^Host, ports: []Port_Assignment) -> []Port_Assignment {
	out := make([]Port_Assignment, len(ports), h.allocator)
	for p, i in ports {
		out[i] = p
		out[i].input_name = strings.clone(p.input_name, h.allocator)
		out[i].output_name = strings.clone(p.output_name, h.allocator)
	}
	return out
}

@(private)
free_device_ports :: proc(h: ^Host, ports: []Port_Assignment) {
	for p in ports {
		delete(p.input_name, h.allocator)
		delete(p.output_name, h.allocator)
	}
	delete(ports, h.allocator)
}

@(private)
set_state :: proc(h: ^Host, d: ^Device, state: Device_State) {
	if d.state == state do return
	old := d.state
	d.state = state
	h.routes_dirty = true
	if h.config.on_device != nil do h.config.on_device(h.config.user, d, old)
}

@(private)
device_remove :: proc(h: ^Host, i: int) {
	d := h.devices[i]
	ordered_remove(&h.devices, i)
	if d.instance != nil {
		s := d.instance
		s.device = nil
		d.instance = nil
		instance_destroy(s)
	}
	free_device_ports(h, d.ports)
	free(d, h.allocator)
}

// Whether the host is sending a device identity requests (not its surface).
@(private)
probing :: proc(d: ^Device) -> bool {
	return d.state == .Identifying && d.descriptor.identity != nil && d.descriptor.identity.method == .Request
}

// The pair a device's identity request goes on, and its reply comes in on.
@(private)
identity_ports :: proc(d: ^Device) -> (Port_Assignment, bool) {
	k := 0
	if id := d.descriptor.identity; id != nil && id.port_role != nil {
		k = -1
		for i in 0 ..< int(d.descriptor.port_count) do if d.descriptor.ports[i].role == id.port_role || string(d.descriptor.ports[i].role) == string(id.port_role) { k = i; break }
	}
	if k < 0 || k >= len(d.ports) do return {}, false
	return d.ports[k], true
}

@(private)
same_names :: proc(a, b: []Port_Assignment) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x.input_name != b[i].input_name || x.output_name != b[i].output_name do return false
	return true
}

@(private)
has_extensions :: proc(h: ^Host, d: ^abi.Descriptor) -> bool {
	if d.required_extensions == nil do return true
	for i := 0; d.required_extensions[i] != nil; i += 1 {
		id := string(d.required_extensions[i])
		if h.config.has_extension == nil || !h.config.has_extension(h.config.user, id) do return false
	}
	return true
}

// Whether a port name is among the system's now; and its id.
@(private)
port_id :: proc(ports: []Port_Info, name: string) -> (u32, bool) {
	if name == "" do return abi.NO_PORT, true
	for p in ports do if p.name == name do return p.id, true
	return abi.NO_PORT, false
}

// Matches the ports against every descriptor again, and brings the devices
// up to date: those gone, those back, those new.
@(private)
rematch :: proc(h: ^Host) {
	h.routes_dirty = true
	Candidate :: struct { library: ^Library, match: Match, taken: bool }
	candidates := make([dynamic]Candidate, context.temp_allocator)
	for l in h.libraries {
		for desc in l.descriptors {
			if !host_auto_detect(h, string(desc.id)) || !has_extensions(h, desc) do continue
			for m in find_matches(desc, h.inputs[:], h.outputs[:], context.temp_allocator) do append(&candidates, Candidate{library = l, match = m})
		}
	}

	// Those assigned by hand: there while their ports' names are.
	for d in h.devices {
		if !d.manual do continue
		present := true
		for &p in d.ports {
			id_in, ok_in := port_id(h.inputs[:], p.input_name)
			id_out, ok_out := port_id(h.outputs[:], p.output_name)
			if !ok_in || !ok_out { present = false; continue }
			p.input = id_in
			p.output = id_out
		}
		if !present {
			device_gone(h, d)
		} else if d.state == .Gone {
			set_state(h, d, .Waiting)
		}
	}

	// Those found before: kept while a candidate has their ports' names.
	for i := len(h.devices) - 1; i >= 0; i -= 1 {
		d := h.devices[i]
		if d.manual do continue
		found := -1
		for c, k in candidates do if !c.taken && c.match.descriptor == d.descriptor && same_names(c.match.ports, d.ports) { found = k; break }
		if found < 0 {
			if d.instance != nil {
				device_gone(h, d)
			} else {
				device_remove(h, i)
			}
			continue
		}
		c := &candidates[found]
		c.taken = true
		moved := false
		for p, k in c.match.ports do if p.input != d.ports[k].input || p.output != d.ports[k].output do moved = true
		for p, k in c.match.ports { d.ports[k].input = p.input; d.ports[k].output = p.output }
		d.index = c.match.index
		switch d.state {
		case .Gone:
			device_start(h, d)
		case .Active:
			if moved { // the same names on other ids: start it again on those
				instance_deactivate(d.instance)
				device_start(h, d)
			}
		case .Passed_Over:
			set_state(h, d, .Waiting) // judged again: what took its ports may have gone
		case .Identifying, .Waiting, .Not_Identified, .Failed:
		}
	}

	// New ones; not on ports assigned by hand.
	for &c in candidates {
		if c.taken || on_manual_ports(h, c.match.ports) do continue
		d := new(Device, h.allocator)
		d^ = {library = c.library, descriptor = c.match.descriptor, index = c.match.index, state = .Identifying}
		d.ports = clone_ports(h, c.match.ports)
		append(&h.devices, d)
		if h.config.on_device != nil do h.config.on_device(h.config.user, d, .Identifying)
		device_start(h, d)
	}
	tick_probes(h)
	resolve(h)
	publish_routes(h)
}

@(private)
on_manual_ports :: proc(h: ^Host, ports: []Port_Assignment) -> bool {
	for d in h.devices do if d.manual && d.state != .Gone && shares_ports(d.ports, ports) do return true
	return false
}

@(private)
shares_ports :: proc(a, b: []Port_Assignment) -> bool {
	for x in a do for y in b {
		if x.input != abi.NO_PORT && x.input == y.input do return true
		if x.output != abi.NO_PORT && x.output == y.output do return true
	}
	return false
}

@(private)
device_gone :: proc(h: ^Host, d: ^Device) {
	if d.state == .Gone do return
	if d.instance != nil do instance_deactivate(d.instance)
	set_state(h, d, .Gone)
}

// Starts identifying a device (again).
@(private)
device_start :: proc(h: ^Host, d: ^Device) {
	id := d.descriptor.identity
	method := id.method if id != nil else .Names
	d.sent = 0
	switch method {
	case .Names:
		d.score = identity_score(d.descriptor)
		set_state(h, d, .Waiting)
	case .Request:
		d.next_ns = host_now_ns(h) + u64(id.delay_ms) * 1_000_000
		set_state(h, d, .Identifying)
	case .Surface:
		if d.instance == nil && !device_make(h, d) do return
		set_state(h, d, .Identifying)
		if !instance_identify(d.instance, d.ports) do device_fail(h, d, .Failed)
	}
}

@(private)
device_make :: proc(h: ^Host, d: ^Device) -> bool {
	s, err := instance_create(h, d.library, string(d.descriptor.id))
	if err != .None {
		set_state(h, d, .Failed)
		return false
	}
	s.device = d
	d.instance = s
	if h.config.device_settings != nil do instance_set_settings(s, h.config.device_settings(h.config.user, d))
	return true
}

@(private)
device_fail :: proc(h: ^Host, d: ^Device, state: Device_State) {
	if d.instance != nil {
		s := d.instance
		s.device = nil
		d.instance = nil
		instance_destroy(s)
	}
	set_state(h, d, state)
}

// Identity requests due, and deadlines passed. Each update.
@(private)
tick_probes :: proc(h: ^Host) {
	now := host_now_ns(h)
	for d in h.devices {
		if d.state != .Identifying do continue
		id := d.descriptor.identity
		if id.method == .Surface {
			s := d.instance
			if s == nil || s.state != .Identifying do continue
			if ok, answered := s.identified.?; answered {
				if ok {
					d.score = identity_score(d.descriptor)
					s.state = .Ready
					set_state(h, d, .Waiting)
				} else {
					device_fail(h, d, .Not_Identified)
				}
			}
			continue
		}
		if now < d.next_ns do continue
		retries := id.retries if id.retries > 0 else DEFAULT_RETRIES
		retry_ms := id.retry_ms if id.retry_ms > 0 else DEFAULT_RETRY_MS
		if d.sent > retries {
			set_state(h, d, .Not_Identified)
			continue
		}
		p, ok := identity_ports(d)
		if !ok || p.output == abi.NO_PORT || h.config.send_midi == nil {
			set_state(h, d, .Not_Identified)
			continue
		}
		request := UNIVERSAL_IDENTITY_REQUEST
		bytes := request[:]
		if id.request != nil && id.request_size > 0 do bytes = id.request[:id.request_size]
		h.config.send_midi(h.config.user, nil, p.output, bytes)
		d.sent += 1
		d.next_ns = now + u64(retry_ms) * 1_000_000
	}
}

// The identity request a descriptor sends when it names none.
UNIVERSAL_IDENTITY_REQUEST :: [6]u8{0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7}

// An identity request's retries and the wait between, when a descriptor
// leaves them 0.
DEFAULT_RETRIES :: 2
// (See DEFAULT_RETRIES.)
DEFAULT_RETRY_MS :: 300

// A SysEx from a port the host is identifying a device on.
@(private)
probe_reply :: proc(h: ^Host, port: u32, bytes: []u8) {
	changed := false
	for d in h.devices {
		if !probing(d) do continue
		p, ok := identity_ports(d)
		if !ok || p.input != port || !identity_matches(d.descriptor.identity, bytes) do continue
		d.score = identity_score(d.descriptor)
		set_state(h, d, .Waiting)
		changed = true
	}
	if changed {
		resolve(h)
		publish_routes(h)
	}
}

// Starts the identified devices that win their ports: the most specific
// identification, once every other surface on those ports has answered.
@(private)
resolve :: proc(h: ^Host) {
	for _ in 0 ..< len(h.devices) + 1 {
		changed := false
		for d in h.devices {
			if d.state != .Waiting do continue
			best := d
			undecided := false
			for c in h.devices {
				if c == d || !shares_ports(c.ports, d.ports) do continue
				#partial switch c.state {
				case .Identifying: undecided = true
				case .Waiting, .Active:
					if c.score > best.score || (c.score == best.score && c.state == .Active && best.state != .Active) do best = c
				}
			}
			if undecided && !d.manual do continue // (one assigned by hand doesn't wait)
			if best != d {
				if best.state == .Active { device_fail_or_pass(h, d); changed = true }
				continue // a Waiting best takes its turn
			}
			for c in h.devices {
				if c == d || !shares_ports(c.ports, d.ports) do continue
				#partial switch c.state {
				case .Active:
					instance_deactivate(c.instance)
					device_fail_or_pass(h, c)
				case .Waiting:
					device_fail_or_pass(h, c)
				}
			}
			device_activate(h, d)
			changed = true
		}
		if !changed do break
	}
}

// Passed over: a surface made only to identify its device goes.
@(private)
device_fail_or_pass :: proc(h: ^Host, d: ^Device) {
	if d.instance != nil && d.instance.state != .Active && d.descriptor.identity != nil && d.descriptor.identity.method == .Surface {
		device_fail(h, d, .Passed_Over)
		return
	}
	set_state(h, d, .Passed_Over)
}

@(private)
device_activate :: proc(h: ^Host, d: ^Device) {
	if d.instance == nil && !device_make(h, d) do return
	if !instance_activate(d.instance, d.ports) {
		device_fail(h, d, .Failed)
		return
	}
	set_state(h, d, .Active)
}

// The devices, in the order they were found. Read-only.
host_devices :: proc(h: ^Host) -> []^Device {
	return h.devices[:]
}

@(private)
devices_destroy :: proc(h: ^Host) {
	for len(h.devices) > 0 do device_remove(h, len(h.devices) - 1)
	delete(h.devices)
	for p in h.inputs do delete(p.name, h.allocator)
	for p in h.outputs do delete(p.name, h.allocator)
	delete(h.inputs)
	delete(h.outputs)
	for s in h.disabled do delete(s, h.allocator)
	delete(h.disabled)
	delete(h.libraries)
}
