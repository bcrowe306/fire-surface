/*
The fire-surface protocol in Odin: the same declarations as
`include/fsurf.h`, for hosts and surfaces written in Odin. Read the header
for the rules (threads, who owns what, versions); each declaration here
names its C counterpart.

A surface library exports `fsurf_entry` (an `Entry`):

	@(export, link_name = abi.ENTRY_SYMBOL)
	fsurf_entry := abi.Entry{fsurf_version = abi.VERSION, init = ..., deinit = ..., get_factory = ...}
*/
package fsurf_abi

// The header's version: FSURF_VERSION_MAJOR, _MINOR, _REVISION.
VERSION :: Version{0, 1, 0}

// The symbol a .fsurf exports: an `Entry`.
ENTRY_SYMBOL :: "fsurf_entry"

// The id of the surface factory (FSURF_SURFACE_FACTORY_ID).
SURFACE_FACTORY_ID :: "fsurf.surface-factory"

// No port (FSURF_NO_PORT).
NO_PORT :: max(u32)

// A version of the protocol (fsurf_version_t).
Version :: struct {
	major, minor, revision: u32,
}

// Whether a host of this package's version loads a library built against
// `v` (fsurf_version_is_compatible): before 1.0 the same major and minor,
// from 1.0 the same major.
version_is_compatible :: proc "contextless" (v: Version) -> bool {
	if v.major != VERSION.major do return false
	return VERSION.major > 0 || v.minor == VERSION.minor
}

// Where a host's project goes (fsurf_ostream_t). `write` returns the bytes
// written, or -1.
Ostream :: struct {
	ctx:   rawptr,
	write: proc "c" (stream: ^Ostream, buffer: rawptr, size: u64) -> i64,
}

// Where a project comes from (fsurf_istream_t). `read` returns the bytes
// read (0 at the end), or -1.
Istream :: struct {
	ctx:  rawptr,
	read: proc "c" (stream: ^Istream, buffer: rawptr, size: u64) -> i64,
}

// A MIDI port pair a surface uses, by role (fsurf_port_spec_t). Names are
// null-terminated arrays of patterns: `*` for any run of characters, case
// ignored, an optional "mac:", "win:" or "linux:" prefix.
Port_Spec :: struct {
	struct_size:  u32,
	role:         cstring,
	flags:        Port_Flags,
	input_names:  [^]cstring,
	output_names: [^]cstring,
}

// FSURF_PORT_*.
Port_Flag :: enum u32 {
	Input    = 0,
	Output   = 1,
	Optional = 2,
}

// A port spec's flags.
Port_Flags :: distinct bit_set[Port_Flag; u32]

// How a host recognizes a device (FSURF_IDENTIFY_*).
Identify_Method :: enum u32 {
	Names   = 0, // the port names alone
	Request = 1, // a request sent, the reply matched
	Surface = 2, // the surface's `identify`, answered with `Host.identified`
}

// How a host recognizes the device on its ports (fsurf_identity_t). The
// reply matches when `(reply[i] & mask[i]) == (match[i] & mask[i])` for
// each i < match_size (mask nil: all bits).
Identity :: struct {
	struct_size:  u32,
	method:       Identify_Method,
	port_role:    cstring, // nil = the first port spec
	request:      [^]u8,   // nil = F0 7E 7F 06 01 F7
	request_size: u32,
	match:        [^]u8,
	mask:         [^]u8,
	match_size:   u32,
	delay_ms:     u32,
	retry_ms:     u32,
	retries:      u32,
}

// One kind of surface: a controller model (fsurf_descriptor_t).
Descriptor :: struct {
	struct_size:         u32,
	fsurf_version:       Version,
	id:                  cstring, // reverse-DNS: "com.example.mk2"
	name:                cstring,
	vendor:              cstring,
	version:             cstring,
	url:                 cstring, // or nil
	description:         cstring, // or nil
	ports:               [^]Port_Spec,
	port_count:          u32,
	identity:            ^Identity, // nil = by port names alone
	required_extensions: [^]cstring, // null-terminated, or nil
}

// A host log level (FSURF_LOG_*).
Log_Level :: enum i32 {
	Debug   = 0,
	Info    = 1,
	Warning = 2,
	Error   = 3,
}

// The host, as a surface sees it (fsurf_host_t).
Host :: struct {
	struct_size:   u32,
	fsurf_version: Version,
	host_data:     rawptr,
	name:          cstring,
	vendor:        cstring,
	url:           cstring,
	version:       cstring,
	get_extension: proc "c" (host: ^Host, id: cstring, version: u32) -> rawptr,
	log:           proc "c" (host: ^Host, level: Log_Level, message: cstring),
	notify:        proc "c" (host: ^Host, text: cstring),
	send_midi:     proc "c" (host: ^Host, port: u32, bytes: [^]u8, size: u32) -> bool,
	timer_start:   proc "c" (host: ^Host, period_ms: u32) -> u32,
	timer_stop:    proc "c" (host: ^Host, timer_id: u32),
	now_ns:        proc "c" (host: ^Host) -> u64,
	settings_get:  proc "c" (host: ^Host, buffer: rawptr, capacity: u32) -> u32,
	settings_set:  proc "c" (host: ^Host, data: rawptr, size: u32) -> bool,
	identified:    proc "c" (host: ^Host, ok: bool),
}

// A port pair given at activate (fsurf_port_t).
Port :: struct {
	role:        cstring,
	input:       u32, // or NO_PORT
	output:      u32, // or NO_PORT
	input_name:  cstring,
	output_name: cstring,
}

// A surface (fsurf_surface_t).
Surface :: struct {
	struct_size:   u32,
	desc:          ^Descriptor,
	surface_data:  rawptr,
	init:          proc "c" (surface: ^Surface) -> bool,
	destroy:       proc "c" (surface: ^Surface),
	identify:      proc "c" (surface: ^Surface, ports: [^]Port, count: u32),
	activate:      proc "c" (surface: ^Surface, ports: [^]Port, count: u32) -> bool,
	deactivate:    proc "c" (surface: ^Surface),
	on_midi:       proc "c" (surface: ^Surface, port: u32, bytes: [^]u8, size: u32, time_ns: u64),
	on_timer:      proc "c" (surface: ^Surface, timer_id: u32),
	on_idle:       proc "c" (surface: ^Surface),
	project_save:  proc "c" (surface: ^Surface, stream: ^Ostream) -> bool,
	project_load:  proc "c" (surface: ^Surface, stream: ^Istream) -> bool,
	get_extension: proc "c" (surface: ^Surface, id: cstring) -> rawptr,
}

// The factory of a library's surfaces (fsurf_surface_factory_t).
Surface_Factory :: struct {
	count:          proc "c" (factory: ^Surface_Factory) -> u32,
	get_descriptor: proc "c" (factory: ^Surface_Factory, index: u32) -> ^Descriptor,
	create:         proc "c" (factory: ^Surface_Factory, host: ^Host, surface_id: cstring) -> ^Surface,
}

// What a .fsurf exports as `fsurf_entry` (fsurf_entry_t).
Entry :: struct {
	fsurf_version: Version,
	init:          proc "c" (library_path: cstring) -> bool,
	deinit:        proc "c" (),
	get_factory:   proc "c" (factory_id: cstring) -> rawptr,
}
