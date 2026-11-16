package draw

import "base:runtime"
import "core:math"

/*
Anti-aliased drawing: shapes as paths (contours of lines and curves),
filled by how much of each pixel they cover. The TrueType fonts
(truetype.odin) are filled the same way.

	p := draw.path_make()
	draw.path_move(&p, 10, 10)
	draw.path_line(&p, 50, 30)
	draw.path_quad(&p, 60, 60, 10, 50)
	draw.path_close(&p)
	draw.fill_path(&cv, &p, draw.ORANGE)

Or the shapes made with it: `aa_line`, `aa_polyline`, `aa_circle`,
`aa_ring`, `aa_arc`, `aa_round_rect`, `aa_knob`. Coordinates are in
pixels, as f32: (0, 0) is the top left corner of the top left pixel, so
a pixel's centre is (x + 0.5, y + 0.5).

The fill is non-zero-ish: overlapping contours the same way round add up
(and saturate); a contour the other way round cuts a hole (a ring).
(The coverage is accumulated per row as in font-rs and stb_truetype's
second rasterizer: exact area for straight lines; curves are flattened.)
*/

// A shape: contours of points joined by straight lines (curves flattened
// as they're added). In the temp allocator unless given another.
Path :: struct {
	points: [dynamic][2]f32,
	starts: [dynamic]int, // where each contour begins in `points`
}

// An empty path.
path_make :: proc(allocator := context.temp_allocator) -> Path {
	return {points = make([dynamic][2]f32, allocator), starts = make([dynamic]int, allocator)}
}

// Frees a path (one not in the temp allocator).
path_destroy :: proc(p: ^Path) {
	delete(p.points)
	delete(p.starts)
}

// Empties a path, to use it again.
path_clear :: proc(p: ^Path) {
	runtime.clear(&p.points)
	runtime.clear(&p.starts)
}

// Starts a contour at (x, y).
path_move :: proc(p: ^Path, x, y: f32) {
	append(&p.starts, len(p.points))
	append(&p.points, [2]f32{x, y})
}

// A straight line to (x, y).
path_line :: proc(p: ^Path, x, y: f32) {
	if len(p.starts) == 0 do path_move(p, x, y)
	else do append(&p.points, [2]f32{x, y})
}

// A quadratic curve to (x, y) by the control point (cx, cy).
path_quad :: proc(p: ^Path, cx, cy, x, y: f32) {
	if len(p.points) == 0 {
		path_move(p, x, y)
		return
	}
	a := p.points[len(p.points) - 1]
	// Enough segments that each is within a tenth of a pixel of the curve.
	dd := abs(a.x - 2 * cx + x) + abs(a.y - 2 * cy + y)
	n := clamp(int(math.sqrt(dd * 2.5)) + 1, 1, 64)
	for i in 1 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		append(&p.points, [2]f32{u * u * a.x + 2 * u * t * cx + t * t * x, u * u * a.y + 2 * u * t * cy + t * t * y})
	}
}

// A cubic curve to (x, y) by two control points.
path_cubic :: proc(p: ^Path, c1x, c1y, c2x, c2y, x, y: f32) {
	if len(p.points) == 0 {
		path_move(p, x, y)
		return
	}
	a := p.points[len(p.points) - 1]
	dd := abs(a.x - 2 * c1x + c2x) + abs(a.y - 2 * c1y + c2y) + abs(c1x - 2 * c2x + x) + abs(c1y - 2 * c2y + y)
	n := clamp(int(math.sqrt(dd * 3)) + 1, 1, 96)
	for i in 1 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		append(&p.points, [2]f32{
			u * u * u * a.x + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x,
			u * u * u * a.y + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * y,
		})
	}
}

// An arc of the circle at (cx, cy) of radius r, from angle `from` to `to`
// (degrees, 0 = up, clockwise; `to` < `from` goes counter-clockwise),
// joined to the contour by a line (or starting one).
path_arc :: proc(p: ^Path, cx, cy, r: f32, from, to: f32) {
	span := to - from
	n := clamp(int(abs(span) / 360 * max(r, 1) * 1.6) + 2, 2, 256)
	for i in 0 ..= n {
		a := (from + span * f32(i) / f32(n)) * math.PI / 180
		x, y := cx + r * math.sin(a), cy - r * math.cos(a)
		if i == 0 && len(p.points) == 0 do path_move(p, x, y)
		else do path_line(p, x, y)
	}
}

// Ends the contour (it's closed when filled either way).
path_close :: proc(p: ^Path) {
	// (Contours are closed implicitly: nothing to add.)
}

// Fills a path in `c`, by how much of each pixel it covers (times `alpha`).
fill_path :: proc(cv: ^Canvas, p: ^Path, c: u32, alpha: u8 = 255) {
	if len(p.points) < 3 || alpha == 0 do return
	// The pixels it may touch, within the clip.
	lo, hi := p.points[0], p.points[0]
	for q in p.points {
		lo = {min(lo.x, q.x), min(lo.y, q.y)}
		hi = {max(hi.x, q.x), max(hi.y, q.y)}
	}
	// Rows: clipped (the rasterizer starts and stops lines at the box's top
	// and bottom exactly). Columns: the whole path across, so no line is
	// cut (its area left of the clip still counts); only what's inside the
	// clip is drawn.
	full := Rect{int(math.floor(lo.x)), int(math.floor(lo.y)), int(math.ceil(hi.x)) - int(math.floor(lo.x)) + 1, int(math.ceil(hi.y)) - int(math.floor(lo.y)) + 1}
	rows := intersect(full, {full.x, cv.clip.y, full.w, cv.clip.h})
	if rows.w <= 0 || rows.h <= 0 || intersect(full, cv.clip).w <= 0 do return
	if full.w > 8192 do return // (a stray point far off: not a shape for a display)
	box := rows
	stride := box.w + 2
	acc := make([]f32, stride * box.h + 2, context.temp_allocator)
	ox, oy := f32(box.x), f32(box.y)
	for s, k in p.starts {
		end := p.starts[k + 1] if k + 1 < len(p.starts) else len(p.points)
		if end - s < 2 do continue
		for i in s ..< end {
			a := p.points[i]
			b := p.points[i + 1] if i + 1 < end else p.points[s]
			raster_line(acc, stride, box.w, box.h, {a.x - ox, a.y - oy}, {b.x - ox, b.y - oy})
		}
	}
	// Each row's running sum is the coverage.
	for y in 0 ..< box.h {
		sum: f32
		row := acc[y * stride:]
		for x in 0 ..< box.w {
			sum += row[x]
			cover := min(abs(sum), 1)
			if cover <= 0.002 do continue
			blend(cv, box.x + x, box.y + y, c, u8(cover * f32(alpha) + 0.5))
		}
	}
}

// Accumulates a line's signed area into rows of `stride` (w + 2) floats.
@(private)
raster_line :: proc(acc: []f32, stride, w, h: int, p0, p1: [2]f32) {
	EPS :: 1e-6
	if abs(p0.y - p1.y) <= EPS do return
	dir: f32 = 1
	a, b := p0, p1
	if a.y > b.y {
		dir = -1
		a, b = p1, p0
	}
	dxdy := (b.x - a.x) / (b.y - a.y)
	x := a.x
	if a.y < 0 do x -= a.y * dxdy
	y0 := max(int(a.y), 0)
	y1 := min(int(math.ceil(b.y)), h)
	for y := y0; y < y1; y += 1 {
		line := y * stride
		dy := min(f32(y + 1), b.y) - max(f32(y), a.y)
		xnext := x + dxdy * dy
		d := dy * dir
		x0, x1 := x, xnext
		if x0 > x1 do x0, x1 = x1, x0
		x0floor := math.floor(x0)
		x0i := int(x0floor)
		x1ceil := math.ceil(x1)
		x1i := int(x1ceil)
		if x1i <= x0i + 1 {
			xmf := 0.5 * (x + xnext) - x0floor
			acc[line + x0i] += d - d * xmf
			acc[line + x0i + 1] += d * xmf
		} else {
			s := 1 / (x1 - x0)
			x0f := x0 - x0floor
			a0 := 0.5 * s * (1 - x0f) * (1 - x0f)
			x1f := x1 - x1ceil + 1
			am := 0.5 * s * x1f * x1f
			acc[line + x0i] += d * a0
			if x1i == x0i + 2 {
				acc[line + x0i + 1] += d * (1 - a0 - am)
			} else {
				a1 := s * (1.5 - x0f)
				acc[line + x0i + 1] += d * (a1 - a0)
				for xi in x0i + 2 ..< x1i - 1 do acc[line + xi] += d * s
				a2 := a1 + f32(x1i - x0i - 3) * s
				acc[line + x1i - 1] += d * (1 - a2 - am)
			}
			acc[line + x1i] += d * am
		}
		x = xnext
	}
}

// ── Shapes ────────────────────────────────────────────────────────────

// A line `width` pixels wide, with round ends when `round`.
aa_line :: proc(cv: ^Canvas, x0, y0, x1, y1: f32, width: f32, c: u32, round := false, alpha: u8 = 255) {
	p := path_make()
	stroke_segment(&p, x0, y0, x1, y1, width, round)
	fill_path(cv, &p, c, alpha)
}

// Lines through the points, `width` wide, joined (a curve's plot: an
// envelope, a filter's response).
aa_polyline :: proc(cv: ^Canvas, points: [][2]f32, width: f32, c: u32, alpha: u8 = 255) {
	if len(points) < 2 do return
	p := path_make()
	for i in 0 ..< len(points) - 1 do stroke_segment(&p, points[i].x, points[i].y, points[i + 1].x, points[i + 1].y, width, true)
	fill_path(cv, &p, c, alpha)
}

// The area under points down to `base_y` (a plot's fill), in `c` at `alpha`.
aa_fill_under :: proc(cv: ^Canvas, points: [][2]f32, base_y: f32, c: u32, alpha: u8 = 255) {
	if len(points) < 2 do return
	p := path_make()
	path_move(&p, points[0].x, base_y)
	for q in points do path_line(&p, q.x, q.y)
	path_line(&p, points[len(points) - 1].x, base_y)
	fill_path(cv, &p, c, alpha)
}

@(private)
stroke_segment :: proc(p: ^Path, x0, y0, x1, y1, width: f32, round: bool) {
	dx, dy := x1 - x0, y1 - y0
	n := math.sqrt(dx * dx + dy * dy)
	if n < 1e-4 {
		if round do circle_path(p, x0, y0, width / 2)
		return
	}
	// Clockwise on the screen (as circles and arcs are), so overlapping
	// pieces add up rather than cancel.
	hx, hy := dy / n * width / 2, -dx / n * width / 2
	path_move(p, x0 + hx, y0 + hy)
	path_line(p, x1 + hx, y1 + hy)
	path_line(p, x1 - hx, y1 - hy)
	path_line(p, x0 - hx, y0 - hy)
	if round {
		circle_path(p, x0, y0, width / 2)
		circle_path(p, x1, y1, width / 2)
	}
}

@(private)
circle_path :: proc(p: ^Path, cx, cy, r: f32) {
	n := clamp(int(r * 1.6) + 8, 8, 256)
	// (Clockwise, as the other contours: overlaps add up, saturating.)
	for i in 0 ..< n {
		a := f32(i) / f32(n) * 2 * math.PI
		x, y := cx + r * math.sin(a), cy - r * math.cos(a)
		if i == 0 do path_move(p, x, y)
		else do path_line(p, x, y)
	}
}

// A filled circle.
aa_circle :: proc(cv: ^Canvas, cx, cy, r: f32, c: u32, alpha: u8 = 255) {
	p := path_make()
	circle_path(&p, cx, cy, r)
	fill_path(cv, &p, c, alpha)
}

// A circle's outline, `width` wide (inside `r`).
aa_ring :: proc(cv: ^Canvas, cx, cy, r, width: f32, c: u32, alpha: u8 = 255) {
	aa_arc(cv, cx, cy, r, width, 0, 360, c, false, alpha)
}

// An arc `width` wide inside radius `r`, from `from` to `to` (degrees, 0 =
// up, clockwise), its ends round when `round`.
aa_arc :: proc(cv: ^Canvas, cx, cy, r, width: f32, from, to: f32, c: u32, round := false, alpha: u8 = 255) {
	if to <= from do return
	p := path_make()
	rm := r - width / 2
	path_arc(&p, cx, cy, r, from, to)
	path_arc_back(&p, cx, cy, r - width, to, from)
	if round && to - from < 360 {
		for a in ([2]f32{from, to}) {
			t := a * math.PI / 180
			circle_path(&p, cx + rm * math.sin(t), cy - rm * math.cos(t), width / 2)
		}
	}
	fill_path(cv, &p, c, alpha)
}

@(private)
path_arc_back :: proc(p: ^Path, cx, cy, r: f32, from, to: f32) {
	// The inner edge, back the other way (in the same contour).
	span := to - from
	n := clamp(int(abs(span) / 360 * max(r, 1) * 1.6) + 2, 2, 256)
	for i in 0 ..= n {
		a := (from + span * f32(i) / f32(n)) * math.PI / 180
		path_line(p, cx + r * math.sin(a), cy - r * math.cos(a))
	}
}

// A rectangle with rounded corners, filled; x, y, w, h in pixels (f32).
aa_round_rect :: proc(cv: ^Canvas, x, y, w, h, radius: f32, c: u32, alpha: u8 = 255) {
	rad := min(radius, w / 2, h / 2)
	p := path_make()
	if rad <= 0 {
		path_move(&p, x, y)
		path_line(&p, x + w, y)
		path_line(&p, x + w, y + h)
		path_line(&p, x, y + h)
	} else {
		path_arc(&p, x + w - rad, y + rad, rad, 0, 90)
		path_arc(&p, x + w - rad, y + h - rad, rad, 90, 180)
		path_arc(&p, x + rad, y + h - rad, rad, 180, 270)
		path_arc(&p, x + rad, y + rad, rad, 270, 360)
	}
	fill_path(cv, &p, c, alpha)
}

// A rounded rectangle's outline, `width` wide, inside it.
aa_round_rect_outline :: proc(cv: ^Canvas, x, y, w, h, radius, width: f32, c: u32, alpha: u8 = 255) {
	rad := min(radius, w / 2, h / 2)
	p := path_make()
	// Outer clockwise, inner counter-clockwise: a ring.
	path_arc(&p, x + w - rad, y + rad, rad, 0, 90)
	path_arc(&p, x + w - rad, y + h - rad, rad, 90, 180)
	path_arc(&p, x + rad, y + h - rad, rad, 180, 270)
	path_arc(&p, x + rad, y + rad, rad, 270, 360)
	ir := max(rad - width, 0)
	ix, iy, iw, ih := x + width, y + width, w - 2 * width, h - 2 * width
	append(&p.starts, len(p.points))
	path_arc_back(&p, ix + ir, iy + ir, ir, 360, 270)
	path_arc_back(&p, ix + ir, iy + ih - ir, ir, 270, 180)
	path_arc_back(&p, ix + iw - ir, iy + ih - ir, ir, 180, 90)
	path_arc_back(&p, ix + iw - ir, iy + ir, ir, 90, 0)
	fill_path(cv, &p, c, alpha)
}

// A knob, smooth: a ring from -135 to 135 degrees lit up to `value` (0-1)
// from the bottom left (from the top when `bipolar`), and a pointer.
aa_knob :: proc(cv: ^Canvas, cx, cy, r: f32, value: f32, c: u32, track := DARK_GREY, width: f32 = 4, bipolar := false) {
	aa_arc(cv, cx, cy, r, width, -135, 135, track, true)
	v := clamp(value, 0, 1)
	at := -135 + 270 * v
	if bipolar {
		if abs(at) > 0.5 do aa_arc(cv, cx, cy, r, width, min(at, 0), max(at, 0), c, true)
	} else if v > 0.001 {
		aa_arc(cv, cx, cy, r, width, -135, at, c, true)
	}
	t := at * math.PI / 180
	aa_line(cv, cx + (r - width - 2) * 0.35 * math.sin(t), cy - (r - width - 2) * 0.35 * math.cos(t), cx + (r - width - 2) * math.sin(t), cy - (r - width - 2) * math.cos(t), max(width * 0.6, 1.5), WHITE, true)
}
