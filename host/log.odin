package fsurf_host

import "core:strings"

import abi "../abi"

/*
The surfaces' log: each line a surface logged (`log` in fsurf.h, the
kit's `surface.log` and `core:log`) and each the host wrote about one
(a device that didn't open, a reload that failed), with its time, level
and surface. A tool for writing surfaces: a host shows it beside the
monitor.

	host.log_set_debug(&h, true) // debug lines kept too (off by default)
	for e in host.log_entries(&h) do fmt.println(host.log_line(e))
	host.log_clear(&h)

- **Bounded:** at most LOG_PER_SURFACE lines a surface (its oldest go
  first, so one that logs every message doesn't push the others out) and
  LOG_CAPACITY in all.
- **Repeats:** a line the same as its surface's last (level and text) is
  counted on that one, not added.

Surface thread only, as every call from a surface is. Lines also go on to
`Host_Config.log`, kept or not.
*/

// The lines the log keeps in all, and for each surface (or the host's own).
LOG_CAPACITY :: 4096
LOG_PER_SURFACE :: 1024

// Who wrote a log line.
Log_Source :: enum u8 {
	Surface, // the surface itself
	Host,    // the host, about it (or about a library: uid 0)
}

// A line in the log.
Log_Entry :: struct {
	time_ns: u64, // its last repeat's
	level:   abi.Log_Level,
	source:  Log_Source,
	uid:     u32, // the surface's (Instance.uid); 0 = none
	surface: string, // its name, when written (owned)
	message: string, // owned
	count:   int, // 1, or how many times it came in a row
}

@(private)
Log :: struct {
	debug:   bool,
	entries: [dynamic]Log_Entry,
}

@(private)
log_init :: proc(l: ^Log, allocator := context.allocator) {
	l.entries = make([dynamic]Log_Entry, allocator)
}

@(private)
log_destroy :: proc(l: ^Log) {
	for e in l.entries do log_entry_free(e, l.entries.allocator)
	delete(l.entries)
}

@(private)
log_entry_free :: proc(e: Log_Entry, allocator := context.allocator) {
	delete(e.surface, allocator)
	delete(e.message, allocator)
}

// Keeps debug lines too, or not (the default: they're dropped).
log_set_debug :: proc(h: ^Host, on: bool) {
	h.log.debug = on
}

// Whether debug lines are kept.
log_debug :: proc(h: ^Host) -> bool {
	return h.log.debug
}

// What the log has, oldest first.
log_entries :: proc(h: ^Host) -> []Log_Entry {
	return h.log.entries[:]
}

// Forgets what the log has.
log_clear :: proc(h: ^Host) {
	for e in h.log.entries do log_entry_free(e, h.log.entries.allocator)
	clear(&h.log.entries)
}

// Writes a line in the log, about surface `s` (nil: none), and hands it on
// to `Host_Config.log`. For the app's own lines about its surfaces too
// (`source = .Host`).
log_add :: proc(h: ^Host, s: ^Instance, level: abi.Log_Level, message: string, source := Log_Source.Host) {
	if h.config.log != nil do h.config.log(h.config.user, s, level, message)
	if level == .Debug && !h.log.debug do return
	l := &h.log
	uid := s.uid if s != nil else 0
	now := host_now_ns(h)
	// The same as this surface's last line: counted on it.
	for i := len(l.entries) - 1; i >= 0; i -= 1 {
		e := &l.entries[i]
		if e.uid != uid || e.source != source do continue
		if e.level == level && e.message == message {
			e.count += 1
			e.time_ns = now
			return
		}
		break
	}
	a := l.entries.allocator
	// Its surface's oldest goes when it has its share; the oldest of all
	// when the log is full.
	n, first := 0, -1
	for e, i in l.entries do if e.uid == uid {
		if first < 0 do first = i
		n += 1
	}
	if n >= LOG_PER_SURFACE {
		log_entry_free(l.entries[first], a)
		ordered_remove(&l.entries, first)
	} else if len(l.entries) >= LOG_CAPACITY {
		log_entry_free(l.entries[0], a)
		ordered_remove(&l.entries, 0)
	}
	name := string(s.descriptor.name) if s != nil && s.descriptor != nil && s.descriptor.name != nil else ""
	append(&l.entries, Log_Entry{
		time_ns = now, level = level, source = source, uid = uid, count = 1,
		surface = strings.clone(name, a), message = strings.clone(message, a),
	})
}

// A level's name: "debug", "info", "warning", "error".
log_level_name :: proc(level: abi.Log_Level) -> string {
	switch level {
	case .Debug:   return "debug"
	case .Info:    return "info"
	case .Warning: return "warning"
	case .Error:   return "error"
	}
	return "?"
}

// An entry as a line of text (in the temp allocator):
//
//	12.345  info     Grid (kit example)  mode: mixer
//	12.400  warning  host: Grid (kit example)  its device "display" (2982:1967) isn't open
//	12.500  debug    Grid (kit example)  pad 3,0 (x12)
log_line :: proc(e: Log_Entry) -> string {
	b := strings.builder_make(context.temp_allocator)
	ms := e.time_ns / 1_000_000
	strings.write_uint(&b, uint(ms / 1000))
	strings.write_byte(&b, '.')
	frac := ms % 1000
	if frac < 100 do strings.write_byte(&b, '0')
	if frac < 10 do strings.write_byte(&b, '0')
	strings.write_uint(&b, uint(frac))
	strings.write_string(&b, "  ")
	name := log_level_name(e.level)
	strings.write_string(&b, name)
	for _ in len(name) ..< 9 do strings.write_byte(&b, ' ')
	if e.source == .Host do strings.write_string(&b, "host: " if e.surface != "" else "host")
	strings.write_string(&b, e.surface)
	strings.write_string(&b, "  ")
	strings.write_string(&b, e.message)
	if e.count > 1 {
		strings.write_string(&b, " (x")
		strings.write_int(&b, e.count)
		strings.write_string(&b, ")")
	}
	return strings.to_string(b)
}
