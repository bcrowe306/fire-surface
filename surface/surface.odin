/*
The Odin kit for writing a control surface: a surface is a `Spec` (what
the device is, its ports, how it is identified, its hello and goodbye) and
a `setup` procedure that builds its controls, components and modes. The
kit turns them into the protocol (fsurf.h): the descriptor, the
lifecycle, MIDI to the controls, the claim table worked out from which
controls the active components own, timers for tasks.

	spec := surface.Spec{id = "com.example.grid", name = "Grid", vendor = "Example", version = "1.0",
		ports = {{role = "main", inputs = {"Grid*"}, outputs = {"Grid*"}}}, setup = setup}
	library := surface.Library{specs = {&spec}}

	@(export, link_name = abi.ENTRY_SYMBOL)
	fsurf_entry := abi.Entry{
		fsurf_version = abi.VERSION,
		init        = proc "c" (path: cstring) -> bool { return surface.library_init(&library) },
		deinit      = proc "c" () { surface.library_deinit(&library) },
		get_factory = proc "c" (id: cstring) -> rawptr { return surface.library_factory(&library, id) },
	}

	setup :: proc(cs: ^surface.Control_Surface) -> bool {
		play := surface.button(cs, "Play", surface.bind_cc(85))
		t := surface.component_make(cs, "Transport")
		surface.layer_bind(t.layer, "play", play)
		t.on_event = proc(c: ^surface.Component, e: surface.Event) { ... }
		surface.surface_add(cs, t) // active while the surface is
		return true
	}

Everything here runs on the host's surface thread.
*/
package surface

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"

import abi "../abi"

// A MIDI port pair of a surface, by role (abi.Port_Spec).
Port_Def :: struct {
	role:    string,
	inputs:  []string, // name patterns: `*`, any case, "mac:"/"win:"/"linux:"
	outputs: []string,
	flags:   abi.Port_Flags, // {} = {.Input, .Output}
}

// How the device is recognized (abi.Identity).
Identity_Def :: struct {
	method:    abi.Identify_Method,
	port_role: string, // "" = the first port
	request:   []u8, // nil = the universal identity request
	match:     []u8,
	mask:      []u8, // nil = every bit; else as long as `match`
	delay_ms, retry_ms, retries: u32,
}

// What a surface is: its descriptor's parts, and its procedures. Any
// procedure may be nil.
Spec :: struct {
	id, name, vendor, version, url, description: string,
	ports:               []Port_Def,
	identity:            ^Identity_Def, // nil = by port names alone
	required_extensions: []string,
	// Sent on the first port when activated, and when deactivated (after
	// the lights are turned off).
	hello, goodbye:      [][]u8,
	// The skin the controls' named values come from (nil = an empty one:
	// "*.On" is 127, "*.Off" 0).
	skin:                ^Skin,
	// What isn't owned: by default the surface takes the messages of its
	// controls even when no component owns them (a button doesn't play a
	// note); with this, they go to the host.
	pass_unowned:        bool,

	// Builds the controls, components and modes. False = the surface
	// can't run.
	setup:         proc(cs: ^Control_Surface) -> bool,
	on_activate:   proc(cs: ^Control_Surface),
	on_deactivate: proc(cs: ^Control_Surface),
	on_destroy:    proc(cs: ^Control_Surface),
	on_idle:       proc(cs: ^Control_Surface),
	// Every message, before the controls: true = handled (no control sees it).
	on_midi:       proc(cs: ^Control_Surface, port: int, m: Message) -> bool,
	// Identify_Method.Surface: the ports are open; answer with `identified`.
	identify:      proc(cs: ^Control_Surface),
	// Its part of a project.
	save:          proc(cs: ^Control_Surface, out: ^[dynamic]u8) -> bool,
	load:          proc(cs: ^Control_Surface, data: []u8) -> bool,
}

// A port pair while active.
Port :: struct {
	role:          string,
	input, output: u32, // the host's ids, or abi.NO_PORT
}

// A running surface. Fields are read-only but `user`.
Control_Surface :: struct {
	surface:    abi.Surface, // first: what the host holds
	host:       ^abi.Host,
	spec:       ^Spec,
	library:    ^Library,
	allocator:  mem.Allocator,
	user:       rawptr, // the author's
	active:     bool,
	identifying: bool,
	ports:      [dynamic]Port,
	controls:   [dynamic]^Control,
	matrices:   [dynamic]^Matrix,
	components: [dynamic]^Component,
	roots:      [dynamic]^Component,
	lookup:     map[u64]Lookup,
	sysex_controls: [dynamic]^Control,
	tasks:      [dynamic]Task,
	next_task:  u32,
	timer:      u32,
	sequence:   int, // activation order, for owners of equal priority
	rules_dirty: bool,
	rules_sent: bool,
	last_rules: [dynamic]u8,
	skin:       ^Skin,
	own_skin:   bool,
	temp:       virtual.Arena, // its temp allocator: freed after each call from the host
	depth:      int,
}

// A library of kit surfaces: what a .fsurf's entry points at.
Library :: struct {
	factory: abi.Surface_Factory, // first: what the host holds
	specs:   []^Spec,
	built:   [dynamic]^Built,
	// Initialized once however many hosts (or loads) use it; the last
	// deinit frees it.
	refs:    int,
	lock:    sync.Mutex,
}

@(private)
Built :: struct {
	spec:       ^Spec,
	desc:       abi.Descriptor,
	ports:      []abi.Port_Spec,
	identity:   abi.Identity,
	strings:    [dynamic]cstring,
	arrays:     [dynamic][]cstring,
}

// The entry's init: builds the descriptors (the first time: it counts).
library_init :: proc "c" (l: ^Library) -> bool {
	context = runtime.default_context()
	sync.mutex_lock(&l.lock)
	defer sync.mutex_unlock(&l.lock)
	if l.refs > 0 {
		l.refs += 1
		return true
	}
	l.factory = {count = factory_count, get_descriptor = factory_descriptor, create = factory_create}
	l.built = make([dynamic]^Built)
	for s in l.specs {
		if s.id == "" || s.name == "" {
			built_free(l)
			return false
		}
		append(&l.built, build(s))
	}
	l.refs = 1
	return true
}

// The entry's deinit (the last one frees the descriptors).
library_deinit :: proc "c" (l: ^Library) {
	context = runtime.default_context()
	sync.mutex_lock(&l.lock)
	defer sync.mutex_unlock(&l.lock)
	if l.refs == 0 do return
	l.refs -= 1
	if l.refs == 0 do built_free(l)
}

@(private)
built_free :: proc(l: ^Library) {
	for b in l.built {
		for c in b.strings do delete(c)
		for a in b.arrays do delete(a)
		delete(b.strings)
		delete(b.arrays)
		delete(b.ports)
		free(b)
	}
	delete(l.built)
	l.built = nil
}

// The entry's get_factory.
library_factory :: proc "c" (l: ^Library, id: cstring) -> rawptr {
	return &l.factory if id == abi.SURFACE_FACTORY_ID else nil
}

@(private)
build :: proc(s: ^Spec) -> ^Built {
	b := new(Built)
	b.strings = make([dynamic]cstring)
	b.arrays = make([dynamic][]cstring)
	cs :: proc(b: ^Built, s: string) -> cstring {
		if s == "" do return nil
		c := strings.clone_to_cstring(s)
		append(&b.strings, c)
		return c
	}
	list :: proc(b: ^Built, items: []string) -> [^]cstring {
		if len(items) == 0 do return nil
		a := make([]cstring, len(items) + 1)
		for it, i in items do a[i] = cs(b, it)
		append(&b.arrays, a)
		return raw_data(a)
	}
	b.spec = s
	b.ports = make([]abi.Port_Spec, len(s.ports))
	for p, i in s.ports {
		flags := p.flags if p.flags != {} else {.Input, .Output}
		b.ports[i] = {struct_size = size_of(abi.Port_Spec), role = cs(b, p.role), flags = flags, input_names = list(b, p.inputs), output_names = list(b, p.outputs)}
	}
	b.desc = {
		struct_size = size_of(abi.Descriptor), fsurf_version = abi.VERSION,
		id = cs(b, s.id), name = cs(b, s.name), vendor = cs(b, s.vendor), version = cs(b, s.version),
		url = cs(b, s.url), description = cs(b, s.description),
		ports = raw_data(b.ports), port_count = u32(len(b.ports)),
		required_extensions = list(b, s.required_extensions),
	}
	if id := s.identity; id != nil {
		b.identity = {
			struct_size = size_of(abi.Identity), method = id.method, port_role = cs(b, id.port_role),
			request = raw_data(id.request), request_size = u32(len(id.request)),
			match = raw_data(id.match), mask = raw_data(id.mask), match_size = u32(len(id.match)),
			delay_ms = id.delay_ms, retry_ms = id.retry_ms, retries = id.retries,
		}
		b.desc.identity = &b.identity
	}
	return b
}

@(private)
factory_count :: proc "c" (f: ^abi.Surface_Factory) -> u32 {
	return u32(len((^Library)(f).built))
}

@(private)
factory_descriptor :: proc "c" (f: ^abi.Surface_Factory, i: u32) -> ^abi.Descriptor {
	l := (^Library)(f)
	return &l.built[i].desc if int(i) < len(l.built) else nil
}

@(private)
factory_create :: proc "c" (f: ^abi.Surface_Factory, host: ^abi.Host, id: cstring) -> ^abi.Surface {
	l := (^Library)(f)
	context = runtime.default_context()
	if host == nil || !abi.version_is_compatible(host.fsurf_version) do return nil
	for b in l.built {
		if b.desc.id != id do continue
		cs := new(Control_Surface)
		cs^ = {host = host, spec = b.spec, library = l, allocator = context.allocator, next_task = 1}
		if virtual.arena_init_growing(&cs.temp) != nil {
			free(cs)
			return nil
		}
		cs.ports = make([dynamic]Port)
		cs.controls = make([dynamic]^Control)
		cs.matrices = make([dynamic]^Matrix)
		cs.components = make([dynamic]^Component)
		cs.roots = make([dynamic]^Component)
		cs.lookup = make(map[u64]Lookup)
		cs.sysex_controls = make([dynamic]^Control)
		cs.tasks = make([dynamic]Task)
		cs.last_rules = make([dynamic]u8)
		cs.skin = b.spec.skin
		if cs.skin == nil {
			cs.skin = skin_make()
			cs.own_skin = true
		}
		cs.surface = {
			struct_size = size_of(abi.Surface), desc = &b.desc, surface_data = cs,
			init = c_init, destroy = c_destroy, identify = c_identify,
			activate = c_activate, deactivate = c_deactivate,
			on_midi = c_on_midi, on_timer = c_on_timer, on_idle = c_on_idle,
			project_save = c_save, project_load = c_load,
		}
		return &cs.surface
	}
	return nil
}

@(private)
from :: #force_inline proc "contextless" (s: ^abi.Surface) -> ^Control_Surface { return (^Control_Surface)(s.surface_data) }

@(private)
c_init :: proc "c" (s: ^abi.Surface) -> bool {
	cs := from(s)
	context = enter(cs)
	defer leave(cs)
	if cs.spec.setup != nil && !cs.spec.setup(cs) do return false
	return true
}

@(private)
c_destroy :: proc "c" (s: ^abi.Surface) {
	cs := from(s)
	context = enter(cs) // (no leave: the arena goes with it)
	if cs.spec.on_destroy != nil do cs.spec.on_destroy(cs)
	tasks_clear(cs)
	for c in cs.components do component_free(c)
	for c in cs.controls do control_free(c)
	for m in cs.matrices { delete(m.controls); free(m) }
	delete(cs.components); delete(cs.roots); delete(cs.controls); delete(cs.matrices)
	delete(cs.lookup); delete(cs.sysex_controls); delete(cs.tasks); delete(cs.last_rules); delete(cs.ports)
	if cs.own_skin do skin_destroy(cs.skin)
	context.temp_allocator = runtime.default_context().temp_allocator
	virtual.arena_destroy(&cs.temp)
	free(cs)
}

// The context of a call from the host: the surface's allocator, and its own
// temp allocator, freed when the outermost call returns.
@(private)
enter :: proc "contextless" (cs: ^Control_Surface) -> runtime.Context {
	context = runtime.default_context()
	c := context
	c.allocator = cs.allocator
	c.temp_allocator = virtual.arena_allocator(&cs.temp)
	cs.depth += 1
	return c
}

@(private)
leave :: proc(cs: ^Control_Surface) {
	cs.depth -= 1
	if cs.depth == 0 do virtual.arena_free_all(&cs.temp)
}

@(private)
set_ports :: proc(cs: ^Control_Surface, ports: [^]abi.Port, count: u32) {
	clear(&cs.ports)
	for i in 0 ..< int(count) do append(&cs.ports, Port{role = string(ports[i].role), input = ports[i].input, output = ports[i].output})
}

@(private)
c_identify :: proc "c" (s: ^abi.Surface, ports: [^]abi.Port, count: u32) {
	cs := from(s)
	context = enter(cs)
	defer leave(cs)
	set_ports(cs, ports, count)
	cs.identifying = true
	if cs.spec.identify != nil {
		cs.spec.identify(cs)
	} else {
		identified(cs, true)
	}
}

// Identify_Method.Surface: the answer.
identified :: proc(cs: ^Control_Surface, ok: bool) {
	cs.identifying = false
	cs.host.identified(cs.host, ok)
}

@(private)
c_activate :: proc "c" (s: ^abi.Surface, ports: [^]abi.Port, count: u32) -> bool {
	cs := from(s)
	context = enter(cs)
	defer leave(cs)
	set_ports(cs, ports, count)
	cs.identifying = false
	cs.active = true
	for c in cs.controls do c.has_last = false // the device knows nothing: send everything again
	for m in cs.spec.hello do send(cs, m)
	cs.timer = cs.host.timer_start(cs.host, TICK_MS)
	cs.rules_dirty = true
	cs.rules_sent = false
	clear(&cs.last_rules)
	for c in cs.roots do component_activate(c)
	if cs.spec.on_activate != nil do cs.spec.on_activate(cs)
	flush(cs)
	return true
}

@(private)
c_deactivate :: proc "c" (s: ^abi.Surface) {
	cs := from(s)
	context = enter(cs)
	defer leave(cs)
	if cs.spec.on_deactivate != nil do cs.spec.on_deactivate(cs)
	#reverse for c in cs.roots do component_deactivate(c)
	for c in cs.controls do light_off(c)
	for m in cs.spec.goodbye do send(cs, m)
	cs.host.timer_stop(cs.host, cs.timer)
	cs.timer = 0
	tasks_clear(cs)
	cs.active = false
	clear(&cs.ports)
}

@(private)
c_on_midi :: proc "c" (s: ^abi.Surface, port: u32, b: [^]u8, size: u32, time_ns: u64) {
	cs := from(s)
	context = enter(cs)
	defer leave(cs)
	role := -1
	for p, i in cs.ports do if p.input == port { role = i; break }
	if role < 0 do return
	m, ok := parse(b[:size])
	if !ok do return
	if cs.spec.on_midi != nil && cs.spec.on_midi(cs, role, m) {
		flush(cs)
		return
	}
	if cs.active do dispatch(cs, role, m, time_ns)
	flush(cs)
}

@(private)
c_on_timer :: proc "c" (s: ^abi.Surface, id: u32) {
	cs := from(s)
	context = enter(cs)
	defer leave(cs)
	if id == cs.timer do run_tasks(cs)
	flush(cs)
}

@(private)
c_on_idle :: proc "c" (s: ^abi.Surface) {
	cs := from(s)
	context = enter(cs)
	defer leave(cs)
	if cs.spec.on_idle != nil do cs.spec.on_idle(cs)
	flush(cs)
}

@(private)
c_save :: proc "c" (s: ^abi.Surface, st: ^abi.Ostream) -> bool {
	cs := from(s)
	context = enter(cs)
	defer leave(cs)
	if cs.spec.save == nil do return true
	buf := make([dynamic]u8, context.temp_allocator)
	if !cs.spec.save(cs, &buf) do return false
	return len(buf) == 0 || st.write(st, raw_data(buf), u64(len(buf))) == i64(len(buf))
}

@(private)
c_load :: proc "c" (s: ^abi.Surface, st: ^abi.Istream) -> bool {
	cs := from(s)
	context = enter(cs)
	defer leave(cs)
	if cs.spec.load == nil do return true
	buf := make([dynamic]u8, context.temp_allocator)
	chunk: [4096]u8
	for {
		n := st.read(st, &chunk[0], len(chunk))
		if n < 0 do return false
		if n == 0 do break
		append(&buf, ..chunk[:n])
	}
	return cs.spec.load(cs, buf[:])
}

// After every call from the host: the claim table, if what owns the
// controls changed.
@(private)
flush :: proc(cs: ^Control_Surface) {
	if cs.active && cs.rules_dirty do publish_rules(cs)
}

// ── What a surface does ───────────────────────────────────────────────

// Sends MIDI on a port's output (by index in the spec's ports; 0 = the
// first). False if it has none, or the host refused.
send :: proc(cs: ^Control_Surface, bytes: []u8, port := 0) -> bool {
	if port < 0 || port >= len(cs.ports) || len(bytes) == 0 do return false
	out := cs.ports[port].output
	if out == abi.NO_PORT do return false
	return cs.host.send_midi(cs.host, out, raw_data(bytes), u32(len(bytes)))
}

// Hands a message on to the host as if it came in on a port and was passed.
inject :: proc(cs: ^Control_Surface, bytes: []u8, port := 0) -> bool {
	if port < 0 || port >= len(cs.ports) || len(bytes) == 0 || cs.host.inject_midi == nil do return false
	return cs.host.inject_midi(cs.host, cs.ports[port].input, raw_data(bytes), u32(len(bytes)))
}

// A short message for the user ("Mixer", "Bank 2").
notify :: proc(cs: ^Control_Surface, text: string) {
	cs.host.notify(cs.host, strings.clone_to_cstring(text, context.temp_allocator))
}

// A line in the host's log.
log :: proc(cs: ^Control_Surface, text: string, level := abi.Log_Level.Info) {
	cs.host.log(cs.host, level, strings.clone_to_cstring(text, context.temp_allocator))
}

// An extension of the host (its function table), or nil.
extension :: proc(cs: ^Control_Surface, id: string, version: u32) -> rawptr {
	return cs.host.get_extension(cs.host, strings.clone_to_cstring(id, context.temp_allocator), version)
}

// The host's clock, in nanoseconds.
now_ns :: proc(cs: ^Control_Surface) -> u64 { return cs.host.now_ns(cs.host) }

// The surface's settings blob (kept by the host for this device). Free
// with `delete`.
settings_get :: proc(cs: ^Control_Surface, allocator := context.allocator) -> []u8 {
	n := cs.host.settings_get(cs.host, nil, 0)
	if n == 0 do return nil
	buf := make([]u8, n, allocator)
	cs.host.settings_get(cs.host, raw_data(buf), n)
	return buf
}

// Replaces the surface's settings blob.
settings_set :: proc(cs: ^Control_Surface, data: []u8) -> bool {
	return cs.host.settings_set(cs.host, raw_data(data), u32(len(data)))
}

// Adds a component that is active while the surface is (activated in the
// order added).
surface_add :: proc(cs: ^Control_Surface, c: ^Component) {
	append(&cs.roots, c)
	if cs.active {
		component_activate(c)
	}
}
