package fsurf_host

import "base:intrinsics"
import "core:mem"
import "core:strings"

import abi "../abi"

/*
The MIDI monitor: every message from a device (what the claim table did
with it, and which rule), every message a surface sent it or handed on to
the app, and the surface's own description of each (the control, from its
fsurf.layout extension, and the component that has it).

	host.monitor_enable(&h, true)
	// ... route, host_update ...
	for e in host.monitor_entries(&h) do fmt.println(host.monitor_line(e))
	host.monitor_clear(&h)

`route` records on its own thread without locking or allocating, into a
ring that `host_update` reads; the rest is on the surface thread.
*/

// What a monitor entry is.
Monitor_Kind :: enum u8 {
	In,     // from a device's port, through the claim table
	Out,    // a surface to its device
	Inject, // a surface's message handed on to the app (`inject_midi`)
}

// The first bytes of a message a monitor entry keeps (and `size` its whole).
MONITOR_BYTES :: 24

// One message, and what became of it.
Monitor_Entry :: struct {
	kind:       Monitor_Kind,
	time_ns:    u64,
	port:       u32, // the app's port id
	bytes:      [MONITOR_BYTES]u8,
	size:       int,
	// In:
	action:     abi.Rule_Action,
	to_host:    bool,
	to_surface: bool,
	rule:       int, // from 1; 0 = none
	// The surface (0 = none), its control (-1 = none) and the component that had it.
	uid:        u32,
	surface:    string, // its descriptor's name (the descriptor's: not owned)
	control:    string, // owned by the monitor
	owner:      string, // owned
}

// The entries a monitor keeps; the oldest go first. (A ring of the same
// size takes `route`'s, between updates.)
MONITOR_CAPACITY :: 2048

@(private)
Monitor :: struct {
	on:      bool, // atomic
	ring:    []Monitor_Raw,
	head:    u64, // atomic: route's
	tail:    u64, // atomic: the surface thread's
	lost:    u64, // atomic: entries route couldn't record
	entries: [dynamic]Monitor_Entry,
}

@(private)
Monitor_Raw :: struct {
	time_ns: u64,
	port:    u32,
	size:    u32,
	bytes:   [MONITOR_BYTES]u8,
	action:  abi.Rule_Action,
	rule:    u16,
	host:    bool,
	surface: bool,
}

@(private)
monitor_init :: proc(m: ^Monitor, allocator := context.allocator) {
	m.ring = make([]Monitor_Raw, MONITOR_CAPACITY, allocator)
	m.entries = make([dynamic]Monitor_Entry, allocator)
}

@(private)
monitor_destroy :: proc(m: ^Monitor, allocator := context.allocator) {
	for e in m.entries do entry_free(e, m.entries.allocator)
	delete(m.entries)
	delete(m.ring, allocator)
}

@(private)
entry_free :: proc(e: Monitor_Entry, allocator: mem.Allocator) {
	delete(e.control, allocator)
	delete(e.owner, allocator)
}

// Turns the monitor on or off.
monitor_enable :: proc(h: ^Host, on: bool) {
	intrinsics.atomic_store(&h.monitor.on, on)
}

// What the monitor has, oldest first, as of the last `host_update`.
monitor_entries :: proc(h: ^Host) -> []Monitor_Entry {
	return h.monitor.entries[:]
}

// Forgets what the monitor has.
monitor_clear :: proc(h: ^Host) {
	for e in h.monitor.entries do entry_free(e, h.monitor.entries.allocator)
	clear(&h.monitor.entries)
}

// Entries `route` couldn't record (more than MONITOR_CAPACITY between updates).
monitor_lost :: proc(h: ^Host) -> u64 {
	return intrinsics.atomic_load(&h.monitor.lost)
}

// [rt] What `route` did, for the monitor.
@(private)
monitor_route :: proc "contextless" (m: ^Monitor, port: u32, bytes: []u8, time_ns: u64, r: Route) {
	head := intrinsics.atomic_load_explicit(&m.head, .Relaxed)
	tail := intrinsics.atomic_load_explicit(&m.tail, .Acquire)
	if head - tail >= u64(len(m.ring)) {
		intrinsics.atomic_add(&m.lost, 1)
		return
	}
	e := &m.ring[head % u64(len(m.ring))]
	e^ = {time_ns = time_ns, port = port, size = u32(len(bytes)), action = r.action, rule = u16(min(r.rule, 65535)), host = r.host != nil, surface = r.surface}
	for i in 0 ..< min(len(bytes), MONITOR_BYTES) do e.bytes[i] = bytes[i]
	intrinsics.atomic_store_explicit(&m.head, head + 1, .Release)
}

// Surface thread: what `route_here` did, straight into the list.
@(private)
monitor_route_here :: proc(h: ^Host, port: u32, bytes: []u8, time_ns: u64, r: Route) {
	e := Monitor_Entry{kind = .In, time_ns = time_ns, port = port, size = len(bytes), action = r.action, to_host = r.host != nil, to_surface = r.surface, rule = r.rule}
	for i in 0 ..< min(len(bytes), MONITOR_BYTES) do e.bytes[i] = bytes[i]
	for s in h.instances {
		if s.state != .Active && s.state != .Identifying do continue
		for p in s.ports do if p.input == port {
			describe(h, &e, s)
			break
		}
		if e.uid != 0 do break
	}
	monitor_add(h, e)
}

// Surface thread: route's entries into the list, described.
@(private)
monitor_drain :: proc(h: ^Host) {
	m := &h.monitor
	tail := intrinsics.atomic_load_explicit(&m.tail, .Relaxed)
	head := intrinsics.atomic_load_explicit(&m.head, .Acquire)
	for tail < head {
		raw := m.ring[tail % u64(len(m.ring))]
		tail += 1
		e := Monitor_Entry{kind = .In, time_ns = raw.time_ns, port = raw.port, bytes = raw.bytes, size = int(raw.size),
			action = raw.action, to_host = raw.host, to_surface = raw.surface, rule = int(raw.rule)}
		// The surface on that port.
		for s in h.instances {
			if s.state != .Active && s.state != .Identifying do continue
			for p in s.ports do if p.input == raw.port {
				describe(h, &e, s)
				break
			}
			if e.uid != 0 do break
		}
		monitor_add(h, e)
	}
	intrinsics.atomic_store_explicit(&m.tail, tail, .Release)
}

// Surface thread: a message a surface sent (or handed on).
@(private)
monitor_sent :: proc(h: ^Host, s: ^Instance, kind: Monitor_Kind, port: u32, bytes: []u8) {
	if !intrinsics.atomic_load_explicit(&h.monitor.on, .Relaxed) do return
	e := Monitor_Entry{kind = kind, time_ns = host_now_ns(h), port = port, size = len(bytes)}
	for i in 0 ..< min(len(bytes), MONITOR_BYTES) do e.bytes[i] = bytes[i]
	describe(h, &e, s)
	monitor_add(h, e)
}

@(private)
describe :: proc(h: ^Host, e: ^Monitor_Entry, s: ^Instance) {
	e.uid = s.uid
	e.surface = string(s.descriptor.name)
	l := (^abi.Layout)(instance_extension(s, abi.LAYOUT_ID))
	if l == nil || l.struct_size < size_of(abi.Layout) || l.find == nil do return
	i := l.find(s.surface, e.kind == .Out, e.port, &e.bytes[0], u32(min(e.size, MONITOR_BYTES)))
	if i < 0 do return
	a := h.monitor.entries.allocator
	c := abi.Layout_Control{struct_size = size_of(abi.Layout_Control)}
	if l.get != nil && l.get(s.surface, u32(i), &c) && c.name != nil do e.control = strings.clone(string(c.name), a)
	if l.owner != nil do if o := l.owner(s.surface, u32(i)); o != nil do e.owner = strings.clone(string(o), a)
}

@(private)
monitor_add :: proc(h: ^Host, e: Monitor_Entry) {
	m := &h.monitor
	if len(m.entries) >= MONITOR_CAPACITY {
		entry_free(m.entries[0], m.entries.allocator)
		ordered_remove(&m.entries, 0)
	}
	append(&m.entries, e)
}

// An entry as a line of text (in the temp allocator):
//
//	in   3  90 24 64      claim (rule 2)  surface  Grid / Pad 3,0 (Drum)
//	out  4  90 24 7F                               Grid / Pad 3,0 (Drum)
monitor_line :: proc(e: Monitor_Entry) -> string {
	b := strings.builder_make(context.temp_allocator)
	kinds := [Monitor_Kind]string{.In = "in ", .Out = "out", .Inject = "inj"}
	strings.write_string(&b, kinds[e.kind])
	strings.write_string(&b, " ")
	strings.write_uint(&b, uint(e.port))
	strings.write_string(&b, "  ")
	hex := "0123456789ABCDEF"
	for i in 0 ..< min(e.size, MONITOR_BYTES) {
		if i > 0 do strings.write_byte(&b, ' ')
		strings.write_byte(&b, hex[e.bytes[i] >> 4])
		strings.write_byte(&b, hex[e.bytes[i] & 15])
	}
	if e.size > MONITOR_BYTES {
		strings.write_string(&b, " ... (")
		strings.write_int(&b, e.size)
		strings.write_string(&b, " bytes)")
	}
	if e.kind == .In {
		actions := [abi.Rule_Action]string{.Pass = "pass", .Claim = "claim", .Observe = "observe", .Remap = "remap", .Drop = "drop"}
		strings.write_string(&b, "  ")
		strings.write_string(&b, actions[e.action])
		if e.rule > 0 {
			strings.write_string(&b, " (rule ")
			strings.write_int(&b, e.rule)
			strings.write_string(&b, ")")
		}
	}
	if e.surface != "" {
		strings.write_string(&b, "  ")
		strings.write_string(&b, e.surface)
		if e.control != "" {
			strings.write_string(&b, " / ")
			strings.write_string(&b, e.control)
		}
		if e.owner != "" {
			strings.write_string(&b, " (")
			strings.write_string(&b, e.owner)
			strings.write_string(&b, ")")
		}
	}
	return strings.to_string(b)
}
