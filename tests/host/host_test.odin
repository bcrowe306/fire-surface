#+feature dynamic-literals
// The host library with the two example surfaces (built by
// scripts/build.sh into .build/), and the Odin ABI package against the C
// header's layout. Run from the repository's root: ./scripts/test.sh
package host_test

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:testing"

import abi "../../abi"
import host "../../host"

BUILD :: ".build"

EXAMPLES :: [2]struct { file, id: string }{
	{"hello_c.fsurf", "org.fsurf.example.hello-c"},
	{"hello_odin.fsurf", "org.fsurf.example.hello-odin"},
}

// ── The ABI's layout, against the header's ────────────────────────────

@(test)
abi_matches_the_header :: proc(t: ^testing.T) {
	exe := filepath.join({BUILD, "layout.exe" when ODIN_OS == .Windows else "layout"}, context.temp_allocator) or_else ""
	state, stdout, stderr, err := os.process_exec({command = {exe}}, context.temp_allocator)
	if !testing.expectf(t, err == nil && state.exit_code == 0, "run %s (./scripts/build.sh): %v %s", exe, err, stderr) do return
	types := map[string]typeid{
		"fsurf_version_t"         = abi.Version,
		"fsurf_ostream_t"         = abi.Ostream,
		"fsurf_istream_t"         = abi.Istream,
		"fsurf_port_spec_t"       = abi.Port_Spec,
		"fsurf_identity_t"        = abi.Identity,
		"fsurf_descriptor_t"      = abi.Descriptor,
		"fsurf_host_t"            = abi.Host,
		"fsurf_port_t"            = abi.Port,
		"fsurf_surface_t"         = abi.Surface,
		"fsurf_surface_factory_t" = abi.Surface_Factory,
		"fsurf_entry_t"           = abi.Entry,
		"fsurf_rule_t"            = abi.Rule,
	}
	defer delete(types)
	seen := 0
	for line in strings.split_lines(string(stdout), context.temp_allocator) {
		if line == "" do continue
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) == 5 && parts[1] == "size" { // "T size N align A"
			id, ok := types[parts[0]]
			if !testing.expectf(t, ok, "no Odin type for %s", parts[0]) do continue
			ti := type_info_of(id)
			testing.expectf(t, fmt.tprint(ti.size) == parts[2], "%s: size %d in Odin, %s in C", parts[0], ti.size, parts[2])
			testing.expectf(t, fmt.tprint(ti.align) == parts[4], "%s: align %d in Odin, %s in C", parts[0], ti.align, parts[4])
			seen += 1
		} else if len(parts) == 2 { // "T.field OFFSET"
			dot := strings.index_byte(parts[0], '.')
			id := types[parts[0][:dot]]
			f := reflect.struct_field_by_name(id, parts[0][dot + 1:])
			testing.expectf(t, f.name != "", "%s: no such field in Odin", parts[0])
			off, _ := strconv.parse_int(parts[1])
			testing.expectf(t, int(f.offset) == off, "%s: offset %d in Odin, %d in C", parts[0], f.offset, off)
			seen += 1
		}
	}
	testing.expect(t, seen > 80)
	// Every Odin struct's fields are in the header (none added on one side only).
	for name, id in types {
		n := 0
		for line in strings.split_lines(string(stdout), context.temp_allocator) do if strings.has_prefix(line, fmt.tprintf("%s.", name)) do n += 1
		testing.expectf(t, n == len(reflect.struct_field_names(id)), "%s: %d fields in C, %d in Odin", name, n, len(reflect.struct_field_names(id)))
	}
}

// ── A fake host: what the surfaces did ────────────────────────────────

Fake :: struct {
	sent:     [dynamic][]u8,
	notified: [dynamic]string,
	logged:   [dynamic]string,
	pings:    [dynamic]string,
	now:      u64,
}

fake_destroy :: proc(f: ^Fake) {
	for b in f.sent do delete(b)
	for s in f.notified do delete(s)
	for s in f.logged do delete(s)
	for s in f.pings do delete(s)
	delete(f.sent); delete(f.notified); delete(f.logged); delete(f.pings)
}

Test_Ext :: struct {
	ping: proc "c" (host: ^abi.Host, what: cstring),
}

test_ext := Test_Ext{
	ping = proc "c" (h: ^abi.Host, what: cstring) {
		s := (^host.Instance)(h.host_data)
		context = s.host.ctx
		append(&(^Fake)(s.host.config.user).pings, strings.clone(string(what)))
	},
}

fake_config :: proc(f: ^Fake) -> host.Host_Config {
	return {
		name = "Test Host", vendor = "fire-surface", version = "1.0",
		user = f,
		send_midi = proc(user: rawptr, s: ^host.Instance, port: u32, bytes: []u8) -> bool {
			append(&(^Fake)(user).sent, transmute([]u8)strings.clone(string(bytes)))
			return true
		},
		get_extension = proc(user: rawptr, s: ^host.Instance, id: string, version: u32) -> rawptr {
			return &test_ext if id == "org.fsurf.test" && version == 1 else nil
		},
		log = proc(user: rawptr, s: ^host.Instance, level: abi.Log_Level, message: string) {
			append(&(^Fake)(user).logged, strings.clone(message))
		},
		notify = proc(user: rawptr, s: ^host.Instance, text: string) {
			append(&(^Fake)(user).notified, strings.clone(text))
		},
		now_ns = proc(user: rawptr) -> u64 { return (^Fake)(user).now },
	}
}

example_path :: proc(file: string) -> string {
	return filepath.join({BUILD, file}, context.temp_allocator) or_else ""
}

// ── The examples, through the host library ────────────────────────────

@(test)
an_example_runs_its_whole_life :: proc(t: ^testing.T) {
	for ex in EXAMPLES {
		lib, err := host.library_load(example_path(ex.file))
		if !testing.expectf(t, err == .None, "%s: %v (./scripts/build.sh)", ex.file, err) do continue
		testing.expect_value(t, len(lib.descriptors), 1)
		d := lib.descriptors[0]
		testing.expect_value(t, string(d.id), ex.id)
		testing.expect_value(t, d.port_count, 1)
		testing.expect_value(t, string(d.ports[0].role), "main")
		testing.expect_value(t, d.ports[0].flags, abi.Port_Flags{.Input, .Output})
		testing.expect_value(t, string(d.ports[0].input_names[0]), "Hello*")
		testing.expect(t, d.ports[0].input_names[1] == nil)
		testing.expect_value(t, d.identity.method, abi.Identify_Method.Request)
		testing.expect_value(t, d.identity.match_size, 6)

		f: Fake
		defer fake_destroy(&f)
		h: host.Host
		host.host_init(&h, fake_config(&f))
		s, ie := host.instance_create(&h, lib, ex.id)
		if !testing.expect_value(t, ie, host.Instance_Error.None) { host.host_destroy(&h); host.library_unload(lib); continue }
		testing.expect_value(t, s.state, host.Instance_State.Ready)
		testing.expect_value(t, len(f.logged), 1)
		testing.expect_value(t, len(f.pings), 1) // it found the host's extension
		if len(f.pings) == 1 do testing.expect_value(t, f.pings[0], "init")
		testing.expect(t, !host.library_unload(lib)) // not while it has a surface

		// Activating: the hello, its settings counted.
		testing.expect(t, !host.instance_activate(s, {})) // a port a spec, or nothing
		testing.expect(t, host.instance_activate(s, {{input = 3, output = 5, input_name = "Hello In", output_name = "Hello Out"}}))
		testing.expect_value(t, s.state, host.Instance_State.Active)
		expect_sent(t, &f, {0xF0, 0x7D, 0x01, 0xF7})
		settings := host.instance_settings(s)
		testing.expect_value(t, len(settings), 4)
		if len(settings) == 4 do testing.expect_value(t, (^u32)(raw_data(settings))^, 1)

		// MIDI in: a note lights its pad, a SysEx is noticed, a note off isn't answered.
		host.instance_midi(s, 3, {0x91, 36, 100}, 0)
		expect_sent(t, &f, {0x91, 36, 127})
		host.instance_midi(s, 3, {0x81, 36, 0}, 0)
		testing.expect_value(t, len(f.sent), 0)
		host.instance_midi(s, 3, {0xF0, 0x7D, 0x05, 0xF7}, 0)
		testing.expect_value(t, len(f.notified), 1)

		// Its 10 ms timer, on the host's clock.
		host.host_update(&h)
		testing.expect_value(t, len(f.sent), 0)
		f.now = 10_000_000
		host.host_update(&h)
		expect_sent(t, &f, {0xB0, 16, 1})
		f.now = 15_000_000
		host.host_update(&h)
		testing.expect_value(t, len(f.sent), 0)
		f.now = 50_000_000 // behind: one tick, not three
		host.host_update(&h)
		expect_sent(t, &f, {0xB0, 16, 2})

		// Its project state, out and back.
		data, ok := host.instance_project_save(s)
		testing.expect(t, ok)
		testing.expect_value(t, string(data), "ticks=2")
		delete(data)
		testing.expect(t, host.instance_project_load(s, transmute([]u8)string("ticks=41")))
		testing.expect_value(t, f.notified[len(f.notified) - 1], "loaded 41")
		testing.expect(t, !host.instance_project_load(s, transmute([]u8)string("nonsense")))

		// Deactivating: the goodbye; no more ticks or MIDI.
		host.instance_deactivate(s)
		expect_sent(t, &f, {0xF0, 0x7D, 0x00, 0xF7})
		f.now = 100_000_000
		host.host_update(&h)
		host.instance_midi(s, 3, {0x91, 36, 100}, 0)
		testing.expect_value(t, len(f.sent), 0)

		// Activated again with what it saved: its second activation.
		saved := strings.clone(string(host.instance_settings(s)))
		defer delete(saved)
		host.instance_destroy(s)
		s2, _ := host.instance_create(&h, lib, ex.id)
		host.instance_set_settings(s2, transmute([]u8)saved)
		testing.expect(t, host.instance_activate(s2, {{input = 0, output = 0}}))
		testing.expect_value(t, (^u32)(raw_data(host.instance_settings(s2)))^, 2)
		host.host_destroy(&h) // deactivates and destroys it: the goodbye
		testing.expect_value(t, len(f.sent), 2)
		testing.expect(t, host.library_unload(lib))
	}
}

expect_sent :: proc(t: ^testing.T, f: ^Fake, want: []u8, loc := #caller_location) {
	if !testing.expectf(t, len(f.sent) == 1, "sent %v, want one message %v", f.sent[:], want, loc = loc) {
		for b in f.sent do delete(b)
		clear(&f.sent)
		return
	}
	testing.expectf(t, string(f.sent[0]) == string(want), "sent %v, want %v", f.sent[0], want, loc = loc)
	delete(f.sent[0])
	clear(&f.sent)
}

@(test)
creating_the_wrong_surface_fails :: proc(t: ^testing.T) {
	lib, err := host.library_load(example_path("hello_c.fsurf"))
	if !testing.expect_value(t, err, host.Library_Error.None) do return
	defer host.library_unload(lib)
	f: Fake
	defer fake_destroy(&f)
	h: host.Host
	host.host_init(&h, fake_config(&f))
	defer host.host_destroy(&h)
	_, e := host.instance_create(&h, lib, "org.fsurf.example.nothing")
	testing.expect_value(t, e, host.Instance_Error.No_Such_Surface)
	testing.expect_value(t, lib.instances, 0)
}

@(test)
a_surface_sends_only_on_its_own_ports :: proc(t: ^testing.T) {
	lib, err := host.library_load(example_path("hello_c.fsurf"))
	if !testing.expect_value(t, err, host.Library_Error.None) do return
	defer host.library_unload(lib)
	f: Fake
	defer fake_destroy(&f)
	h: host.Host
	host.host_init(&h, fake_config(&f))
	defer host.host_destroy(&h)
	s, _ := host.instance_create(&h, lib, "org.fsurf.example.hello-c")
	host.instance_activate(s, {{input = 0, output = 7}})
	expect_sent(t, &f, {0xF0, 0x7D, 0x01, 0xF7})
	b := [3]u8{0x90, 1, 1}
	testing.expect(t, !s.c_host.send_midi(&s.c_host, 8, &b[0], 3))
	testing.expect(t, s.c_host.send_midi(&s.c_host, 7, &b[0], 3))
	expect_sent(t, &f, {0x90, 1, 1})
}

// ── Scanning ──────────────────────────────────────────────────────────

@(test)
a_scan_finds_the_surfaces_in_a_folder :: proc(t: ^testing.T) {
	dir, _ := os.make_directory_temp("", "fsurf-scan-*", context.temp_allocator)
	defer os.remove_all(dir)
	copy_file :: proc(from, to: string) {
		data, _ := os.read_entire_file(from, context.temp_allocator)
		_ = os.write_entire_file(to, data)
	}
	j :: proc(a, b: string) -> string { return filepath.join({a, b}, context.temp_allocator) or_else "" }
	copy_file(example_path("hello_odin.fsurf"), j(dir, "B.fsurf"))
	copy_file(example_path("hello_c.fsurf"), j(dir, "a.FSURF")) // any case
	_ = os.write_entire_file(j(dir, "broken.fsurf"), transmute([]u8)string("not a library"))
	_ = os.write_entire_file(j(dir, "notes.txt"), transmute([]u8)string("ignored"))
	os.make_directory(j(dir, "sub.fsurf")) // a folder: ignored

	entries := host.scan({dir})
	defer host.scan_destroy(entries)
	if !testing.expect_value(t, len(entries), 3) do return
	testing.expect_value(t, filepath.base(entries[0].path), "B.fsurf") // sorted by path
	testing.expect_value(t, filepath.base(entries[1].path), "a.FSURF")
	testing.expect_value(t, filepath.base(entries[2].path), "broken.fsurf")
	testing.expect_value(t, entries[0].error, host.Library_Error.None)
	testing.expect_value(t, entries[0].surfaces[0].id, "org.fsurf.example.hello-odin")
	testing.expect_value(t, entries[0].surfaces[0].name, "Hello (Odin)")
	testing.expect_value(t, entries[1].surfaces[0].id, "org.fsurf.example.hello-c")
	testing.expect_value(t, entries[1].surfaces[0].vendor, "fire-surface")
	testing.expect_value(t, entries[2].error, host.Library_Error.Cannot_Load)
	testing.expect_value(t, len(entries[2].surfaces), 0)
}

@(test)
the_default_folders_start_with_fsurf_path :: proc(t: ^testing.T) {
	sep := ";" when ODIN_OS == .Windows else ":"
	os.set_env("FSURF_PATH", fmt.tprintf("/one%s%s/two", sep, sep))
	defer os.unset_env("FSURF_PATH")
	folders := host.default_folders()
	defer host.delete_folders(folders)
	testing.expect(t, len(folders) >= 4)
	testing.expect_value(t, folders[0], "/one")
	testing.expect_value(t, folders[1], "/two")
}
