package surface

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// ── Notes and frequencies ─────────────────────────────────────────────

// A MIDI note's frequency in Hz; A4 (note 69) at `a4` Hz.
midi_note_to_freq :: proc(note: f64, a4: f64 = 440) -> f64 {
	return a4 * math.pow(2, (note - 69) / 12)
}

// A frequency's MIDI note, fractional (round it for the nearest); A4 at `a4`.
freq_to_midi_note :: proc(freq: f64, a4: f64 = 440) -> f64 {
	if freq <= 0 do return 0
	return 69 + 12 * math.log2(freq / a4)
}

// The names of the twelve notes from C, with sharps.
NOTE_NAMES :: [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

// A note's name and octave: "C4" for 60 when `middle_c_octave` is 4 (the
// usual), "C3" when it's 3 (Ableton, Yamaha). Allocated with `allocator`.
note_name :: proc(note: u8, middle_c_octave := 4, allocator := context.temp_allocator) -> string {
	names := NOTE_NAMES
	octave := int(note) / 12 - 5 + middle_c_octave
	return fmt.aprintf("%s%d", names[note % 12], octave, allocator = allocator)
}

// A note by name ("C4", "f#2", "Bb-1", "E3"): its number, or false.
note_number :: proc(name: string, middle_c_octave := 4) -> (u8, bool) {
	if len(name) < 2 do return 0, false
	letters := [7]int{9, 11, 0, 2, 4, 5, 7} // a..g
	c := name[0] | 0x20
	if c < 'a' || c > 'g' do return 0, false
	pc := letters[c - 'a']
	rest := name[1:]
	for len(rest) > 0 && (rest[0] == '#' || rest[0] == 'b') {
		pc += 1 if rest[0] == '#' else -1
		rest = rest[1:]
	}
	octave, ok := strconv.parse_int(rest)
	if !ok do return 0, false
	n := (octave - middle_c_octave + 5) * 12 + pc
	if n < 0 || n > 127 do return 0, false
	return u8(n), true
}

// ── Scales and chords ─────────────────────────────────────────────────

// A scale: its steps from the root, in semitones, within an octave.
Scale :: struct {
	name:  string,
	steps: []u8,
}

// Common scales and modes.
SCALES := [?]Scale{
	{"Major", {0, 2, 4, 5, 7, 9, 11}},
	{"Minor", {0, 2, 3, 5, 7, 8, 10}},
	{"Dorian", {0, 2, 3, 5, 7, 9, 10}},
	{"Phrygian", {0, 1, 3, 5, 7, 8, 10}},
	{"Lydian", {0, 2, 4, 6, 7, 9, 11}},
	{"Mixolydian", {0, 2, 4, 5, 7, 9, 10}},
	{"Locrian", {0, 1, 3, 5, 6, 8, 10}},
	{"Harmonic Minor", {0, 2, 3, 5, 7, 8, 11}},
	{"Melodic Minor", {0, 2, 3, 5, 7, 9, 11}},
	{"Major Pentatonic", {0, 2, 4, 7, 9}},
	{"Minor Pentatonic", {0, 3, 5, 7, 10}},
	{"Blues", {0, 3, 5, 6, 7, 10}},
	{"Whole Tone", {0, 2, 4, 6, 8, 10}},
	{"Chromatic", {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}},
}

// A scale by name (any case), or nil.
scale_named :: proc(name: string) -> ^Scale {
	for &s in SCALES do if strings.equal_fold(s.name, name) do return &s
	return nil
}

// The note at a degree of a scale (degree 0 = the root; past the steps,
// the next octave up; below 0, down), or -1 outside 0-127.
scale_note :: proc(s: ^Scale, root: int, degree: int) -> int {
	n := len(s.steps)
	octave := degree / n if degree >= 0 else (degree - n + 1) / n
	d := degree - octave * n
	note := root + octave * 12 + int(s.steps[d])
	return note if note >= 0 && note <= 127 else -1
}

// Whether a note is in a scale on `root` (0-11, or any note of that class).
in_scale :: proc(s: ^Scale, root: int, note: int) -> bool {
	pc := ((note - root) % 12 + 12) % 12
	for st in s.steps do if int(st) == pc do return true
	return false
}

// A chord: its notes above the root, in semitones.
Chord :: struct {
	name:      string,
	intervals: []u8,
}

// Common chords.
CHORDS := [?]Chord{
	{"Major", {0, 4, 7}},
	{"Minor", {0, 3, 7}},
	{"Diminished", {0, 3, 6}},
	{"Augmented", {0, 4, 8}},
	{"Sus2", {0, 2, 7}},
	{"Sus4", {0, 5, 7}},
	{"Major 7", {0, 4, 7, 11}},
	{"Minor 7", {0, 3, 7, 10}},
	{"Dominant 7", {0, 4, 7, 10}},
	{"Half-Diminished 7", {0, 3, 6, 10}},
	{"Diminished 7", {0, 3, 6, 9}},
}

// ── Velocity curves ───────────────────────────────────────────────────

// A velocity curve as a map for the claim table's `value_map` (and the
// kit's pads): `curve` < 0 softer at the low end (more gain), 0 linear,
// > 0 harder; each 1 is a power of 2 (in -4..4). Velocities from `low` to
// `high` (1-127); 0 stays 0.
velocity_curve :: proc(curve: f64, low: u8 = 1, high: u8 = 127) -> (m: [128]u8) {
	p := math.pow(2, clamp(curve, -4, 4))
	lo, hi := f64(max(low, 1)), f64(max(high, low, 1))
	for i in 1 ..< 128 {
		x := f64(i - 1) / 126
		m[i] = u8(clamp(math.round(lo + (hi - lo) * math.pow(x, p)), 1, 127))
	}
	return
}

// Every velocity as one.
velocity_fixed :: proc(v: u8) -> (m: [128]u8) {
	for i in 1 ..< 128 do m[i] = max(v, 1)
	return
}

// ── Tempo ─────────────────────────────────────────────────────────────

// Milliseconds a beat at a tempo.
beat_ms :: proc(bpm: f64) -> f64 { return 60_000 / bpm if bpm > 0 else 0 }
// A tempo from milliseconds a beat.
bpm_from_ms :: proc(ms: f64) -> f64 { return 60_000 / ms if ms > 0 else 0 }
// Milliseconds a MIDI clock tick (24 a beat) at a tempo.
clock_tick_ms :: proc(bpm: f64) -> f64 { return beat_ms(bpm) / 24 }

// Tap tempo: the average of the last few taps' intervals. A gap of more
// than `reset_ms` starts again.
Tap_Tempo :: struct {
	times:    [5]u64, // ns
	count:    int,
	reset_ms: f64, // 0 = 2000
}

// A tap at `time_ns`: the tempo so far (0 until two taps).
tap :: proc(t: ^Tap_Tempo, time_ns: u64) -> f64 {
	reset := t.reset_ms if t.reset_ms > 0 else 2000
	if t.count > 0 && f64(time_ns - t.times[(t.count - 1) % len(t.times)]) / 1e6 > reset do t.count = 0
	t.times[t.count % len(t.times)] = time_ns
	t.count += 1
	n := min(t.count, len(t.times))
	if n < 2 do return 0
	first := t.times[(t.count - n) % len(t.times)]
	last := t.times[(t.count - 1) % len(t.times)]
	return bpm_from_ms(f64(last - first) / 1e6 / f64(n - 1))
}
