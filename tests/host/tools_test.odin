// The developer tools in the host library: the MIDI monitor, the virtual
// controller (from a surface's fsurf.layout) and hot reload, on the
// examples' libraries.
package host_test

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import abi "../../abi"
import host "../../host"

// The grid example, made and activated by hand on input 1 / output 2.
grid_up :: proc(t: ^testing.T, f: ^Fake, h: ^host.Host) -> (^host.Library, ^host.Instance, bool) {
	lib, err := host.library_load(example_path("grid_odin.fsurf"))
	if !testing.expectf(t, err == .None, "grid_odin.fsurf: %v", err) do return nil, nil, false
	host.host_init(h, fake_config(f))
	s, ie := host.instance_create(h, lib, "org.fsurf.example.grid")
	if !testing.expect_value(t, ie, host.Instance_Error.None) do return lib, nil, false
	testing.expect(t, host.instance_activate(s, {{1, 2, "Grid", "Grid"}}))
	return lib, s, true
}

grid_down :: proc(f: ^Fake, h: ^host.Host, lib: ^host.Library) {
	host.host_destroy(h)
	host.library_unload(lib)
	fake_destroy(f)
}

@(test)
the_monitor_says_what_became_of_each_message :: proc(t: ^testing.T) {
	f: Fake
	h: host.Host
	lib, _, ok := grid_up(t, &f, &h)
	defer grid_down(&f, &h, lib)
	if !ok do return
	out: [3]u8
	host.route(&h, 1, {0x99, 40, 100}, 0, &out) // off: not recorded
	host.host_update(&h)
	testing.expect_value(t, len(host.monitor_entries(&h)), 0)

	host.monitor_enable(&h, true)
	clear_sent(&f)
	host.route(&h, 1, {0x99, 36, 100}, 5, &out) // a pad: remapped, and the surface lights it
	host.route(&h, 1, {0x90, 60, 100}, 6, &out) // a key: nobody's
	host.host_update(&h)
	es := host.monitor_entries(&h)
	if !testing.expect_value(t, len(es), 3) do return
	testing.expect_value(t, es[0].kind, host.Monitor_Kind.In)
	testing.expect_value(t, es[0].action, abi.Rule_Action.Remap)
	testing.expect(t, es[0].rule > 0 && es[0].to_host && es[0].to_surface)
	testing.expect_value(t, es[0].control, "Pads 3,0")
	testing.expect_value(t, es[0].owner, "Drum")
	testing.expect_value(t, es[1].action, abi.Rule_Action.Pass)
	testing.expect_value(t, es[1].control, "")
	testing.expect_value(t, es[2].kind, host.Monitor_Kind.Out) // its light, for the hit
	testing.expect_value(t, es[2].control, "Pads 3,0")
	testing.expect_value(t, es[2].port, 2)
	line := host.monitor_line(es[0])
	testing.expectf(t, strings.has_prefix(line, "in  1  99 24 64  remap (rule ") && strings.has_suffix(line, "Grid (kit example) / Pads 3,0 (Drum)"), "%s", line)
	testing.expect_value(t, host.monitor_line(es[1]), "in  1  90 3C 64  pass  Grid (kit example)")

	// More between updates than it keeps: counted, not recorded.
	host.monitor_clear(&h)
	for _ in 0 ..< host.MONITOR_CAPACITY + 10 do host.route(&h, 9, {0xF8}, 7, &out)
	testing.expect_value(t, host.monitor_lost(&h), 10)
	host.host_update(&h)
	testing.expect_value(t, len(host.monitor_entries(&h)), host.MONITOR_CAPACITY)
	clear_sent(&f)
}

@(test)
a_virtual_controller_draws_and_plays_the_surface :: proc(t: ^testing.T) {
	f: Fake
	h: host.Host
	lib, s, ok := grid_up(t, &f, &h)
	defer grid_down(&f, &h, lib)
	if !ok do return
	v, vok := host.virtual_open(s)
	if !testing.expect(t, vok) do return
	defer host.virtual_close(&v)
	testing.expect_value(t, v.width, 150)
	testing.expect_value(t, len(v.controls), 16 + 4 + 1 + 14)
	pad := host.virtual_find(&v, "Pads 3,0")
	testing.expect(t, pad >= 0)
	testing.expect_value(t, v.controls[pad].kind, abi.Layout_Kind.Pad)
	testing.expect_value(t, v.controls[pad].x, 34)
	testing.expect_value(t, v.controls[pad].y, 28 + 3 * 20)
	st := host.virtual_state(&v, pad)
	testing.expect(t, st.has_rgb && st.rgb == 0x203a5a && st.value == 10)

	// Played with the mouse: what the device would send, through the claim table.
	out: [3]u8
	clear_sent(&f)
	m := host.virtual_press(&v, pad, 90)
	testing.expect_value(t, m.count, 1)
	testing.expect_value(t, m.port, 1)
	testing.expect_value(t, m.bytes[0], [3]u8{0x99, 36, 90})
	r := host.route(&h, m.port, m.bytes[0][:m.sizes[0]], 0, &out)
	testing.expect_value(t, r.action, abi.Rule_Action.Remap)
	host.host_update(&h)
	st = host.virtual_state(&v, pad)
	testing.expect(t, st.pressed && st.rgb == 0x60b0ff) // lit as hit
	svg := host.virtual_svg(&v)
	testing.expect(t, strings.has_prefix(svg, "<svg") && strings.contains(svg, "#60B0FF") && strings.contains(svg, "Grid (kit example)"))
	_ = os.write_entire_file(filepath.join({BUILD, "grid.svg"}, context.temp_allocator) or_else "", transmute([]u8)svg) // to look at
	m = host.virtual_release(&v, pad)
	testing.expect_value(t, m.bytes[0], [3]u8{0x89, 36, 0})

	// An encoder turned (two's complement), the fader moved (14 bits).
	knob := host.virtual_find(&v, "Knob")
	testing.expect_value(t, host.virtual_turn(&v, knob, 3).bytes[0], [3]u8{0xB0, 70, 3})
	testing.expect_value(t, host.virtual_turn(&v, knob, -2).bytes[0], [3]u8{0xB0, 70, 126})
	fm := host.virtual_move(&v, host.virtual_find(&v, "Fader"), 1)
	testing.expect_value(t, fm.count, 2)
	testing.expect_value(t, fm.bytes[0], [3]u8{0xB0, 7, 127})
	testing.expect_value(t, fm.bytes[1], [3]u8{0xB0, 39, 127})
	testing.expect_value(t, host.virtual_press(&v, host.virtual_find(&v, "Play")).bytes[0], [3]u8{0xB0, 85, 127})
	testing.expect_value(t, host.virtual_find(&v, "Nothing"), -1)
	testing.expect_value(t, host.virtual_press(&v, -1).count, 0)
	clear_sent(&f)
}

@(test)
a_surface_without_a_layout_has_no_virtual_controller :: proc(t: ^testing.T) {
	lib, err := host.library_load(example_path("hello_c.fsurf"))
	if !testing.expect_value(t, err, host.Library_Error.None) do return
	defer host.library_unload(lib)
	f: Fake
	defer fake_destroy(&f)
	h: host.Host
	host.host_init(&h, fake_config(&f))
	defer host.host_destroy(&h)
	s, _ := host.instance_create(&h, lib, "org.fsurf.example.hello-c")
	_, ok := host.virtual_open(s)
	testing.expect(t, !ok)
}

// ── Hot reload ────────────────────────────────────────────────────────

Reloads :: struct {
	fake: ^Fake,
	ok:   int,
	bad:  int,
}

@(test)
a_rebuilt_library_is_reloaded_with_its_surfaces_state :: proc(t: ^testing.T) {
	dir, _ := os.make_directory_temp("", "fsurf-reload-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	path := filepath.join({dir, "hello.fsurf"}, context.temp_allocator) or_else ""
	// Each version a later modification time, set (a filesystem's own may
	// be coarse, and the two builds are about the same size).
	version := 0
	stamp :: proc(path: string, version: ^int) {
		version^ += 1
		mt := time.time_add(time.now(), time.Duration(version^) * 2 * time.Second)
		_ = os.change_times(path, mt, mt)
	}
	put :: proc(path, from: string) {
		data, _ := os.read_entire_file(from, context.temp_allocator)
		_ = os.write_entire_file(path, data)
	}
	put(path, example_path("hello_c.fsurf"))
	lib, err := host.library_load_watched(path)
	if !testing.expect_value(t, err, host.Library_Error.None) do return
	f: Fake
	defer fake_destroy(&f)
	rl := Reloads{fake = &f}
	h: host.Host
	cfg := fake_config(&f)
	cfg.user = &rl
	// (The fake's procedures want the Fake: wrap them.)
	cfg.send_midi = proc(user: rawptr, s: ^host.Instance, port: u32, bytes: []u8) -> bool {
		append(&(^Reloads)(user).fake.sent, transmute([]u8)strings.clone(string(bytes)))
		return true
	}
	cfg.notify = proc(user: rawptr, s: ^host.Instance, text: string) { append(&(^Reloads)(user).fake.notified, strings.clone(text)) }
	cfg.log = proc(user: rawptr, s: ^host.Instance, level: abi.Log_Level, message: string) { append(&(^Reloads)(user).fake.logged, strings.clone(message)) }
	cfg.now_ns = proc(user: rawptr) -> u64 { return (^Reloads)(user).fake.now }
	cfg.get_extension = nil
	cfg.on_reload = proc(user: rawptr, l: ^host.Library, ok: bool) {
		r := (^Reloads)(user)
		if ok do r.ok += 1
		else do r.bad += 1
	}
	host.host_init(&h, cfg)
	host.host_add_library(&h, lib)
	host.host_set_ports(&h, {{1, "Hello"}}, {{2, "Hello"}})
	out: [3]u8
	host.route(&h, 1, {0xF0, 0x7E, 0x00, 0x06, 0x02, 0x7D, 0xF7}, 0, &out) // its identity
	host.host_update(&h)
	d := host.host_devices(&h)[0]
	s := d.instance
	testing.expect_value(t, d.state, host.Device_State.Active)
	testing.expect(t, has_sent(&f, {0xF0, 0x7D, 0x01, 0xF7}))
	f.now = 35_000_000
	host.host_update(&h) // three ticks... (one a frame here: behind, once)
	clear_sent(&f)

	// Rebuilt: a new hello. Reloaded once it has settled.
	put(path, example_path("hello_c_2.fsurf"))
	stamp(path, &version)
	host.host_update(&h)
	testing.expect_value(t, rl.ok, 0) // not settled yet
	ticks := host.instance_project_save(s, context.temp_allocator) or_else nil // what it has as it's reloaded
	f.now += 400_000_000
	host.host_update(&h)
	testing.expect_value(t, rl.ok, 1)
	testing.expect(t, d.instance == s) // the same instance, device, ports
	testing.expect_value(t, d.state, host.Device_State.Active)
	testing.expect(t, has_sent(&f, {0xF0, 0x7D, 0x00, 0xF7})) // the old one's goodbye
	testing.expect(t, has_sent(&f, {0xF0, 0x7D, 0x02, 0xF7})) // the new one's hello
	testing.expect_value(t, (^u32)(raw_data(host.instance_settings(s)))^, 2) // its settings kept: activated twice
	testing.expectf(t, len(f.notified) > 0 && f.notified[len(f.notified) - 1] == strings.concatenate({"loaded ", string(ticks)[len("ticks="):]}, context.temp_allocator), "notified %v, saved %s", f.notified[:], string(ticks))
	clear_sent(&f)
	r := host.route(&h, 1, {0x90, 40, 9}, 0, &out) // its rules again: the pad is its
	testing.expect(t, r.surface)
	host.host_update(&h)
	testing.expect(t, has_sent(&f, {0x90, 40, 127}))

	// A broken build: the old one goes on.
	_ = os.write_entire_file(path, transmute([]u8)string("half a build"))
	stamp(path, &version)
	host.host_update(&h)
	f.now += 400_000_000
	host.host_update(&h)
	testing.expect_value(t, rl.bad, 1)
	testing.expect_value(t, d.state, host.Device_State.Active)
	testing.expect(t, len(f.logged) > 0 && strings.contains(f.logged[len(f.logged) - 1], "didn't load"))
	f.now += 400_000_000
	host.host_update(&h) // not tried again until it changes
	testing.expect_value(t, rl.bad, 1)
	// Fixed: back to the first build.
	put(path, example_path("hello_c.fsurf"))
	stamp(path, &version)
	host.host_update(&h)
	f.now += 400_000_000
	clear_sent(&f)
	host.host_update(&h)
	testing.expect_value(t, rl.ok, 2)
	testing.expect(t, has_sent(&f, {0xF0, 0x7D, 0x01, 0xF7}))
	clear_sent(&f)
	host.host_destroy(&h)
	testing.expect(t, host.library_unload(lib))
}

has_sent :: proc(f: ^Fake, want: []u8) -> bool {
	for b in f.sent do if string(b) == string(want) do return true
	return false
}
