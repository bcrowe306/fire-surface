package fsurf_host

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:time"

import abi "../abi"

// What the app does for its surfaces. Any procedure may be nil.
Host_Config :: struct {
	name, vendor, url, version: string, // the app, as surfaces see it
	user: rawptr, // given back to each procedure
	// MIDI to a device on the app's output `port` (fsurf_port_t.output).
	send_midi:     proc(user: rawptr, s: ^Instance, port: u32, bytes: []u8) -> bool,
	// An extension of the app by id and version: its table, or nil.
	get_extension: proc(user: rawptr, s: ^Instance, id: string, version: u32) -> rawptr,
	log:           proc(user: rawptr, s: ^Instance, level: abi.Log_Level, message: string),
	notify:        proc(user: rawptr, s: ^Instance, text: string),
	// The clock on_midi's times are on; nil = the time since `host_init`.
	now_ns:        proc(user: rawptr) -> u64,
	// A message a surface hands on (`inject_midi`), as if it had come in on
	// its input `port` and been passed: for the app's own MIDI handling.
	inject_midi:   proc(user: rawptr, s: ^Instance, port: u32, bytes: []u8) -> bool,
	// Detection: whether the app has an extension (a descriptor's
	// required_extensions); nil = none.
	has_extension: proc(user: rawptr, id: string) -> bool,
	// Detection: a device's state changed (`old` == `d.state` for one just
	// found). Read `instance_settings` here when it goes Gone, to keep them.
	on_device:     proc(user: rawptr, d: ^Device, old: Device_State),
	// Detection: the settings blob kept for a device, given to its surface
	// when it is made (copied). nil, or empty: none.
	device_settings: proc(user: rawptr, d: ^Device) -> []u8,
}

// Runs surfaces. Surface thread only. Fields are internal.
Host :: struct {
	config:     Host_Config,
	allocator:  mem.Allocator,
	ctx:        runtime.Context, // for the surfaces' calls back in
	strings:    [4]cstring, // name, vendor, url, version
	instances:  [dynamic]^Instance,
	timers:     [dynamic]Timer,
	next_timer: u32,
	started:    time.Tick,
	updating:   bool,
	next_uid:   u32,
	router:     Router,
	routes_dirty: bool,
	libraries:  [dynamic]^Library,
	devices:    [dynamic]^Device,
	inputs:     [dynamic]Port_Info,
	outputs:    [dynamic]Port_Info,
	disabled:   [dynamic]string, // surface ids not detected
}

@(private)
Timer :: struct {
	instance:  ^Instance,
	id:        u32,
	period_ns: u64,
	next_ns:   u64,
	stopped:   bool,
}

// Where a surface is in its life.
Instance_State :: enum {
	Ready,      // made and initialized
	Identifying, // its own identification is running (Identify_Method.Surface)
	Active,     // its device is there
}

// A surface made from a library. From `instance_create`; free with
// `instance_destroy`. Fields are read-only.
Instance :: struct {
	host:       ^Host,
	library:    ^Library,
	descriptor: ^abi.Descriptor,
	surface:    ^abi.Surface,
	state:      Instance_State,
	// What its identification answered (Identify_Method.Surface): nil
	// while it hasn't.
	identified: Maybe(bool),
	settings:   [dynamic]u8, // its settings blob: the app keeps it between runs
	c_host:     abi.Host, // what it was given
	ports:      [dynamic]abi.Port, // while identifying or active
	port_names: [dynamic]cstring, // owned
	uid:        u32, // never 0
	device:     ^Device, // what detection made it for, or nil
	rules:      [dynamic]Compiled_Rule, // its claim table
	rule_bytes: [dynamic]u8,
}

// Why a surface couldn't be made.
Instance_Error :: enum {
	None,
	No_Such_Surface, // the library has no surface with that id
	Create_Failed,   // its factory's create returned nil (or a bad surface)
	Init_Failed,     // its init returned false
}

// Sets up a host for surfaces. Free with `host_destroy`.
host_init :: proc(h: ^Host, config: Host_Config, allocator := context.allocator) {
	h^ = {config = config, allocator = allocator, ctx = context, started = time.tick_now(), next_timer = 1, next_uid = 1}
	h.instances = make([dynamic]^Instance, allocator)
	h.timers = make([dynamic]Timer, allocator)
	h.libraries = make([dynamic]^Library, allocator)
	h.devices = make([dynamic]^Device, allocator)
	h.inputs = make([dynamic]Port_Info, allocator)
	h.outputs = make([dynamic]Port_Info, allocator)
	h.disabled = make([dynamic]string, allocator)
	router_init(&h.router, allocator)
	for s, i in ([4]string{config.name, config.vendor, config.url, config.version}) do h.strings[i] = strings.clone_to_cstring(s, allocator)
}

// Destroys every surface still running (deactivating the active ones) and
// frees the host. Libraries stay loaded: unload them after. Stop calling
// `route` first.
host_destroy :: proc(h: ^Host) {
	devices_destroy(h)
	for len(h.instances) > 0 do instance_destroy(h.instances[len(h.instances) - 1])
	router_destroy(&h.router, h.allocator)
	delete(h.instances)
	delete(h.timers)
	for s in h.strings do delete(s, h.allocator)
}

// The host's clock (the times given to `instance_midi`), in nanoseconds.
host_now_ns :: proc(h: ^Host) -> u64 {
	if h.config.now_ns != nil do return h.config.now_ns(h.config.user)
	return u64(time.tick_diff(h.started, time.tick_now()))
}

// Once a host frame: the MIDI `route` queued for surfaces (and identity
// replies), then the timers that are due, identification, and every active
// surface's on_idle.
host_update :: proc(h: ^Host) {
	h.updating = true
	router_drain(h, deliver)
	now := host_now_ns(h)
	// (A timer may start or stop timers: those made now wait for the next update.)
	n := len(h.timers)
	for i in 0 ..< n {
		t := &h.timers[i]
		if t.stopped || now < t.next_ns do continue
		// Behind by more than a period (a long frame): once, not a burst.
		t.next_ns = max(t.next_ns + t.period_ns, now)
		s := t.instance
		if s.surface.on_timer != nil do s.surface.on_timer(s.surface, t.id)
	}
	for i := len(h.timers) - 1; i >= 0; i -= 1 do if h.timers[i].stopped do ordered_remove(&h.timers, i)
	tick_probes(h)
	resolve(h)
	publish_routes(h)
	router_collect(&h.router, h.allocator)
	for i := 0; i < len(h.instances); i += 1 {
		s := h.instances[i]
		if s.state == .Active && s.surface.on_idle != nil do s.surface.on_idle(s.surface)
	}
	h.updating = false
}

// Makes a surface of `surface_id` from a library and initializes it.
instance_create :: proc(h: ^Host, l: ^Library, surface_id: string) -> (^Instance, Instance_Error) {
	d := library_find(l, surface_id)
	if d == nil do return nil, .No_Such_Surface
	s := new(Instance, h.allocator)
	s^ = {host = h, library = l, descriptor = d, uid = h.next_uid}
	h.next_uid += 1
	if h.next_uid == 0 do h.next_uid = 1
	s.rules = make([dynamic]Compiled_Rule, h.allocator)
	s.rule_bytes = make([dynamic]u8, h.allocator)
	s.settings = make([dynamic]u8, h.allocator)
	s.ports = make([dynamic]abi.Port, h.allocator)
	s.port_names = make([dynamic]cstring, h.allocator)
	s.c_host = {
		struct_size   = size_of(abi.Host),
		fsurf_version = abi.VERSION,
		host_data     = s,
		name          = h.strings[0],
		vendor        = h.strings[1],
		url           = h.strings[2],
		version       = h.strings[3],
		get_extension = c_get_extension,
		log           = c_log,
		notify        = c_notify,
		send_midi     = c_send_midi,
		timer_start   = c_timer_start,
		timer_stop    = c_timer_stop,
		now_ns        = c_now_ns,
		settings_get  = c_settings_get,
		settings_set  = c_settings_set,
		identified    = c_identified,
		set_rules     = c_set_rules,
		inject_midi   = c_inject_midi,
	}
	id := strings.clone_to_cstring(surface_id, context.temp_allocator)
	surf := l.factory.create(l.factory, &s.c_host, id)
	if surf == nil || surf.struct_size < size_of(abi.Surface) || surf.init == nil || surf.destroy == nil || surf.activate == nil || surf.deactivate == nil {
		instance_free(s)
		return nil, .Create_Failed
	}
	s.surface = surf
	l.instances += 1
	append(&h.instances, s)
	if !surf.init(surf) {
		instance_destroy(s)
		return nil, .Init_Failed
	}
	return s, .None
}

// Gives the surface its settings blob (what `instance_settings` read on an
// earlier run). Before activating it, as a rule.
instance_set_settings :: proc(s: ^Instance, data: []u8) {
	clear(&s.settings)
	append(&s.settings, ..data)
}

// The surface's settings blob, for the app to keep.
instance_settings :: proc(s: ^Instance) -> []u8 {
	return s.settings[:]
}

// A port pair for `instance_activate` and `instance_identify`, in the
// descriptor's order. `abi.NO_PORT` for a side it doesn't have.
Port_Assignment :: struct {
	input, output: u32,
	input_name, output_name: string,
}

@(private)
set_ports :: proc(s: ^Instance, ports: []Port_Assignment) -> bool {
	if len(ports) != int(s.descriptor.port_count) do return false
	free_ports(s)
	for p, i in ports {
		spec := s.descriptor.ports[i]
		in_name, out_name: cstring
		if p.input_name != "" { in_name = strings.clone_to_cstring(p.input_name, s.host.allocator); append(&s.port_names, in_name) }
		if p.output_name != "" { out_name = strings.clone_to_cstring(p.output_name, s.host.allocator); append(&s.port_names, out_name) }
		append(&s.ports, abi.Port{role = spec.role, input = p.input, output = p.output, input_name = in_name, output_name = out_name})
	}
	return true
}

@(private)
free_ports :: proc(s: ^Instance) {
	for n in s.port_names do delete(n, s.host.allocator)
	clear(&s.port_names)
	clear(&s.ports)
}

// Starts the surface's own identification (`Identify_Method.Surface`) on
// these ports. Its answer comes to `Instance.identified`, then the app
// activates it (or destroys it). False if it has no `identify`.
instance_identify :: proc(s: ^Instance, ports: []Port_Assignment) -> bool {
	if s.state == .Active || s.surface.identify == nil || !set_ports(s, ports) do return false
	s.identified = nil
	s.state = .Identifying
	s.host.routes_dirty = true
	publish_routes(s.host)
	s.surface.identify(s.surface, raw_data(s.ports), u32(len(s.ports)))
	return true
}

// Its device is there: activates the surface on these ports (one pair a
// port spec, in the descriptor's order). False if the ports don't fit the
// descriptor, or the surface couldn't start.
instance_activate :: proc(s: ^Instance, ports: []Port_Assignment) -> bool {
	if s.state == .Active do return true
	if !set_ports(s, ports) do return false
	if !s.surface.activate(s.surface, raw_data(s.ports), u32(len(s.ports))) {
		free_ports(s)
		s.state = .Ready
		return false
	}
	s.state = .Active
	s.host.routes_dirty = true
	publish_routes(s.host)
	return true
}

// Its device is gone, or it is turned off: deactivates the surface.
instance_deactivate :: proc(s: ^Instance) {
	if s.state == .Active do s.surface.deactivate(s.surface)
	free_ports(s)
	s.state = .Ready
	s.host.routes_dirty = true
	publish_routes(s.host)
}

// MIDI from its device (a short message, or a whole SysEx), on the input
// `port`, at `time_ns` on the host's clock. Only while it is active, or
// identifying itself.
instance_midi :: proc(s: ^Instance, port: u32, bytes: []u8, time_ns: u64) {
	if len(bytes) == 0 || s.surface.on_midi == nil do return
	if s.state != .Active && s.state != .Identifying do return
	s.surface.on_midi(s.surface, port, raw_data(bytes), u32(len(bytes)), time_ns)
}

// The surface's part of a project (nil and true when it keeps none).
// Free the bytes with `delete`.
instance_project_save :: proc(s: ^Instance, allocator := context.allocator) -> (data: []u8, ok: bool) {
	if s.surface.project_save == nil do return nil, true
	buf := make([dynamic]u8, allocator)
	stream := abi.Ostream{ctx = &buf, write = proc "c" (st: ^abi.Ostream, b: rawptr, n: u64) -> i64 {
		d := (^[dynamic]u8)(st.ctx)
		context = runtime.default_context()
		context.allocator = d.allocator
		append(d, ..([^]u8)(b)[:n])
		return i64(n)
	}}
	if !s.surface.project_save(s.surface, &stream) {
		delete(buf)
		return nil, false
	}
	return buf[:], true
}

// Gives the surface its part of a project (from `instance_project_save`).
instance_project_load :: proc(s: ^Instance, data: []u8) -> bool {
	if s.surface.project_load == nil do return true
	Reader :: struct { data: []u8, at: int }
	r := Reader{data = data}
	stream := abi.Istream{ctx = &r, read = proc "c" (st: ^abi.Istream, b: rawptr, n: u64) -> i64 {
		r := (^Reader)(st.ctx)
		k := min(int(n), len(r.data) - r.at)
		if k > 0 do runtime.mem_copy_non_overlapping(b, &r.data[r.at], k)
		r.at += k
		return i64(k)
	}}
	return s.surface.project_load(s.surface, &stream)
}

// An extension of the surface by id (its table), or nil.
instance_extension :: proc(s: ^Instance, id: string) -> rawptr {
	if s.surface.get_extension == nil do return nil
	return s.surface.get_extension(s.surface, strings.clone_to_cstring(id, context.temp_allocator))
}

// Deactivates the surface if it is active, stops its timers, and destroys
// it. Its library can be unloaded once none of its surfaces are left.
instance_destroy :: proc(s: ^Instance) {
	h := s.host
	if s.state == .Active do s.surface.deactivate(s.surface)
	s.state = .Ready
	for &t in h.timers do if t.instance == s do t.stopped = true
	if !h.updating {
		for i := len(h.timers) - 1; i >= 0; i -= 1 do if h.timers[i].stopped do ordered_remove(&h.timers, i)
	}
	s.surface.destroy(s.surface)
	s.library.instances -= 1
	for x, i in h.instances do if x == s { ordered_remove(&h.instances, i); break }
	if d := s.device; d != nil { // destroyed by the app, not by detection
		d.instance = nil
		set_state(h, d, .Failed)
	}
	instance_free(s)
	h.routes_dirty = true
	publish_routes(h)
}

@(private)
instance_free :: proc(s: ^Instance) {
	free_ports(s)
	delete(s.ports)
	delete(s.port_names)
	delete(s.settings)
	delete(s.rules)
	delete(s.rule_bytes)
	free(s, s.host.allocator)
}

// ── What a surface calls (fsurf_host_t) ───────────────────────────────

@(private)
from :: #force_inline proc "contextless" (h: ^abi.Host) -> ^Instance { return (^Instance)(h.host_data) }

@(private)
c_get_extension :: proc "c" (h: ^abi.Host, id: cstring, version: u32) -> rawptr {
	s := from(h)
	context = s.host.ctx
	if s.host.config.get_extension == nil || id == nil do return nil
	return s.host.config.get_extension(s.host.config.user, s, string(id), version)
}

@(private)
c_log :: proc "c" (h: ^abi.Host, level: abi.Log_Level, message: cstring) {
	s := from(h)
	context = s.host.ctx
	if s.host.config.log != nil && message != nil do s.host.config.log(s.host.config.user, s, level, string(message))
}

@(private)
c_notify :: proc "c" (h: ^abi.Host, text: cstring) {
	s := from(h)
	context = s.host.ctx
	if s.host.config.notify != nil && text != nil do s.host.config.notify(s.host.config.user, s, string(text))
}

@(private)
c_send_midi :: proc "c" (h: ^abi.Host, port: u32, bytes: [^]u8, size: u32) -> bool {
	s := from(h)
	context = s.host.ctx
	if s.host.config.send_midi == nil || bytes == nil || size == 0 || port == abi.NO_PORT do return false
	// Only its own outputs.
	mine := false
	for p in s.ports do if p.output == port do mine = true
	if !mine do return false
	return s.host.config.send_midi(s.host.config.user, s, port, bytes[:size])
}

@(private)
c_timer_start :: proc "c" (h: ^abi.Host, period_ms: u32) -> u32 {
	s := from(h)
	context = s.host.ctx
	hh := s.host
	id := hh.next_timer
	hh.next_timer += 1
	if hh.next_timer == 0 do hh.next_timer = 1
	period := u64(max(period_ms, 1)) * 1_000_000
	append(&hh.timers, Timer{instance = s, id = id, period_ns = period, next_ns = host_now_ns(hh) + period})
	return id
}

@(private)
c_timer_stop :: proc "c" (h: ^abi.Host, id: u32) {
	s := from(h)
	for &t in s.host.timers do if t.id == id && t.instance == s do t.stopped = true
}

@(private)
c_now_ns :: proc "c" (h: ^abi.Host) -> u64 {
	s := from(h)
	context = s.host.ctx
	return host_now_ns(s.host)
}

@(private)
c_settings_get :: proc "c" (h: ^abi.Host, buffer: rawptr, capacity: u32) -> u32 {
	s := from(h)
	n := min(int(capacity), len(s.settings))
	if n > 0 && buffer != nil do runtime.mem_copy_non_overlapping(buffer, raw_data(s.settings), n)
	return u32(len(s.settings))
}

@(private)
c_settings_set :: proc "c" (h: ^abi.Host, data: rawptr, size: u32) -> bool {
	s := from(h)
	context = s.host.ctx
	if size > 0 && data == nil do return false
	instance_set_settings(s, ([^]u8)(data)[:size])
	return true
}

@(private)
c_identified :: proc "c" (h: ^abi.Host, ok: bool) {
	s := from(h)
	if s.state == .Identifying do s.identified = ok
}

@(private)
c_set_rules :: proc "c" (h: ^abi.Host, rules: [^]abi.Rule, count: u32) -> bool {
	s := from(h)
	context = s.host.ctx
	if count > 0 && rules == nil do return false
	compiled := make([dynamic]Compiled_Rule, s.host.allocator)
	bytes := make([dynamic]u8, s.host.allocator)
	if !compile_rules(rules[:count] if count > 0 else nil, &compiled, &bytes) {
		delete(compiled)
		delete(bytes)
		return false
	}
	delete(s.rules)
	delete(s.rule_bytes)
	s.rules = compiled
	s.rule_bytes = bytes
	s.host.routes_dirty = true
	publish_routes(s.host)
	return true
}

@(private)
c_inject_midi :: proc "c" (h: ^abi.Host, port: u32, bytes: [^]u8, size: u32) -> bool {
	s := from(h)
	context = s.host.ctx
	if s.host.config.inject_midi == nil || bytes == nil || size == 0 || port == abi.NO_PORT do return false
	mine := false
	for p in s.ports do if p.input == port do mine = true
	if !mine do return false
	return s.host.config.inject_midi(s.host.config.user, s, port, bytes[:size])
}

// What `route` queued, to its surface (or to detection).
@(private)
deliver :: proc(h: ^Host, uid, port: u32, bytes: []u8, time_ns: u64) {
	if uid == 0 {
		probe_reply(h, port, bytes)
		return
	}
	for s in h.instances do if s.uid == uid {
		instance_midi(s, port, bytes, time_ns)
		return
	}
}
