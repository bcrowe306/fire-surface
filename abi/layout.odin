package fsurf_abi

// The surface's layout extension's id (FSURF_LAYOUT_ID). Read
// include/fsurf_layout.h for the rules.
LAYOUT_ID :: "fsurf.layout"

// What a control is (FSURF_LAYOUT_BUTTON ...).
Layout_Kind :: enum u32 {
	Button  = 0,
	Pad     = 1,
	Encoder = 2,
	Fader   = 3,
	Other   = 4,
}

// How an encoder sends its turns (FSURF_LAYOUT_ABSOLUTE ...).
Layout_Encoding :: enum u8 {
	Absolute        = 0,
	Twos_Complement = 1,
	Signed_Bit      = 2,
	Binary_Offset   = 3,
}

// FSURF_LAYOUT_14_BIT, FSURF_LAYOUT_TOGGLE.
Layout_Flag :: enum u8 {
	Fourteen_Bit = 0,
	Toggle       = 1,
}

// A control's flags.
Layout_Flags :: distinct bit_set[Layout_Flag; u8]

// One control (fsurf_layout_control_t).
Layout_Control :: struct {
	struct_size: u32,
	name:        cstring,
	kind:        Layout_Kind,
	x, y, w, h:  f32,
	port:        u32,
	message:     Messages, // one kind
	channel:     u8,
	number:      u8,
	encoding:    Layout_Encoding,
	flags:       Layout_Flags,
}

// What a control shows (fsurf_layout_state_t).
Layout_State :: struct {
	struct_size: u32,
	value:       u32,
	channel:     i32,
	rgb:         u32,
	has_rgb:     bool,
	pressed:     bool,
	position:    f32,
}

// The extension's table (fsurf_layout_t).
Layout :: struct {
	struct_size:   u32,
	width, height: f32,
	count:         proc "c" (surface: ^Surface) -> u32,
	get:           proc "c" (surface: ^Surface, index: u32, out: ^Layout_Control) -> bool,
	find:          proc "c" (surface: ^Surface, output: bool, port: u32, bytes: [^]u8, size: u32) -> i32,
	owner:         proc "c" (surface: ^Surface, index: u32) -> cstring,
	state:         proc "c" (surface: ^Surface, index: u32, out: ^Layout_State) -> bool,
}
