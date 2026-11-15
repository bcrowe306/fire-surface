package surface

import "core:slice"

import abi "../abi"

/*
The claim table, worked out from the controls: an owned control's
messages go where its route says (Claim by default; Observe, Remap, Pass);
an unowned one's are the surface's (or the host's, with
Spec.pass_unowned). Neighbouring controls that go the same way are one
rule with a range; remapped ones of a channel share one rule and its note
map. Sent only when it changed.
*/

@(private)
Entry :: struct {
	port:     u32,
	messages: abi.Messages,
	channel:  u8,
	number:   u8,
	ranged:   bool, // has a data byte 1 to match
	action:   abi.Rule_Action,
	sysex:    []u8,
	// Remap
	to:       u8,
	to_channel: u8,
	velocity: ^[128]u8,
}

@(private)
publish_rules :: proc(cs: ^Control_Surface) {
	cs.rules_dirty = false
	entries := make([dynamic]Entry, context.temp_allocator)
	for c in cs.controls {
		route := c.route if top_owner(c) != nil else (Route_Mode.Pass if cs.spec.pass_unowned else Route_Mode.Claim)
		if route == .Pass do continue
		add := proc(cs: ^Control_Surface, entries: ^[dynamic]Entry, b: Binding, c: ^Control, route: Route_Mode, touch := false) {
			if b.port < 0 || b.port >= len(cs.ports) do return
			port := cs.ports[b.port].input
			if port == abi.NO_PORT do return
			e := Entry{port = port, channel = b.channel, number = b.number, ranged = true}
			switch route {
			case .Claim, .Pass: e.action = .Claim
			case .Observe: e.action = .Observe
			case .Remap:
				if touch {
					e.action = .Claim
				} else {
					e.action = .Remap
					e.to = c.remap_note
					e.to_channel = c.remap_channel
					e.velocity = c.velocity_map
				}
			}
			switch b.kind {
			case .None: return
			case .Note: e.messages = abi.MESSAGES_NOTES
			case .CC: e.messages = {.Control}
			case .CC14:
				e.messages = {.Control}
				append(entries, e)
				e.number = b.number + 32
				if e.action == .Remap do e.to = c.remap_note + 32
			case .Pitch_Bend: e.messages = {.Pitch_Bend}; e.ranged = false
			case .Channel_Pressure: e.messages = {.Channel_Pressure}; e.ranged = false
			case .Program: e.messages = {.Program}; e.ranged = false
			case .Sysex: e.messages = {.Sysex}; e.ranged = false; e.sysex = b.sysex; e.channel = 0
			}
			append(entries, e)
		}
		add(cs, &entries, c.binding, c, route)
		if c.touch.kind != .None do add(cs, &entries, c.touch, c, route, true)
	}

	rules := make([dynamic]abi.Rule, context.temp_allocator)
	// Claims and observes first (ranges), so a remap's note map never
	// takes a note another control claims.
	plain := make([dynamic]Entry, context.temp_allocator)
	remaps := make([dynamic]Entry, context.temp_allocator)
	for e in entries do append(&remaps if e.action == .Remap else &plain, e)
	slice.sort_by(plain[:], proc(a, b: Entry) -> bool {
		if a.port != b.port do return a.port < b.port
		if transmute(u32)a.messages != transmute(u32)b.messages do return transmute(u32)a.messages < transmute(u32)b.messages
		if a.channel != b.channel do return a.channel < b.channel
		if a.action != b.action do return a.action < b.action
		return a.number < b.number
	})
	for i := 0; i < len(plain); {
		e := plain[i]
		r := abi.Rule{port = e.port, messages = e.messages, channels = 1 << e.channel, action = e.action}
		if e.messages == {.Sysex} {
			r.channels = 0
			r.sysex = raw_data(e.sysex)
			r.sysex_size = u32(len(e.sysex))
			append(&rules, r)
			i += 1
			continue
		}
		j := i + 1
		if e.ranged {
			for j < len(plain) {
				n := plain[j]
				if n.port != e.port || n.messages != e.messages || n.channel != e.channel || n.action != e.action || !n.ranged do break
				if int(n.number) > int(plain[j - 1].number) + 1 do break
				j += 1
			}
			r.first = e.number
			r.end = plain[j - 1].number + 1 if plain[j - 1].number < 127 else 0
		} else {
			for j < len(plain) && plain[j].port == e.port && plain[j].messages == e.messages && plain[j].channel == e.channel && plain[j].action == e.action do j += 1
		}
		append(&rules, r)
		i = j
	}
	// Remaps: one rule a port, kind, channel, target channel and velocity map.
	slice.sort_by(remaps[:], proc(a, b: Entry) -> bool {
		if a.port != b.port do return a.port < b.port
		if transmute(u32)a.messages != transmute(u32)b.messages do return transmute(u32)a.messages < transmute(u32)b.messages
		if a.channel != b.channel do return a.channel < b.channel
		if a.to_channel != b.to_channel do return a.to_channel < b.to_channel
		if uintptr(a.velocity) != uintptr(b.velocity) do return uintptr(a.velocity) < uintptr(b.velocity)
		return a.number < b.number
	})
	for i := 0; i < len(remaps); {
		e := remaps[i]
		j := i
		note_map := new([128]u8, context.temp_allocator)
		for k in 0 ..< 128 do note_map[k] = u8(k)
		for j < len(remaps) {
			n := remaps[j]
			if n.port != e.port || n.messages != e.messages || n.channel != e.channel || n.to_channel != e.to_channel || n.velocity != e.velocity do break
			note_map[n.number] = n.to
			j += 1
		}
		last := remaps[j - 1].number
		r := abi.Rule{
			port = e.port, messages = e.messages, channels = 1 << e.channel, first = e.number, end = last + 1 if last < 127 else 0,
			action = .Remap, flags = {.Copy}, note_map = &note_map[0], channel = u32(e.to_channel),
		}
		if e.velocity != nil do r.value_map = &e.velocity[0]
		append(&rules, r)
		i = j
	}

	// Only when it changed.
	key := make([dynamic]u8, context.temp_allocator)
	for r in rules {
		x := r
		x.sysex = nil
		x.note_map = nil
		x.value_map = nil
		raw := transmute([size_of(abi.Rule)]u8)x
		append(&key, ..raw[:])
		if r.sysex != nil do append(&key, ..r.sysex[:r.sysex_size])
		if r.note_map != nil do append(&key, ..r.note_map[:128])
		if r.value_map != nil do append(&key, ..r.value_map[:128])
	}
	if len(key) == len(cs.last_rules) && string(key[:]) == string(cs.last_rules[:]) && len(cs.last_rules) > 0 do return
	if len(rules) == 0 && cs.rules_sent && len(cs.last_rules) == 0 do return
	clear(&cs.last_rules)
	append(&cs.last_rules, ..key[:])
	cs.rules_sent = true
	cs.host.set_rules(cs.host, raw_data(rules), u32(len(rules)))
}
