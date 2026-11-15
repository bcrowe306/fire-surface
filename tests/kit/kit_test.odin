// The kit's machinery, with small surfaces made for each part: owner
// stacks, controls and their events, modes and their behaviours, tasks,
// the claim table, settings and project state.
package kit_test

import "core:fmt"
import "core:strings"
import "core:testing"

import abi "../../abi"
import kit "../../surface"
import fst "../../testing"

// What a test surface's components saw: "component slot kind ...".
State :: struct {
	log:   [dynamic]string,
	comps: map[string]^kit.Component,
	ctl:   map[string]^kit.Control,
	modes: [dynamic]^kit.Modes,
	saved: [dynamic]u8,
}

state :: proc(th: ^fst.Test_Host) -> ^State { return (^State)(fst.kit_surface(th).user) }

state_make :: proc(cs: ^kit.Control_Surface) -> ^State {
	st := new(State)
	st.log = make([dynamic]string)
	st.comps = make(map[string]^kit.Component)
	st.ctl = make(map[string]^kit.Control)
	st.modes = make([dynamic]^kit.Modes)
	st.saved = make([dynamic]u8)
	cs.user = st
	return st
}

state_free :: proc(cs: ^kit.Control_Surface) {
	st := (^State)(cs.user)
	for s in st.log do delete(s)
	delete(st.log); delete(st.comps); delete(st.ctl); delete(st.modes); delete(st.saved)
	free(st)
}

// A component that logs its events, and lights what it owns with `lit`.
logger :: proc(cs: ^kit.Control_Surface, name: string, priority := 0, lit: u8 = 0) -> ^kit.Component {
	c := kit.component_make(cs, name, priority)
	c.user = rawptr(uintptr(lit))
	c.on_event = proc(c: ^kit.Component, e: kit.Event) {
		st := (^State)(c.cs.user)
		line: string
		#partial switch e.kind {
		case .Delta: line = fmt.aprintf("%s %s %v %d", c.name, e.slot, e.kind, e.delta, allocator = c.cs.allocator)
		case .Value, .Pressure: line = fmt.aprintf("%s %s %v %.3f", c.name, e.slot, e.kind, e.value, allocator = c.cs.allocator)
		case .Press: line = fmt.aprintf("%s %s %v %d %d,%d", c.name, e.slot, e.kind, e.velocity, e.row, e.col, allocator = c.cs.allocator)
		case .Sysex: line = fmt.aprintf("%s %s %v %d", c.name, e.slot, e.kind, len(e.bytes), allocator = c.cs.allocator)
		case: line = fmt.aprintf("%s %s %v", c.name, e.slot, e.kind, allocator = c.cs.allocator)
		}
		append(&st.log, line)
	}
	c.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		if lit := u8(uintptr(c.user)); lit > 0 do kit.light_value(control, lit)
	}
	c.on_activate = proc(c: ^kit.Component) { append(&(^State)(c.cs.user).log, fmt.aprintf("%s on", c.name, allocator = c.cs.allocator)) }
	c.on_deactivate = proc(c: ^kit.Component) { append(&(^State)(c.cs.user).log, fmt.aprintf("%s off", c.name, allocator = c.cs.allocator)) }
	(^State)(cs.user).comps[name] = c
	return c
}

// The log since last asked (then cleared), joined by "; ".
take_log :: proc(th: ^fst.Test_Host) -> string {
	st := state(th)
	out := strings.join(st.log[:], "; ", context.temp_allocator)
	for s in st.log do delete(s, fst.kit_surface(th).allocator) // (the surface's)
	clear(&st.log)
	return out
}

ports_main := []kit.Port_Def{{role = "main", inputs = {"T*"}, outputs = {"T*"}}}

// ── The test surfaces ─────────────────────────────────────────────────

owners_spec := kit.Spec{
	id = "t.owners", name = "owners", ports = ports_main, on_destroy = state_free,
	setup = proc(cs: ^kit.Control_Surface) -> bool {
		st := state_make(cs)
		a := kit.button(cs, "A", kit.bind_cc(1))
		st.ctl["A"] = a
		st.ctl["B"] = kit.button(cs, "B", kit.bind_cc(2)) // nobody's
		low := logger(cs, "low", 0, 10)
		high := logger(cs, "high", 1, 20)
		tie := logger(cs, "tie", 0, 30)
		kit.layer_bind(low.layer, "a", a)
		kit.layer_bind(high.layer, "a", a)
		kit.layer_bind(tie.layer, "a", a)
		kit.surface_add(cs, low)
		return true
	},
}

pass_spec := kit.Spec{
	id = "t.pass", name = "pass", ports = ports_main, pass_unowned = true,
	setup = proc(cs: ^kit.Control_Surface) -> bool {
		kit.button(cs, "B", kit.bind_cc(2))
		return true
	},
}

controls_spec := kit.Spec{
	id = "t.controls", name = "controls", ports = ports_main, on_destroy = state_free,
	setup = proc(cs: ^kit.Control_Surface) -> bool {
		state_make(cs)
		c := logger(cs, "c")
		bind :: proc(c: ^kit.Component, ctl: ^kit.Control, slot: string) {
			kit.layer_bind(c.layer, slot, ctl)
			(^State)(c.cs.user).ctl[slot] = ctl
		}
		bind(c, kit.button(cs, "btn", kit.bind_note(10)), "btn")
		bind(c, kit.button(cs, "tog", kit.bind_cc(11), toggle = true), "tog")
		bind(c, kit.pad(cs, "pad", kit.bind_note(12)), "pad")
		bind(c, kit.encoder(cs, "two", kit.bind_cc(20), .Twos_Complement), "two")
		bind(c, kit.encoder(cs, "sign", kit.bind_cc(21), .Signed_Bit), "sign")
		bind(c, kit.encoder(cs, "off", kit.bind_cc(22), .Binary_Offset), "off")
		bind(c, kit.encoder(cs, "abs", kit.bind_cc(23), .Absolute), "abs")
		acc := kit.encoder(cs, "acc", kit.bind_cc(24))
		acc.acceleration = 3
		bind(c, acc, "acc")
		bind(c, kit.touch_encoder(cs, "touch", kit.bind_cc(25), kit.bind_note(90)), "touch")
		bind(c, kit.fader(cs, "f14", kit.bind_cc14(5)), "f14")
		bind(c, kit.pitch_wheel(cs, "pb", 2), "pb")
		bind(c, kit.sysex_control(cs, "sx", {0xF0, 0x7D}), "sx")
		bind(c, kit.sysex_control(cs, "sx2", {0xF0, 0x7D, 0x01}), "sx2")
		m := kit.matrix_make(cs, "grid", 2, 3, proc(r, col: int) -> kit.Binding { return kit.bind_note(u8(60 + r * 3 + col), 1) })
		kit.layer_bind_matrix(c.layer, "grid", m)
		kit.surface_add(cs, c)
		return true
	},
}

modes_spec := kit.Spec{
	id = "t.modes", name = "modes", ports = ports_main, on_destroy = state_free,
	setup = proc(cs: ^kit.Control_Surface) -> bool {
		st := state_make(cs)
		m := kit.modes_make(cs, "M")
		append(&st.modes, m)
		a, b, c, d := logger(cs, "a"), logger(cs, "b"), logger(cs, "c"), logger(cs, "d")
		shared := logger(cs, "shared")
		inner := kit.modes_make(cs, "Inner")
		append(&st.modes, inner)
		kit.modes_add(inner, "i1", {logger(cs, "i1")}, kit.button(cs, "I1", kit.bind_cc(10)))
		kit.modes_add(inner, "i2", {logger(cs, "i2")}, kit.button(cs, "I2", kit.bind_cc(11)))
		kit.modes_add(m, "a", {a, shared}, kit.button(cs, "A", kit.bind_cc(1)), .Latching)
		kit.modes_add(m, "b", {b, shared}, kit.button(cs, "B", kit.bind_cc(2)), .Momentary)
		kit.modes_add(m, "c", {c}, kit.button(cs, "C", kit.bind_cc(3)), .Toggle)
		kit.modes_add(m, "d", {d, &inner.component}, kit.button(cs, "D", kit.bind_cc(4)), .Hybrid)
		kit.modes_cycle_button(m, kit.button(cs, "Next", kit.bind_cc(5)))
		m.on_change = proc(m: ^kit.Modes, from, to: int) {
			append(&(^State)(m.cs.user).log, fmt.aprintf("-> %s", kit.modes_current(m), allocator = m.cs.allocator))
		}
		kit.surface_add(cs, &m.component)
		return true
	},
}

tasks_spec := kit.Spec{
	id = "t.tasks", name = "tasks", ports = ports_main, on_destroy = state_free,
	setup = proc(cs: ^kit.Control_Surface) -> bool {
		state_make(cs)
		owner := logger(cs, "owner")
		kit.layer_bind(owner.layer, "led", kit.button(cs, "LED", kit.bind_cc(7)))
		kit.surface_add(cs, owner)
		return true
	},
	save = proc(cs: ^kit.Control_Surface, out: ^[dynamic]u8) -> bool {
		append(out, ..transmute([]u8)string("state:42"))
		return true
	},
	load = proc(cs: ^kit.Control_Surface, data: []u8) -> bool {
		st := (^State)(cs.user)
		append(&st.saved, ..data)
		return true
	},
}

rules_spec := kit.Spec{
	id = "t.rules", name = "rules", ports = ports_main, on_destroy = state_free,
	setup = proc(cs: ^kit.Control_Surface) -> bool {
		state_make(cs)
		c := logger(cs, "c")
		for i in 0 ..< 8 do kit.layer_bind(c.layer, "row", kit.button(cs, "row", kit.bind_note(u8(20 + i))))
		obs := kit.button(cs, "obs", kit.bind_cc(50))
		kit.layer_bind(c.layer, "obs", obs)
		c.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
			if slot == "obs" do kit.set_route(control, .Observe)
			if slot == "pass" do kit.set_route(control, .Pass)
		}
		kit.layer_bind(c.layer, "pass", kit.button(cs, "pass", kit.bind_cc(51)))
		kit.surface_add(cs, c)
		return true
	},
}

test_library := kit.Library{specs = {&owners_spec, &pass_spec, &controls_spec, &modes_spec, &tasks_spec, &rules_spec}}

test_entry := abi.Entry{
	fsurf_version = abi.VERSION,
	init          = proc "c" (path: cstring) -> bool { return kit.library_init(&test_library) },
	deinit        = proc "c" () { kit.library_deinit(&test_library) },
	get_factory   = proc "c" (id: cstring) -> rawptr { return kit.library_factory(&test_library, id) },
}

start :: proc(t: ^testing.T, th: ^fst.Test_Host, id: string) -> bool {
	return testing.expectf(t, fst.start(th, &test_entry, id), "start %s", id)
}

// ── Owner stacks ──────────────────────────────────────────────────────

@(test)
the_highest_active_layer_owns_a_control :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !start(t, &th, "t.owners") do return
	defer fst.stop(&th)
	st := state(&th)
	testing.expect(t, fst.sent_has(&th, cc(1, 10))) // low's
	fst.midi_in(&th, cc(1, 127))
	fst.midi_in(&th, cc(1, 0))
	testing.expect_value(t, take_log(&th), "low on; low a Press 127 0,0; low a Release")

	fst.clear_sent(&th)
	fst.advance(&th, 1000) // (not a double press)
	kit.component_activate(st.comps["high"])
	testing.expect(t, fst.sent_has(&th, cc(1, 20)))
	fst.midi_in(&th, cc(1, 127))
	kit.component_activate(st.comps["tie"]) // the same priority as low, later: under high still
	testing.expect(t, kit.owns(st.comps["high"], st.ctl["A"]))
	fst.midi_in(&th, cc(1, 0)) // the release goes where its press went
	testing.expect_value(t, take_log(&th), "high on; high a Press 127 0,0; tie on; high a Release")

	fst.clear_sent(&th)
	kit.component_deactivate(st.comps["high"]) // back to the next down (tie: later than low), redrawn
	testing.expect(t, kit.owns(st.comps["tie"], st.ctl["A"]))
	testing.expect(t, fst.sent_has(&th, cc(1, 30)))
	kit.component_deactivate(st.comps["tie"])
	testing.expect(t, fst.sent_has(&th, cc(1, 10)))
	kit.component_deactivate(st.comps["low"]) // nobody's: dark
	testing.expect(t, fst.sent_has(&th, cc(1, 0)))
	take_log(&th)
	r := fst.midi_in(&th, cc(1, 127)) // still the surface's, but nobody hears it
	testing.expect(t, r.surface && r.host == nil)
	testing.expect_value(t, take_log(&th), "")
	r = fst.midi_in(&th, cc(2, 127))
	testing.expect(t, r.surface && r.host == nil)
}

@(test)
pass_unowned_lets_the_host_have_them :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !start(t, &th, "t.pass") do return
	defer fst.stop(&th)
	r := fst.midi_in(&th, cc(2, 127))
	testing.expect(t, !r.surface && r.host != nil)
}

// ── Controls ──────────────────────────────────────────────────────────

@(test)
buttons_press_hold_double_press_and_toggle :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !start(t, &th, "t.controls") do return
	defer fst.stop(&th)
	take_log(&th)
	fst.midi_in(&th, nt(0x90, 10, 90))
	fst.advance(&th, 520)
	fst.midi_in(&th, nt(0x80, 10, 0))
	testing.expect_value(t, take_log(&th), "c btn Press 90 0,0; c btn Hold; c btn Release")
	fst.advance(&th, 1000)
	fst.midi_in(&th, nt(0x90, 10, 90))
	fst.midi_in(&th, nt(0x90, 10, 0)) // velocity 0: off
	fst.advance(&th, 100)
	fst.midi_in(&th, nt(0x90, 10, 90))
	fst.midi_in(&th, nt(0x90, 10, 90)) // a repeat while held: ignored
	fst.midi_in(&th, nt(0x80, 10, 0))
	fst.advance(&th, 600) // no hold: released
	testing.expect_value(t, take_log(&th), "c btn Press 90 0,0; c btn Release; c btn Press 90 0,0; c btn Double_Press; c btn Release")
	tog := state(&th).ctl["tog"]
	fst.midi_in(&th, cc(11, 127))
	testing.expect(t, tog.on)
	fst.midi_in(&th, cc(11, 0))
	fst.midi_in(&th, cc(11, 127))
	testing.expect(t, !tog.on)
}

@(test)
encoders_decode_their_steps :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !start(t, &th, "t.controls") do return
	defer fst.stop(&th)
	take_log(&th)
	for m in ([][2]u8{{20, 1}, {20, 127}, {20, 70}, {21, 3}, {21, 67}, {22, 66}, {22, 60}, {22, 64}, {23, 32}}) do fst.midi_in(&th, cc(m[0], m[1]))
	testing.expect_value(t, take_log(&th), "c two Delta 1; c two Delta -1; c two Delta -58; c sign Delta 3; c sign Delta -3; c off Delta 2; c off Delta -4; c abs Value 0.252")
	// Acceleration: fast steps are multiplied.
	fst.midi_in(&th, cc(24, 1))
	fst.advance(&th, 10)
	fst.midi_in(&th, cc(24, 1))
	fst.advance(&th, 200)
	fst.midi_in(&th, cc(24, 1))
	testing.expect_value(t, take_log(&th), "c acc Delta 1; c acc Delta 3; c acc Delta 1")
	// A touch encoder: its touch.
	fst.midi_in(&th, nt(0x90, 90, 127))
	fst.midi_in(&th, cc(25, 1))
	fst.midi_in(&th, nt(0x80, 90, 0))
	testing.expect_value(t, take_log(&th), "c touch Touch; c touch Delta 1; c touch Untouch")
}

@(test)
faders_wheels_pads_sysex_and_matrices :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !start(t, &th, "t.controls") do return
	defer fst.stop(&th)
	take_log(&th)
	fst.midi_in(&th, cc(5, 127))
	fst.midi_in(&th, cc(37, 127)) // the LSB: all 14 bits
	fst.midi_in(&th, {0xE2, 0x00, 0x40})
	fst.midi_in(&th, nt(0x90, 12, 64))
	fst.midi_in(&th, nt(0xA0, 12, 100))
	fst.midi_in(&th, {0xF0, 0x7D, 0x01, 0x02, 0xF7}) // the longer prefix wins
	fst.midi_in(&th, {0xF0, 0x7D, 0x05, 0xF7})
	fst.midi_in(&th, nt(0x91, 65, 33)) // row 1, column 2
	testing.expect_value(t, take_log(&th), "c f14 Value 0.992; c f14 Value 1.000; c pb Value 0.500; c pad Press 64 0,0; c pad Pressure 0.787; c sx2 Sysex 5; c sx Sysex 4; c grid Press 33 1,2")
	r := fst.midi_in(&th, {0xF0, 0x7E, 0x00, 0xF7}) // not its: the host's
	testing.expect(t, r.host != nil && !r.surface)
}

@(test)
lights_are_sent_only_when_they_change :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !start(t, &th, "t.controls") do return
	defer fst.stop(&th)
	btn := state(&th).ctl["btn"]
	fst.clear_sent(&th)
	kit.light_value(btn, 5)
	kit.light_value(btn, 5)
	kit.light_value(btn, 5, channel = 2)
	testing.expect_value(t, fst.sent_count(&th), 2)
	testing.expect(t, fst.sent_has(&th, nt(0x90, 10, 5)) && fst.sent_has(&th, nt(0x92, 10, 5)))
	kit.light_reset(btn)
	kit.light_value(btn, 5, channel = 2)
	testing.expect_value(t, fst.sent_count(&th), 3)
	f := state(&th).ctl["f14"]
	kit.set_position(f, 1)
	testing.expect(t, fst.sent_has(&th, cc(5, 127)) && fst.sent_has(&th, cc(37, 127)))
	kit.set_position(state(&th).ctl["pb"], 0.5)
	testing.expect(t, fst.sent_has(&th, {0xE2, 0x00, 0x40}))
}

// ── Modes ─────────────────────────────────────────────────────────────

@(test)
modes_switch_by_their_behaviours :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !start(t, &th, "t.modes") do return
	defer fst.stop(&th)
	m := state(&th).modes[0]
	testing.expect_value(t, take_log(&th), "a on; shared on; -> a")
	testing.expect(t, fst.sent_has(&th, cc(1, 127)) && fst.sent_has(&th, cc(2, 0)))

	fst.midi_in(&th, cc(2, 127)) // Momentary: b while held (shared stays)
	testing.expect_value(t, take_log(&th), "a off; b on; -> b")
	fst.midi_in(&th, cc(2, 0))
	testing.expect_value(t, take_log(&th), "b off; a on; -> a")

	tap(&th, 3) // Toggle: c, then back
	tap(&th, 3)
	testing.expect_value(t, take_log(&th), "a off; shared off; c on; -> c; c off; a on; shared on; -> a")

	tap(&th, 4) // Hybrid tapped: latched. Nested: Inner starts in i1.
	testing.expect_value(t, modes_current(m), "d")
	testing.expect_value(t, take_log(&th), "a off; shared off; d on; i1 on; -> d")
	tap(&th, 11) // the inner Modes' own buttons, while d is
	testing.expect_value(t, take_log(&th), "i1 off; i2 on")
	fst.midi_in(&th, cc(1, 127)) // Latching a
	fst.midi_in(&th, cc(1, 0))
	fst.midi_in(&th, cc(4, 127)) // Hybrid held: momentary
	fst.advance(&th, 350)
	fst.midi_in(&th, cc(4, 0))
	testing.expect_value(t, modes_current(m), "a")
	take_log(&th)
	r := fst.midi_in(&th, cc(11, 127)) // the inner buttons are nobody's now
	testing.expect(t, r.surface)
	testing.expect_value(t, take_log(&th), "")
	fst.midi_in(&th, cc(11, 0))
	tap(&th, 5) // the cycle button
	testing.expect_value(t, modes_current(m), "b")
	tap(&th, 4) // d again: the inner one remembers i2
	testing.expect(t, strings.contains(take_log(&th), "i2 on"))
}

modes_current :: proc(m: ^kit.Modes) -> string { return kit.modes_current(m) }

// ── Tasks ─────────────────────────────────────────────────────────────

@(test)
tasks_run_on_time_and_go_with_their_owner :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !start(t, &th, "t.tasks") do return
	defer fst.stop(&th)
	cs := fst.kit_surface(&th)
	owner := state(&th).comps["owner"]
	Count :: struct { once, every, owned: int }
	n: Count
	kit.task_after(cs, 50, proc(d: rawptr) { (^Count)(d).once += 1 }, &n)
	every := kit.task_every(cs, 20, proc(d: rawptr) { (^Count)(d).every += 1 }, &n)
	kit.task_every(cs, 10, proc(d: rawptr) { (^Count)(d).owned += 1 }, &n, owner)
	fst.advance(&th, 45)
	testing.expect_value(t, n, Count{0, 2, 4})
	fst.advance(&th, 10)
	testing.expect_value(t, n.once, 1)
	kit.task_cancel(cs, every)
	kit.component_deactivate(owner) // its tasks go with it
	before := n
	fst.advance(&th, 100)
	testing.expect_value(t, n, before)
	fst.clear_sent(&th)
	kit.send_sequence(cs, {{0xF0, 1, 0xF7}, {0xF0, 2, 0xF7}, {0xF0, 3, 0xF7}}, 50)
	testing.expect_value(t, fst.sent_count(&th), 1)
	fst.advance(&th, 55)
	testing.expect_value(t, fst.sent_count(&th), 2)
	fst.advance(&th, 50)
	testing.expect_value(t, fst.sent_count(&th), 3)
	// Blinking while its owner is active.
	kit.component_activate(owner)
	led := kit.layer_control(owner.layer, "led")
	fst.clear_sent(&th)
	kit.blink(led, "Blink.On", "Blink.Off", 100, owner)
	fst.advance(&th, 305)
	testing.expect_value(t, fst.sent_count(&th), 4) // on, off, on, off
	kit.component_deactivate(owner)
	fst.clear_sent(&th)
	fst.advance(&th, 300)
	testing.expect_value(t, fst.sent_count(&th), 0)
}

@(test)
a_surface_keeps_its_project_state_and_settings :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !start(t, &th, "t.tasks") do return
	defer fst.stop(&th)
	data, ok := fst.project_save(&th)
	testing.expect(t, ok)
	testing.expect_value(t, string(data), "state:42")
	delete(data)
	testing.expect(t, fst.project_load(&th, transmute([]u8)string("hello")))
	testing.expect_value(t, string(state(&th).saved[:]), "hello")
	cs := fst.kit_surface(&th)
	testing.expect(t, kit.settings_set(cs, transmute([]u8)string("abc")))
	got := kit.settings_get(cs)
	defer delete(got)
	testing.expect_value(t, string(got), "abc")
}

// ── The claim table ───────────────────────────────────────────────────

@(test)
neighbouring_controls_share_a_rule :: proc(t: ^testing.T) {
	th: fst.Test_Host
	if !start(t, &th, "t.rules") do return
	defer fst.stop(&th)
	// Eight notes in a row: one rule; an observed CC; a passed one (no rule).
	testing.expect_value(t, len(th.s.rules), 2)
	r := fst.midi_in(&th, nt(0x90, 23, 1))
	testing.expect(t, r.surface && r.host == nil)
	r = fst.midi_in(&th, nt(0x90, 28, 1)) // past the row
	testing.expect(t, !r.surface && r.host != nil)
	r = fst.midi_in(&th, cc(50, 1))
	testing.expect(t, r.surface && r.host != nil)
	r = fst.midi_in(&th, cc(51, 1))
	testing.expect(t, !r.surface && r.host != nil)
	// The same table again isn't sent again.
	rules_before := th.s.rules
	fst.kit_surface(&th).rules_dirty = true
	fst.midi_in(&th, cc(1, 1))
	testing.expect(t, raw_data(th.s.rules) == raw_data(rules_before))
}
