// Detection (port names, identity requests, surfaces' own handshakes, hot
// plug, assigning by hand) and the claim table (`route`), with surfaces
// linked into the test (`library_static`) and the examples.
package host_test

import "base:runtime"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:thread"

import abi "../../abi"
import host "../../host"

// ── A library of test surfaces, linked in ─────────────────────────────

// What a test surface saw. Its surface_data.
Probe_Surface :: struct {
	surface:     abi.Surface,
	host:        ^abi.Host,
	got:         [dynamic][]u8, // MIDI given to on_midi
	activations: int,
	out:         u32,
}

keys_in := [?]cstring{"Keys*", nil}
grid_in := [?]cstring{"*Grid*", nil}
shake_in := [?]cstring{"Shake*", nil}
duo_main := [?]cstring{"Duo Live*", nil}
duo_user := [?]cstring{"Duo User*", nil}
mac_only := [?]cstring{"mac:Apple Only*", "win:Windows Only*", "linux:Linux Only*", nil}

spec :: proc "contextless" (names: []cstring, role: cstring = "main", flags := abi.Port_Flags{.Input, .Output}) -> abi.Port_Spec {
	return {struct_size = size_of(abi.Port_Spec), role = role, flags = flags, input_names = raw_data(names), output_names = raw_data(names)}
}

keys_ports := [1]abi.Port_Spec{}
grid_ports := [1]abi.Port_Spec{}
shake_ports := [1]abi.Port_Spec{}
duo_ports := [2]abi.Port_Spec{}
os_ports := [1]abi.Port_Spec{}

// A family's reply: F0 7E <any> 06 02 00 20 29 ...; a model's: and 69 01.
family_match := [?]u8{0xF0, 0x7E, 0x00, 0x06, 0x02, 0x00, 0x20, 0x29}
family_mask := [?]u8{0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}
model_match := [?]u8{0xF0, 0x7E, 0x00, 0x06, 0x02, 0x00, 0x20, 0x29, 0x69, 0x01}
model_mask := [?]u8{0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}
family_identity := abi.Identity{}
model_identity := abi.Identity{}
surface_identity := abi.Identity{struct_size = size_of(abi.Identity), method = .Surface}
duo_identity := abi.Identity{}

descriptors := [?]abi.Descriptor{
	{id = "test.keys"},   // by names
	{id = "test.family"}, // a request: any of the family
	{id = "test.model"},  // a request: that model (more specific)
	{id = "test.shake"},  // its own handshake
	{id = "test.duo"},    // two port pairs, the second optional; identified on "user"... by names
	{id = "test.os"},     // names per system
	{id = "test.needs"},  // needs an extension
}

needs := [?]cstring{"fsurf.daw", nil}

@(init)
init_descriptors :: proc "contextless" () {
	keys_ports[0] = spec(keys_in[:])
	grid_ports[0] = spec(grid_in[:])
	shake_ports[0] = spec(shake_in[:])
	duo_ports[0] = spec(duo_main[:])
	duo_ports[1] = spec(duo_user[:], "user", {.Input, .Output, .Optional})
	os_ports[0] = spec(mac_only[:])
	family_identity = {struct_size = size_of(abi.Identity), method = .Request, match = raw_data(family_match[:]), mask = raw_data(family_mask[:]), match_size = len(family_match)}
	model_identity = {struct_size = size_of(abi.Identity), method = .Request, match = raw_data(model_match[:]), mask = raw_data(model_mask[:]), match_size = len(model_match), retries = 1, retry_ms = 100}
	duo_identity = {struct_size = size_of(abi.Identity), method = .Names, port_role = "user"}
	ports := [?][]abi.Port_Spec{keys_ports[:], grid_ports[:], grid_ports[:], shake_ports[:], duo_ports[:], os_ports[:], keys_ports[:]}
	idents := [?]^abi.Identity{nil, &family_identity, &model_identity, &surface_identity, &duo_identity, nil, nil}
	for &d, i in descriptors {
		d.struct_size = size_of(abi.Descriptor)
		d.fsurf_version = abi.VERSION
		d.name = d.id
		d.vendor = "tests"
		d.version = "1"
		d.ports = raw_data(ports[i])
		d.port_count = u32(len(ports[i]))
		d.identity = idents[i]
	}
	descriptors[6].required_extensions = raw_data(needs[:])
}

probe_ctx :: proc "contextless" (s: ^abi.Surface) -> runtime.Context {
	p := (^Probe_Surface)(s.surface_data)
	return (^host.Instance)(p.host.host_data).host.ctx
}

probe_factory := abi.Surface_Factory{
	count = proc "c" (f: ^abi.Surface_Factory) -> u32 { return len(descriptors) },
	get_descriptor = proc "c" (f: ^abi.Surface_Factory, i: u32) -> ^abi.Descriptor {
		return &descriptors[i] if i < len(descriptors) else nil
	},
	create = proc "c" (f: ^abi.Surface_Factory, h: ^abi.Host, id: cstring) -> ^abi.Surface {
		context = (^host.Instance)(h.host_data).host.ctx
		desc: ^abi.Descriptor
		for &d in descriptors do if d.id == id do desc = &d
		if desc == nil do return nil
		p := new(Probe_Surface)
		p.host = h
		p.out = abi.NO_PORT
		p.got = make([dynamic][]u8)
		p.surface = {
			struct_size = size_of(abi.Surface), desc = desc, surface_data = p,
			init = proc "c" (s: ^abi.Surface) -> bool { return true },
			destroy = proc "c" (s: ^abi.Surface) {
				context = probe_ctx(s)
				p := (^Probe_Surface)(s.surface_data)
				for b in p.got do delete(b)
				delete(p.got)
				free(p)
			},
			// The handshake: sends F0 7D 10 F7; F0 7D 11 F7 back is yes, 12 no.
			identify = proc "c" (s: ^abi.Surface, ports: [^]abi.Port, count: u32) {
				p := (^Probe_Surface)(s.surface_data)
				hi := [4]u8{0xF0, 0x7D, 0x10, 0xF7}
				p.host.send_midi(p.host, ports[0].output, &hi[0], 4)
			},
			activate = proc "c" (s: ^abi.Surface, ports: [^]abi.Port, count: u32) -> bool {
				p := (^Probe_Surface)(s.surface_data)
				p.activations += 1
				p.out = ports[0].output
				return true
			},
			deactivate = proc "c" (s: ^abi.Surface) { (^Probe_Surface)(s.surface_data).out = abi.NO_PORT },
			on_midi = proc "c" (s: ^abi.Surface, port: u32, b: [^]u8, size: u32, time_ns: u64) {
				context = probe_ctx(s)
				p := (^Probe_Surface)(s.surface_data)
				msg := make([]u8, size)
				copy(msg, b[:size])
				append(&p.got, msg)
				inst := (^host.Instance)(p.host.host_data)
				if inst.state == .Identifying && size == 4 && b[0] == 0xF0 && b[1] == 0x7D {
					if b[2] == 0x11 do p.host.identified(p.host, true)
					if b[2] == 0x12 do p.host.identified(p.host, false)
				}
			},
		}
		return &p.surface
	},
}

probe_entry := abi.Entry{
	fsurf_version = abi.VERSION,
	init = proc "c" (path: cstring) -> bool { return true },
	deinit = proc "c" () {},
	get_factory = proc "c" (id: cstring) -> rawptr { return &probe_factory if id == abi.SURFACE_FACTORY_ID else nil },
}

probe_of :: proc(s: ^host.Instance) -> ^Probe_Surface { return (^Probe_Surface)(s.surface.surface_data) }

// Whether the surface got exactly these messages since last asked.
expect_got :: proc(t: ^testing.T, s: ^host.Instance, want: [][]u8, loc := #caller_location) {
	p := probe_of(s)
	ok := len(p.got) == len(want)
	if ok do for m, i in p.got do if string(m) != string(want[i]) do ok = false
	testing.expectf(t, ok, "the surface got %v, want %v", p.got[:], want, loc = loc)
	for b in p.got do delete(b)
	clear(&p.got)
}

expect_bytes :: proc(t: ^testing.T, got, want: []u8, loc := #caller_location) {
	testing.expectf(t, string(got) == string(want), "got %v, want %v", got, want, loc = loc)
}

clear_sent :: proc(f: ^Fake) {
	for b in f.sent do delete(b)
	clear(&f.sent)
}

// A host with the test library added, and a surface on `test.keys` made
// by hand and active on input 1 / output 2.
Rig :: struct {
	f:   Fake,
	h:   host.Host,
	lib: ^host.Library,
	s:   ^host.Instance,
}

rig_init :: proc(r: ^Rig, activate := true, allocator := context.allocator) {
	host.host_init(&r.h, fake_config(&r.f), allocator)
	r.lib, _ = host.library_static(&probe_entry)
	if activate {
		r.s, _ = host.instance_create(&r.h, r.lib, "test.keys")
		host.instance_activate(r.s, {{input = 1, output = 2}})
	}
}

rig_destroy :: proc(r: ^Rig) {
	host.host_destroy(&r.h)
	host.library_unload(r.lib)
	fake_destroy(&r.f)
}

set_rules :: proc(s: ^host.Instance, rules: []abi.Rule) -> bool {
	return s.c_host.set_rules(&s.c_host, raw_data(rules), u32(len(rules)))
}

// `host.route`, with what the app got copied (it may be in `out`).
route :: proc(r: ^Rig, port: u32, bytes: []u8) -> (host.Route, int) {
	out: [3]u8
	res := host.route(&r.h, port, bytes, 0, &out)
	if res.host != nil {
		c := make([]u8, len(res.host), context.temp_allocator)
		copy(c, res.host)
		res.host = c
	}
	return res, 0
}

// ── Port names and pairing ────────────────────────────────────────────

@(test)
names_match_with_stars_any_case_and_per_system :: proc(t: ^testing.T) {
	testing.expect(t, host.name_matches("Push 2*Live Port*", "Ableton Push 2 Live Port") == false) // starts with "Push 2"
	testing.expect(t, host.name_matches("*Push 2*Live Port*", "Ableton Push 2 Live Port"))
	testing.expect(t, host.name_matches("launchpad*", "LAUNCHPAD X LPX MIDI"))
	testing.expect(t, host.name_matches("*", ""))
	testing.expect(t, host.name_matches("a*b*c", "aXXbYYc"))
	testing.expect(t, !host.name_matches("a*b*c", "aXXbYY"))
	testing.expect(t, host.name_matches("MPK*", "MPK mini 3"))
	testing.expect(t, !host.name_matches("MPK", "MPK mini 3")) // the whole name
	when ODIN_OS == .Darwin {
		testing.expect(t, host.name_matches("mac:Apple*", "Apple Port"))
		testing.expect(t, !host.name_matches("win:Apple*", "Apple Port"))
	} else when ODIN_OS == .Windows {
		testing.expect(t, host.name_matches("WIN:Apple*", "Apple Port"))
		testing.expect(t, !host.name_matches("mac:Apple*", "Apple Port"))
	} else {
		testing.expect(t, host.name_matches("linux:Apple*", "Apple Port"))
		testing.expect(t, !host.name_matches("mac:Apple*", "Apple Port"))
	}
}

@(test)
ports_pair_into_controllers :: proc(t: ^testing.T) {
	// Two of a two-role model; outputs listed in another order. The second
	// has no user port (optional).
	ins := []host.Port_Info{{1, "Duo Live 1"}, {2, "Duo User 1"}, {3, "Duo Live 2"}, {9, "Other"}}
	outs := []host.Port_Info{{13, "Duo Live 2"}, {11, "Duo Live 1"}, {12, "Duo User 1"}}
	ms := host.find_matches(&descriptors[4], ins, outs)
	defer host.matches_destroy(ms)
	if !testing.expect_value(t, len(ms), 2) do return
	testing.expect_value(t, ms[0].index, 0)
	testing.expect_value(t, ms[0].ports[0], host.Port_Assignment{1, 11, "Duo Live 1", "Duo Live 1"}) // the same name
	testing.expect_value(t, ms[0].ports[1], host.Port_Assignment{2, 12, "Duo User 1", "Duo User 1"})
	testing.expect_value(t, ms[1].ports[0], host.Port_Assignment{3, 13, "Duo Live 2", "Duo Live 2"})
	testing.expect_value(t, ms[1].ports[1], host.Port_Assignment{abi.NO_PORT, abi.NO_PORT, "", ""})

	// A required pair missing: no controller. An input without an output isn't a pair.
	ms2 := host.find_matches(&descriptors[0], {{1, "Keys A"}}, {})
	defer host.matches_destroy(ms2)
	testing.expect_value(t, len(ms2), 0)
	// Other names: paired in order.
	ms3 := host.find_matches(&descriptors[0], {{1, "Keys In"}, {2, "Keys In 2"}}, {{5, "Keys Out"}, {6, "Keys Out 2"}})
	defer host.matches_destroy(ms3)
	testing.expect_value(t, len(ms3), 2)
	if len(ms3) == 2 do testing.expect_value(t, ms3[1].ports[0].output, 6)

	// Names for another system don't match here.
	here := "Apple Only" when ODIN_OS == .Darwin else "Windows Only" when ODIN_OS == .Windows else "Linux Only"
	ms4 := host.find_matches(&descriptors[5], {{1, here}, {2, "Apple Only X" when ODIN_OS != .Darwin else "Linux Only X"}}, {{3, here}})
	defer host.matches_destroy(ms4)
	testing.expect_value(t, len(ms4), 1)
}

@(test)
identity_replies_match_under_their_mask :: proc(t: ^testing.T) {
	testing.expect(t, host.identity_matches(&family_identity, {0xF0, 0x7E, 0x05, 0x06, 0x02, 0x00, 0x20, 0x29, 0x69, 0x01, 0xF7}))
	testing.expect(t, host.identity_matches(&model_identity, {0xF0, 0x7E, 0x7F, 0x06, 0x02, 0x00, 0x20, 0x29, 0x69, 0x01, 0xF7}))
	testing.expect(t, !host.identity_matches(&model_identity, {0xF0, 0x7E, 0x7F, 0x06, 0x02, 0x00, 0x20, 0x29, 0x13, 0x01, 0xF7}))
	testing.expect(t, !host.identity_matches(&family_identity, {0xF0, 0x7E, 0x00, 0x06, 0x02, 0x00})) // too short
}

// ── The claim table ───────────────────────────────────────────────────

@(test)
the_claim_table_sends_each_message_where_its_rule_says :: proc(t: ^testing.T) {
	r: Rig
	rig_init(&r)
	defer rig_destroy(&r)
	s := r.s

	// No rules yet: everything passes, nothing reaches the surface.
	res, _ := route(&r, 1, {0x90, 40, 100})
	expect_bytes(t, res.host, {0x90, 40, 100})
	testing.expect(t, !res.surface)

	up := [128]u8{}
	for &v, i in up do v = u8(min(i + 12, 127))
	soft := [128]u8{}
	for &v, i in soft do v = u8(i / 2) // velocity halved (a note on's 1 at least)
	sx := [3]u8{0xF0, 0x00, 0x21}
	rules := []abi.Rule{
		{port = abi.NO_PORT, messages = abi.MESSAGES_NOTES, first = 36, end = 52, action = .Claim},
		{port = abi.NO_PORT, messages = {.Control}, channels = 1 << 0, first = 1, end = 11, action = .Observe},
		{port = abi.NO_PORT, messages = abi.MESSAGES_NOTES, first = 60, end = 72, action = .Remap, note_map = &up[0], value_map = &soft[0], channel = 2, flags = {.Copy}},
		{port = abi.NO_PORT, messages = {.Pitch_Bend}, action = .Drop},
		{port = abi.NO_PORT, messages = {.Sysex}, sysex = &sx[0], sysex_size = 3, action = .Claim},
		{port = 7, messages = {.Control}, action = .Claim}, // another port: never this one
	}
	testing.expect(t, set_rules(s, rules))

	Case :: struct { msg: []u8, host: []u8, surface: bool, action: abi.Rule_Action }
	cases := []Case{
		{{0x90, 36, 100}, nil, true, .Claim},             // a pad
		{{0x80, 36, 0}, nil, true, .Claim},               // its note off
		{{0x93, 51, 1}, nil, true, .Claim},               // any channel, to 51
		{{0x90, 52, 9}, {0x90, 52, 9}, false, .Pass},     // past the range: no rule
		{{0xB0, 5, 64}, {0xB0, 5, 64}, true, .Observe},   // CC 5 on channel 1: both
		{{0xB1, 5, 64}, {0xB1, 5, 64}, false, .Pass},     // channel 2: not that rule
		{{0xB0, 11, 64}, {0xB0, 11, 64}, false, .Pass},   // CC 11: past its end
		{{0x90, 60, 100}, {0x91, 72, 50}, true, .Remap},  // up an octave, channel 2, softer, and a copy
		{{0x90, 61, 1}, {0x91, 73, 1}, true, .Remap},     // a note on stays one (velocity 1, not 0)
		{{0xE0, 0, 64}, nil, false, .Drop},               // pitch bend: nowhere
		{{0xF0, 0x00, 0x21, 0x09, 0xF7}, nil, true, .Claim}, // its SysEx
		{{0xF0, 0x00, 0x22, 0xF7}, {0xF0, 0x00, 0x22, 0xF7}, false, .Pass}, // another's
		{{0xF8}, {0xF8}, false, .Pass},                   // clock
	}
	want_got := make([dynamic][]u8, context.temp_allocator)
	for c in cases {
		res2, _ := route(&r, 1, c.msg)
		testing.expectf(t, string(res2.host) == string(c.host), "%v: the host got %v, want %v", c.msg, res2.host, c.host)
		testing.expectf(t, res2.surface == c.surface, "%v: the surface %v, want %v", c.msg, res2.surface, c.surface)
		testing.expectf(t, res2.action == c.action, "%v: %v, want %v", c.msg, res2.action, c.action)
		if c.surface do append(&want_got, c.msg)
	}
	// Not on the surface's thread yet: its update gives them, in order.
	expect_got(t, s, {})
	host.host_update(&r.h)
	expect_got(t, s, want_got[:])

	// Another port: no surface there.
	res3, _ := route(&r, 9, {0x90, 36, 100})
	testing.expect(t, !res3.surface && res3.host != nil)

	// Deactivated: its rules are gone with it.
	host.instance_deactivate(s)
	res4, _ := route(&r, 1, {0x90, 40, 100})
	testing.expect(t, !res4.surface && res4.host != nil)
}

@(test)
a_note_off_goes_where_its_note_on_went :: proc(t: ^testing.T) {
	r: Rig
	rig_init(&r)
	defer rig_destroy(&r)
	s := r.s
	up := [128]u8{}
	for &v, i in up do v = u8(min(i + 12, 127))
	set_rules(s, {{port = abi.NO_PORT, messages = abi.MESSAGES_NOTES, first = 36, end = 37, action = .Claim}, {port = abi.NO_PORT, messages = abi.MESSAGES_NOTES, first = 60, end = 61, action = .Remap, note_map = &up[0]}})
	res, _ := route(&r, 1, {0x90, 36, 100}) // claimed
	testing.expect(t, res.surface && res.host == nil)
	res, _ = route(&r, 1, {0x90, 60, 100}) // remapped to 72
	expect_bytes(t, res.host, {0x90, 72, 100})
	res, _ = route(&r, 1, {0x91, 60, 100}) // channel 2: its own note
	expect_bytes(t, res.host, {0x91, 72, 100})

	set_rules(s, {}) // a new mode: everything passes now
	res, _ = route(&r, 1, {0xA0, 36, 20}) // its pressure, then its note off: still the surface's
	testing.expect(t, res.surface && res.host == nil)
	res, _ = route(&r, 1, {0x80, 36, 0})
	testing.expect(t, res.surface && res.host == nil)
	res, _ = route(&r, 1, {0x90, 60, 0}) // a note on of velocity 0 is a note off: to 72, as its note on
	expect_bytes(t, res.host, {0x90, 72, 0})
	testing.expect_value(t, res.action, abi.Rule_Action.Remap)
	res, _ = route(&r, 1, {0x81, 60, 0}) // even with the surface gone
	host.instance_deactivate(s)
	_ = res
	res, _ = route(&r, 1, {0x80, 36, 0}) // its note off was had: now the rules (none) judge it
	expect_bytes(t, res.host, {0x80, 36, 0})
	host.host_update(&r.h)
}

@(test)
a_surface_whose_note_off_was_routed_away_after_deactivating_stays_sane :: proc(t: ^testing.T) {
	r: Rig
	rig_init(&r)
	defer rig_destroy(&r)
	up := [128]u8{}
	for &v, i in up do v = u8(min(i + 12, 127))
	set_rules(r.s, {{port = abi.NO_PORT, messages = abi.MESSAGES_NOTES, action = .Remap, note_map = &up[0]}})
	route(&r, 1, {0x90, 60, 100})
	host.instance_deactivate(r.s) // no table for the port now
	res, _ := route(&r, 1, {0x80, 60, 0})
	expect_bytes(t, res.host, {0x80, 72, 0}) // no stuck 72 in the host
}

@(test)
malformed_rules_are_refused :: proc(t: ^testing.T) {
	r: Rig
	rig_init(&r)
	defer rig_destroy(&r)
	testing.expect(t, set_rules(r.s, {{port = abi.NO_PORT, action = .Claim}}))
	bad_map := [128]u8{}
	bad_map[3] = 200
	bads := []abi.Rule{
		{action = abi.Rule_Action(9)},
		{first = 10, end = 10},
		{end = 200},
		{channels = 1 << 16},
		{channel = 17},
		{sysex_size = 2},
		{action = .Remap, note_map = &bad_map[0]},
		{action = .Remap, value_map = &bad_map[0]},
	}
	for b in bads do testing.expectf(t, !set_rules(r.s, {b}), "%v accepted", b)
	res, _ := route(&r, 1, {0x90, 1, 1}) // the last good table still applies
	testing.expect(t, res.surface)
	testing.expect(t, !r.s.c_host.set_rules(&r.s.c_host, nil, 3))
	host.host_update(&r.h)
}

@(test)
a_full_queue_drops_and_counts :: proc(t: ^testing.T) {
	r: Rig
	rig_init(&r)
	defer rig_destroy(&r)
	set_rules(r.s, {{port = abi.NO_PORT, action = .Claim}})
	big := make([]u8, 1000)
	defer delete(big)
	big[0] = 0xF0
	big[999] = 0xF7
	kept := 0
	for _ in 0 ..< 100 {
		res, _ := route(&r, 1, big)
		if res.surface do kept += 1
	}
	testing.expect(t, kept > 0 && kept < 100)
	testing.expect_value(t, host.messages_dropped(&r.h), u64(100 - kept))
	host.host_update(&r.h)
	testing.expect_value(t, len(probe_of(r.s).got), kept)
	expect_got_count_clear(r.s)
	res, _ := route(&r, 1, big) // room again
	testing.expect(t, res.surface)
	host.host_update(&r.h)
	expect_got_count_clear(r.s)
}

expect_got_count_clear :: proc(s: ^host.Instance) {
	p := probe_of(s)
	for b in p.got do delete(b)
	clear(&p.got)
}

@(test)
a_surface_hands_on_what_it_claimed :: proc(t: ^testing.T) {
	r: Rig
	rig_init(&r)
	defer rig_destroy(&r)
	Got :: struct { port: u32, n: int }
	got: Got
	r.h.config.user = &got
	r.h.config.inject_midi = proc(user: rawptr, s: ^host.Instance, port: u32, bytes: []u8) -> bool {
		g := (^Got)(user)
		g.port = port
		g.n += len(bytes)
		return true
	}
	b := [3]u8{0x90, 1, 1}
	testing.expect(t, r.s.c_host.inject_midi(&r.s.c_host, 1, &b[0], 3))
	testing.expect(t, !r.s.c_host.inject_midi(&r.s.c_host, 2, &b[0], 3)) // its output, not an input
	testing.expect_value(t, got, Got{1, 3})
	r.h.config.user = &r.f
}

// An allocator that never frees until the end, and fills what is freed
// with 0xDD: reading a table after it was freed reads garbage pointers
// (and crashes), so freeing one `route` is reading can't go unnoticed.
Poison :: struct {
	backing: mem.Allocator,
	held:    [dynamic]rawptr,
}

POISON_HEADER :: 16

poison_allocator :: proc(p: ^Poison) -> mem.Allocator {
	return {data = p, procedure = proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
		p := (^Poison)(data)
		hold :: proc(p: ^Poison, old: rawptr) {
			if old == nil do return
			base := rawptr(uintptr(old) - POISON_HEADER)
			mem.set(old, 0xDD, (^int)(base)^)
			append(&p.held, base)
		}
		switch mode {
		case .Alloc, .Alloc_Non_Zeroed:
			raw, err := mem.alloc_bytes(size + POISON_HEADER, POISON_HEADER, p.backing)
			if err != nil do return nil, err
			(^int)(raw_data(raw))^ = size
			return raw[POISON_HEADER:], nil
		case .Free:
			hold(p, old_memory)
			return nil, nil
		case .Resize, .Resize_Non_Zeroed:
			raw, err := mem.alloc_bytes(size + POISON_HEADER, POISON_HEADER, p.backing)
			if err != nil do return nil, err
			(^int)(raw_data(raw))^ = size
			if old_memory != nil do mem.copy(&raw[POISON_HEADER], old_memory, min(size, old_size))
			hold(p, old_memory)
			return raw[POISON_HEADER:], nil
		case .Free_All, .Query_Info:
			return nil, .Mode_Not_Implemented
		case .Query_Features:
			set := (^mem.Allocator_Mode_Set)(old_memory)
			if set != nil do set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
			return nil, nil
		}
		return nil, nil
	}}
}

@(test)
rules_change_while_another_thread_routes :: proc(t: ^testing.T) {
	poison := Poison{backing = context.allocator}
	poison.held = make([dynamic]rawptr, context.allocator)
	defer {
		for b in poison.held do free(b, poison.backing)
		delete(poison.held)
	}
	r: Rig
	rig_init(&r, allocator = poison_allocator(&poison))
	defer rig_destroy(&r)
	Shared :: struct { h: ^host.Host, stop: bool, routed: int }
	sh := Shared{h = &r.h}
	th := thread.create_and_start_with_data(&sh, proc(data: rawptr) {
		sh := (^Shared)(data)
		out: [3]u8
		for !sync.atomic_load(&sh.stop) {
			for n in 0 ..< 128 {
				host.route(sh.h, 1, {0x90, u8(n), 100}, 0, &out)
				host.route(sh.h, 1, {0x80, u8(n), 0}, 0, &out)
			}
			sync.atomic_add(&sh.routed, 1)
		}
	})
	up := [128]u8{}
	for &v, i in up do v = u8(127 - i)
	// Until the other thread has routed a good while, whatever the timing.
	for i := 0; i < 2000 || sync.atomic_load(&sh.routed) < 500; i += 1 {
		switch i % 3 {
		case 0: set_rules(r.s, {{port = abi.NO_PORT, first = u8(i % 100), end = u8(i % 100 + 20), action = .Claim}})
		case 1: set_rules(r.s, {{port = abi.NO_PORT, action = .Remap, note_map = &up[0]}, {port = abi.NO_PORT, action = .Observe}})
		case 2: set_rules(r.s, {})
		}
		if i % 50 == 0 do host.host_update(&r.h)
	}
	sync.atomic_store(&sh.stop, true)
	thread.join(th)
	thread.destroy(th)
	host.host_update(&r.h)
	expect_got_count_clear(r.s)
	testing.expect(t, sync.atomic_load(&sh.routed) >= 500)
}

// ── Detection ─────────────────────────────────────────────────────────

devices_of :: proc(h: ^host.Host, id: string) -> []^host.Device {
	out := make([dynamic]^host.Device, context.temp_allocator)
	for d in host.host_devices(h) do if string(d.descriptor.id) == id do append(&out, d)
	return out[:]
}

@(test)
a_controller_found_by_its_names_comes_and_goes_with_its_ports :: proc(t: ^testing.T) {
	r: Rig
	rig_init(&r, activate = false)
	defer rig_destroy(&r)
	host.host_set_auto_detect(&r.h, "test.needs", false) // (it has keys' names too; tested below)
	host.host_add_library(&r.h, r.lib)
	testing.expect_value(t, len(host.host_devices(&r.h)), 0)

	ins := []host.Port_Info{{1, "Keys In"}, {2, "Unrelated"}}
	outs := []host.Port_Info{{4, "Keys In"}}
	host.host_set_ports(&r.h, ins, outs)
	ds := devices_of(&r.h, "test.keys")
	if !testing.expect_value(t, len(ds), 1) do return
	d := ds[0]
	testing.expect_value(t, d.state, host.Device_State.Active)
	s := d.instance
	testing.expect_value(t, probe_of(s).activations, 1)
	testing.expect_value(t, probe_of(s).out, 4)

	host.host_set_ports(&r.h, {{2, "Unrelated"}}, {}) // unplugged
	testing.expect_value(t, d.state, host.Device_State.Gone)
	testing.expect(t, d.instance == s) // kept
	testing.expect_value(t, s.state, host.Instance_State.Ready)

	host.host_set_ports(&r.h, {{7, "Keys In"}}, {{8, "Keys In"}}) // back, on other ids
	testing.expect_value(t, d.state, host.Device_State.Active)
	testing.expect(t, d.instance == s)
	testing.expect_value(t, probe_of(s).activations, 2)
	testing.expect_value(t, probe_of(s).out, 8)

	// A second of the same: its own surface.
	host.host_set_ports(&r.h, {{7, "Keys In"}, {9, "Keys In 2"}}, {{8, "Keys In"}, {10, "Keys In 2"}})
	ds = devices_of(&r.h, "test.keys")
	if testing.expect_value(t, len(ds), 2) {
		testing.expect_value(t, ds[1].index, 1)
		testing.expect_value(t, ds[1].state, host.Device_State.Active)
		testing.expect(t, ds[1].instance != s)
	}

	// Off: forgotten. On: found again.
	host.host_set_auto_detect(&r.h, "test.keys", false)
	testing.expect_value(t, len(devices_of(&r.h, "test.keys")), 0)
	testing.expect(t, !host.host_auto_detect(&r.h, "test.keys"))
	host.host_set_auto_detect(&r.h, "test.keys", true)
	testing.expect_value(t, len(devices_of(&r.h, "test.keys")), 2)
}

@(test)
a_surface_needing_an_extension_the_host_lacks_isnt_offered :: proc(t: ^testing.T) {
	r: Rig
	rig_init(&r, activate = false)
	defer rig_destroy(&r)
	host.host_set_auto_detect(&r.h, "test.keys", false)
	host.host_add_library(&r.h, r.lib)
	host.host_set_ports(&r.h, {{1, "Keys"}}, {{2, "Keys"}})
	testing.expect_value(t, len(devices_of(&r.h, "test.needs")), 0)
	r.h.config.has_extension = proc(user: rawptr, id: string) -> bool { return id == "fsurf.daw" }
	host.host_set_ports(&r.h, {{1, "Keys"}}, {{2, "Keys"}})
	testing.expect_value(t, len(devices_of(&r.h, "test.needs")), 1)
}

@(test)
an_identity_reply_picks_the_most_specific_surface :: proc(t: ^testing.T) {
	r: Rig
	rig_init(&r, activate = false)
	defer rig_destroy(&r)
	host.host_add_library(&r.h, r.lib)
	host.host_set_ports(&r.h, {{1, "My Grid"}}, {{2, "My Grid"}})
	fam := devices_of(&r.h, "test.family")[0]
	mod := devices_of(&r.h, "test.model")[0]
	testing.expect_value(t, fam.state, host.Device_State.Identifying)
	testing.expect_value(t, mod.state, host.Device_State.Identifying)
	// The universal request, once each, on the output.
	testing.expect_value(t, len(r.f.sent), 2)
	for m in r.f.sent do expect_bytes(t, m, {0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7})
	clear_sent(&r.f)

	// The device answers: its reply reaches the app too (detection only looks).
	res, _ := route(&r, 1, {0xF0, 0x7E, 0x01, 0x06, 0x02, 0x00, 0x20, 0x29, 0x69, 0x01, 0x00, 0xF7})
	testing.expect(t, res.surface && res.host != nil)
	host.host_update(&r.h)
	testing.expect_value(t, mod.state, host.Device_State.Active)
	testing.expect_value(t, fam.state, host.Device_State.Passed_Over)
	testing.expect(t, fam.instance == nil)
	testing.expect(t, mod.instance != nil)
	// No more probes once identified.
	r.f.now += 1_000_000_000
	host.host_update(&r.h)
	testing.expect_value(t, len(r.f.sent), 0)
}

@(test)
a_family_member_is_taken_when_the_model_doesnt_match :: proc(t: ^testing.T) {
	r: Rig
	rig_init(&r, activate = false)
	defer rig_destroy(&r)
	host.host_add_library(&r.h, r.lib)
	host.host_set_ports(&r.h, {{1, "Grid"}}, {{2, "Grid"}})
	fam := devices_of(&r.h, "test.family")[0]
	mod := devices_of(&r.h, "test.model")[0]
	route(&r, 1, {0xF0, 0x7E, 0x01, 0x06, 0x02, 0x00, 0x20, 0x29, 0x13, 0x01, 0x00, 0xF7}) // another model
	host.host_update(&r.h)
	testing.expect_value(t, fam.state, host.Device_State.Waiting) // the model may still answer
	// The model's retries: one more request after 100 ms, then 100 ms to answer.
	clear_sent(&r.f)
	r.f.now = 100_000_000
	host.host_update(&r.h)
	testing.expect_value(t, len(r.f.sent), 1)
	r.f.now = 200_000_000
	host.host_update(&r.h)
	testing.expect_value(t, mod.state, host.Device_State.Not_Identified)
	testing.expect_value(t, fam.state, host.Device_State.Active)
}

@(test)
a_device_that_never_answers_isnt_identified :: proc(t: ^testing.T) {
	r: Rig
	rig_init(&r, activate = false)
	defer rig_destroy(&r)
	host.host_set_auto_detect(&r.h, "test.model", false)
	host.host_add_library(&r.h, r.lib)
	host.host_set_ports(&r.h, {{1, "Grid"}}, {{2, "Grid"}})
	fam := devices_of(&r.h, "test.family")[0]
	for i in 1 ..= 4 { // the default: 2 retries, 300 ms apart
		r.f.now = u64(i) * 300_000_000
		host.host_update(&r.h)
	}
	testing.expect_value(t, len(r.f.sent), 3)
	testing.expect_value(t, fam.state, host.Device_State.Not_Identified)
	// Plugged in again: asked again.
	host.host_set_ports(&r.h, {}, {})
	testing.expect_value(t, len(devices_of(&r.h, "test.family")), 0)
	host.host_set_ports(&r.h, {{1, "Grid"}}, {{2, "Grid"}})
	testing.expect_value(t, devices_of(&r.h, "test.family")[0].state, host.Device_State.Identifying)
}

@(test)
a_surface_can_identify_its_device_itself :: proc(t: ^testing.T) {
	for answer in ([2]u8{0x11, 0x12}) {
		r: Rig
		rig_init(&r, activate = false)
		host.host_add_library(&r.h, r.lib)
		host.host_set_ports(&r.h, {{1, "Shake It"}}, {{2, "Shake It"}})
		d := devices_of(&r.h, "test.shake")[0]
		testing.expect_value(t, d.state, host.Device_State.Identifying)
		s := d.instance
		expect_sent(t, &r.f, {0xF0, 0x7D, 0x10, 0xF7}) // its handshake
		// While it identifies, it sees everything on its ports, and so does the app.
		res, _ := route(&r, 1, {0x90, 1, 1})
		testing.expect(t, res.surface && res.host != nil)
		route(&r, 1, {0xF0, 0x7D, answer, 0xF7})
		host.host_update(&r.h)
		if answer == 0x11 {
			testing.expect_value(t, d.state, host.Device_State.Active)
			testing.expect(t, d.instance == s)
			testing.expect_value(t, probe_of(s).activations, 1)
			expect_got(t, s, {{0x90, 1, 1}, {0xF0, 0x7D, 0x11, 0xF7}})
			res, _ = route(&r, 1, {0x90, 1, 1}) // active, no rules: it gets nothing now
			testing.expect(t, !res.surface)
		} else {
			testing.expect_value(t, d.state, host.Device_State.Not_Identified)
			testing.expect(t, d.instance == nil)
		}
		rig_destroy(&r)
	}
}

@(test)
a_surface_assigned_by_hand_takes_the_ports :: proc(t: ^testing.T) {
	r: Rig
	rig_init(&r, activate = false)
	defer rig_destroy(&r)
	host.host_set_auto_detect(&r.h, "test.needs", false)
	host.host_add_library(&r.h, r.lib)
	host.host_set_ports(&r.h, {{1, "Keys"}}, {{2, "Keys"}})
	auto := devices_of(&r.h, "test.keys")[0]
	testing.expect_value(t, auto.state, host.Device_State.Active)

	d, err := host.host_assign(&r.h, r.lib, "test.shake", {{1, 2, "Keys", "Keys"}})
	testing.expect_value(t, err, host.Instance_Error.None)
	testing.expect(t, d.manual)
	testing.expect_value(t, d.state, host.Device_State.Active)
	testing.expect_value(t, auto.state, host.Device_State.Passed_Over)
	testing.expect_value(t, auto.instance.state, host.Instance_State.Ready)

	host.host_set_ports(&r.h, {}, {}) // unplugged: it waits for its ports
	testing.expect_value(t, d.state, host.Device_State.Gone)
	host.host_set_ports(&r.h, {{5, "Keys"}}, {{6, "Keys"}})
	testing.expect_value(t, d.state, host.Device_State.Active)
	testing.expect_value(t, d.ports[0].input, 5)
	keys := devices_of(&r.h, "test.keys") // found again, but the ports are taken
	if testing.expect_value(t, len(keys), 1) do testing.expect_value(t, keys[0].state, host.Device_State.Passed_Over)

	host.host_unassign(&r.h, d)
	keys = devices_of(&r.h, "test.keys")
	if testing.expect_value(t, len(keys), 1) do testing.expect_value(t, keys[0].state, host.Device_State.Active)

	// On a grid still being asked who it is: it doesn't wait.
	host.host_set_ports(&r.h, {{5, "Keys"}, {7, "Grid"}}, {{6, "Keys"}, {8, "Grid"}})
	g, _ := host.host_assign(&r.h, r.lib, "test.keys", {{7, 8, "Grid", "Grid"}})
	testing.expect_value(t, g.state, host.Device_State.Active)
	testing.expect_value(t, devices_of(&r.h, "test.family")[0].state, host.Device_State.Identifying)

	_, e := host.host_assign(&r.h, r.lib, "test.nothing", {})
	testing.expect_value(t, e, host.Instance_Error.No_Such_Surface)
}

@(test)
removing_a_library_stops_its_surfaces :: proc(t: ^testing.T) {
	r: Rig
	rig_init(&r, activate = false)
	defer rig_destroy(&r)
	host.host_add_library(&r.h, r.lib)
	host.host_set_ports(&r.h, {{1, "Keys"}}, {{2, "Keys"}})
	testing.expect(t, len(host.host_devices(&r.h)) > 0)
	host.host_remove_library(&r.h, r.lib)
	testing.expect_value(t, len(host.host_devices(&r.h)), 0)
	testing.expect_value(t, r.lib.instances, 0)
}

// ── The examples, found and routed ────────────────────────────────────

@(test)
the_examples_are_found_identified_and_claim_their_pads :: proc(t: ^testing.T) {
	for ex in EXAMPLES {
		lib, err := host.library_load(example_path(ex.file))
		if !testing.expectf(t, err == .None, "%s: %v", ex.file, err) do continue
		f: Fake
		h: host.Host
		host.host_init(&h, fake_config(&f))
		host.host_add_library(&h, lib)
		host.host_set_ports(&h, {{1, "Hello In"}}, {{2, "Hello In"}})
		expect_sent(t, &f, {0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7})
		out: [3]u8
		host.route(&h, 1, {0xF0, 0x7E, 0x00, 0x06, 0x02, 0x7D, 0x01, 0xF7}, 0, &out)
		host.host_update(&h)
		d := host.host_devices(&h)[0]
		testing.expect_value(t, d.state, host.Device_State.Active)
		expect_sent(t, &f, {0xF0, 0x7D, 0x01, 0xF7}) // its hello

		res := host.route(&h, 1, {0x90, 40, 90}, 0, &out) // a pad: its
		testing.expect(t, res.surface && res.host == nil)
		res = host.route(&h, 1, {0x90, 60, 90}, 0, &out) // a key: the app's
		testing.expect(t, !res.surface && res.host != nil)
		res = host.route(&h, 1, {0xF0, 0x7D, 0x05, 0xF7}, 0, &out) // its SysEx
		testing.expect(t, res.surface && res.host == nil)
		testing.expect_value(t, len(f.sent), 0)
		host.host_update(&h) // on its thread: the pad lit, the SysEx noticed
		expect_sent(t, &f, {0x90, 40, 127})
		testing.expect_value(t, len(f.notified), 1)

		host.host_set_ports(&h, {}, {}) // unplugged: deactivated (its goodbye can't be sent, but it tries)
		testing.expect_value(t, d.state, host.Device_State.Gone)
		clear_sent(&f)
		host.host_destroy(&h)
		testing.expect(t, host.library_unload(lib))
		fake_destroy(&f)
	}
}

// The kit example as a loaded library (its own runtime, apart from the
// host's): found, identified, its hello, its pads remapped.
@(test)
a_kit_surface_loads_from_its_library :: proc(t: ^testing.T) {
	lib, err := host.library_load(example_path("grid_odin.fsurf"))
	if !testing.expectf(t, err == .None, "grid_odin.fsurf: %v (./scripts/build.sh)", err) do return
	f: Fake
	h: host.Host
	host.host_init(&h, fake_config(&f))
	host.host_add_library(&h, lib)
	host.host_set_ports(&h, {{1, "Grid MIDI"}}, {{2, "Grid MIDI"}})
	expect_sent(t, &f, {0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7})
	out: [3]u8
	host.route(&h, 1, {0xF0, 0x7E, 0x00, 0x06, 0x02, 0x7D, 0x20, 0x01, 0xF7}, 0, &out)
	host.host_update(&h)
	d := host.host_devices(&h)[0]
	testing.expect_value(t, d.state, host.Device_State.Active)
	testing.expect(t, len(f.sent) > 16) // its hello and lights
	if len(f.sent) > 0 do expect_bytes(t, f.sent[0], {0xF0, 0x7D, 0x20, 0x01, 0xF7})
	clear_sent(&f)
	r := host.route(&h, 1, {0x99, 37, 100}, 0, &out) // a pad: drum 37, and a copy to light it
	testing.expect_value(t, r.action, abi.Rule_Action.Remap)
	testing.expect(t, r.surface)
	host.host_update(&h)
	if testing.expect_value(t, len(f.sent), 1) do expect_bytes(t, f.sent[0], {0x99, 37, 127})
	clear_sent(&f)
	host.host_destroy(&h)
	testing.expect(t, host.library_unload(lib))
	fake_destroy(&f)
}

// A surface that requires fsurf.daw is offered only by a host that has it.
@(test)
a_surface_requiring_the_daw_extension_waits_for_a_host_with_it :: proc(t: ^testing.T) {
	lib, err := host.library_load(example_path("keys_odin.fsurf"))
	if !testing.expectf(t, err == .None, "keys_odin.fsurf: %v", err) do return
	f: Fake
	h: host.Host
	host.host_init(&h, fake_config(&f))
	host.host_add_library(&h, lib)
	host.host_set_ports(&h, {{1, "Keys 25 MIDI"}}, {{2, "Keys 25 MIDI"}})
	testing.expect_value(t, len(host.host_devices(&h)), 0)
	h.config.has_extension = proc(user: rawptr, id: string) -> bool { return id == abi.DAW_ID }
	host.host_set_ports(&h, {{1, "Keys 25 MIDI"}}, {{2, "Keys 25 MIDI"}})
	if testing.expect_value(t, len(host.host_devices(&h)), 1) do testing.expect_value(t, host.host_devices(&h)[0].state, host.Device_State.Active)
	r := host.route(&h, 1, {0x90, 60, 100}, 0, nil) // a key: the host's
	testing.expect(t, r.host != nil && !r.surface)
	clear_sent(&f)
	host.host_destroy(&h)
	testing.expect(t, host.library_unload(lib))
	fake_destroy(&f)
}

// SysEx routed on the surface thread (`route_here`), as a host that
// assembles it there does: identity replies, a surface's own SysEx, the
// monitor.
@(test)
sysex_routed_on_the_surface_thread_reaches_detection_and_surfaces :: proc(t: ^testing.T) {
	lib, err := host.library_load(example_path("hello_c.fsurf"))
	if !testing.expect_value(t, err, host.Library_Error.None) do return
	f: Fake
	h: host.Host
	host.host_init(&h, fake_config(&f))
	host.host_add_library(&h, lib)
	host.monitor_enable(&h, true)
	host.host_set_ports(&h, {{1, "Hello"}}, {{2, "Hello"}})
	out: [3]u8
	r := host.route_here(&h, 1, {0xF0, 0x7E, 0x00, 0x06, 0x02, 0x7D, 0xF7}, 0, &out) // its identity reply
	testing.expect(t, r.surface && r.host != nil) // (detection looks; the app gets it too)
	host.host_update(&h)
	d := host.host_devices(&h)[0]
	testing.expect_value(t, d.state, host.Device_State.Active)
	r = host.route_here(&h, 1, {0xF0, 0x7D, 0x09, 0xF7}, 0, &out) // its own SysEx: claimed
	testing.expect(t, r.surface && r.host == nil)
	n := len(f.notified)
	host.host_update(&h)
	testing.expect_value(t, len(f.notified), n + 1) // it noticed
	found := false
	for e in host.monitor_entries(&h) do if e.kind == .In && e.bytes[2] == 0x09 do found = e.action == .Claim
	testing.expect(t, found)
	clear_sent(&f)
	host.host_destroy(&h)
	testing.expect(t, host.library_unload(lib))
	fake_destroy(&f)
}
