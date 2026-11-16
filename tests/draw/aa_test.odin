// Anti-aliased shapes and TrueType text. Writes .build/aa.png to look at.
package draw_test

import "core:math"
import "core:os"
import "core:testing"

import "../../draw"

// How much of a colour a canvas holds, in pixels (its coverage summed).
covered :: proc(cv: ^draw.Canvas, c: u32) -> f64 {
	sum: f64
	for p in cv.pixels do sum += f64(p & 0xFF) / f64(c & 0xFF)
	return sum
}

@(test)
a_smooth_circle_covers_its_area :: proc(t: ^testing.T) {
	cv := draw.canvas_make(64, 64)
	defer draw.canvas_destroy(&cv)
	draw.aa_circle(&cv, 32, 32, 20, 0x0000FF)
	area := covered(&cv, 0x0000FF)
	testing.expectf(t, abs(area - math.PI * 400) < 400 * 0.02, "area %.1f, want %.1f", area, math.PI * 400)
	// Its edge is partly covered: neither 0 nor full (about the circumference).
	partial := 0
	for p in cv.pixels do if p & 0xFF > 8 && p & 0xFF < 247 do partial += 1
	testing.expectf(t, partial > 80 && partial < 200, "%d pixels partly covered", partial)
	testing.expect_value(t, draw.get(&cv, 32, 32), u32(0x0000FF))
	// A ring has a hole.
	draw.clear(&cv, 0)
	draw.aa_ring(&cv, 32, 32, 20, 4, 0x0000FF)
	testing.expect_value(t, draw.get(&cv, 32, 32), u32(0))
	testing.expectf(t, abs(covered(&cv, 0x0000FF) - math.PI * (400 - 256)) < 10, "ring %.1f", covered(&cv, 0x0000FF))
}

@(test)
a_square_path_is_exact :: proc(t: ^testing.T) {
	cv := draw.canvas_make(16, 16)
	defer draw.canvas_destroy(&cv)
	p := draw.path_make()
	draw.path_move(&p, 2.5, 2)
	draw.path_line(&p, 10.5, 2)
	draw.path_line(&p, 10.5, 6)
	draw.path_line(&p, 2.5, 6)
	draw.fill_path(&cv, &p, 0x0000FF)
	testing.expectf(t, abs(covered(&cv, 0x0000FF) - 32) < 0.1, "%v", covered(&cv, 0x0000FF))
	testing.expect_value(t, draw.get(&cv, 2, 3) & 0xFF, 128) // half a pixel
	testing.expect_value(t, draw.get(&cv, 5, 3), u32(0x0000FF))
	// Half off the canvas (left): its part inside is all there.
	draw.clear(&cv, 0)
	draw.aa_round_rect(&cv, -4, 0, 8, 8, 0, 0x0000FF)
	testing.expectf(t, abs(covered(&cv, 0x0000FF) - 32) < 0.1, "%v", covered(&cv, 0x0000FF))
}

@(test)
open_sans_reads_and_draws :: proc(t: ^testing.T) {
	sans := draw.open_sans()
	if !testing.expect(t, sans != nil, "Open Sans") do return
	testing.expect(t, draw.glyph_index(sans, 'A') != 0)
	testing.expect(t, draw.glyph_index(sans, 'é') != 0)
	testing.expect(t, draw.glyph_index(sans, 0x10FFFF) == 0)
	w := draw.type_width(sans, 20, "Volume")
	testing.expectf(t, w > 50 && w < 90, "width %v", w)
	cv := draw.canvas_make(200, 40)
	defer draw.canvas_destroy(&cv)
	draw.type_text(&cv, sans, 20, 4, 4, "Volume", 0x0000FF)
	ink := covered(&cv, 0x0000FF)
	testing.expectf(t, ink > 80 && ink < 400, "ink %.1f", ink)
	// Cut to a rectangle, with an ellipsis.
	draw.clear(&cv, 0)
	draw.type_text_in(&cv, sans, 20, {0, 0, 50, 40}, "Volume envelope", 0x0000FF)
	for y in 0 ..< 40 do for x in 50 ..< 200 do testing.expect_value(t, draw.get(&cv, x, y), u32(0))
}

@(test)
a_sample_to_look_at :: proc(t: ^testing.T) {
	cv := draw.canvas_make(960, 160)
	defer draw.canvas_destroy(&cv)
	draw.clear(&cv, 0x101216)
	sans := draw.open_sans()
	semi := draw.open_sans(.Semibold)
	x: f32 = 8
	for size in ([?]f32{11, 13, 16, 20, 28, 40}) {
		x = draw.type_text(&cv, sans, size, x, 6, "Pads Ag", 0xE8E8EC) + 14
	}
	draw.type_text(&cv, semi, 22, 8, 58, "Semibold: Filter Cutoff 1.2 kHz", 0xFFB030)
	draw.aa_round_rect(&cv, 520, 56, 120, 34, 8, 0x2A3550)
	draw.type_text_in(&cv, semi, 16, {520, 56, 120, 34}, "Selected", 0xFFFFFF, .Center)
	for i in 0 ..< 4 {
		cx := f32(680 + i * 70)
		draw.aa_knob(&cv, cx, 74, 26, f32(i) / 3, 0xFFB030, 0x3A3A44, 5, i == 2)
	}
	pts := make([][2]f32, 200, context.temp_allocator)
	for i in 0 ..< 200 {
		f := f32(i) / 199
		pts[i] = {8 + f * 500, 140 - 30 * math.exp(-4 * f) * math.cos(f * 20)}
	}
	draw.aa_fill_under(&cv, pts, 156, 0x3080FF, 60)
	draw.aa_polyline(&cv, pts, 2, 0x60A0FF)
	draw.aa_line(&cv, 540, 110, 940, 150, 3, 0x30E040, true)
	draw.aa_circle(&cv, 600, 130, 12, 0xFF3030)
	out := make([dynamic]u8, context.temp_allocator)
	draw.png(&cv, &out)
	_ = os.write_entire_file(".build/aa.png", out[:])
}
