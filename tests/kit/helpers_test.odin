// The kit's MIDI, music and colour helpers.
package kit_test

import "core:testing"

import abi "../../abi"
import kit "../../surface"

@(test)
messages_parse_and_build :: proc(t: ^testing.T) {
	m, ok := kit.parse({0x93, 60, 0})
	testing.expect(t, ok)
	testing.expect_value(t, m.kind, abi.Message.Note_Off) // velocity 0
	testing.expect_value(t, m.channel, 3)
	m, _ = kit.parse({0xE1, 0x00, 0x40})
	testing.expect_value(t, m.kind, abi.Message.Pitch_Bend)
	testing.expect_value(t, m.value14, 8192)
	m, _ = kit.parse({0xD2, 99})
	testing.expect_value(t, m.data1, 99)
	m, _ = kit.parse({0xF0, 1, 2, 0xF7})
	testing.expect_value(t, m.kind, abi.Message.Sysex)
	m, _ = kit.parse({0xF8})
	testing.expect_value(t, m.kind, abi.Message.System)
	_, ok = kit.parse({0x90, 60}) // short
	testing.expect(t, !ok)
	_, ok = kit.parse({60})
	testing.expect(t, !ok)
	testing.expect_value(t, kit.note_on(17, 200, 100), [3]u8{0x91, 72, 100})
	testing.expect_value(t, kit.pitch_bend(0, 16383), [3]u8{0xE0, 0x7F, 0x7F})
	testing.expect_value(t, kit.pitch_bend(0, 20000), [3]u8{0xE0, 0x7F, 0x7F})
}

@(test)
a_stream_with_running_status_becomes_messages :: proc(t: ^testing.T) {
	p: kit.Parser
	defer kit.parser_destroy(&p)
	got := make([dynamic][]u8, context.temp_allocator)
	emit :: proc(user: rawptr, msg: []u8) {
		got := (^[dynamic][]u8)(user)
		c := make([]u8, len(msg), context.temp_allocator)
		copy(c, msg)
		append(got, c)
	}
	// A note, two more by running status, a clock between their bytes, a
	// SysEx with a clock inside, a program change, a tune request.
	kit.parser_feed(&p, {0x90, 60, 100, 62, 0xF8, 90, 64}, emit, &got)
	kit.parser_feed(&p, {0, 0xF0, 1, 0xF8, 2, 0xF7, 0xC0, 5, 6, 0xF6}, emit, &got)
	want := [][]u8{{0x90, 60, 100}, {0xF8}, {0x90, 62, 90}, {0x90, 64, 0}, {0xF8}, {0xF0, 1, 2, 0xF7}, {0xC0, 5}, {0xC0, 6}, {0xF6}}
	if !testing.expect_value(t, len(got), len(want)) do return
	for w, i in want do testing.expectf(t, string(got[i]) == string(w), "%d: %v, want %v", i, got[i], w)
}

@(test)
fourteen_bits_rpn_and_nrpn :: proc(t: ^testing.T) {
	testing.expect_value(t, kit.join14(0x40, 0x01), 8193)
	msb, lsb := kit.split14(8193)
	testing.expect_value(t, msb, 0x40)
	testing.expect_value(t, lsb, 0x01)
	msgs := kit.nrpn(2, 300, 9000)
	r: kit.Parameter_Reader
	last_v: u16
	last_p: u16
	n := 0
	for m in msgs {
		p, v, is_nrpn, ok := kit.parameter_feed(&r, m[0] & 0x0F, m[1], m[2])
		if ok {
			testing.expect(t, is_nrpn)
			last_p, last_v = p, v
			n += 1
		}
	}
	testing.expect_value(t, n, 2) // the coarse value, then the fine
	testing.expect_value(t, last_p, 300)
	testing.expect_value(t, last_v, 9000)
	testing.expect_value(t, kit.rpn(0, 0, 0x0200)[0], [3]u8{0xB0, 101, 0})
}

@(test)
sysex_packing_nibbles_and_checksums :: proc(t: ^testing.T) {
	data := []u8{0x00, 0x80, 0xFF, 0x7F, 0x01, 0x81, 0xC3, 0x55, 0xAA}
	packed := make([dynamic]u8, context.temp_allocator)
	kit.pack7(&packed, data)
	for b in packed do testing.expect(t, b < 0x80)
	testing.expect_value(t, len(packed), 8 + 3)
	back := make([dynamic]u8, context.temp_allocator)
	kit.unpack7(&back, packed[:])
	testing.expect_value(t, string(back[:]), string(data))
	testing.expect_value(t, kit.nibbles(0xA5), [2]u8{0xA, 0x5})
	testing.expect_value(t, kit.from_nibbles(0xA, 0x5), 0xA5)
	// Roland: 40 00 7F 00 -> 41.
	testing.expect_value(t, kit.roland_checksum({0x40, 0x00, 0x7F, 0x00}), 0x41)
	out := make([dynamic]u8, context.temp_allocator)
	man := kit.MANUFACTURER_NON_COMMERCIAL
	kit.sysex(&out, man[:], {1, 0x82})
	want := []u8{0xF0, 0x7D, 1, 0x02, 0xF7}
	testing.expect_value(t, string(out[:]), string(want))
}

@(test)
notes_names_and_frequencies :: proc(t: ^testing.T) {
	testing.expect(t, abs(kit.midi_note_to_freq(69) - 440) < 1e-9)
	testing.expect(t, abs(kit.midi_note_to_freq(60) - 261.6255653) < 1e-6)
	testing.expect(t, abs(kit.freq_to_midi_note(880) - 81) < 1e-9)
	testing.expect(t, abs(kit.freq_to_midi_note(kit.midi_note_to_freq(37.3, 442), 442) - 37.3) < 1e-9)
	testing.expect_value(t, kit.note_name(60), "C4")
	testing.expect_value(t, kit.note_name(60, middle_c_octave = 3), "C3")
	testing.expect_value(t, kit.note_name(0), "C-1")
	testing.expect_value(t, kit.note_name(70), "A#4")
	Named :: struct { name: string, note: u8 }
	for c in ([]Named{{"C4", 60}, {"f#2", 42}, {"Bb-1", 10}, {"G9", 127}, {"A0", 21}}) {
		n, ok := kit.note_number(c.name)
		testing.expectf(t, ok && n == c.note, "%s: %d %v", c.name, n, ok)
	}
	_, ok := kit.note_number("H4")
	testing.expect(t, !ok)
	_, ok = kit.note_number("G#9") // 128
	testing.expect(t, !ok)
}

@(test)
scales_and_curves :: proc(t: ^testing.T) {
	major := kit.scale_named("major")
	testing.expect(t, major != nil)
	testing.expect_value(t, kit.scale_note(major, 60, 0), 60)
	testing.expect_value(t, kit.scale_note(major, 60, 7), 72)
	testing.expect_value(t, kit.scale_note(major, 60, 9), 76)
	testing.expect_value(t, kit.scale_note(major, 60, -1), 59)
	testing.expect_value(t, kit.scale_note(major, 120, 7), -1)
	testing.expect(t, kit.in_scale(major, 2, 66)) // F# in D major
	testing.expect(t, !kit.in_scale(major, 2, 65))
	testing.expect(t, kit.scale_named("nothing") == nil)

	lin := kit.velocity_curve(0)
	for i in 1 ..< 128 do testing.expect_value(t, int(lin[i]), i)
	testing.expect_value(t, lin[0], 0)
	soft := kit.velocity_curve(-1)
	hard := kit.velocity_curve(1)
	testing.expect(t, soft[40] > 40 && hard[40] < 40)
	for i in 2 ..< 128 do testing.expect(t, soft[i] >= soft[i - 1] && hard[i] >= hard[i - 1])
	testing.expect_value(t, soft[127], 127)
	ranged := kit.velocity_curve(0, 40, 100)
	testing.expect(t, ranged[1] == 40 && ranged[127] == 100)
	testing.expect_value(t, kit.velocity_fixed(100)[5], 100)
}

@(test)
tap_tempo_and_beats :: proc(t: ^testing.T) {
	tt: kit.Tap_Tempo
	testing.expect_value(t, kit.tap(&tt, 1_000_000_000), 0)
	bpm: f64
	for i in 1 ..= 6 do bpm = kit.tap(&tt, 1_000_000_000 + u64(i) * 500_000_000) // 500 ms apart
	testing.expect(t, abs(bpm - 120) < 1e-6)
	testing.expect_value(t, kit.tap(&tt, 10_000_000_000), 0) // a long gap: again
	testing.expect(t, abs(kit.beat_ms(120) - 500) < 1e-9)
	testing.expect(t, abs(kit.clock_tick_ms(125) - 20) < 1e-9)
}

@(test)
colours_convert_and_find_their_palette_index :: proc(t: ^testing.T) {
	testing.expect_value(t, kit.hsv_to_rgb(0, 1, 1), kit.RGB{255, 0, 0})
	testing.expect_value(t, kit.hsv_to_rgb(120, 1, 1), kit.RGB{0, 255, 0})
	testing.expect_value(t, kit.hsv_to_rgb(-120, 1, 1), kit.RGB{0, 0, 255})
	testing.expect_value(t, kit.hsl_to_rgb(0, 0, 0.5), kit.RGB{128, 128, 128})
	for c in ([]kit.RGB{{12, 200, 99}, {255, 255, 255}, {0, 0, 0}, {250, 10, 128}}) {
		h, s, v := kit.rgb_to_hsv(c)
		testing.expect_value(t, kit.hsv_to_rgb(h, s, v), c)
		h2, s2, l := kit.rgb_to_hsl(c)
		testing.expect_value(t, kit.hsl_to_rgb(h2, s2, l), c)
	}
	testing.expect_value(t, kit.rgb_to_hex(kit.rgb_from_hex(0x12AB34)), 0x12AB34)
	testing.expect_value(t, kit.scale_brightness({200, 100, 50}, 0.5), kit.RGB{100, 50, 25})
	testing.expect(t, kit.brightness({0, 255, 0}) > kit.brightness({0, 0, 255}))
	palette := []kit.RGB{{0, 0, 0}, {255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 255}}
	testing.expect_value(t, kit.nearest_in_palette({240, 30, 20}, palette), 1)
	testing.expect_value(t, kit.nearest_in_palette({200, 210, 220}, palette), 4)
	testing.expect_value(t, kit.nearest_in_palette({1, 2, 3}, nil), -1)
	testing.expect_value(t, kit.rgb7({255, 128, 1}), [3]u8{127, 64, 0})
}
