/*
The draw kit: pictures for a controller's display. A `Canvas` holds 24-bit
colour (0xRRGGBB) whatever the display is; drawing marks what changed
(`Canvas.dirty`); `encode` turns it into the display's pixels (RGB565,
Push 2's frames, 1-bit OLED pages...); `rgba` gives it to a host to mirror,
`png` as a picture.

	cv := draw.canvas_make(128, 64)
	draw.clear(&cv, draw.BLACK)
	draw.text(&cv, &draw.FONT_5X7, 2, 2, "Volume", draw.WHITE)
	draw.knob(&cv, 32, 40, 14, 0.7, draw.ORANGE)
	draw.encode(&cv, .Mono_Pages, &frame)
*/
package draw

import "core:math"

// Some colours.
BLACK :: u32(0x000000)
// (See BLACK.)
WHITE :: u32(0xFFFFFF)
// (See BLACK.)
GREY :: u32(0x808080)
// (See BLACK.)
DARK_GREY :: u32(0x303030)
// (See BLACK.)
RED :: u32(0xFF3030)
// (See BLACK.)
GREEN :: u32(0x30E040)
// (See BLACK.)
BLUE :: u32(0x3080FF)
// (See BLACK.)
ORANGE :: u32(0xFF9020)
// (See BLACK.)
YELLOW :: u32(0xFFE040)

// A rectangle: its top left, width and height.
Rect :: struct {
	x, y, w, h: int,
}

// A picture: `width` x `height` pixels of 0xRRGGBB, rows top to bottom.
Canvas :: struct {
	width, height: int,
	pixels:        []u32,
	clip:          Rect, // drawing outside it is ignored (the whole canvas by default)
	dirty:         Rect, // what changed since `dirty_clear` (w 0: nothing)
}

// A canvas, black. Free with `canvas_destroy`.
canvas_make :: proc(width, height: int, allocator := context.allocator) -> Canvas {
	cv := Canvas{width = width, height = height}
	cv.pixels = make([]u32, width * height, allocator)
	cv.clip = {0, 0, width, height}
	return cv
}

// Frees a canvas.
canvas_destroy :: proc(cv: ^Canvas, allocator := context.allocator) {
	delete(cv.pixels, allocator)
	cv^ = {}
}

// Limits drawing to a rectangle (within the canvas).
set_clip :: proc(cv: ^Canvas, r: Rect) {
	cv.clip = intersect(r, {0, 0, cv.width, cv.height})
}

// Lets drawing reach the whole canvas again.
clear_clip :: proc(cv: ^Canvas) {
	cv.clip = {0, 0, cv.width, cv.height}
}

// Forgets what changed (after sending it).
dirty_clear :: proc(cv: ^Canvas) {
	cv.dirty = {}
}

// Marks the whole canvas changed (send it all: a device just opened).
dirty_all :: proc(cv: ^Canvas) {
	cv.dirty = {0, 0, cv.width, cv.height}
}

// The overlap of two rectangles (w or h 0 when none).
intersect :: proc(a, b: Rect) -> Rect {
	x0, y0 := max(a.x, b.x), max(a.y, b.y)
	x1, y1 := min(a.x + a.w, b.x + b.w), min(a.y + a.h, b.y + b.h)
	if x1 <= x0 || y1 <= y0 do return {}
	return {x0, y0, x1 - x0, y1 - y0}
}

// The smallest rectangle holding both (an empty one adds nothing).
union_rect :: proc(a, b: Rect) -> Rect {
	if a.w <= 0 || a.h <= 0 do return b
	if b.w <= 0 || b.h <= 0 do return a
	x0, y0 := min(a.x, b.x), min(a.y, b.y)
	x1, y1 := max(a.x + a.w, b.x + b.w), max(a.y + a.h, b.y + b.h)
	return {x0, y0, x1 - x0, y1 - y0}
}

@(private)
touch :: #force_inline proc(cv: ^Canvas, r: Rect) {
	cv.dirty = union_rect(cv.dirty, intersect(r, cv.clip))
}

// A pixel (0 outside).
get :: proc(cv: ^Canvas, x, y: int) -> u32 {
	if x < 0 || y < 0 || x >= cv.width || y >= cv.height do return 0
	return cv.pixels[y * cv.width + x]
}

// Sets a pixel (inside the clip; only marked changed if it did).
set :: #force_inline proc(cv: ^Canvas, x, y: int, c: u32) {
	r := cv.clip
	if x < r.x || y < r.y || x >= r.x + r.w || y >= r.y + r.h do return
	p := &cv.pixels[y * cv.width + x]
	if p^ == c do return
	p^ = c
	touch(cv, {x, y, 1, 1})
}

// Mixes `c` over a pixel by `alpha` (0-255).
blend :: proc(cv: ^Canvas, x, y: int, c: u32, alpha: u8) {
	if alpha == 0 do return
	if alpha == 255 {
		set(cv, x, y, c)
		return
	}
	set(cv, x, y, mix(get(cv, x, y), c, alpha))
}

// Two colours mixed: `alpha` (0-255) of b over a.
mix :: proc(a, b: u32, alpha: u8) -> u32 {
	k := u32(alpha)
	ch :: proc(a, b, k: u32, shift: u32) -> u32 {
		x, y := (a >> shift) & 0xFF, (b >> shift) & 0xFF
		return ((x * (255 - k) + y * k + 127) / 255) << shift
	}
	return ch(a, b, k, 16) | ch(a, b, k, 8) | ch(a, b, k, 0)
}

// A colour from red, green and blue.
rgb :: proc(r, g, b: u8) -> u32 { return u32(r) << 16 | u32(g) << 8 | u32(b) }

// Fills the whole canvas (within the clip).
clear :: proc(cv: ^Canvas, c: u32) {
	fill_rect(cv, cv.clip, c)
}

// Fills a rectangle.
fill_rect :: proc(cv: ^Canvas, r: Rect, c: u32) {
	a := intersect(r, cv.clip)
	for y in a.y ..< a.y + a.h {
		row := cv.pixels[y * cv.width:]
		for x in a.x ..< a.x + a.w {
			if row[x] != c {
				row[x] = c
				touch(cv, {x, y, 1, 1})
			}
		}
	}
}

// A rectangle's outline, `thickness` pixels wide, inside it.
rect :: proc(cv: ^Canvas, r: Rect, c: u32, thickness := 1) {
	t := min(thickness, r.w / 2, r.h / 2)
	if t <= 0 do return
	fill_rect(cv, {r.x, r.y, r.w, t}, c)
	fill_rect(cv, {r.x, r.y + r.h - t, r.w, t}, c)
	fill_rect(cv, {r.x, r.y + t, t, r.h - 2 * t}, c)
	fill_rect(cv, {r.x + r.w - t, r.y + t, t, r.h - 2 * t}, c)
}

// A rectangle with rounded corners, filled.
fill_round_rect :: proc(cv: ^Canvas, r: Rect, radius: int, c: u32) {
	rad := min(radius, r.w / 2, r.h / 2)
	if rad <= 0 {
		fill_rect(cv, r, c)
		return
	}
	fill_rect(cv, {r.x, r.y + rad, r.w, r.h - 2 * rad}, c)
	for dy in 0 ..< rad {
		// The row's inset, from the circle.
		yy := f64(rad - dy) - 0.5
		inset := rad - int(sqrt(f64(rad * rad) - yy * yy) + 0.5)
		fill_rect(cv, {r.x + inset, r.y + dy, r.w - 2 * inset, 1}, c)
		fill_rect(cv, {r.x + inset, r.y + r.h - 1 - dy, r.w - 2 * inset, 1}, c)
	}
}

// A horizontal line from x0 to x1 (inclusive).
hline :: proc(cv: ^Canvas, x0, x1, y: int, c: u32) {
	fill_rect(cv, {min(x0, x1), y, abs(x1 - x0) + 1, 1}, c)
}

// A vertical line from y0 to y1 (inclusive).
vline :: proc(cv: ^Canvas, x, y0, y1: int, c: u32) {
	fill_rect(cv, {x, min(y0, y1), 1, abs(y1 - y0) + 1}, c)
}

// A line between two points (Bresenham's).
line :: proc(cv: ^Canvas, x0, y0, x1, y1: int, c: u32) {
	dx, dy := abs(x1 - x0), -abs(y1 - y0)
	sx := 1 if x0 < x1 else -1
	sy := 1 if y0 < y1 else -1
	err := dx + dy
	x, y := x0, y0
	for {
		set(cv, x, y, c)
		if x == x1 && y == y1 do break
		e2 := 2 * err
		if e2 >= dy { err += dy; x += sx }
		if e2 <= dx { err += dx; y += sy }
	}
}

// A circle's outline.
circle :: proc(cv: ^Canvas, cx, cy, r: int, c: u32) {
	x, y := r, 0
	err := 1 - r
	for x >= y {
		for p in ([8][2]int{{x, y}, {y, x}, {-y, x}, {-x, y}, {-x, -y}, {-y, -x}, {y, -x}, {x, -y}}) do set(cv, cx + p[0], cy + p[1], c)
		y += 1
		if err < 0 {
			err += 2 * y + 1
		} else {
			x -= 1
			err += 2 * (y - x) + 1
		}
	}
}

// A filled circle.
fill_circle :: proc(cv: ^Canvas, cx, cy, r: int, c: u32) {
	for dy in -r ..= r {
		w := int(sqrt(f64(r * r - dy * dy)) + 0.5)
		hline(cv, cx - w, cx + w, cy + dy, c)
	}
}

// An arc of a ring: from angle `from` to `to` (degrees, 0 = up, clockwise),
// between radii `inner` and `outer`, smooth at its edges.
arc :: proc(cv: ^Canvas, cx, cy: int, inner, outer: f64, from, to: f64, c: u32) {
	if to <= from do return
	r := int(outer) + 1
	for dy in -r ..= r do for dx in -r ..= r {
		fx, fy := f64(dx), f64(dy)
		d := sqrt(fx * fx + fy * fy)
		cover := clamp(outer + 0.5 - d, 0, 1) * clamp(d - inner + 0.5, 0, 1)
		if cover <= 0 do continue
		a := atan2_deg(fx, -fy) // 0 up, clockwise
		if a < from || a > to {
			// Wrap: angles below 0 (counter-clockwise of up).
			if !(a - 360 >= from && a - 360 <= to) do continue
		}
		blend(cv, cx + dx, cy + dy, c, u8(cover * 255))
	}
}

// ── Images ────────────────────────────────────────────────────────────

// Pixels with alpha: `width` x `height`, each 0xAARRGGBB.
Image :: struct {
	width, height: int,
	pixels:        []u32,
}

// Draws an image with its top left at (x, y), blended by its alpha.
blit :: proc(cv: ^Canvas, img: Image, x, y: int) {
	for iy in 0 ..< img.height do for ix in 0 ..< img.width {
		p := img.pixels[iy * img.width + ix]
		blend(cv, x + ix, y + iy, p & 0xFFFFFF, u8(p >> 24))
	}
}

// ── Maths ─────────────────────────────────────────────────────────────

@(private)
sqrt :: proc(x: f64) -> f64 { return math.sqrt(max(x, 0)) }

@(private)
atan2_deg :: proc(x, y: f64) -> f64 {
	a := math.atan2(x, y) * 180 / math.PI
	return a + 360 if a < 0 else a
}
