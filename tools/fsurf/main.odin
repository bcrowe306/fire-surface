/*
fsurf: a surface author's command-line tool.

	fsurf scan [FOLDER...]               the .fsurf files found (FSURF_PATH and the system's folders by default)
	fsurf info FILE.fsurf                its surfaces: ports, identity, extensions, controls
	fsurf run FILE.fsurf [OPTIONS] [SCRIPT]
	                                     a surface on a headless host, driven by a script (or stdin), every
	                                     message shown as the MIDI monitor sees it
	    --surface ID   which surface (default: the first)
	    --daw          a fake fsurf.daw (8 tracks, 4 scenes)
	    --watch        hot reload: rebuild the library and `wait`; the surface is reloaded

A script, a command a line ("#" comments):

	in 90 24 64          MIDI from the device (hex), through the claim table
	press NAME [VEL]     a control by its layout name ("Play", "Pads 3,0")
	release NAME
	click NAME           press and release
	turn NAME STEPS      an encoder
	move NAME VALUE      a fader, 0-1
	wait MS              time passes (timers, tasks, hot reload)
	svg FILE             the device as it is now, as a picture
	expect HEX           fail (exit 1) unless the surface sent this since the last command
	daw                  the fake DAW's state
	quit
*/
package fsurf_tool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import host "../../host"
import fst "../../testing"

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		usage()
		os.exit(2)
	}
	switch args[0] {
	case "scan": os.exit(scan(args[1:]))
	case "info": os.exit(info(args[1:]))
	case "run": os.exit(run(args[1:]))
	case "help", "-h", "--help": usage()
	case:
		fmt.eprintfln("fsurf: no command %q", args[0])
		usage()
		os.exit(2)
	}
}

usage :: proc() {
	fmt.eprintln(`usage:
  fsurf scan [FOLDER...]
  fsurf info FILE.fsurf
  fsurf run FILE.fsurf [--surface ID] [--daw] [--watch] [SCRIPT]   (script commands: in, press, release, click,
                                                                   turn, move, wait, svg, expect, daw, quit)`)
}

scan :: proc(folders: []string) -> int {
	fs := folders
	defaults: []string
	if len(fs) == 0 {
		defaults = host.default_folders()
		fs = defaults
	}
	defer if defaults != nil do host.delete_folders(defaults)
	entries := host.scan(fs)
	defer host.scan_destroy(entries)
	for e in entries {
		if e.error != .None {
			fmt.printfln("%s: %v", e.path, e.error)
			continue
		}
		fmt.println(e.path)
		for s in e.surfaces do fmt.printfln("  %s  %s (%s %s)", s.id, s.name, s.vendor, s.version)
	}
	if len(entries) == 0 do fmt.printfln("no .fsurf files in %v", fs)
	return 0
}

info :: proc(args: []string) -> int {
	if len(args) != 1 {
		usage()
		return 2
	}
	lib, err := host.library_load(args[0])
	if err != .None {
		fmt.eprintfln("%s: %v", args[0], err)
		return 1
	}
	defer host.library_unload(lib)
	for d in lib.descriptors {
		fmt.printfln("%s  %s", d.id, d.name)
		fmt.printfln("  vendor %s, version %s, protocol %d.%d.%d", d.vendor, d.version, d.fsurf_version.major, d.fsurf_version.minor, d.fsurf_version.revision)
		if d.url != nil do fmt.printfln("  %s", d.url)
		if d.description != nil do fmt.printfln("  %s", d.description)
		for i in 0 ..< int(d.port_count) {
			p := d.ports[i]
			fmt.printfln("  port %q %v: in %v, out %v", p.role, p.flags, names(p.input_names), names(p.output_names))
		}
		if id := d.identity; id != nil {
			fmt.printf("  identified by %v", id.method)
			if id.method == .Request do fmt.printf(": a reply matching % 02X (mask % 02X)", id.match[:id.match_size], id.mask[:id.match_size] if id.mask != nil else nil)
			fmt.println()
		} else {
			fmt.println("  identified by its port names")
		}
		if d.required_extensions != nil do fmt.printfln("  requires %v", names(d.required_extensions))
		for i in 0 ..< int(d.device_count) {
			v := d.devices[i]
			fmt.printfln("  device %q: %v %04X:%04X%s", v.role, v.transport, v.vendor_id, v.product_id, " (optional)" if .Optional in v.flags else "")
		}
		for i in 0 ..< int(d.display_count) {
			v := d.displays[i]
			fmt.printfln("  display %q: %d x %d %v, %d fps, %s", v.name, v.width, v.height, v.format, v.fps, "over MIDI" if v.device < 0 else fmt.tprintf("over device %d", v.device))
		}
		// Its controls, from a headless host.
		th: fst.Test_Host
		fst.daw_enable(&th)
		ok, _ := fst.start_file(&th, args[0], string(d.id))
		if ok {
			if v := fst.virtual(&th); v != nil {
				fmt.printfln("  %d controls (%.0f x %.0f):", len(v.controls), v.width, v.height)
				for c in v.controls do fmt.printfln("    %-16s %v %v ch %d #%d at %.0f,%.0f %.0fx%.0f", c.label, c.kind, c.message, c.channel + 1, c.number, c.x, c.y, c.w, c.h)
			} else {
				fmt.println("  no layout (fsurf.layout)")
			}
		}
		fst.stop(&th)
	}
	return 0
}

names :: proc(list: [^]cstring) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if list != nil do for i := 0; list[i] != nil; i += 1 do append(&out, string(list[i]))
	return out[:]
}

run :: proc(args: []string) -> int {
	path, surface, script := "", "", ""
	daw, watch := false, false
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--surface":
			i += 1
			if i < len(args) do surface = args[i]
		case "--daw": daw = true
		case "--watch": watch = true
		case:
			if path == "" do path = args[i]
			else do script = args[i]
		}
	}
	if path == "" {
		usage()
		return 2
	}
	if surface == "" {
		lib, err := host.library_load(path)
		if err != .None {
			fmt.eprintfln("%s: %v", path, err)
			return 1
		}
		surface = strings.clone(string(lib.descriptors[0].id)) if len(lib.descriptors) > 0 else ""
		host.library_unload(lib)
	}
	th: fst.Test_Host
	if daw do fst.daw_enable(&th, tracks = 8, scenes = 4)
	ok, err := fst.start_file(&th, path, surface, watch = watch)
	if !ok {
		fmt.eprintfln("%s: %s didn't start (%v)", path, surface, err)
		fst.stop(&th)
		return 1
	}
	defer fst.stop(&th)
	host.monitor_enable(&th.h, true)
	shown := Shown{}
	show(&th, &shown)

	text: string
	if script != "" {
		data, rerr := os.read_entire_file(script, context.allocator)
		if rerr != nil {
			fmt.eprintfln("%s: %v", script, rerr)
			return 1
		}
		text = string(data)
	} else {
		text = string(read_all_stdin())
	}
	failed := false
	for raw in strings.split_lines(text, context.temp_allocator) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' do continue
		fmt.printfln("> %s", line)
		cmd, rest := split(line)
		if cmd != "expect" && cmd != "svg" && cmd != "daw" { // (expect looks at what the last one sent)
			fst.clear_sent(&th)
			host.monitor_clear(&th.h)
			shown.monitor = 0
		}
		switch cmd {
		case "in":
			bytes, bok := hex(rest)
			if !bok { fmt.println("  ? hex bytes"); failed = true; continue }
			fst.midi_in(&th, bytes)
		case "press":
			name, vel := name_and_number(rest, 127)
			if _, pok := fst.press(&th, name, u8(clamp(vel, 1, 127))); !pok { fmt.printfln("  ? no control %q", name); failed = true }
		case "release":
			if _, rok := fst.release(&th, rest); !rok { fmt.printfln("  ? no control %q", rest); failed = true }
		case "click":
			if !fst.click(&th, rest) { fmt.printfln("  ? no control %q", rest); failed = true }
		case "turn":
			name, steps := name_and_number(rest, 1)
			if _, tok := fst.turn(&th, name, int(steps)); !tok { fmt.printfln("  ? no encoder %q", name); failed = true }
		case "move":
			name, value := name_and_float(rest)
			if _, mok := fst.move(&th, name, f32(value)); !mok { fmt.printfln("  ? no fader %q", name); failed = true }
		case "wait":
			ms, _ := strconv.parse_int(rest)
			fst.advance(&th, u32(max(ms, 0)))
		case "svg":
			if os.write_entire_file(rest, transmute([]u8)fst.svg(&th)) != nil { fmt.printfln("  ? can't write %s", rest); failed = true }
			else do fmt.printfln("  wrote %s", rest)
		case "expect":
			bytes, bok := hex(rest)
			if !bok || !fst.sent_has(&th, bytes) {
				fmt.printfln("  FAIL: it didn't send %s", rest)
				failed = true
			}
		case "daw":
			if d := th.daw; d != nil {
				fmt.printfln("  playing %v, recording %v, tempo %.1f, selected track %d, ring %v", d.playing, d.recording, d.tempo, d.selected_track, d.ring)
				for t, i in d.tracks do fmt.printfln("  track %d %q: volume %.3f, pan %.2f, mute %v, solo %v, arm %v", i, t.name, t.volume, t.pan, t.mute, t.solo, t.arm)
				if len(d.actions) > 0 do fmt.printfln("  actions: %v", d.actions[:])
			} else {
				fmt.println("  (no fake DAW: run with --daw)")
			}
		case "quit":
			break
		case:
			fmt.printfln("  ? no command %q", cmd)
			failed = true
		}
		if cmd == "quit" do break
		show(&th, &shown)
	}
	return 1 if failed else 0
}

// What has been printed of the host's lines.
Shown :: struct {
	monitor, logged, notified: int,
}

show :: proc(th: ^fst.Test_Host, s: ^Shown) {
	es := host.monitor_entries(&th.h)
	for e in es[min(s.monitor, len(es)):] do fmt.printfln("  %s", host.monitor_line(e))
	s.monitor = len(es)
	for l in th.logged[s.logged:] do fmt.printfln("  log: %s", l)
	s.logged = len(th.logged)
	for n in th.notified[s.notified:] do fmt.printfln("  notify: %s", n)
	s.notified = len(th.notified)
}

read_all_stdin :: proc() -> []u8 {
	out := make([dynamic]u8)
	buf: [4096]u8
	for {
		n, err := os.read(os.stdin, buf[:])
		if n > 0 do append(&out, ..buf[:n])
		if err != nil || n == 0 do break
	}
	return out[:]
}

split :: proc(line: string) -> (string, string) {
	i := strings.index_byte(line, ' ')
	if i < 0 do return line, ""
	return line[:i], strings.trim_space(line[i + 1:])
}

name_and_number :: proc(s: string, default: int) -> (string, int) {
	i := strings.last_index_byte(s, ' ')
	if i > 0 {
		if n, ok := strconv.parse_int(s[i + 1:]); ok do return strings.trim_space(s[:i]), n
	}
	return s, default
}

name_and_float :: proc(s: string) -> (string, f64) {
	i := strings.last_index_byte(s, ' ')
	if i > 0 {
		if v, ok := strconv.parse_f64(s[i + 1:]); ok do return strings.trim_space(s[:i]), v
	}
	return s, 0
}

hex :: proc(s: string) -> ([]u8, bool) {
	out := make([dynamic]u8, context.temp_allocator)
	for f in strings.fields(s, context.temp_allocator) {
		v, ok := strconv.parse_uint(f, 16)
		if !ok || v > 255 do return nil, false
		append(&out, u8(v))
	}
	return out[:], len(out) > 0
}

