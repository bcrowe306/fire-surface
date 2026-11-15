package surface

// ── Drum pads ─────────────────────────────────────────────────────────

// A grid as drum pads: each pad remapped (claim table Remap: no latency)
// to a note from `base`, along each row from the bottom-left, as on most
// drum machines. The surface gets a copy, to light the pad: "Drum.Pad" at
// rest, "Drum.Hit" while played.
Drum_Pads :: struct {
	using component: Component,
	pads:         ^Matrix,
	base:         int, // the bottom-left pad's note
	channel:      u8, // 1-16, 0 = the pads' own
	velocity_map: ^[128]u8, // or nil
	top_down:     bool, // rows from the top instead
}

// Drum pads on a matrix, from `base` (36 is the usual first drum).
drum_pads_make :: proc(cs: ^Control_Surface, name: string, pads: ^Matrix, base := 36, priority := 0) -> ^Drum_Pads {
	d := new(Drum_Pads)
	component_init(cs, &d.component, name, priority)
	d.pads = pads
	d.base = base
	layer_bind_matrix(d.layer, "pads", pads)
	d.on_owned = proc(c: ^Component, slot: string, control: ^Control) { drum_pad_set((^Drum_Pads)(c), control) }
	d.on_event = proc(c: ^Component, e: Event) {
		#partial switch e.kind {
		case .Press: light(e.control, "Drum.Hit")
		case .Release: light(e.control, "Drum.Pad")
		}
	}
	return d
}

// The note a pad plays, or -1 outside 0-127.
drum_pad_note :: proc(d: ^Drum_Pads, row, col: int) -> int {
	r := row if d.top_down else d.pads.rows - 1 - row
	n := d.base + r * d.pads.cols + col
	return n if n >= 0 && n <= 127 else -1
}

// Moves the pads to another first note (a bank up or down).
drum_pads_set_base :: proc(d: ^Drum_Pads, base: int) {
	d.base = base
	if !d.active do return
	for c in d.pads.controls do if owns(&d.component, c) do drum_pad_set(d, c)
}

@(private)
drum_pad_set :: proc(d: ^Drum_Pads, c: ^Control) {
	n := drum_pad_note(d, c.row, c.col)
	if n < 0 {
		set_route(c, .Claim)
		light_off(c)
		return
	}
	set_route(c, .Remap, u8(n), d.channel, d.velocity_map)
	light(c, "Drum.Pad")
}

// ── Keyboard ──────────────────────────────────────────────────────────

// A grid as a keyboard: in key (each pad a degree of the scale, each row up
// `row_degrees` degrees) or chromatic (each row up `row_semitones`). Remapped
// like drum pads, lit "Keyboard.Root", "Keyboard.In_Scale" or
// "Keyboard.Out_Of_Scale", and "Keyboard.Playing" on every pad of a note
// being played.
Keyboard :: struct {
	using component: Component,
	pads:          ^Matrix,
	scale:         ^Scale,
	root:          int, // 0-11
	octave:        int, // the bottom-left pad's octave (note = root + 12 * (octave + 1))
	in_key:        bool,
	row_degrees:   int, // in key: 0 = 3 (a fourth in a 7-note scale)
	row_semitones: int, // chromatic: 0 = 5
	channel:       u8, // 1-16, 0 = own
	velocity_map:  ^[128]u8,
	playing:       [128]u8, // how many pads hold each note
}

// A keyboard on a matrix, in `scale` (nil: Major) on `root`.
keyboard_make :: proc(cs: ^Control_Surface, name: string, pads: ^Matrix, scale: ^Scale = nil, root := 0, octave := 2, priority := 0) -> ^Keyboard {
	k := new(Keyboard)
	component_init(cs, &k.component, name, priority)
	k.pads = pads
	k.scale = scale if scale != nil else &SCALES[0]
	k.root = root
	k.octave = octave
	k.in_key = true
	layer_bind_matrix(k.layer, "pads", pads)
	k.on_owned = proc(c: ^Component, slot: string, control: ^Control) { key_set((^Keyboard)(c), control) }
	k.on_event = proc(c: ^Component, e: Event) {
		k := (^Keyboard)(c)
		n := keyboard_note(k, e.control.row, e.control.col)
		if n < 0 do return
		#partial switch e.kind {
		case .Press: k.playing[n] += 1
		case .Release: if k.playing[n] > 0 do k.playing[n] -= 1
		case: return
		}
		for p in k.pads.controls do if owns(&k.component, p) && keyboard_note(k, p.row, p.col) == n do key_light(k, p, n)
	}
	k.on_deactivate = proc(c: ^Component) { (^Keyboard)(c).playing = {} }
	return k
}

// The note a pad plays, or -1 outside 0-127.
keyboard_note :: proc(k: ^Keyboard, row, col: int) -> int {
	r := k.pads.rows - 1 - row
	base := k.root + 12 * (k.octave + 1)
	if k.in_key {
		step := k.row_degrees if k.row_degrees > 0 else 3
		return scale_note(k.scale, base, r * step + col)
	}
	step := k.row_semitones if k.row_semitones > 0 else 5
	n := base + r * step + col
	return n if n >= 0 && n <= 127 else -1
}

// Changes the scale, root, octave or layout; the pads follow.
keyboard_set :: proc(k: ^Keyboard, scale: ^Scale, root, octave: int, in_key: bool) {
	k.scale = scale if scale != nil else k.scale
	k.root = ((root % 12) + 12) % 12
	k.octave = octave
	k.in_key = in_key
	k.playing = {}
	if !k.active do return
	for c in k.pads.controls do if owns(&k.component, c) do key_set(k, c)
}

@(private)
key_set :: proc(k: ^Keyboard, c: ^Control) {
	n := keyboard_note(k, c.row, c.col)
	if n < 0 {
		set_route(c, .Claim)
		light_off(c)
		return
	}
	set_route(c, .Remap, u8(n), k.channel, k.velocity_map)
	key_light(k, c, n)
}

@(private)
key_light :: proc(k: ^Keyboard, c: ^Control, n: int) {
	switch {
	case k.playing[n] > 0: light(c, "Keyboard.Playing")
	case (n - k.root) % 12 == 0: light(c, "Keyboard.Root")
	case in_scale(k.scale, k.root, n): light(c, "Keyboard.In_Scale")
	case: light(c, "Keyboard.Out_Of_Scale")
	}
}
