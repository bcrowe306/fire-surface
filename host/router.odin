package fsurf_host

import "base:intrinsics"
import "base:runtime"
import "core:mem"

import abi "../abi"

/*
The claim table on the app's MIDI path.

`route` is the one procedure here for the app's MIDI thread (its driver's
callback, or whatever thread hands MIDI to its engine): it decides where
each message goes from the rules the surfaces published, without calling
them. What a surface is to get is queued, and `host_update` gives it to
the surface on the surface thread. Everything else is for the surface
thread.

The tables are immutable once published: a surface's new rules make a new
one, swapped in atomically. `route` marks the table it is reading (a
hazard pointer), and the surface thread frees an old table only when
`route` isn't reading it. One thread routes at a time.
*/

// What `route` did with a message.
Route :: struct {
	host:    []u8, // what the app's own MIDI handling gets (empty: nothing)
	surface: bool, // a surface gets it (queued for its thread)
	action:  abi.Rule_Action, // the rule's (Pass when none matched)
	rule:    int, // which of the surface's rules took it, from 1 (0: none)
}

// The size of the queue to the surface thread, in bytes. A message that
// doesn't fit is dropped (counted in `Router.dropped`).
QUEUE_BYTES :: 64 * 1024

// Ports whose notes `route` follows (so a note off goes where its note on
// went). Past these, a note off on another port is judged by the rules.
NOTE_PORTS :: 32

@(private)
Router :: struct {
	published: ^Table, // atomic
	hazard:    ^Table, // atomic: what `route` is reading
	retired:   [dynamic]^Table,
	queue:     []u8,
	head:      u64, // atomic: written by `route`
	tail:      u64, // atomic: written by the surface thread
	dropped:   u64, // atomic
	notes:     []Port_Notes, // `route`'s alone
	scratch:   [dynamic]u8, // the surface thread's, for reading the queue
	held:      [dynamic]Held, // `route_here`'s, for the next update
}

@(private)
Port_Mode :: enum u8 {
	Rules,      // an active surface's
	Everything, // a surface identifying itself: it sees everything, the app too
	Probe,      // the host identifying a device: SysEx copied to it
}

@(private)
Table_Port :: struct {
	port:         u32,
	uid:          u32, // the instance's; 0 = the host's detection
	mode:         Port_Mode,
	first, count: int, // its rules in Table.rules
}

// A rule as the router keeps it: its bytes in its table's `bytes`.
@(private)
Compiled_Rule :: struct {
	port:                  u32,
	messages:              abi.Messages,
	channels:              u32,
	first, end:            u8,
	action:                abi.Rule_Action,
	copy:                  bool,
	channel:               u8, // 0 = its own, else 1-16
	sysex_at, sysex_size:  int,
	note_map, value_map:   int, // offsets of 128 bytes, or -1
}

@(private)
Table :: struct {
	ports: []Table_Port,
	rules: []Compiled_Rule,
	bytes: []u8,
}

@(private)
Note_Route :: struct {
	to:      u8, // NOTE_SEEN | NOTE_HOST | NOTE_SURFACE
	note:    u8, // what the app got
	channel: u8,
}

@(private) NOTE_SEEN :: 0x80
@(private) NOTE_HOST :: 0x01
@(private) NOTE_SURFACE :: 0x02

@(private)
Port_Notes :: struct {
	port:  u32,
	used:  bool,
	notes: [16][128]Note_Route,
}

@(private)
QUEUE_HEADER :: 24 // uid u32, port u32, time u64, size u32, (pad) u32

@(private)
router_init :: proc(r: ^Router, allocator: mem.Allocator) {
	r.published = new(Table, allocator) // empty: everything passes
	r.retired = make([dynamic]^Table, allocator)
	r.queue = make([]u8, QUEUE_BYTES, allocator)
	r.notes = make([]Port_Notes, NOTE_PORTS, allocator)
	r.scratch = make([dynamic]u8, allocator)
	r.held = make([dynamic]Held, allocator)
}

@(private)
router_destroy :: proc(r: ^Router, allocator: mem.Allocator) {
	table_free(r.published, allocator)
	for t in r.retired do table_free(t, allocator)
	delete(r.retired)
	delete(r.queue, allocator)
	delete(r.notes, allocator)
	delete(r.scratch)
	for m in r.held do delete(m.bytes, r.held.allocator)
	delete(r.held)
}

@(private)
table_free :: proc(t: ^Table, allocator: mem.Allocator) {
	delete(t.ports, allocator)
	delete(t.rules, allocator)
	delete(t.bytes, allocator)
	free(t, allocator)
}

// Swaps in a new table, and frees the old ones `route` isn't reading.
@(private)
router_publish :: proc(r: ^Router, t: ^Table, allocator: mem.Allocator) {
	old := intrinsics.atomic_exchange(&r.published, t)
	append(&r.retired, old)
	router_collect(r, allocator)
}

@(private)
router_collect :: proc(r: ^Router, allocator: mem.Allocator) {
	reading := intrinsics.atomic_load(&r.hazard)
	for i := len(r.retired) - 1; i >= 0; i -= 1 {
		if r.retired[i] == reading do continue
		table_free(r.retired[i], allocator)
		unordered_remove(&r.retired, i)
	}
}

// Messages dropped because the queue to the surface thread was full.
messages_dropped :: proc(h: ^Host) -> u64 {
	return intrinsics.atomic_load(&h.router.dropped)
}

// [rt] Decides where a message from the app's input `port` goes, by the
// rules of the surface on that port: the app's own MIDI handling gets
// `Route.host` (the message, or a changed one written into `out`), and a
// surface's copy is queued for `host_update`. A port no surface has passes
// everything untouched. `bytes` is one whole message (a status byte first:
// no running status), `time_ns` when it arrived on the host's clock.
//
// Lock-free and allocation-free: call it from the app's MIDI thread, one
// thread at a time, and not while `host_destroy` runs.
route :: proc "contextless" (h: ^Host, port: u32, bytes: []u8, time_ns: u64, out: ^[3]u8) -> Route {
	r := &h.router
	if len(bytes) == 0 do return {}
	t: ^Table
	for {
		t = intrinsics.atomic_load(&r.published)
		intrinsics.atomic_store(&r.hazard, t)
		if intrinsics.atomic_load(&r.published) == t do break
	}
	res := route_message(h, t, false, port, bytes, time_ns, out)
	intrinsics.atomic_store(&r.hazard, nil)
	if intrinsics.atomic_load_explicit(&h.monitor.on, .Relaxed) do monitor_route(&h.monitor, port, bytes, time_ns, res)
	return res
}

// As `route`, on the surface thread: for a host that reads some MIDI there
// (SysEx, as a rule, assembled on that thread) while its MIDI thread routes
// the rest with `route`. A surface's copy is held for the next
// `host_update`, as `route`'s are. A note off here doesn't follow its note
// on (only `route` keeps notes): route notes with `route`.
route_here :: proc(h: ^Host, port: u32, bytes: []u8, time_ns: u64, out: ^[3]u8) -> Route {
	if len(bytes) == 0 do return {}
	res := route_message(h, h.router.published, true, port, bytes, time_ns, out) // (this thread publishes it)
	if intrinsics.atomic_load_explicit(&h.monitor.on, .Relaxed) do monitor_route_here(h, port, bytes, time_ns, res)
	return res
}

@(private)
route_message :: proc "contextless" (h: ^Host, t: ^Table, here: bool, port: u32, bytes: []u8, time_ns: u64, out: ^[3]u8) -> Route {
	r := &h.router

	status := bytes[0]
	if status < 0x80 do return {host = bytes} // not a message: the app's to judge

	kind: abi.Message
	channel := status & 0x0F
	has_channel, has_data1 := status < 0xF0, false
	switch status & 0xF0 {
	case 0x80: kind = .Note_Off; has_data1 = true
	case 0x90: kind = .Note_On if len(bytes) >= 3 && bytes[2] > 0 else .Note_Off; has_data1 = true
	case 0xA0: kind = .Poly_Pressure; has_data1 = true
	case 0xB0: kind = .Control; has_data1 = true
	case 0xC0: kind = .Program; has_data1 = true
	case 0xD0: kind = .Channel_Pressure
	case 0xE0: kind = .Pitch_Bend
	case: kind = .Sysex if status == 0xF0 else .System
	}
	if has_data1 && len(bytes) < 2 do return {host = bytes}
	data1 := bytes[1] & 0x7F if has_data1 else 0

	entry: ^Table_Port
	for &p in t.ports do if p.port == port { entry = &p; break }

	// A note off, or a note's pressure, goes where its note on went.
	if !here && (kind == .Note_Off || kind == .Poly_Pressure) {
		if pn := port_notes(r, port, false); pn != nil {
			rec := &pn.notes[channel][data1]
			if rec.to & NOTE_SEEN != 0 {
				res: Route
				changed := false
				if rec.to & NOTE_HOST != 0 {
					if rec.note == data1 && rec.channel == channel {
						res.host = bytes
					} else if len(bytes) >= 3 {
						out^ = {(status & 0xF0) | rec.channel, rec.note, bytes[2]}
						res.host = out[:]
						changed = true
					}
				}
				surface := rec.to & NOTE_SURFACE != 0
				if surface && entry != nil do res.surface = give(r, here, entry.uid, port, bytes, time_ns)
				switch {
				case res.host == nil && !surface: res.action = .Drop
				case res.host == nil:             res.action = .Claim
				case changed:                     res.action = .Remap
				case surface:                     res.action = .Observe
				case:                             res.action = .Pass
				}
				if kind == .Note_Off do rec^ = {}
				return res
			}
		}
	}

	if entry == nil do return {host = bytes}

	res: Route
	switch entry.mode {
	case .Probe:
		res = {host = bytes}
		if kind == .Sysex do res.surface = give(r, here, 0, port, bytes, time_ns)
	case .Everything:
		res = {host = bytes, action = .Observe}
		res.surface = give(r, here, entry.uid, port, bytes, time_ns)
	case .Rules:
		rule: ^Compiled_Rule
		number := 0
		for &c, i in t.rules[entry.first:][:entry.count] {
			number = i + 1
			if c.port != abi.NO_PORT && c.port != port do continue
			if c.messages != {} && kind not_in c.messages do continue
			if has_channel && c.channels != 0 && c.channels & (1 << channel) == 0 do continue
			if has_data1 && (data1 < c.first || (c.end != 0 && data1 >= c.end)) do continue
			if kind == .Sysex && c.sysex_size > 0 {
				if len(bytes) < c.sysex_size do continue
				prefix := t.bytes[c.sysex_at:][:c.sysex_size]
				same := true
				for b, k in prefix do if bytes[k] != b { same = false; break }
				if !same do continue
			}
			rule = &c
			break
		}
		if rule == nil do return {host = bytes}
		res.action = rule.action
		res.rule = number
		to_surface := false
		switch rule.action {
		case .Pass: res.host = bytes
		case .Claim: to_surface = true
		case .Observe: res.host = bytes; to_surface = true
		case .Drop:
		case .Remap:
			res.host = remap(t, rule, status, kind, bytes, out)
			to_surface = rule.copy
		}
		if to_surface do res.surface = give(r, here, entry.uid, port, bytes, time_ns)
	}

	if kind == .Note_On && !here {
		if pn := port_notes(r, port, true); pn != nil {
			rec := Note_Route{to = NOTE_SEEN, note = data1, channel = channel}
			if res.host != nil {
				rec.to |= NOTE_HOST
				rec.note = res.host[1]
				rec.channel = res.host[0] & 0x0F
			}
			if res.surface do rec.to |= NOTE_SURFACE
			pn.notes[channel][data1] = rec
		}
	}
	return res
}

// [rt] What the app gets for a Remap rule: a channel message changed, nil
// when its note map drops it.
@(private)
remap :: proc "contextless" (t: ^Table, rule: ^Compiled_Rule, status: u8, kind: abi.Message, bytes: []u8, out: ^[3]u8) -> []u8 {
	if status >= 0xF0 do return bytes // SysEx and system messages have nothing to change
	ch := status & 0x0F if rule.channel == 0 else rule.channel - 1
	n := min(len(bytes), 3)
	out^ = {}
	for i in 0 ..< n do out[i] = bytes[i]
	out[0] = (status & 0xF0) | ch
	#partial switch kind {
	case .Note_Off, .Note_On, .Poly_Pressure, .Control, .Program:
		if rule.note_map >= 0 && n >= 2 {
			m := t.bytes[rule.note_map + int(out[1] & 0x7F)]
			if m == 0xFF do return nil
			out[1] = m
		}
		if rule.value_map >= 0 && n >= 3 && kind != .Note_Off && kind != .Program {
			v := t.bytes[rule.value_map + int(out[2] & 0x7F)]
			if kind == .Note_On && v == 0 do v = 1 // still a note on
			out[2] = v
		}
	case .Channel_Pressure:
		if rule.value_map >= 0 && n >= 2 do out[1] = t.bytes[rule.value_map + int(out[1] & 0x7F)]
	}
	return out[:n]
}

// [rt] The notes kept for a port (taking a free slot if `take`), or nil.
@(private)
port_notes :: proc "contextless" (r: ^Router, port: u32, take: bool) -> ^Port_Notes {
	free_slot: ^Port_Notes
	for &pn in r.notes {
		if pn.used && pn.port == port do return &pn
		if !pn.used && free_slot == nil do free_slot = &pn
	}
	if !take || free_slot == nil do return nil
	free_slot.used = true
	free_slot.port = port
	return free_slot
}

// To the surface thread: `route`'s through the queue, `route_here`'s held
// on that thread for the next update.
@(private)
give :: proc "contextless" (r: ^Router, here: bool, uid, port: u32, bytes: []u8, time_ns: u64) -> bool {
	if !here do return enqueue(r, uid, port, bytes, time_ns)
	context = runtime.default_context()
	m := Held{uid = uid, port = port, time_ns = time_ns}
	m.bytes = make([]u8, len(bytes), r.held.allocator)
	copy(m.bytes, bytes)
	append(&r.held, m)
	return true
}

@(private)
Held :: struct {
	uid, port: u32,
	time_ns:   u64,
	bytes:     []u8,
}

// [rt] Queues a message for the surface thread. False when it doesn't fit.
@(private)
enqueue :: proc "contextless" (r: ^Router, uid, port: u32, bytes: []u8, time_ns: u64) -> bool {
	need := u64(QUEUE_HEADER + align8(len(bytes)))
	head := intrinsics.atomic_load_explicit(&r.head, .Relaxed)
	tail := intrinsics.atomic_load_explicit(&r.tail, .Acquire)
	if need > u64(len(r.queue)) - (head - tail) {
		intrinsics.atomic_add(&r.dropped, 1)
		return false
	}
	header: [QUEUE_HEADER]u8
	(^u32)(&header[0])^ = uid
	(^u32)(&header[4])^ = port
	(^u64)(&header[8])^ = time_ns
	(^u32)(&header[16])^ = u32(len(bytes))
	at := head
	ring_write(r.queue, &at, header[:])
	ring_write(r.queue, &at, bytes)
	intrinsics.atomic_store_explicit(&r.head, head + need, .Release)
	return true
}

@(private)
align8 :: #force_inline proc "contextless" (n: int) -> int { return (n + 7) &~ 7 }

@(private)
ring_write :: proc "contextless" (ring: []u8, at: ^u64, src: []u8) {
	n := u64(len(ring))
	for b in src {
		ring[at^ % n] = b
		at^ += 1
	}
}

@(private)
ring_read :: proc "contextless" (ring: []u8, at: u64, dst: []u8) {
	n := u64(len(ring))
	for i in 0 ..< len(dst) do dst[i] = ring[(at + u64(i)) % n]
}

// Surface thread: the queued messages, in order, to `deliver`.
@(private)
router_drain :: proc(h: ^Host, deliver: proc(h: ^Host, uid, port: u32, bytes: []u8, time_ns: u64)) {
	r := &h.router
	tail := intrinsics.atomic_load_explicit(&r.tail, .Relaxed)
	head := intrinsics.atomic_load_explicit(&r.head, .Acquire)
	for tail < head {
		header: [QUEUE_HEADER]u8
		ring_read(r.queue, tail, header[:])
		uid := (^u32)(&header[0])^
		port := (^u32)(&header[4])^
		time_ns := (^u64)(&header[8])^
		size := int((^u32)(&header[16])^)
		resize(&r.scratch, size)
		ring_read(r.queue, tail + QUEUE_HEADER, r.scratch[:])
		tail += u64(QUEUE_HEADER + align8(size))
		// Freed before delivering: a surface's call may route more (inject).
		intrinsics.atomic_store_explicit(&r.tail, tail, .Release)
		deliver(h, uid, port, r.scratch[:], time_ns)
	}
	// Then what `route_here` held (a delivery may route more here: by index).
	for i := 0; i < len(r.held); i += 1 {
		m := r.held[i]
		deliver(h, m.uid, m.port, m.bytes, m.time_ns)
	}
	for m in r.held do delete(m.bytes, r.held.allocator)
	clear(&r.held)
}

// Surface thread: a table from what the surfaces and detection have now,
// if that changed.
@(private)
publish_routes :: proc(h: ^Host) {
	if !h.routes_dirty do return
	h.routes_dirty = false
	a := h.allocator
	ports := make([dynamic]Table_Port, a)
	rules := make([dynamic]Compiled_Rule, a)
	bytes := make([dynamic]u8, a)
	for s in h.instances {
		switch s.state {
		case .Ready:
		case .Identifying:
			for p in s.ports do if p.input != abi.NO_PORT do append(&ports, Table_Port{port = p.input, uid = s.uid, mode = .Everything})
		case .Active:
			first := len(rules)
			base := len(bytes)
			append(&bytes, ..s.rule_bytes[:])
			for c in s.rules {
				c := c
				c.sysex_at += base
				if c.note_map >= 0 do c.note_map += base
				if c.value_map >= 0 do c.value_map += base
				append(&rules, c)
			}
			for p in s.ports do if p.input != abi.NO_PORT {
				append(&ports, Table_Port{port = p.input, uid = s.uid, mode = .Rules, first = first, count = len(s.rules)})
			}
		}
	}
	for d in h.devices {
		if !probing(d) do continue
		if p, ok := identity_ports(d); ok && p.input != abi.NO_PORT do append(&ports, Table_Port{port = p.input, mode = .Probe})
	}
	t := new(Table, a)
	t^ = {ports = ports[:], rules = rules[:], bytes = bytes[:]}
	router_publish(&h.router, t, a)
}

// Checks a surface's rules and compiles them (their bytes copied).
@(private)
compile_rules :: proc(rules: []abi.Rule, out: ^[dynamic]Compiled_Rule, bytes: ^[dynamic]u8) -> bool {
	clear(out)
	clear(bytes)
	ALL :: abi.Messages{.Note_Off, .Note_On, .Poly_Pressure, .Control, .Program, .Channel_Pressure, .Pitch_Bend, .Sysex, .System}
	for r in rules {
		ok := u32(r.action) <= u32(abi.Rule_Action.Drop) && r.messages <= ALL && r.channels < 1 << 16 && r.channel <= 16 &&
			r.first <= 127 && r.end <= 128 && (r.end == 0 || r.end > r.first) && (r.sysex_size == 0 || r.sysex != nil) &&
			r.flags <= abi.Rule_Flags{.Copy}
		if !ok do return false
		c := Compiled_Rule{
			port = r.port, messages = r.messages, channels = r.channels, first = r.first, end = r.end,
			action = r.action, copy = .Copy in r.flags, channel = u8(r.channel),
			sysex_at = len(bytes), sysex_size = int(r.sysex_size), note_map = -1, value_map = -1,
		}
		if r.sysex_size > 0 do append(bytes, ..r.sysex[:r.sysex_size])
		if r.action == .Remap {
			if r.note_map != nil {
				for v in r.note_map[:128] do if v > 127 && v != 0xFF do return false
				c.note_map = len(bytes)
				append(bytes, ..r.note_map[:128])
			}
			if r.value_map != nil {
				for v in r.value_map[:128] do if v > 127 do return false
				c.value_map = len(bytes)
				append(bytes, ..r.value_map[:128])
			}
		}
		append(out, c)
	}
	return true
}
