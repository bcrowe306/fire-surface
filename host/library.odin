/*
The host side of fire-surface, for hosts written in Odin: finding .fsurf
libraries, loading them, and running their surfaces (lifecycle, MIDI to
them, their timers, settings and project state). Everything here is for
the host's surface thread.

	lib, err := host.library_load("/path/Example.fsurf")
	h: host.Host
	host.host_init(&h, {name = "My DAW", version = "1.0", send_midi = to_device})
	s, _ := host.instance_create(&h, lib, "com.example.mk2")
	host.instance_activate(s, {{role = "main", input = 0, output = 0}})
	// MIDI from the device:   host.instance_midi(s, 0, bytes, time_ns)
	// once a frame:           host.host_update(&h)
	host.instance_destroy(s)
	host.host_destroy(&h)
	host.library_unload(lib)
*/
package fsurf_host

import "core:dynlib"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import abi "../abi"

// A .fsurf's file extension.
EXTENSION :: ".fsurf"

// A loaded .fsurf. Fields are read-only.
Library :: struct {
	path:        string,
	descriptors: []^abi.Descriptor, // what it offers, valid until it is unloaded
	lib:         dynlib.Library,
	entry:       ^abi.Entry,
	factory:     ^abi.Surface_Factory,
	instances:   int, // surfaces made from it and not destroyed
}

// Why a library didn't load.
Library_Error :: enum {
	None,
	Cannot_Load,          // not a dynamic library this system can load (or missing)
	No_Entry,             // no `fsurf_entry` symbol
	Incompatible_Version, // built against a protocol version this host doesn't load
	Init_Failed,          // its entry's init returned false
	No_Factory,           // it has no surface factory
	Bad_Descriptor,       // a descriptor without an id or name, or of another version
}

// Loads a .fsurf and reads its descriptors. Unload it with
// `library_unload` once its surfaces are destroyed.
library_load :: proc(path: string, allocator := context.allocator) -> (^Library, Library_Error) {
	lib, ok := dynlib.load_library(path)
	if !ok do return nil, .Cannot_Load
	entry := (^abi.Entry)(dynlib.symbol_address(lib, abi.ENTRY_SYMBOL))
	if entry == nil {
		dynlib.unload_library(lib)
		return nil, .No_Entry
	}
	if !abi.version_is_compatible(entry.fsurf_version) || entry.init == nil || entry.get_factory == nil {
		dynlib.unload_library(lib)
		return nil, .Incompatible_Version
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if !entry.init(cpath) {
		dynlib.unload_library(lib)
		return nil, .Init_Failed
	}
	fail :: proc(entry: ^abi.Entry, lib: dynlib.Library, e: Library_Error) -> (^Library, Library_Error) {
		if entry.deinit != nil do entry.deinit()
		dynlib.unload_library(lib)
		return nil, e
	}
	factory := (^abi.Surface_Factory)(entry.get_factory(abi.SURFACE_FACTORY_ID))
	if factory == nil || factory.count == nil || factory.get_descriptor == nil || factory.create == nil {
		return fail(entry, lib, .No_Factory)
	}
	n := factory.count(factory)
	descs := make([dynamic]^abi.Descriptor, 0, n, allocator)
	for i in 0 ..< n {
		d := factory.get_descriptor(factory, i)
		if d == nil || d.struct_size < size_of(abi.Descriptor) || !abi.version_is_compatible(d.fsurf_version) || d.id == nil || d.name == nil {
			delete(descs)
			return fail(entry, lib, .Bad_Descriptor)
		}
		append(&descs, d)
	}
	l := new(Library, allocator)
	l^ = {path = strings.clone(path, allocator), descriptors = descs[:], lib = lib, entry = entry, factory = factory}
	return l, .None
}

// Calls the library's deinit and unloads it. False (and nothing done)
// while surfaces made from it are still there.
library_unload :: proc(l: ^Library, allocator := context.allocator) -> bool {
	if l == nil do return true
	if l.instances > 0 do return false
	if l.entry.deinit != nil do l.entry.deinit()
	dynlib.unload_library(l.lib)
	delete(l.descriptors, allocator)
	delete(l.path, allocator)
	free(l, allocator)
	return true
}

// The library's descriptor with this id, or nil.
library_find :: proc(l: ^Library, surface_id: string) -> ^abi.Descriptor {
	for d in l.descriptors do if string(d.id) == surface_id do return d
	return nil
}

// What a scan found of one surface: copies of its descriptor's strings.
Surface_Info :: struct {
	id, name, vendor, version, description: string,
}

// One library a scan found: its surfaces, or why it didn't load.
Scan_Entry :: struct {
	path:     string,
	error:    Library_Error,
	surfaces: []Surface_Info,
}

// Loads every .fsurf in `folders` (not their subfolders), reads its
// surfaces, and unloads it again. Free the result with `scan_destroy`.
scan :: proc(folders: []string, allocator := context.allocator) -> []Scan_Entry {
	out := make([dynamic]Scan_Entry, allocator)
	for folder in folders {
		files, err := os.read_all_directory_by_path(folder, context.temp_allocator)
		if err != nil do continue
		paths := make([dynamic]string, context.temp_allocator)
		for f in files do if f.type != .Directory && strings.to_lower(filepath.ext(f.name), context.temp_allocator) == EXTENSION do append(&paths, f.fullpath)
		slice.sort(paths[:]) // the same order every time
		for p in paths {
			e := Scan_Entry{path = strings.clone(p, allocator)}
			l, le := library_load(p, allocator)
			e.error = le
			if le == .None {
				infos := make([]Surface_Info, len(l.descriptors), allocator)
				for d, i in l.descriptors {
					infos[i] = {
						id          = clone_c(d.id, allocator),
						name        = clone_c(d.name, allocator),
						vendor      = clone_c(d.vendor, allocator),
						version     = clone_c(d.version, allocator),
						description = clone_c(d.description, allocator),
					}
				}
				e.surfaces = infos
				library_unload(l, allocator)
			}
			append(&out, e)
		}
	}
	return out[:]
}

// Frees what `scan` returned.
scan_destroy :: proc(entries: []Scan_Entry, allocator := context.allocator) {
	for e in entries {
		for s in e.surfaces {
			delete(s.id, allocator); delete(s.name, allocator); delete(s.vendor, allocator)
			delete(s.version, allocator); delete(s.description, allocator)
		}
		delete(e.surfaces, allocator)
		delete(e.path, allocator)
	}
	delete(entries, allocator)
}

// Where .fsurf files are looked for on this system, first to last: the
// folders in FSURF_PATH (separated as PATH is), then the user's, then the
// system's. Free with `delete_folders`.
//
//	macOS    ~/Library/Audio/Plug-Ins/fsurf, /Library/Audio/Plug-Ins/fsurf
//	Windows  %LOCALAPPDATA%\Programs\Common\fsurf, %COMMONPROGRAMFILES%\fsurf
//	Linux    ~/.fsurf, /usr/lib/fsurf
default_folders :: proc(allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	sep := ";" when ODIN_OS == .Windows else ":"
	if env := os.get_env("FSURF_PATH", context.temp_allocator); env != "" {
		for p in strings.split(env, sep, context.temp_allocator) do if p != "" do append(&out, strings.clone(p, allocator))
	}
	when ODIN_OS == .Darwin {
		if home := os.get_env("HOME", context.temp_allocator); home != "" {
			append(&out, join({home, "Library/Audio/Plug-Ins/fsurf"}, allocator))
		}
		append(&out, strings.clone("/Library/Audio/Plug-Ins/fsurf", allocator))
	} else when ODIN_OS == .Windows {
		if d := os.get_env("LOCALAPPDATA", context.temp_allocator); d != "" do append(&out, join({d, "Programs", "Common", "fsurf"}, allocator))
		if d := os.get_env("COMMONPROGRAMFILES", context.temp_allocator); d != "" do append(&out, join({d, "fsurf"}, allocator))
	} else {
		if home := os.get_env("HOME", context.temp_allocator); home != "" do append(&out, join({home, ".fsurf"}, allocator))
		append(&out, strings.clone("/usr/lib/fsurf", allocator))
	}
	return out[:]
}

// Frees what `default_folders` returned.
delete_folders :: proc(folders: []string, allocator := context.allocator) {
	for f in folders do delete(f, allocator)
	delete(folders, allocator)
}

@(private)
clone_c :: proc(s: cstring, allocator := context.allocator) -> string {
	return strings.clone(string(s), allocator) if s != nil else ""
}

@(private)
join :: proc(parts: []string, allocator := context.allocator) -> string {
	p, _ := filepath.join(parts, allocator)
	return p
}
