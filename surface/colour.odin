package surface

import "core:math"

// A colour, 8 bits a channel.
RGB :: [3]u8

// A colour from hue (0-360), saturation and value (0-1).
hsv_to_rgb :: proc(h, s, v: f64) -> RGB {
	hh := math.mod(h, 360)
	if hh < 0 do hh += 360
	c := v * s
	x := c * (1 - abs(math.mod(hh / 60, 2) - 1))
	m := v - c
	r, g, b: f64
	switch {
	case hh < 60:  r, g, b = c, x, 0
	case hh < 120: r, g, b = x, c, 0
	case hh < 180: r, g, b = 0, c, x
	case hh < 240: r, g, b = 0, x, c
	case hh < 300: r, g, b = x, 0, c
	case:          r, g, b = c, 0, x
	}
	return {to8(r + m), to8(g + m), to8(b + m)}
}

// A colour's hue (0-360), saturation and value (0-1).
rgb_to_hsv :: proc(c: RGB) -> (h, s, v: f64) {
	r, g, b := f64(c.r) / 255, f64(c.g) / 255, f64(c.b) / 255
	hi := max(r, g, b)
	lo := min(r, g, b)
	d := hi - lo
	v = hi
	s = d / hi if hi > 0 else 0
	h = hue(r, g, b, hi, d)
	return
}

// A colour from hue (0-360), saturation and lightness (0-1).
hsl_to_rgb :: proc(h, s, l: f64) -> RGB {
	v := l + s * min(l, 1 - l)
	sv := 0.0 if v == 0 else 2 * (1 - l / v)
	return hsv_to_rgb(h, sv, v)
}

// A colour's hue (0-360), saturation and lightness (0-1).
rgb_to_hsl :: proc(c: RGB) -> (h, s, l: f64) {
	r, g, b := f64(c.r) / 255, f64(c.g) / 255, f64(c.b) / 255
	hi := max(r, g, b)
	lo := min(r, g, b)
	d := hi - lo
	l = (hi + lo) / 2
	s = 0 if d == 0 else d / (1 - abs(2 * l - 1))
	h = hue(r, g, b, hi, d)
	return
}

@(private)
hue :: proc(r, g, b, hi, d: f64) -> f64 {
	if d == 0 do return 0
	h: f64
	switch hi {
	case r: h = math.mod((g - b) / d, 6)
	case g: h = (b - r) / d + 2
	case:   h = (r - g) / d + 4
	}
	h *= 60
	return h + 360 if h < 0 else h
}

@(private)
to8 :: proc(x: f64) -> u8 { return u8(clamp(math.round(x * 255), 0, 255)) }

// A colour scaled in brightness (0 = black, 1 = as it is).
scale_brightness :: proc(c: RGB, k: f64) -> RGB {
	return {to8(f64(c.r) / 255 * k), to8(f64(c.g) / 255 * k), to8(f64(c.b) / 255 * k)}
}

// A colour's perceived brightness, 0-1 (Rec. 709 weights).
brightness :: proc(c: RGB) -> f64 {
	return (0.2126 * f64(c.r) + 0.7152 * f64(c.g) + 0.0722 * f64(c.b)) / 255
}

// A colour as a 24-bit number (0xRRGGBB), and back.
rgb_from_hex :: proc(hex: u32) -> RGB { return {u8(hex >> 16), u8(hex >> 8), u8(hex)} }
// A colour as 0xRRGGBB.
rgb_to_hex :: proc(c: RGB) -> u32 { return u32(c.r) << 16 | u32(c.g) << 8 | u32(c.b) }

// A colour in 7 bits a channel (for SysEx): each channel halved.
rgb7 :: proc(c: RGB) -> [3]u8 { return {c.r >> 1, c.g >> 1, c.b >> 1} }

// The index of the nearest colour in a device's palette (by distance in
// weighted RGB), or -1 for an empty palette.
nearest_in_palette :: proc(c: RGB, palette: []RGB) -> int {
	best, best_d := -1, max(f64)
	for p, i in palette {
		dr := f64(int(c.r) - int(p.r))
		dg := f64(int(c.g) - int(p.g))
		db := f64(int(c.b) - int(p.b))
		d := 2 * dr * dr + 4 * dg * dg + 3 * db * db
		if d < best_d { best, best_d = i, d }
	}
	return best
}
