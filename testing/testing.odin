/*
A headless host for a surface's tests: the surface made and activated on
pretend ports, MIDI fed in through the claim table as a real host would,
what it sent read back, time stepped by hand, extensions faked.

	import fst "fire-surface/testing"

	th: fst.Test_Host
	fst.start(&th, &my_surface.fsurf_entry, "com.example.grid")
	defer fst.stop(&th)
	r := fst.midi_in(&th, {0x90, 36, 100})   // what the claim table did with it
	testing.expect(t, r.surface && r.host == nil)
	testing.expect(t, fst.sent_has(&th, {0x90, 36, 127}))
	fst.advance(&th, 500)                    // timers, tasks
*/
package fsurf_testing

import "core:strings"

import abi "../abi"
import host "../host"
import kit "../surface"

// A message the surface sent, and on which output.
Sent :: struct {
	port:  u32,
	bytes: []u8,
}

// A headless host running one surface. Keep it in one place (the host
// holds its address).
Test_Host :: struct {
	h:          host.Host,
	lib:        ^host.Library,
	s:          ^host.Instance,
	now:        u64, // ns
	sent:       [dynamic]Sent,
	injected:   [dynamic][]u8,
	notified:   [dynamic]string,
	logged:     [dynamic]string,
	extensions: [dynamic]Extension,
	ports:      [dynamic]host.Port_Assignment,
	daw:        ^Fake_Daw, // `daw_enable`'s, or nil
	virtual:    host.Virtual, // `virtual`'s, opened when first asked
	has_virtual: bool,
}

// An extension the test host offers.
Extension :: struct {
	id:      string,
	version: u32,
	table:   rawptr,
}

// The ids of the pretend ports: input `INPUT_BASE + i` and output
// `OUTPUT_BASE + i` for the descriptor's i-th port spec.
INPUT_BASE :: 1
// (See INPUT_BASE.)
OUTPUT_BASE :: 101

// Makes the surface `surface_id` from an entry linked into the test (a
// surface package's `fsurf_entry`), and activates it on pretend ports
// (`ports` overrides them). Extensions added before `start` are there for
// its init. False if any step fails.
start :: proc(th: ^Test_Host, entry: ^abi.Entry, surface_id: string, ports: []host.Port_Assignment = nil) -> bool {
	setup(th)
	err: host.Library_Error
	th.lib, err = host.library_static(entry)
	if err != .None do return false
	return make_surface(th, surface_id, ports)
}

// As `start`, for a surface in a .fsurf file (watched for hot reload when
// `watch`).
start_file :: proc(th: ^Test_Host, path: string, surface_id: string, ports: []host.Port_Assignment = nil, watch := false) -> (bool, host.Library_Error) {
	setup(th)
	err: host.Library_Error
	if watch {
		th.lib, err = host.library_load_watched(path)
	} else {
		th.lib, err = host.library_load(path)
	}
	if err != .None do return false, err
	return make_surface(th, surface_id, ports), .None
}

@(private)
setup :: proc(th: ^Test_Host) {
	th.sent = make([dynamic]Sent)
	th.injected = make([dynamic][]u8)
	th.notified = make([dynamic]string)
	th.logged = make([dynamic]string)
	th.ports = make([dynamic]host.Port_Assignment)
	host.host_init(&th.h, config(th))
}

@(private)
make_surface :: proc(th: ^Test_Host, surface_id: string, ports: []host.Port_Assignment) -> bool {
	ie: host.Instance_Error
	th.s, ie = host.instance_create(&th.h, th.lib, surface_id)
	if ie != .None do return false
	if ports != nil {
		append(&th.ports, ..ports)
	} else {
		for i in 0 ..< int(th.s.descriptor.port_count) {
			sp := th.s.descriptor.ports[i]
			p := host.Port_Assignment{input = abi.NO_PORT, output = abi.NO_PORT}
			if .Input in sp.flags do p.input = u32(INPUT_BASE + i)
			if .Output in sp.flags do p.output = u32(OUTPUT_BASE + i)
			append(&th.ports, p)
		}
	}
	if !host.instance_activate(th.s, th.ports[:]) do return false
	daw_flush(th)
	return true
}

// Destroys the surface (deactivating it) and frees everything.
stop :: proc(th: ^Test_Host) {
	if th.has_virtual do host.virtual_close(&th.virtual)
	host.host_destroy(&th.h)
	if th.lib != nil do host.library_unload(th.lib)
	clear_sent(th)
	for b in th.injected do delete(b)
	for s in th.notified do delete(s)
	for s in th.logged do delete(s)
	delete(th.sent); delete(th.injected); delete(th.notified); delete(th.logged)
	delete(th.extensions)
	delete(th.ports)
	daw_destroy(th)
}

// Offers an extension (before `start` for the surface's init to see it).
add_extension :: proc(th: ^Test_Host, id: string, version: u32, table: rawptr) {
	if th.extensions == nil do th.extensions = make([dynamic]Extension)
	append(&th.extensions, Extension{id, version, table})
}

// MIDI from the device on a port (its index in the descriptor): through
// the claim table, as a host's MIDI thread would, then a host update so the
// surface handles what it got. What the claim table did.
midi_in :: proc(th: ^Test_Host, bytes: []u8, port := 0) -> host.Route {
	return midi_on(th, th.ports[port].input, bytes)
}

@(private)
midi_on :: proc(th: ^Test_Host, input: u32, bytes: []u8) -> host.Route {
	out: [3]u8
	r := host.route(&th.h, input, bytes, th.now, &out)
	if r.host != nil {
		c := make([]u8, len(r.host), context.temp_allocator)
		copy(c, r.host)
		r.host = c
	}
	host.host_update(&th.h)
	daw_flush(th)
	return r
}

// Moves the clock on and updates the host (timers, the kit's tasks). In
// steps of at most 5 ms, so timers fire as they would.
advance :: proc(th: ^Test_Host, ms: u32) {
	left := u64(ms) * 1_000_000
	for left > 0 {
		step := min(left, 5_000_000)
		th.now += step
		left -= step
		host.host_update(&th.h)
		daw_flush(th)
	}
}

// Unplugs and plugs the device back in: deactivated, then activated on
// the same ports.
reconnect :: proc(th: ^Test_Host) -> bool {
	host.instance_deactivate(th.s)
	return host.instance_activate(th.s, th.ports[:])
}

// Whether the surface sent these bytes (since `clear_sent`).
sent_has :: proc(th: ^Test_Host, bytes: []u8) -> bool {
	for s in th.sent do if string(s.bytes) == string(bytes) do return true
	return false
}

// How many messages it sent (since `clear_sent`).
sent_count :: proc(th: ^Test_Host) -> int { return len(th.sent) }

// Forgets what it sent.
clear_sent :: proc(th: ^Test_Host) {
	for s in th.sent do delete(s.bytes)
	clear(&th.sent)
}

// Whether it notified this text.
notified :: proc(th: ^Test_Host, text: string) -> bool {
	for s in th.notified do if s == text do return true
	return false
}

// The last notification ("" for none).
last_notified :: proc(th: ^Test_Host) -> string {
	return th.notified[len(th.notified) - 1] if len(th.notified) > 0 else ""
}

// The kit's surface, for one made with the kit (its state, its controls).
kit_surface :: proc(th: ^Test_Host) -> ^kit.Control_Surface {
	return (^kit.Control_Surface)(th.s.surface.surface_data)
}

@(private)
config :: proc(th: ^Test_Host) -> host.Host_Config {
	return {
		name = "fsurf test host", vendor = "fire-surface", version = "1",
		user = th,
		send_midi = proc(user: rawptr, s: ^host.Instance, port: u32, bytes: []u8) -> bool {
			th := (^Test_Host)(user)
			c := make([]u8, len(bytes))
			copy(c, bytes)
			append(&th.sent, Sent{port, c})
			return true
		},
		inject_midi = proc(user: rawptr, s: ^host.Instance, port: u32, bytes: []u8) -> bool {
			th := (^Test_Host)(user)
			c := make([]u8, len(bytes))
			copy(c, bytes)
			append(&th.injected, c)
			return true
		},
		get_extension = proc(user: rawptr, s: ^host.Instance, id: string, version: u32) -> rawptr {
			th := (^Test_Host)(user)
			for e in th.extensions do if e.id == id && e.version == version do return e.table
			return nil
		},
		has_extension = proc(user: rawptr, id: string) -> bool {
			th := (^Test_Host)(user)
			for e in th.extensions do if e.id == id do return true
			return false
		},
		log = proc(user: rawptr, s: ^host.Instance, level: abi.Log_Level, message: string) {
			append(&(^Test_Host)(user).logged, strings.clone(message))
		},
		notify = proc(user: rawptr, s: ^host.Instance, text: string) {
			append(&(^Test_Host)(user).notified, strings.clone(text))
		},
		now_ns = proc(user: rawptr) -> u64 { return (^Test_Host)(user).now },
	}
}

// The surface's part of a project, as a host saving one gets it. Free with
// `delete`.
project_save :: proc(th: ^Test_Host) -> ([]u8, bool) {
	return host.instance_project_save(th.s)
}

// Gives the surface its part of a project, as a host opening one does.
project_load :: proc(th: ^Test_Host, data: []u8) -> bool {
	return host.instance_project_load(th.s, data)
}

// The surface's virtual controller (from its fsurf.layout), or nil when it
// has none. The test host's: closed with it.
virtual :: proc(th: ^Test_Host) -> ^host.Virtual {
	if !th.has_virtual {
		v, ok := host.virtual_open(th.s)
		if !ok do return nil
		th.virtual = v
		th.has_virtual = true
	}
	return &th.virtual
}

@(private)
by_name :: proc(th: ^Test_Host, name: string) -> (^host.Virtual, int) {
	v := virtual(th)
	if v == nil do return nil, -1
	return v, host.virtual_find(v, name)
}

@(private)
send_virtual :: proc(th: ^Test_Host, msgs: host.Virtual_Messages) -> (r: host.Route, ok: bool) {
	m := msgs
	for i in 0 ..< m.count do r = midi_on(th, m.port, m.bytes[i][:m.sizes[i]])
	return r, m.count > 0
}

// Presses a control by its layout name ("Play", "Pads 3,0"), as the device
// would send it. What the claim table did with it; false when there's no
// such control (or it isn't pressed).
press :: proc(th: ^Test_Host, name: string, velocity: u8 = 127) -> (host.Route, bool) {
	v, i := by_name(th, name)
	if i < 0 do return {}, false
	return send_virtual(th, host.virtual_press(v, i, velocity))
}

// Releases a control by name.
release :: proc(th: ^Test_Host, name: string) -> (host.Route, bool) {
	v, i := by_name(th, name)
	if i < 0 do return {}, false
	return send_virtual(th, host.virtual_release(v, i))
}

// Presses and releases a control by name.
click :: proc(th: ^Test_Host, name: string) -> bool {
	_, ok := press(th, name)
	if ok do release(th, name)
	return ok
}

// Turns an encoder by name, `steps` up (negative: down).
turn :: proc(th: ^Test_Host, name: string, steps: int) -> (host.Route, bool) {
	v, i := by_name(th, name)
	if i < 0 do return {}, false
	return send_virtual(th, host.virtual_turn(v, i, steps))
}

// Moves a fader by name to `value` (0-1).
move :: proc(th: ^Test_Host, name: string, value: f32) -> (host.Route, bool) {
	v, i := by_name(th, name)
	if i < 0 do return {}, false
	return send_virtual(th, host.virtual_move(v, i, value))
}

// What a control shows, by name (its `ok` false: no such control).
shows :: proc(th: ^Test_Host, name: string) -> (abi.Layout_State, bool) {
	v, i := by_name(th, name)
	if i < 0 do return {}, false
	return host.virtual_state(v, i), true
}

// The device as SVG, as it is now (in the temp allocator).
svg :: proc(th: ^Test_Host) -> string {
	v := virtual(th)
	return host.virtual_svg(v) if v != nil else ""
}
