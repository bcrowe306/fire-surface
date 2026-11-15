// The draw kit: shapes, text, widgets, the display formats, PNG. Writes
// .build/draw.png to look at.
package draw_test

import "core:bytes"
import "core:image"
import "core:image/png"
import "core:os"
import "core:testing"

import "../../draw"

@(test)
shapes_mark_what_they_change :: proc(t: ^testing.T) {
	cv := draw.canvas_make(32, 16)
	defer draw.canvas_destroy(&cv)
	testing.expect_value(t, cv.dirty.w, 0)
	draw.fill_rect(&cv, {4, 2, 3, 2}, draw.RED)
	testing.expect_value(t, cv.dirty, draw.Rect{4, 2, 3, 2})
	testing.expect_value(t, draw.get(&cv, 6, 3), draw.RED)
	testing.expect_value(t, draw.get(&cv, 7, 3), 0)
	draw.dirty_clear(&cv)
	draw.fill_rect(&cv, {4, 2, 3, 2}, draw.RED) // the same: nothing changed
	testing.expect_value(t, cv.dirty.w, 0)
	draw.set_clip(&cv, {0, 0, 8, 8})
	draw.fill_rect(&cv, {0, 0, 32, 16}, draw.BLUE)
	testing.expect_value(t, draw.get(&cv, 7, 7), draw.BLUE)
	testing.expect_value(t, draw.get(&cv, 8, 8), 0) // outside the clip
	testing.expect_value(t, cv.dirty, draw.Rect{0, 0, 8, 8})
	draw.clear_clip(&cv)
	draw.line(&cv, 0, 15, 31, 0, draw.WHITE)
	testing.expect_value(t, draw.get(&cv, 0, 15), draw.WHITE)
	testing.expect_value(t, draw.get(&cv, 31, 0), draw.WHITE)
	testing.expect_value(t, draw.mix(0x000000, 0xFFFFFF, 128), 0x808080)
	testing.expect_value(t, draw.union_rect({0, 0, 2, 2}, {5, 5, 1, 1}), draw.Rect{0, 0, 6, 6})
	testing.expect_value(t, draw.intersect({0, 0, 2, 2}, {5, 5, 1, 1}).w, 0)
}

@(test)
text_is_drawn_and_measured :: proc(t: ^testing.T) {
	cv := draw.canvas_make(40, 10)
	defer draw.canvas_destroy(&cv)
	testing.expect_value(t, draw.text_width(&draw.FONT_5X7, "Hi"), 11)
	testing.expect_value(t, draw.text_width(&draw.FONT_5X7, "Hi", 2), 22)
	x := draw.text(&cv, &draw.FONT_5X7, 1, 1, "T", draw.WHITE)
	testing.expect_value(t, x, 7)
	// "T": its top row whole, then its stem in the middle.
	for col in 0 ..< 5 do testing.expect_value(t, draw.get(&cv, 1 + col, 1), draw.WHITE)
	testing.expect_value(t, draw.get(&cv, 3, 7), draw.WHITE)
	testing.expect_value(t, draw.get(&cv, 2, 7), 0)
	// Centred and cut to its rectangle.
	draw.clear(&cv, 0)
	draw.text_in(&cv, &draw.FONT_5X7, {10, 0, 6, 10}, "WIDE", draw.WHITE, .Center)
	for y in 0 ..< 10 do testing.expect_value(t, draw.get(&cv, 9, y), 0)
}

@(test)
formats_encode_the_pixels :: proc(t: ^testing.T) {
	cv := draw.canvas_make(9, 9)
	defer draw.canvas_destroy(&cv)
	draw.set(&cv, 0, 0, 0xFF0000)
	draw.set(&cv, 1, 0, 0x0000FF)
	draw.set(&cv, 8, 0, 0xFFFFFF)
	draw.set(&cv, 0, 8, 0xFFFFFF)
	out := make([dynamic]u8, context.temp_allocator)
	draw.encode(&cv, .Rgb565, &out, {0, 0, 2, 1})
	testing.expect_value(t, len(out), 4)
	testing.expect_value(t, out[0], 0x00) // red: F800, little-endian
	testing.expect_value(t, out[1], 0xF8)
	testing.expect_value(t, out[2], 0x1F) // blue: 001F
	clear(&out)
	draw.encode(&cv, .Bgr565, &out, {0, 0, 1, 1})
	testing.expect_value(t, out[0], 0x1F) // red low when blue is high
	testing.expect_value(t, out[1], 0x00)
	clear(&out)
	draw.encode(&cv, .Mono, &out)
	testing.expect_value(t, len(out), 9 * 2) // 9 bits a row: two bytes
	testing.expect_value(t, out[0], 0x00) // red and blue: not bright
	testing.expect_value(t, out[1], 0x80) // the ninth: white
	testing.expect_value(t, out[16], 0x80) // the last row's first
	clear(&out)
	draw.encode(&cv, .Mono_Pages, &out)
	testing.expect_value(t, len(out), 9 * 2) // two pages of 9 columns
	testing.expect_value(t, out[8], 0x01) // column 8, page 0: the top row
	testing.expect_value(t, out[9], 0x01) // column 0, page 1: row 8
	clear(&out)
	draw.encode(&cv, .Rgb888, &out, {8, 0, 1, 1})
	testing.expect_value(t, len(out), 3)
	testing.expect(t, out[0] == 0xFF && out[1] == 0xFF && out[2] == 0xFF)
}

@(test)
a_push2_frame_is_its_header_and_masked_lines :: proc(t: ^testing.T) {
	cv := draw.canvas_make(draw.PUSH2_WIDTH, draw.PUSH2_HEIGHT)
	defer draw.canvas_destroy(&cv)
	out := make([dynamic]u8, context.temp_allocator)
	draw.encode_push2(&cv, &out)
	testing.expect_value(t, len(out), 16 + 160 * 2048)
	testing.expect_value(t, out[0], 0xFF)
	testing.expect_value(t, out[3], 0x88)
	// Black, masked: the mask itself.
	testing.expect(t, out[16] == 0xE7 && out[17] == 0xF3 && out[18] == 0xE7 && out[19] == 0xFF)
}

@(test)
a_png_reads_back_as_the_canvas :: proc(t: ^testing.T) {
	cv := draw.canvas_make(120, 64)
	defer draw.canvas_destroy(&cv)
	draw.clear(&cv, 0x101418)
	draw.text(&cv, &draw.FONT_5X7, 2, 2, "Fire Surface 0123", draw.WHITE)
	draw.text(&cv, &draw.FONT_5X7, 2, 12, "abc xyz !?#&@", draw.ORANGE)
	draw.knob(&cv, 16, 40, 12, 0.7, draw.ORANGE)
	draw.knob(&cv, 46, 40, 12, 0.3, draw.BLUE, bipolar = true)
	draw.meter(&cv, {66, 26, 6, 30}, 0.85, 0.95)
	draw.waveform(&cv, {78, 26, 38, 30}, {0, 0.5, 1, 0.5, 0, -0.5, -1, -0.5, 0, 0.8, -0.8, 0.2}, draw.GREEN)
	draw.fill_round_rect(&cv, {2, 56, 40, 7}, 3, draw.DARK_GREY)
	draw.bar(&cv, {46, 58, 70, 3}, 0.6, draw.GREEN)
	file := make([dynamic]u8, context.temp_allocator)
	draw.png(&cv, &file)
	_ = os.write_entire_file(".build/draw.png", file[:]) // to look at
	img, err := png.load_from_bytes(file[:])
	if !testing.expectf(t, err == nil, "png: %v", err) do return
	defer image.destroy(img)
	testing.expect_value(t, img.width, 120)
	testing.expect_value(t, img.channels, 4)
	px := bytes.buffer_to_bytes(&img.pixels)
	for y in 0 ..< 64 do for x in 0 ..< 120 {
		p := draw.get(&cv, x, y)
		i := (y * 120 + x) * 4
		if px[i] != u8(p >> 16) || px[i + 1] != u8(p >> 8) || px[i + 2] != u8(p) || px[i + 3] != 255 {
			testing.expectf(t, false, "pixel %d,%d: %v, want %06X", x, y, px[i:i + 4], p)
			return
		}
	}
}
