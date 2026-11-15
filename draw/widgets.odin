package draw

// ── Widgets ───────────────────────────────────────────────────────────

// A level meter, filling from the bottom (or from the left when wider than
// tall): `level` and `peak` 0-1 (peak < 0: none). Green, then yellow above
// `warn`, red above `hot`.
meter :: proc(cv: ^Canvas, r: Rect, level: f32, peak: f32 = -1, back := DARK_GREY, warn: f32 = 0.7, hot: f32 = 0.9) {
	fill_rect(cv, r, back)
	vertical := r.h >= r.w
	n := r.h if vertical else r.w
	lit := int(clamp(level, 0, 1) * f32(n) + 0.5)
	for i in 0 ..< n {
		k := (f32(i) + 0.5) / f32(n)
		c := RED if k > hot else (YELLOW if k > warn else GREEN)
		if i >= lit do continue
		if vertical do fill_rect(cv, {r.x, r.y + r.h - 1 - i, r.w, 1}, c)
		else do fill_rect(cv, {r.x + i, r.y, 1, r.h}, c)
	}
	if peak >= 0 {
		p := min(int(clamp(peak, 0, 1) * f32(n)), n - 1)
		if vertical do fill_rect(cv, {r.x, r.y + r.h - 1 - p, r.w, 1}, WHITE)
		else do fill_rect(cv, {r.x + p, r.y, 1, r.h}, WHITE)
	}
}

// A knob: a ring from -135 to 135 degrees, lit up to `value` (0-1), from
// the bottom left (or from the top when `bipolar`, for pan).
knob :: proc(cv: ^Canvas, cx, cy, radius: int, value: f32, c: u32, track := DARK_GREY, thickness := 3, bipolar := false) {
	outer := f64(radius)
	inner := outer - f64(thickness)
	arc(cv, cx, cy, inner, outer, -135, 135, track)
	v := f64(clamp(value, 0, 1))
	at := -135 + 270 * v
	if bipolar {
		arc(cv, cx, cy, inner, outer, min(at, 0), max(at, 0) + 0.01, c)
	} else {
		arc(cv, cx, cy, inner, outer, -135, at + 0.01, c)
	}
}

// A parameter: its name above, its value below, in a rectangle.
param_label :: proc(cv: ^Canvas, f: ^Font, r: Rect, name, value: string, name_colour := GREY, value_colour := WHITE) {
	half := r.h / 2
	text_in(cv, f, {r.x, r.y, r.w, half}, name, name_colour, .Center)
	text_in(cv, f, {r.x, r.y + half, r.w, r.h - half}, value, value_colour, .Center)
}

// A horizontal bar, filled to `value` (0-1).
bar :: proc(cv: ^Canvas, r: Rect, value: f32, c: u32, back := DARK_GREY) {
	fill_rect(cv, r, back)
	fill_rect(cv, {r.x, r.y, int(clamp(value, 0, 1) * f32(r.w) + 0.5), r.h}, c)
}

// A waveform from samples (-1 to 1): each column the least and most of
// its share of them, around the middle.
waveform :: proc(cv: ^Canvas, r: Rect, samples: []f32, c: u32) {
	if len(samples) == 0 || r.w <= 0 do return
	mid := r.y + r.h / 2
	half := f32(r.h) / 2
	for col in 0 ..< r.w {
		a := col * len(samples) / r.w
		b := max((col + 1) * len(samples) / r.w, a + 1)
		lo, hi := f32(1), f32(-1)
		// From the sample before (the line joins up when samples are few).
		from := max(a - 1, 0) if col > 0 else a
		for s in samples[from:min(b, len(samples))] {
			lo = min(lo, s)
			hi = max(hi, s)
		}
		vline(cv, r.x + col, mid - int(clamp(hi, -1, 1) * half), mid - int(clamp(lo, -1, 1) * half), c)
	}
}
