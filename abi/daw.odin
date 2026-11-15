package fsurf_abi

// The standard extension's id and version (FSURF_DAW_ID, FSURF_DAW_VERSION).
// Read include/fsurf_daw.h for the rules.
DAW_ID :: "fsurf.daw"
// (See DAW_ID.)
DAW_VERSION :: 1

// The master track's index (FSURF_DAW_MASTER).
DAW_MASTER :: -1

// A part a host has (FSURF_DAW_TRANSPORT ...).
Daw_Part :: enum u32 {
	Transport = 0,
	Tracks    = 1,
	Devices   = 2,
	Launcher  = 3,
	Notes     = 4,
	App       = 5,
}

// The parts a host has.
Daw_Parts :: distinct bit_set[Daw_Part; u32]

// A value of the host (FSURF_DAW_PLAYING ...): get, get_text, set.
Daw_Id :: enum u32 {
	None                  = 0,
	Playing               = 0x100,
	Recording,
	Loop,
	Metronome,
	Tempo,
	Position,
	Signature_Numerator,
	Signature_Denominator,

	Track_Count           = 0x200,
	Track_Name,
	Track_Color,
	Selected_Track,
	Track_Mute,
	Track_Solo,
	Track_Arm,
	Track_Volume,
	Track_Pan,
	Send_Count,
	Track_Send,
	Track_Meter,

	Device_Count          = 0x300,
	Device_Name,
	Selected_Device,
	Device_On,
	Param_Count,
	Param_Name,
	Param_Value,
	Param_Steps,
	Param_Default,
	Param_Automated,

	Scene_Count           = 0x400,
	Scene_Name,
	Clip_State,
	Clip_Color,
	Clip_Name,

	Scale_Root            = 0x500,
	Scale_Mask,
	Scale_Name,
}

// Something the host does (FSURF_DAW_UNDO ...).
Daw_Action :: enum u32 {
	Undo           = 0x800,
	Redo,
	Save,
	Tap_Tempo,
	Launch_Clip,
	Stop_Track,
	Launch_Scene,
	Stop_All_Clips,
	Param_Reset,
	Show_View,
}

// A clip's state (FSURF_DAW_CLIP_*).
Clip_State :: enum u32 {
	Empty         = 0,
	Stopped       = 1,
	Playing       = 2,
	Queued        = 3,
	Recording     = 4,
	Record_Queued = 5,
	Stopping      = 6,
}

// A view (FSURF_DAW_VIEW_*).
Daw_View :: enum i32 {
	Mixer    = 0,
	Song     = 1,
	Launcher = 2,
	Devices  = 3,
}

// A topic of events (FSURF_DAW_TOPIC_*).
Daw_Topic :: enum u32 {
	Transport  = 0,
	Tracks     = 1,
	Mixer      = 2,
	Devices    = 3,
	Parameters = 4,
	Launcher   = 5,
	Notes      = 6,
}

// Topics.
Daw_Topics :: distinct bit_set[Daw_Topic; u32]

// Something changed (fsurf_daw_event_t). `topic` is one topic's bit.
Daw_Event :: struct {
	struct_size: u32,
	topic:       Daw_Topics,
	id:          Daw_Id,
	a, b:        i32,
}

// Where events go (fsurf_daw_listener_t).
Daw_Listener :: struct {
	user:     rawptr,
	on_event: proc "c" (listener: ^Daw_Listener, event: ^Daw_Event),
}

// The extension's table (fsurf_daw_t).
Daw :: struct {
	struct_size: u32,
	parts:       Daw_Parts,
	get:         proc "c" (host: ^Host, id: Daw_Id, a, b: i32) -> f64,
	get_text:    proc "c" (host: ^Host, id: Daw_Id, a, b: i32) -> cstring,
	set:         proc "c" (host: ^Host, id: Daw_Id, a, b: i32, value: f64) -> bool,
	action:      proc "c" (host: ^Host, id: Daw_Action, a, b: i32) -> bool,
	set_ring:    proc "c" (host: ^Host, first_track, tracks, first_scene, scenes: i32),
	subscribe:   proc "c" (host: ^Host, topics: Daw_Topics, listener: ^Daw_Listener),
}
