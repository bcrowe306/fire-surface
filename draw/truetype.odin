package draw

import "base:runtime"
import "core:math"
import "core:strings"
import "core:sync"

/*
TrueType text, anti-aliased: a `Typeface` from a .ttf file's bytes, drawn
at any size (pixels from the tallest ascender to the lowest descender, as
Dear ImGui sizes fonts). Glyphs are filled by the kit's rasterizer
(raster.odin) and kept, each size and quarter-pixel offset once. Pure
Odin: no C library, on any platform.

	sans := draw.open_sans()            // bundled (OFL): Regular, or .Semibold
	draw.type_text(&cv, sans, 18, 10, 4, "Volume", draw.WHITE)
	draw.type_text_in(&cv, sans, 14, {0, 0, 120, 20}, "-6.0 dB", draw.GREY, .Center)
	w := draw.type_width(sans, 14, "-6.0 dB")

A typeface may be drawn from several threads (its glyphs are kept under
a lock). Outlines only (glyf: TrueType, not CFF); no hinting, no kerning.
*/

// A TrueType font, read. Make with `typeface_load`; free with `typeface_destroy`.
Typeface :: struct {
	data:          []u8, // the file (not owned)
	units_per_em:  int,
	ascent:        int, // font units (hhea)
	descent:       int, // (negative)
	line_gap:      int,
	glyph_count:   int,
	long_loca:     bool,
	loca, glyf, hmtx, cmap: int, // table offsets
	h_metrics:     int,
	cmap_format:   int, // 4 or 12
	cmap_table:    int,
	cache:         map[u64]^Glyph_Image,
	mutex:         sync.Mutex, // the cache's
}

// A glyph drawn at a size: coverage (0-255), placed from the pen.
@(private)
Glyph_Image :: struct {
	w, h:      int,
	left, top: int, // from the pen's x (rounded) and the baseline
	alpha:     []u8,
}

// Reads a TrueType font from its file's bytes (kept: they must outlive
// it). Nil if it isn't one this can read.
typeface_load :: proc(data: []u8, allocator := context.allocator) -> ^Typeface {
	if len(data) < 12 do return nil
	tables := map[string]int{}
	defer delete(tables)
	n := int(tt_u16(data, 4))
	for i in 0 ..< n {
		r := 12 + i * 16
		if r + 16 > len(data) do return nil
		tables[string(data[r:r + 4])] = int(tt_u32(data, r + 8))
	}
	head, hhea, maxp := tables["head"] or_else -1, tables["hhea"] or_else -1, tables["maxp"] or_else -1
	loca, glyf, hmtx, cmap := tables["loca"] or_else -1, tables["glyf"] or_else -1, tables["hmtx"] or_else -1, tables["cmap"] or_else -1
	if head < 0 || hhea < 0 || maxp < 0 || loca < 0 || glyf < 0 || hmtx < 0 || cmap < 0 do return nil
	tf := new(Typeface, allocator)
	tf^ = {
		data = data, units_per_em = int(tt_u16(data, head + 18)), long_loca = tt_i16(data, head + 50) != 0,
		ascent = int(tt_i16(data, hhea + 4)), descent = int(tt_i16(data, hhea + 6)), line_gap = int(tt_i16(data, hhea + 8)),
		h_metrics = int(tt_u16(data, hhea + 34)), glyph_count = int(tt_u16(data, maxp + 4)),
		loca = loca, glyf = glyf, hmtx = hmtx, cmap = cmap,
	}
	tf.cache = make(map[u64]^Glyph_Image, allocator = allocator)
	// The Unicode character map: format 12 (full), else 4 (the BMP).
	best := 0
	for i in 0 ..< int(tt_u16(data, cmap + 2)) {
		r := cmap + 4 + i * 8
		platform, encoding := tt_u16(data, r), tt_u16(data, r + 2)
		sub := cmap + int(tt_u32(data, r + 4))
		format := int(tt_u16(data, sub))
		unicode := platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10))
		if !unicode do continue
		if format == 12 && best < 2 {
			tf.cmap_format, tf.cmap_table, best = 12, sub, 2
		} else if format == 4 && best < 1 {
			tf.cmap_format, tf.cmap_table, best = 4, sub, 1
		}
	}
	if best == 0 {
		free(tf, allocator)
		return nil
	}
	return tf
}

// Frees a typeface and its glyphs (not its file's bytes).
typeface_destroy :: proc(tf: ^Typeface) {
	if tf == nil do return
	a := tf.cache.allocator
	for _, g in tf.cache {
		delete(g.alpha, a)
		free(g, a)
	}
	delete(tf.cache)
	free(tf, a)
}

// Open Sans' weights, bundled.
Weight :: enum u8 {
	Regular,
	Semibold,
}

@(private)
open_sans_faces: [Weight]^Typeface
@(private)
open_sans_mutex: sync.Mutex

// Open Sans (bundled, SIL Open Font License: draw/fonts/OFL.txt), read
// the first time it's asked for.
open_sans :: proc(weight := Weight.Regular) -> ^Typeface {
	@(static) regular := #load("fonts/OpenSans-Regular.ttf")
	@(static) semibold := #load("fonts/OpenSans-SemiBold.ttf")
	sync.mutex_lock(&open_sans_mutex)
	defer sync.mutex_unlock(&open_sans_mutex)
	if open_sans_faces[weight] == nil {
		// (On the heap: shared by every surface of the library, for good.)
		open_sans_faces[weight] = typeface_load(regular if weight == .Regular else semibold, runtime.heap_allocator())
	}
	return open_sans_faces[weight]
}

// The scale from font units to pixels at a size.
@(private)
type_scale :: proc(tf: ^Typeface, size: f32) -> f32 {
	return size / f32(max(tf.ascent - tf.descent, 1))
}

// Pixels from the top of a line to its baseline, at a size.
type_ascent :: proc(tf: ^Typeface, size: f32) -> f32 { return f32(tf.ascent) * type_scale(tf, size) }

// How wide text is at a size, in pixels.
type_width :: proc(tf: ^Typeface, size: f32, s: string) -> f32 {
	if tf == nil do return 0
	k := type_scale(tf, size)
	w: f32
	for ch in s do w += f32(glyph_advance(tf, glyph_index(tf, ch))) * k
	return w
}

// Draws text with the top of its line at y (its baseline `type_ascent`
// below), from x. The x after it.
type_text :: proc(cv: ^Canvas, tf: ^Typeface, size: f32, x, y: f32, s: string, c: u32, alpha: u8 = 255) -> f32 {
	if tf == nil do return x
	k := type_scale(tf, size)
	base := int(math.round(y + f32(tf.ascent) * k))
	pen := x
	for ch in s {
		if ch == '\n' do continue
		g := glyph_index(tf, ch)
		px := math.floor(pen)
		sub := int((pen - px) * 4) & 3
		sync.mutex_lock(&tf.mutex)
		img := glyph_image(tf, g, size, sub)
		sync.mutex_unlock(&tf.mutex)
		if img != nil && img.w > 0 {
			ox, oy := int(px) + img.left, base + img.top
			for gy in 0 ..< img.h do for gx in 0 ..< img.w {
				a := img.alpha[gy * img.w + gx]
				if a == 0 do continue
				blend(cv, ox + gx, oy + gy, c, u8((u32(a) * u32(alpha) + 127) / 255))
			}
		}
		pen += f32(glyph_advance(tf, g)) * k
	}
	return pen
}

// Draws text in a rectangle: aligned across it, centred down it, cut to the
// rectangle; too long, it ends in "…" (or ".." without one in the font).
type_text_in :: proc(cv: ^Canvas, tf: ^Typeface, size: f32, r: Rect, s: string, c: u32, align := Align.Left, alpha: u8 = 255) {
	if tf == nil do return
	text := s
	if type_width(tf, size, text) > f32(r.w) {
		dots := "…" if glyph_index(tf, '…') != 0 else ".."
		b := strings.builder_make(context.temp_allocator)
		for ch in s {
			if type_width(tf, size, strings.concatenate({strings.to_string(b), string_of(ch), dots}, context.temp_allocator)) > f32(r.w) do break
			strings.write_rune(&b, ch)
		}
		strings.write_string(&b, dots)
		text = strings.to_string(b)
	}
	w := type_width(tf, size, text)
	x := f32(r.x)
	switch align {
	case .Left:
	case .Center: x = f32(r.x) + (f32(r.w) - w) / 2
	case .Right: x = f32(r.x + r.w) - w
	}
	// Centred on the line's ink: between the cap height (about 0.72 of the
	// ascent) and the baseline.
	k := type_scale(tf, size)
	ink := f32(tf.ascent) * k * 0.72
	base := f32(r.y) + (f32(r.h) + ink) / 2
	old := cv.clip
	set_clip(cv, intersect(r, old))
	type_text(cv, tf, size, x, base - f32(tf.ascent) * k, text, c, alpha)
	cv.clip = old
}

@(private)
string_of :: proc(ch: rune) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_rune(&b, ch)
	return strings.to_string(b)
}

// ── Reading the font ──────────────────────────────────────────────────

@(private)
tt_u16 :: #force_inline proc(d: []u8, at: int) -> u16 {
	if at < 0 || at + 2 > len(d) do return 0
	return u16(d[at]) << 8 | u16(d[at + 1])
}

@(private)
tt_i16 :: #force_inline proc(d: []u8, at: int) -> i16 { return i16(tt_u16(d, at)) }

@(private)
tt_u32 :: #force_inline proc(d: []u8, at: int) -> u32 {
	if at < 0 || at + 4 > len(d) do return 0
	return u32(d[at]) << 24 | u32(d[at + 1]) << 16 | u32(d[at + 2]) << 8 | u32(d[at + 3])
}

// A character's glyph (0: the font's "missing" glyph).
glyph_index :: proc(tf: ^Typeface, ch: rune) -> int {
	d := tf.data
	c := u32(ch)
	t := tf.cmap_table
	if tf.cmap_format == 12 {
		lo, hi := 0, int(tt_u32(d, t + 12)) - 1
		for lo <= hi {
			mid := (lo + hi) / 2
			r := t + 16 + mid * 12
			start, end := tt_u32(d, r), tt_u32(d, r + 4)
			if c < start do hi = mid - 1
			else if c > end do lo = mid + 1
			else do return int(tt_u32(d, r + 8) + (c - start))
		}
		return 0
	}
	if c > 0xFFFF do return 0
	seg2 := int(tt_u16(d, t + 6))
	ends := t + 14
	starts := ends + seg2 + 2
	deltas := starts + seg2
	ranges := deltas + seg2
	for i := 0; i < seg2; i += 2 {
		if u32(tt_u16(d, ends + i)) < c do continue
		start := u32(tt_u16(d, starts + i))
		if start > c do return 0
		delta := tt_u16(d, deltas + i)
		ro := int(tt_u16(d, ranges + i))
		if ro == 0 do return int((u16(c) + delta) & 0xFFFF)
		g := tt_u16(d, ranges + i + ro + 2 * int(c - start))
		return 0 if g == 0 else int((g + delta) & 0xFFFF)
	}
	return 0
}

@(private)
glyph_advance :: proc(tf: ^Typeface, g: int) -> int {
	i := min(g, tf.h_metrics - 1)
	return int(tt_u16(tf.data, tf.hmtx + i * 4))
}

@(private)
glyph_range :: proc(tf: ^Typeface, g: int) -> (int, int) {
	if g < 0 || g >= tf.glyph_count do return 0, 0
	if tf.long_loca do return tf.glyf + int(tt_u32(tf.data, tf.loca + g * 4)), tf.glyf + int(tt_u32(tf.data, tf.loca + g * 4 + 4))
	return tf.glyf + int(tt_u16(tf.data, tf.loca + g * 2)) * 2, tf.glyf + int(tt_u16(tf.data, tf.loca + g * 2 + 2)) * 2
}

// A glyph's outline into a path: font units through the transform
// (m: a, b, c, d, e, f: x' = a x + c y + e, y' = b x + d y + f).
@(private)
glyph_outline :: proc(tf: ^Typeface, g: int, p: ^Path, m: [6]f32, depth := 0) {
	if depth > 8 do return
	d := tf.data
	start, end := glyph_range(tf, g)
	if end <= start do return
	contours := int(tt_i16(d, start))
	at :: proc(m: [6]f32, x, y: f32) -> [2]f32 { return {m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]} }
	if contours < 0 {
		// Composite: other glyphs, each moved (and scaled).
		r := start + 10
		for {
			flags := tt_u16(d, r)
			sub := int(tt_u16(d, r + 2))
			r += 4
			dx, dy: f32
			if flags & 1 != 0 {
				dx, dy = f32(tt_i16(d, r)), f32(tt_i16(d, r + 2))
				r += 4
			} else {
				dx, dy = f32(i8(d[r])), f32(i8(d[r + 1]))
				r += 2
			}
			if flags & 2 == 0 do dx, dy = 0, 0 // (point matching: not supported)
			a, b, c, e: f32 = 1, 0, 0, 1
			f2 :: proc(d: []u8, at: int) -> f32 { return f32(tt_i16(d, at)) / 16384 }
			if flags & 8 != 0 {
				a = f2(d, r)
				e = a
				r += 2
			} else if flags & 0x40 != 0 {
				a, e = f2(d, r), f2(d, r + 2)
				r += 4
			} else if flags & 0x80 != 0 {
				a, b, c, e = f2(d, r), f2(d, r + 2), f2(d, r + 4), f2(d, r + 6)
				r += 8
			}
			// This component's transform, then the parent's.
			sm := [6]f32{
				m[0] * a + m[2] * b, m[1] * a + m[3] * b,
				m[0] * c + m[2] * e, m[1] * c + m[3] * e,
				m[0] * dx + m[2] * dy + m[4], m[1] * dx + m[3] * dy + m[5],
			}
			glyph_outline(tf, sub, p, sm, depth + 1)
			if flags & 0x20 == 0 do break
		}
		return
	}
	// Simple: its contours' points, on and off the curve (quadratic).
	ends := start + 10
	n := int(tt_u16(d, ends + (contours - 1) * 2)) + 1 if contours > 0 else 0
	if n <= 0 do return
	ins := int(tt_u16(d, ends + contours * 2))
	r := ends + contours * 2 + 2 + ins
	flags := make([]u8, n, context.temp_allocator)
	for i := 0; i < n; {
		f := d[r] if r < len(d) else 0
		r += 1
		flags[i] = f
		i += 1
		if f & 8 != 0 {
			count := int(d[r]) if r < len(d) else 0
			r += 1
			for _ in 0 ..< count do if i < n {
				flags[i] = f
				i += 1
			}
		}
	}
	pts := make([][2]f32, n, context.temp_allocator)
	v: int
	for i in 0 ..< n {
		f := flags[i]
		if f & 2 != 0 {
			dv := int(d[r])
			r += 1
			v += dv if f & 16 != 0 else -dv
		} else if f & 16 == 0 {
			v += int(tt_i16(d, r))
			r += 2
		}
		pts[i].x = f32(v)
	}
	v = 0
	for i in 0 ..< n {
		f := flags[i]
		if f & 4 != 0 {
			dv := int(d[r])
			r += 1
			v += dv if f & 32 != 0 else -dv
		} else if f & 32 == 0 {
			v += int(tt_i16(d, r))
			r += 2
		}
		pts[i].y = f32(v)
	}
	first := 0
	for k in 0 ..< contours {
		last := int(tt_u16(d, ends + k * 2))
		count := last - first + 1
		if count < 2 {
			first = last + 1
			continue
		}
		// Start on a point on the curve (or, none being on it, between the
		// last and the first); then each point in turn, round to the start.
		cp := pts[first:][:count]
		cf := flags[first:][:count]
		on_start := -1
		for i in 0 ..< count do if cf[i] & 1 != 0 {
			on_start = i
			break
		}
		s0 := cp[on_start] if on_start >= 0 else (cp[count - 1] + cp[0]) / 2
		q0 := at(m, s0.x, s0.y)
		path_move(p, q0.x, q0.y)
		ctrl: [2]f32
		pending := false
		emit :: proc(p: ^Path, m: [6]f32, ctrl: [2]f32, pending: bool, q: [2]f32) {
			at :: proc(m: [6]f32, x, y: f32) -> [2]f32 { return {m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]} }
			qq := at(m, q.x, q.y)
			if pending {
				cq := at(m, ctrl.x, ctrl.y)
				path_quad(p, cq.x, cq.y, qq.x, qq.y)
			} else {
				path_line(p, qq.x, qq.y)
			}
		}
		base := on_start + 1 if on_start >= 0 else 0
		for j in 0 ..< count {
			i := (base + j) % count
			q := cp[i]
			if cf[i] & 1 != 0 {
				emit(p, m, ctrl, pending, q)
				pending = false
			} else {
				if pending do emit(p, m, ctrl, true, (ctrl + q) / 2)
				ctrl = q
				pending = true
			}
		}
		if pending do emit(p, m, ctrl, true, s0) // (back to the start)
		first = last + 1
	}
}

// A glyph at a size and quarter-pixel offset, drawn (kept).
@(private)
glyph_image :: proc(tf: ^Typeface, g: int, size: f32, sub: int) -> ^Glyph_Image {
	key := u64(g) | u64(int(size * 4)) << 24 | u64(sub) << 48
	if img, ok := tf.cache[key]; ok do return img
	a := tf.cache.allocator
	img := new(Glyph_Image, a)
	tf.cache[key] = img
	k := type_scale(tf, size)
	p := path_make()
	glyph_outline(tf, g, &p, {k, 0, 0, -k, f32(sub) / 4, 0})
	if len(p.points) < 3 do return img
	lo, hi := p.points[0], p.points[0]
	for q in p.points {
		lo = {min(lo.x, q.x), min(lo.y, q.y)}
		hi = {max(hi.x, q.x), max(hi.y, q.y)}
	}
	img.left, img.top = int(math.floor(lo.x)), int(math.floor(lo.y))
	img.w = int(math.ceil(hi.x)) - img.left + 1
	img.h = int(math.ceil(hi.y)) - img.top + 1
	if img.w <= 0 || img.h <= 0 || img.w > 1024 || img.h > 1024 {
		img.w, img.h = 0, 0
		return img
	}
	stride := img.w + 2
	acc := make([]f32, stride * img.h + 2, context.temp_allocator)
	ox, oy := f32(img.left), f32(img.top)
	for s, kk in p.starts {
		end := p.starts[kk + 1] if kk + 1 < len(p.starts) else len(p.points)
		for i in s ..< end {
			pa := p.points[i]
			pb := p.points[i + 1] if i + 1 < end else p.points[s]
			raster_line(acc, stride, img.w, img.h, {pa.x - ox, pa.y - oy}, {pb.x - ox, pb.y - oy})
		}
	}
	img.alpha = make([]u8, img.w * img.h, a)
	for y in 0 ..< img.h {
		sum: f32
		for x in 0 ..< img.w {
			sum += acc[y * stride + x]
			img.alpha[y * img.w + x] = u8(min(abs(sum), 1) * 255 + 0.5)
		}
	}
	return img
}
