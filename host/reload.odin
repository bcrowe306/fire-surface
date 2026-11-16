package fsurf_host

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"


/*
Hot reload, for a surface's author: a library loaded with
`library_load_watched` is a copy of the file (so the original can be
rebuilt while it is loaded, and a new copy loads fresh, under a new
name). `host_update` watches the original; once it has changed and stayed
the same for `RELOAD_SETTLE_MS`, the host saves each of its surfaces'
project state, destroys them, loads the new copy, makes them again with
their settings and that state, and activates them on the same ports. A
build that doesn't load leaves the old one running (logged, and
`Host_Config.on_reload` told); the next change is tried again.
*/

// How long a changed library must stay unchanged before it is reloaded
// (a build writes it in pieces).
RELOAD_SETTLE_MS :: 300

@(private)
Watch :: struct {
	original:   string,
	dir:        string, // where the copies go
	copy:       string, // the one loaded
	generation: int,
	stamp:      File_Stamp, // the original's, when last loaded (or tried)
	pending:    bool,
	seen:       File_Stamp,
	seen_ns:    u64,
}

@(private)
File_Stamp :: struct {
	modified: time.Time,
	size:     i64,
}

@(private)
stamp_of :: proc(path: string) -> (File_Stamp, bool) {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil do return {}, false
	return {fi.modification_time, fi.size}, true
}

// Loads a .fsurf for hot reload: a copy of it, watched by `host_update`
// (for the libraries the host has: added for detection, or with surfaces
// made from them). Unload it with `library_unload`, as any other.
library_load_watched :: proc(path: string, allocator := context.allocator) -> (^Library, Library_Error) {
	dir, err := os.make_directory_temp("", "fsurf-reload-*", allocator)
	if err != nil do return nil, .Cannot_Load
	w := new(Watch, allocator)
	w^ = {original = strings.clone(path, allocator), dir = dir}
	l, le := load_copy(w, allocator)
	if le != .None {
		watch_free(w, allocator)
		return nil, le
	}
	l.watch = w
	return l, .None
}

// Loads the next copy of the original. Records its stamp either way.
@(private)
load_copy :: proc(w: ^Watch, allocator := context.allocator) -> (^Library, Library_Error) {
	w.stamp, _ = stamp_of(w.original)
	w.pending = false
	data, err := os.read_entire_file(w.original, context.temp_allocator)
	if err != nil do return nil, .Cannot_Load
	w.generation += 1
	name := fmt.tprintf("%d-%s", w.generation, filepath.base(w.original))
	dst, _ := filepath.join({w.dir, name}, context.temp_allocator)
	if os.write_entire_file(dst, data) != nil do return nil, .Cannot_Load
	l, le := library_load(dst, allocator)
	if le != .None {
		os.remove(dst)
		return nil, le
	}
	return l, .None
}

@(private)
watch_free :: proc(w: ^Watch, allocator := context.allocator) {
	os.remove_all(w.dir)
	delete(w.dir, allocator)
	delete(w.original, allocator)
	free(w, allocator)
}

// Checks the watched libraries; reloads those whose rebuild has settled.
@(private)
reload_check :: proc(h: ^Host) {
	libs := make([dynamic]^Library, context.temp_allocator)
	add :: proc(libs: ^[dynamic]^Library, l: ^Library) {
		if l.watch == nil do return
		for x in libs do if x == l do return
		append(libs, l)
	}
	for l in h.libraries do add(&libs, l)
	for s in h.instances do add(&libs, s.library)
	now := host_now_ns(h)
	for l in libs {
		w := l.watch
		st, ok := stamp_of(w.original)
		if !ok || st == w.stamp {
			w.pending = false
			continue
		}
		if !w.pending || st != w.seen {
			w.pending = true
			w.seen = st
			w.seen_ns = now
			continue
		}
		if now - w.seen_ns >= RELOAD_SETTLE_MS * 1_000_000 do library_reload(h, l)
	}
}

// Reloads a watched library now (as `host_update` does when its file
// changes). False if the new build didn't load: the old one goes on.
library_reload :: proc(h: ^Host, l: ^Library) -> bool {
	w := l.watch
	if w == nil do return false
	fresh, err := load_copy(w, h.allocator)
	if err != .None {
		msg := fmt.tprintf("%s: the new build didn't load (%v); the old one goes on", w.original, err)
		log_add(h, nil, .Error, msg)
		if h.config.on_reload != nil do h.config.on_reload(h.config.user, l, false)
		return false
	}

	// Its surfaces, as they are.
	Saved :: struct {
		s:       ^Instance,
		id:      string,
		state:   Instance_State,
		ports:   [dynamic]Port_Assignment,
		project: []u8,
		has:     bool,
	}
	saved := make([dynamic]Saved, context.temp_allocator)
	for s in h.instances {
		if s.library != l do continue
		sv := Saved{s = s, id = strings.clone(string(s.descriptor.id), context.temp_allocator), state = s.state}
		sv.ports = make([dynamic]Port_Assignment, context.temp_allocator)
		for p in s.ports {
			append(&sv.ports, Port_Assignment{input = p.input, output = p.output,
				input_name = strings.clone(string(p.input_name), context.temp_allocator) if p.input_name != nil else "",
				output_name = strings.clone(string(p.output_name), context.temp_allocator) if p.output_name != nil else ""})
		}
		data, ok := instance_project_save(s, context.temp_allocator)
		sv.project, sv.has = data, ok && data != nil
		instance_detach(s)
		append(&saved, sv)
	}
	device_ids := make(map[^Device]string, allocator = context.temp_allocator)
	for d in h.devices do if d.library == l do device_ids[d] = strings.clone(string(d.descriptor.id), context.temp_allocator)

	// The new code in the old Library (everything points at it).
	old := l^
	l.path = fresh.path
	l.descriptors = fresh.descriptors
	l.lib = fresh.lib
	l.entry = fresh.entry
	l.factory = fresh.factory
	free(fresh, h.allocator)
	if old.entry.deinit != nil do old.entry.deinit()
	if old.lib != nil do unload_dynlib(old.lib)
	delete(old.descriptors, h.allocator)
	os.remove(old.path)
	delete(old.path, h.allocator)

	// Its surfaces again: their settings kept, their project given back,
	// started where they were.
	for sv in saved {
		s := sv.s
		if !instance_attach(s, sv.id) {
			log_add(h, s, .Error, fmt.tprintf("%s: %s is gone or didn't start after the reload", w.original, sv.id))
			instance_destroy_detached(s)
			continue
		}
		if sv.has do instance_project_load(s, sv.project)
		switch sv.state {
		case .Active: instance_activate(s, sv.ports[:])
		case .Identifying: instance_identify(s, sv.ports[:])
		case .Ready:
		}
	}
	for d, id in device_ids {
		d.descriptor = library_find(l, id)
		if d.descriptor == nil {
			for x, i in h.devices do if x == d { device_remove(h, i); break }
		}
	}
	rematch(h)
	log_add(h, nil, .Info, fmt.tprintf("%s: reloaded", w.original))
	if h.config.on_reload != nil do h.config.on_reload(h.config.user, l, true)
	return true
}
