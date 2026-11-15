// The smallest useful surface, in Odin against the ABI package: the same
// as examples/hello_c (read it for what it does), built with
// -build-mode:dll into a .fsurf.
package hello_odin

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

import abi "../../abi"

// What a host offers as "org.fsurf.test" version 1 (the tests do).
Test_Ext :: struct {
	ping: proc "c" (host: ^abi.Host, what: cstring),
}

Hello :: struct {
	surface:  abi.Surface,
	host:     ^abi.Host,
	out_port: u32,
	timer:    u32,
	ticks:    u32,
}

in_names := [?]cstring{"Hello*", nil}
out_names := [?]cstring{"Hello*", nil}

ports := [?]abi.Port_Spec{{
	struct_size  = size_of(abi.Port_Spec),
	role         = "main",
	flags        = {.Input, .Output},
	input_names  = raw_data(in_names[:]),
	output_names = raw_data(out_names[:]),
}}

// Its claim table: its pads (notes 36-51) and its own SysEx come to it.
own_sysex := [?]u8{0xF0, 0x7D}
rules := [?]abi.Rule{
	{port = abi.NO_PORT, messages = abi.MESSAGES_NOTES, first = 36, end = 52, action = .Claim},
	{port = abi.NO_PORT, messages = {.Sysex}, sysex = raw_data(own_sysex[:]), sysex_size = len(own_sysex), action = .Claim},
}

id_match := [?]u8{0xF0, 0x7E, 0x00, 0x06, 0x02, 0x7D}
id_mask := [?]u8{0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0xFF}

identity := abi.Identity{
	struct_size = size_of(abi.Identity),
	method      = .Request,
	match       = raw_data(id_match[:]),
	mask        = raw_data(id_mask[:]),
	match_size  = len(id_match),
}

descriptor := abi.Descriptor{
	struct_size   = size_of(abi.Descriptor),
	fsurf_version = abi.VERSION,
	id            = "org.fsurf.example.hello-odin",
	name          = "Hello (Odin)",
	vendor        = "fire-surface",
	version       = "0.2.0",
	url           = "https://github.com/bcrowe306/fire-surface",
	description   = "The smallest useful surface, in Odin",
	ports         = raw_data(ports[:]),
	port_count    = len(ports),
	identity      = &identity,
}

self :: proc "contextless" (s: ^abi.Surface) -> ^Hello { return (^Hello)(s.surface_data) }

send :: proc "contextless" (h: ^Hello, bytes: []u8) {
	if h.out_port != abi.NO_PORT do h.host.send_midi(h.host, h.out_port, raw_data(bytes), u32(len(bytes)))
}

hello_init :: proc "c" (s: ^abi.Surface) -> bool {
	h := self(s)
	h.host.log(h.host, .Info, "hello init")
	if ext := (^Test_Ext)(h.host.get_extension(h.host, "org.fsurf.test", 1)); ext != nil do ext.ping(h.host, "init")
	return true
}

hello_destroy :: proc "c" (s: ^abi.Surface) {
	context = runtime.default_context()
	free(self(s))
}

hello_activate :: proc "c" (s: ^abi.Surface, p: [^]abi.Port, count: u32) -> bool {
	h := self(s)
	if count != 1 do return false
	h.out_port = p[0].output
	hi := [?]u8{0xF0, 0x7D, 0x01, 0xF7}
	send(h, hi[:])
	n: u32
	if h.host.settings_get(h.host, &n, size_of(n)) != size_of(n) do n = 0
	n += 1
	h.host.settings_set(h.host, &n, size_of(n))
	h.timer = h.host.timer_start(h.host, 10)
	return h.host.set_rules(h.host, raw_data(rules[:]), len(rules))
}

hello_deactivate :: proc "c" (s: ^abi.Surface) {
	h := self(s)
	bye := [?]u8{0xF0, 0x7D, 0x00, 0xF7}
	send(h, bye[:])
	h.host.timer_stop(h.host, h.timer)
	h.timer = 0
	h.out_port = abi.NO_PORT
}

hello_on_midi :: proc "c" (s: ^abi.Surface, port: u32, b: [^]u8, size: u32, time_ns: u64) {
	h := self(s)
	if size == 3 && b[0] & 0xF0 == 0x90 && b[2] > 0 {
		lit := [3]u8{b[0], b[1], 127}
		send(h, lit[:])
	} else if size > 0 && b[0] == 0xF0 {
		h.host.notify(h.host, "sysex")
	}
}

hello_on_timer :: proc "c" (s: ^abi.Surface, id: u32) {
	h := self(s)
	if id != h.timer do return
	h.ticks += 1
	cc := [3]u8{0xB0, 16, u8(h.ticks & 127)}
	send(h, cc[:])
}

hello_save :: proc "c" (s: ^abi.Surface, st: ^abi.Ostream) -> bool {
	context = runtime.default_context()
	text := fmt.tprintf("ticks=%d", self(s).ticks)
	return st.write(st, raw_data(text), u64(len(text))) == i64(len(text))
}

hello_load :: proc "c" (s: ^abi.Surface, st: ^abi.Istream) -> bool {
	context = runtime.default_context()
	h := self(s)
	buf: [32]u8
	n := st.read(st, &buf[0], len(buf) - 1)
	if n <= 0 do return false
	text := string(buf[:n])
	if !strings.has_prefix(text, "ticks=") do return false
	t, ok := strconv.parse_uint(text[len("ticks="):], 10)
	if !ok do return false
	h.ticks = u32(t)
	h.host.notify(h.host, fmt.ctprintf("loaded %d", t))
	return true
}

factory := abi.Surface_Factory{
	count = proc "c" (f: ^abi.Surface_Factory) -> u32 { return 1 },
	get_descriptor = proc "c" (f: ^abi.Surface_Factory, i: u32) -> ^abi.Descriptor {
		return &descriptor if i == 0 else nil
	},
	create = proc "c" (f: ^abi.Surface_Factory, host: ^abi.Host, id: cstring) -> ^abi.Surface {
		if id != descriptor.id || !abi.version_is_compatible(host.fsurf_version) do return nil
		context = runtime.default_context()
		h := new(Hello)
		h.host = host
		h.out_port = abi.NO_PORT
		h.surface = {
			struct_size  = size_of(abi.Surface),
			desc         = &descriptor,
			surface_data = h,
			init         = hello_init,
			destroy      = hello_destroy,
			activate     = hello_activate,
			deactivate   = hello_deactivate,
			on_midi      = hello_on_midi,
			on_timer     = hello_on_timer,
			project_save = hello_save,
			project_load = hello_load,
		}
		return &h.surface
	},
}

// The library's one export.
@(export, link_name = abi.ENTRY_SYMBOL)
fsurf_entry := abi.Entry{
	fsurf_version = abi.VERSION,
	init = proc "c" (path: cstring) -> bool { return true },
	deinit = proc "c" () {},
	get_factory = proc "c" (id: cstring) -> rawptr {
		return &factory if id == abi.SURFACE_FACTORY_ID else nil
	},
}
