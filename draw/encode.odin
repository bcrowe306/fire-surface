package draw

import "core:hash"

// A display's pixel format (the protocol's FSURF_PIXEL_*, but text).
Format :: enum u8 {
	Rgb565,     // 16 bits, little-endian: red high
	Bgr565,     // 16 bits, little-endian: blue high
	Rgb888,     // 3 bytes: red, green, blue
	Mono,       // 1 bit, rows, most significant bit first; lit = brighter than half
	Mono_Pages, // 1 bit, pages of 8 rows: a byte a column, its low bit the top row (SSD1306)
}

// The bytes a canvas is in a format (a region of it: the whole by
// default), appended to `out`. For Mono_Pages a region's rows are widened
// to whole pages.
encode :: proc(cv: ^Canvas, format: Format, out: ^[dynamic]u8, region := Rect{}) {
	r := region if region.w > 0 && region.h > 0 else Rect{0, 0, cv.width, cv.height}
	r = intersect(r, {0, 0, cv.width, cv.height})
	switch format {
	case .Rgb565, .Bgr565:
		for y in r.y ..< r.y + r.h do for x in r.x ..< r.x + r.w {
			v := to565(cv.pixels[y * cv.width + x], format == .Bgr565)
			append(out, u8(v), u8(v >> 8))
		}
	case .Rgb888:
		for y in r.y ..< r.y + r.h do for x in r.x ..< r.x + r.w {
			p := cv.pixels[y * cv.width + x]
			append(out, u8(p >> 16), u8(p >> 8), u8(p))
		}
	case .Mono:
		for y in r.y ..< r.y + r.h {
			b: u8
			n := 0
			for x in r.x ..< r.x + r.w {
				b <<= 1
				if lit(cv.pixels[y * cv.width + x]) do b |= 1
				n += 1
				if n == 8 {
					append(out, b)
					b, n = 0, 0
				}
			}
			if n > 0 do append(out, b << u8(8 - n))
		}
	case .Mono_Pages:
		p0, p1 := r.y / 8, (r.y + r.h + 7) / 8
		for page in p0 ..< p1 do for x in r.x ..< r.x + r.w {
			b: u8
			for bit in 0 ..< 8 {
				y := page * 8 + bit
				if y < cv.height && lit(cv.pixels[y * cv.width + x]) do b |= 1 << u8(bit)
			}
			append(out, b)
		}
	}
}

// A colour in 16 bits: 5 red, 6 green, 5 blue (red high), or blue high.
to565 :: proc(c: u32, bgr := false) -> u16 {
	r, g, b := u16(c >> 19) & 0x1F, u16(c >> 10) & 0x3F, u16(c >> 3) & 0x1F
	return b << 11 | g << 5 | r if bgr else r << 11 | g << 5 | b
}

@(private)
lit :: proc(c: u32) -> bool {
	return 2 * ((c >> 16) & 0xFF) + 5 * ((c >> 8) & 0xFF) + (c & 0xFF) >= 8 * 128
}

// Push 2's display: 960 x 160. A frame is a 16-byte header, then 160 lines
// of 960 BGR565 pixels and 128 bytes of filler (2048 bytes a line), each
// 4 bytes XORed with E7 F3 E7 FF; it is sent to the display's bulk endpoint
// (0x01) after the header, in 16 KiB transfers. As Ableton documents it
// (github.com/Ableton/push-interface); tried on a Push 2.
PUSH2_WIDTH :: 960
// (See PUSH2_WIDTH.)
PUSH2_HEIGHT :: 160
// The frame header.
PUSH2_HEADER :: [16]u8{0xFF, 0xCC, 0xAA, 0x88, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}

// A Push 2 frame of a 960 x 160 canvas (header and lines), appended to `out`.
encode_push2 :: proc(cv: ^Canvas, out: ^[dynamic]u8) {
	header := PUSH2_HEADER
	append(out, ..header[:])
	mask := [4]u8{0xE7, 0xF3, 0xE7, 0xFF}
	for y in 0 ..< PUSH2_HEIGHT {
		k := 0
		for x in 0 ..< 1024 {
			v: u16
			if x < PUSH2_WIDTH && x < cv.width && y < cv.height do v = to565(cv.pixels[y * cv.width + x], true)
			append(out, u8(v) ~ mask[k], u8(v >> 8) ~ mask[k + 1])
			k = (k + 2) & 3
		}
	}
}

// The canvas as RGBA, 8 bits a channel, rows top to bottom (what a host
// mirrors), appended to `out`.
rgba :: proc(cv: ^Canvas, out: ^[dynamic]u8) {
	for p in cv.pixels do append(out, u8(p >> 16), u8(p >> 8), u8(p), 255)
}

// ── PNG ───────────────────────────────────────────────────────────────

// RGBA pixels (`width` x `height`) as a PNG file (stored, not compressed),
// appended to `out`.
png_rgba :: proc(rgba: []u8, width, height: int, out: ^[dynamic]u8) {
	sig := [8]u8{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}
	append(out, ..sig[:])
	ihdr: [13]u8
	be32(ihdr[0:], u32(width))
	be32(ihdr[4:], u32(height))
	ihdr[8], ihdr[9], ihdr[10], ihdr[11], ihdr[12] = 8, 6, 0, 0, 0 // 8 bits, RGBA
	chunk(out, "IHDR", ihdr[:])
	// The image: a filter byte (0) a row, in zlib's stored blocks.
	raw := make([dynamic]u8, context.temp_allocator)
	for y in 0 ..< height {
		append(&raw, 0)
		append(&raw, ..rgba[y * width * 4:][:width * 4])
	}
	z := make([dynamic]u8, context.temp_allocator)
	append(&z, 0x78, 0x01)
	for i := 0; i < len(raw); i += 65535 {
		n := min(65535, len(raw) - i)
		last := u8(1) if i + n >= len(raw) else 0
		append(&z, last, u8(n), u8(n >> 8), u8(~u16(n)), u8(~u16(n) >> 8))
		append(&z, ..raw[i:][:n])
	}
	if len(raw) == 0 do append(&z, 1, 0, 0, 0xFF, 0xFF)
	a := hash.adler32(raw[:])
	tail: [4]u8
	be32(tail[:], a)
	append(&z, ..tail[:])
	chunk(out, "IDAT", z[:])
	chunk(out, "IEND", nil)
}

// A canvas as a PNG file, appended to `out`.
png :: proc(cv: ^Canvas, out: ^[dynamic]u8) {
	px := make([dynamic]u8, context.temp_allocator)
	rgba(cv, &px)
	png_rgba(px[:], cv.width, cv.height, out)
}

@(private)
be32 :: proc(b: []u8, v: u32) {
	b[0], b[1], b[2], b[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}

@(private)
chunk :: proc(out: ^[dynamic]u8, kind: string, data: []u8) {
	n: [4]u8
	be32(n[:], u32(len(data)))
	append(out, ..n[:])
	start := len(out)
	append(out, ..transmute([]u8)kind)
	append(out, ..data)
	c: [4]u8
	be32(c[:], hash.crc32(out[start:]))
	append(out, ..c[:])
}
