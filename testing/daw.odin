package fsurf_testing

import "core:fmt"
import "core:math"

import abi "../abi"
import host "../host"

/*
A fake fsurf.daw: a small DAW in memory (transport, tracks with clips and
devices, scenes, a scale), offered to the surface as the real extension.
What the surface changes queues an event, as a host's own changes do
(`daw_changed`); they are delivered after the next host update
(`midi_in`, `advance`, `update`), as a host delivers them on its next
frame. Change the model through `th.daw` and call `daw_changed`.

	fst.daw_enable(&th, tracks = 8, scenes = 4) // before start
	fst.start(&th, &entry, "com.example.keys")
	th.daw.tracks[2].clips[0].state = .Stopped
	fst.daw_changed(&th, {.Launcher})
	fst.update(&th)
*/

// A clip of the fake DAW.
Fake_Clip :: struct {
	state: abi.Clip_State,
	color: u32,
	name:  string,
}

// A parameter of a fake device.
Fake_Param :: struct {
	name:      string,
	value:     f64,
	default:   f64,
	steps:     int,
	automated: bool,
}

// A device of a fake track.
Fake_Device :: struct {
	name:   string,
	on:     bool,
	params: [dynamic]Fake_Param,
}

// A track of the fake DAW.
Fake_Track :: struct {
	name:            string,
	color:           u32,
	mute, solo, arm: bool,
	volume, pan:     f64,
	sends:           [2]f64,
	clips:           [dynamic]Fake_Clip, // a scene each
	devices:         [dynamic]Fake_Device,
	selected_device: int,
}

// The fake DAW. Fields are the model: change them, then `daw_changed`.
Fake_Daw :: struct {
	table:                    abi.Daw,
	playing, recording:       bool,
	loop, metronome:          bool,
	tempo, position:          f64,
	numerator, denominator:   int,
	tracks:                   [dynamic]Fake_Track,
	master:                   Fake_Track,
	scenes:                   [dynamic]string,
	selected_track:           int,
	scale_root:               int,
	scale_mask:               u32,
	scale_name:               string,
	tap_tempo:                bool, // whether it has its own tap tempo (the action works)
	ring:                     [4]int, // first track, tracks, first scene, scenes
	topics:                   abi.Daw_Topics,
	listener:                 ^abi.Daw_Listener,
	pending:                  [dynamic]abi.Daw_Event,
	actions:                  [dynamic]string, // what the surface asked: "launch_clip 1 0"
	text:                     [128]u8,
	names:                    [dynamic]string, // names it made (freed with it)
}

// Offers a fake fsurf.daw with every part: `tracks` tracks ("1", "2"...)
// of `scenes` empty clips each, each with one device ("Device 1"...) of
// `params` parameters ("P1"... at 0.5; P3 has 3 steps); a C minor scale.
// Before `start`.
daw_enable :: proc(th: ^Test_Host, tracks := 4, scenes := 4, params := 16) {
	d := new(Fake_Daw)
	th.daw = d
	d.tempo = 120
	d.numerator, d.denominator = 4, 4
	d.tracks = make([dynamic]Fake_Track)
	d.scenes = make([dynamic]string)
	d.pending = make([dynamic]abi.Daw_Event)
	d.actions = make([dynamic]string)
	d.names = make([dynamic]string)
	d.scale_mask = 0b0101_1010_1101 // C minor: 0 2 3 5 7 8 10
	d.scale_name = "Minor"
	d.master = {name = "Master", volume = 0.8, pan = 0.5}
	for s in 0 ..< scenes do append(&d.scenes, name(d, "Scene %d", s + 1))
	for t in 0 ..< tracks {
		tr := Fake_Track{name = name(d, "%d", t + 1), color = 0xFF0000 >> u32(t % 3 * 8), volume = 0.8, pan = 0.5}
		tr.clips = make([dynamic]Fake_Clip)
		for _ in 0 ..< scenes do append(&tr.clips, Fake_Clip{})
		tr.devices = make([dynamic]Fake_Device)
		dev := Fake_Device{name = name(d, "Device %d", t + 1), on = true}
		dev.params = make([dynamic]Fake_Param)
		for p in 0 ..< params do append(&dev.params, Fake_Param{name = name(d, "P%d", p + 1), value = 0.5, default = 0.5, steps = 3 if p == 2 else 0})
		append(&tr.devices, dev)
		append(&d.tracks, tr)
	}
	d.table = {
		struct_size = size_of(abi.Daw),
		parts = {.Transport, .Tracks, .Devices, .Launcher, .Notes, .App},
		get = fake_get, get_text = fake_get_text, set = fake_set, action = fake_action,
		set_ring = fake_set_ring, subscribe = fake_subscribe,
	}
	add_extension(th, abi.DAW_ID, abi.DAW_VERSION, &d.table)
}

@(private)
name :: proc(d: ^Fake_Daw, format: string, args: ..any) -> string {
	s := fmt.aprintf(format, ..args)
	append(&d.names, s)
	return s
}

@(private)
daw_destroy :: proc(th: ^Test_Host) {
	d := th.daw
	if d == nil do return
	free_track :: proc(t: ^Fake_Track) {
		for &dev in t.devices do delete(dev.params)
		delete(t.devices)
		delete(t.clips)
	}
	for &t in d.tracks do free_track(&t)
	free_track(&d.master)
	delete(d.tracks)
	delete(d.scenes)
	delete(d.pending)
	for a in d.actions do delete(a)
	delete(d.actions)
	for n in d.names do delete(n)
	delete(d.names)
	free(d)
	th.daw = nil
}

// Queues an event, as the host does when something changes.
daw_changed :: proc(th: ^Test_Host, topic: abi.Daw_Topics, id := abi.Daw_Id.None, a := 0, b := 0) {
	if th.daw == nil do return
	append(&th.daw.pending, abi.Daw_Event{struct_size = size_of(abi.Daw_Event), topic = topic, id = id, a = i32(a), b = i32(b)})
}

// A host update, then the events (as a host's next frame).
update :: proc(th: ^Test_Host) {
	host.host_update(&th.h)
	daw_flush(th)
}

@(private)
daw_flush :: proc(th: ^Test_Host) {
	d := th.daw
	if d == nil do return
	for len(d.pending) > 0 {
		events := make([]abi.Daw_Event, len(d.pending), context.temp_allocator)
		copy(events, d.pending[:])
		clear(&d.pending)
		for e in events {
			e := e
			if d.listener != nil && d.topics & e.topic != {} do d.listener.on_event(d.listener, &e)
		}
		host.host_update(&th.h) // what the events changed (their own events: again)
	}
}

// The last action the surface asked for ("" for none), and how many.
last_action :: proc(th: ^Test_Host) -> string {
	d := th.daw
	return d.actions[len(d.actions) - 1] if d != nil && len(d.actions) > 0 else ""
}

@(private)
fake :: proc "contextless" (h: ^abi.Host) -> (^Test_Host, ^Fake_Daw) {
	s := (^host.Instance)(h.host_data)
	th := (^Test_Host)(s.host.config.user)
	return th, th.daw
}

@(private)
track :: proc(d: ^Fake_Daw, a: i32) -> ^Fake_Track {
	if a == abi.DAW_MASTER do return &d.master
	if a < 0 || int(a) >= len(d.tracks) do return nil
	return &d.tracks[a]
}

@(private)
device :: proc(d: ^Fake_Daw) -> ^Fake_Device {
	t := track(d, i32(d.selected_track))
	if t == nil || t.selected_device < 0 || t.selected_device >= len(t.devices) do return nil
	return &t.devices[t.selected_device]
}

@(private)
param :: proc(d: ^Fake_Daw, a: i32) -> ^Fake_Param {
	dev := device(d)
	if dev == nil || a < 0 || int(a) >= len(dev.params) do return nil
	return &dev.params[a]
}

@(private)
clip :: proc(d: ^Fake_Daw, a, b: i32) -> ^Fake_Clip {
	t := track(d, a)
	if t == nil || b < 0 || int(b) >= len(t.clips) do return nil
	return &t.clips[b]
}

@(private)
b2f :: proc(b: bool) -> f64 { return 1 if b else 0 }

@(private)
fake_get :: proc "c" (h: ^abi.Host, id: abi.Daw_Id, a, b: i32) -> f64 {
	th, d := fake(h)
	context = th.h.ctx
	#partial switch id {
	case .Playing: return b2f(d.playing)
	case .Recording: return b2f(d.recording)
	case .Loop: return b2f(d.loop)
	case .Metronome: return b2f(d.metronome)
	case .Tempo: return d.tempo
	case .Position: return d.position
	case .Signature_Numerator: return f64(d.numerator)
	case .Signature_Denominator: return f64(d.denominator)
	case .Track_Count: return f64(len(d.tracks))
	case .Selected_Track: return f64(d.selected_track)
	case .Send_Count: return 2
	case .Scene_Count: return f64(len(d.scenes))
	case .Scale_Root: return f64(d.scale_root)
	case .Scale_Mask: return f64(d.scale_mask)
	}
	if t := track(d, a); t != nil {
		#partial switch id {
		case .Track_Color: return f64(t.color)
		case .Track_Mute: return b2f(t.mute)
		case .Track_Solo: return b2f(t.solo)
		case .Track_Arm: return b2f(t.arm)
		case .Track_Volume: return t.volume
		case .Track_Pan: return t.pan
		case .Track_Send: return t.sends[b] if b >= 0 && b < 2 else 0
		case .Track_Meter: return t.volume * 0.5
		}
	}
	if t := track(d, i32(d.selected_track)); t != nil {
		#partial switch id {
		case .Device_Count: return f64(len(t.devices))
		case .Selected_Device: return f64(t.selected_device)
		case .Device_On: return b2f(t.devices[a].on) if a >= 0 && int(a) < len(t.devices) else 0
		case .Param_Count: return f64(len(device(d).params)) if device(d) != nil else 0
		}
	}
	if p := param(d, a); p != nil {
		#partial switch id {
		case .Param_Value: return p.value
		case .Param_Steps: return f64(p.steps)
		case .Param_Default: return p.default
		case .Param_Automated: return b2f(p.automated)
		}
	}
	if c := clip(d, a, b); c != nil {
		#partial switch id {
		case .Clip_State: return f64(u32(c.state))
		case .Clip_Color: return f64(c.color)
		}
	}
	return 0
}

@(private)
fake_get_text :: proc "c" (h: ^abi.Host, id: abi.Daw_Id, a, b: i32) -> cstring {
	th, d := fake(h)
	context = th.h.ctx
	s: string
	ok := true
	#partial switch id {
	case .Track_Name: if t := track(d, a); t != nil do s = t.name; else do ok = false
	case .Track_Volume:
		t := track(d, a)
		if t == nil do return nil
		s = fmt.bprintf(d.text[:len(d.text) - 1], "%.1f dB", 40 * math.log10(max(t.volume, 1e-4)))
	case .Device_Name:
		t := track(d, i32(d.selected_track))
		if t == nil || a < 0 || int(a) >= len(t.devices) do return nil
		s = t.devices[a].name
	case .Param_Name: if p := param(d, a); p != nil do s = p.name; else do ok = false
	case .Param_Value:
		p := param(d, a)
		if p == nil do return nil
		s = fmt.bprintf(d.text[:len(d.text) - 1], "%.2f", p.value)
	case .Scene_Name: if a >= 0 && int(a) < len(d.scenes) do s = d.scenes[a]; else do ok = false
	case .Clip_Name: if c := clip(d, a, b); c != nil do s = c.name; else do ok = false
	case .Scale_Name: s = d.scale_name
	case: return nil
	}
	if !ok do return nil
	n := min(len(s), len(d.text) - 1)
	copy(d.text[:n], s)
	d.text[n] = 0
	return cstring(&d.text[0])
}

@(private)
fake_set :: proc "c" (h: ^abi.Host, id: abi.Daw_Id, a, b: i32, v: f64) -> bool {
	th, d := fake(h)
	context = th.h.ctx
	on := v >= 0.5
	unit := clamp(v, 0, 1)
	topic: abi.Daw_Topics
	switch {
	case id >= .Playing && id <= .Signature_Denominator:
		topic = {.Transport}
		#partial switch id {
		case .Playing: d.playing = on
		case .Recording: d.recording = on
		case .Loop: d.loop = on
		case .Metronome: d.metronome = on
		case .Tempo: d.tempo = clamp(v, 20, 999)
		case .Position: d.position = max(v, 0); return true // no event for the position
		case: return false
		}
	case id == .Selected_Track:
		if track(d, i32(v)) == nil do return false
		d.selected_track = int(v)
		topic = {.Tracks}
		daw_changed(th, {.Devices})
	case id == .Selected_Device:
		t := track(d, i32(d.selected_track))
		if t == nil || int(v) < 0 || int(v) >= len(t.devices) do return false
		t.selected_device = int(v)
		topic = {.Devices}
	case id == .Device_On:
		t := track(d, i32(d.selected_track))
		if t == nil || a < 0 || int(a) >= len(t.devices) do return false
		t.devices[a].on = on
		topic = {.Devices}
	case id == .Param_Value:
		p := param(d, a)
		if p == nil do return false
		p.value = unit
		topic = {.Parameters}
	case id >= .Track_Mute && id <= .Track_Send:
		t := track(d, a)
		if t == nil do return false
		topic = {.Mixer}
		#partial switch id {
		case .Track_Mute: t.mute = on
		case .Track_Solo: t.solo = on
		case .Track_Arm: t.arm = on
		case .Track_Volume: t.volume = unit
		case .Track_Pan: t.pan = unit
		case .Track_Send:
			if b < 0 || b >= 2 do return false
			t.sends[b] = unit
		case: return false
		}
	case:
		return false
	}
	daw_changed(th, topic, id, int(a), int(b))
	return true
}

@(private)
fake_action :: proc "c" (h: ^abi.Host, id: abi.Daw_Action, a, b: i32) -> bool {
	th, d := fake(h)
	context = th.h.ctx
	names := [abi.Daw_Action]string{
		.Undo = "undo", .Redo = "redo", .Save = "save", .Tap_Tempo = "tap_tempo", .Launch_Clip = "launch_clip",
		.Stop_Track = "stop_track", .Launch_Scene = "launch_scene", .Stop_All_Clips = "stop_all_clips",
		.Param_Reset = "param_reset", .Show_View = "show_view",
	}
	if id < .Undo || id > .Show_View do return false
	if id == .Tap_Tempo && !d.tap_tempo do return false
	append(&d.actions, fmt.aprintf("%s %d %d", names[id], a, b))
	launch :: proc(t: ^Fake_Track, s: int) {
		for &c, i in t.clips {
			if i == s && c.state != .Empty do c.state = .Playing
			else if c.state == .Playing do c.state = .Stopped
		}
	}
	#partial switch id {
	case .Launch_Clip:
		t := track(d, a)
		if t == nil || clip(d, a, b) == nil do return false
		launch(t, int(b))
		daw_changed(th, {.Launcher})
	case .Launch_Scene:
		for &t in d.tracks do if int(a) < len(t.clips) && t.clips[a].state != .Empty do launch(&t, int(a))
		daw_changed(th, {.Launcher})
	case .Stop_Track:
		t := track(d, a)
		if t == nil do return false
		for &c in t.clips do if c.state == .Playing do c.state = .Stopped
		daw_changed(th, {.Launcher})
	case .Stop_All_Clips:
		for &t in d.tracks do for &c in t.clips do if c.state == .Playing do c.state = .Stopped
		daw_changed(th, {.Launcher})
	case .Param_Reset:
		p := param(d, a)
		if p == nil do return false
		p.value = p.default
		daw_changed(th, {.Parameters}, .Param_Value, int(a))
	}
	return true
}

@(private)
fake_set_ring :: proc "c" (h: ^abi.Host, ft, nt, fs, ns: i32) {
	_, d := fake(h)
	d.ring = {int(ft), int(nt), int(fs), int(ns)}
}

@(private)
fake_subscribe :: proc "c" (h: ^abi.Host, topics: abi.Daw_Topics, listener: ^abi.Daw_Listener) {
	_, d := fake(h)
	d.topics = topics
	d.listener = listener
}
