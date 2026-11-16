package surface

import "core:fmt"
import "core:math"

import abi "../abi"

/*
Built-in components on fsurf.daw. Each binds its controls to named slots
of its layer (`layer_bind(c.layer, "play", button)`, or the `*_bind`
procedures for strips and parameters), follows the topics it shows, and
lights its controls from the skin. Without the extension they light
nothing and do nothing.
*/

@(private)
light_flag :: proc(c: ^Control, base: string, on: bool) {
	light(c, concat(base, ".On" if on else ".Off"))
}

// Lights again each control a component owns (its `on_owned` for each):
// after what its controls mean changed (a page, a bank).
redraw_owned :: proc(comp: ^Component) {
	if comp.on_owned == nil do return
	for s in comp.layer.slots {
		if s.control != nil && owns(comp, s.control) do comp.on_owned(comp, s.name, s.control)
		if s.grid != nil do for c in s.grid.controls do if owns(comp, c) do comp.on_owned(comp, s.name, c)
	}
}

// ── Transport ─────────────────────────────────────────────────────────

// Play, stop, record, loop, metronome and tap tempo: slots "play", "stop",
// "record", "loop", "metronome", "tap". Lit "Transport.Play.On"/".Off" and
// so on ("Transport.Stop.On" while stopped).
Transport :: struct {
	using component: Component,
	play_toggles: bool, // play while playing stops (true by default)
	taps:         Tap_Tempo,
}

// A transport component; bind its buttons to its slots.
transport_make :: proc(cs: ^Control_Surface, name := "Transport", priority := 0) -> ^Transport {
	t := new(Transport)
	component_init(cs, &t.component, name, priority)
	t.play_toggles = true
	t.daw_topics = {.Transport}
	t.on_daw = proc(c: ^Component, e: abi.Daw_Event) { redraw_owned(c) }
	t.on_owned = proc(c: ^Component, slot: string, control: ^Control) {
		cs := c.cs
		switch slot {
		case "play": light_flag(control, "Transport.Play", daw_flag(cs, .Playing))
		case "stop": light_flag(control, "Transport.Stop", !daw_flag(cs, .Playing))
		case "record": light_flag(control, "Transport.Record", daw_flag(cs, .Recording))
		case "loop": light_flag(control, "Transport.Loop", daw_flag(cs, .Loop))
		case "metronome": light_flag(control, "Transport.Metronome", daw_flag(cs, .Metronome))
		case "tap": light(control, "Transport.Tap.Off")
		}
	}
	t.on_event = proc(c: ^Component, e: Event) {
		t := (^Transport)(c)
		cs := c.cs
		if e.kind == .Release && e.slot == "tap" do light(e.control, "Transport.Tap.Off")
		if e.kind != .Press do return
		switch e.slot {
		case "play":
			if daw_flag(cs, .Playing) && t.play_toggles {
				daw_set(cs, .Playing, 0, 0, 0)
			} else {
				daw_set(cs, .Playing, 0, 0, 1)
			}
		case "stop":
			if daw_flag(cs, .Playing) do daw_set(cs, .Playing, 0, 0, 0)
			else do daw_set(cs, .Position, 0, 0, 0) // stopped: back to the start
		case "record": daw_toggle(cs, .Recording)
		case "loop": daw_toggle(cs, .Loop)
		case "metronome": daw_toggle(cs, .Metronome)
		case "tap":
			light(e.control, "Transport.Tap.On")
			if !daw_action(cs, .Tap_Tempo) {
				if bpm := tap(&t.taps, e.time_ns); bpm > 0 do daw_set(cs, .Tempo, 0, 0, math.round(bpm * 10) / 10)
			}
		}
	}
	return t
}

// ── Mixer ─────────────────────────────────────────────────────────────

// What a mixer strip's control does.
Strip_Part :: enum u8 {
	Volume, // a fader (Value) or encoder (Delta)
	Pan,
	Send, // with its send index
	Mute, // buttons: toggled
	Solo,
	Arm,
	Select, // selects the track
}

@(private)
Strip_Binding :: struct {
	control: ^Control,
	strip:   int,
	part:    Strip_Part,
	send:    int,
}

// Mixer strips for the ring's tracks (strip i: the track at
// ring.first_track + i), or one strip on the selected track
// (`follow_selection`: a channel strip). Faders and encoders set volume,
// pan and sends (faders pick up the value when they have `pickup`;
// controls with `ring` are sent the value); buttons mute, solo, arm and
// select, lit "Mixer.Mute.On"/".Off" and so on, dark past the last track.
Mixer :: struct {
	using component: Component,
	strips:           int,
	follow_selection: bool,
	sensitivity:      f64, // an encoder's step (0 = 1/100)
	bindings:         [dynamic]Strip_Binding,
}

// A mixer of `strips` strips; bind controls with `mixer_bind`.
mixer_make :: proc(cs: ^Control_Surface, name: string, strips: int, follow_selection := false, priority := 0) -> ^Mixer {
	m := new(Mixer)
	component_init(cs, &m.component, name, priority)
	m.strips = strips
	m.follow_selection = follow_selection
	m.bindings = make([dynamic]Strip_Binding)
	m.daw_topics = {.Tracks, .Mixer}
	m.on_daw = proc(c: ^Component, e: abi.Daw_Event) { redraw_owned(c) }
	m.on_ring = proc(c: ^Component) { redraw_owned(c) }
	m.on_activate = proc(c: ^Component) {
		m := (^Mixer)(c)
		if !m.follow_selection && c.cs.ring.tracks == 0 do ring_setup(c.cs, m.strips, c.cs.ring.scenes)
	}
	m.on_free = proc(c: ^Component) { delete((^Mixer)(c).bindings) }
	m.on_owned = proc(c: ^Component, slot: string, control: ^Control) {
		m := (^Mixer)(c)
		if b, ok := strip_binding(m, control); ok do strip_draw(m, b)
	}
	m.on_event = proc(c: ^Component, e: Event) {
		m := (^Mixer)(c)
		b, ok := strip_binding(m, e.control)
		if !ok do return
		track, here := strip_track(m, b.strip)
		if !here do return
		cs := c.cs
		switch b.part {
		case .Volume, .Pan, .Send:
			id := abi.Daw_Id.Track_Volume if b.part == .Volume else (.Track_Pan if b.part == .Pan else .Track_Send)
			sub := b.send if b.part == .Send else 0
			v: f64
			#partial switch e.kind {
			case .Value: v = f64(e.value)
			case .Delta:
				step := m.sensitivity if m.sensitivity > 0 else 0.01
				v = clamp(daw_get(cs, id, track, sub) + f64(e.delta) * step, 0, 1)
			case: return
			}
			daw_set(cs, id, track, sub, v)
		case .Mute, .Solo, .Arm:
			if e.kind != .Press do return
			id := abi.Daw_Id.Track_Mute if b.part == .Mute else (.Track_Solo if b.part == .Solo else .Track_Arm)
			daw_toggle(cs, id, track)
		case .Select:
			if e.kind == .Press do daw_set(cs, .Selected_Track, 0, 0, f64(track))
		}
	}
	return m
}

// Binds a control to a strip's part (a send's index for Send).
mixer_bind :: proc(m: ^Mixer, strip: int, part: Strip_Part, control: ^Control, send := 0) {
	append(&m.bindings, Strip_Binding{control, strip, part, send})
	names := [Strip_Part]string{.Volume = "volume", .Pan = "pan", .Send = "send", .Mute = "mute", .Solo = "solo", .Arm = "arm", .Select = "select"}
	layer_bind(m.layer, names[part], control)
}

// The track a strip shows, and whether it is one of the host's.
mixer_strip_track :: proc(m: ^Mixer, strip: int) -> (int, bool) { return strip_track(m, strip) }

@(private)
strip_binding :: proc(m: ^Mixer, c: ^Control) -> (Strip_Binding, bool) {
	for b in m.bindings do if b.control == c do return b, true
	return {}, false
}

@(private)
strip_track :: proc(m: ^Mixer, strip: int) -> (int, bool) {
	cs := m.cs
	if cs.daw == nil do return 0, false
	if m.follow_selection {
		t := selected_track(cs)
		return t, t >= 0 || t == abi.DAW_MASTER
	}
	t := cs.ring.first_track + strip
	return t, t >= 0 && t < track_count(cs)
}

@(private)
strip_draw :: proc(m: ^Mixer, b: Strip_Binding) {
	cs := m.cs
	track, here := strip_track(m, b.strip)
	if !here {
		light_off(b.control)
		return
	}
	switch b.part {
	case .Volume, .Pan, .Send:
		id := abi.Daw_Id.Track_Volume if b.part == .Volume else (.Track_Pan if b.part == .Pan else .Track_Send)
		v := f32(daw_get(cs, id, track, b.send if b.part == .Send else 0))
		set_value(b.control, v)
		if b.control.ring do set_position(b.control, v)
	case .Mute: light_flag(b.control, "Mixer.Mute", daw_flag(cs, .Track_Mute, track))
	case .Solo: light_flag(b.control, "Mixer.Solo", daw_flag(cs, .Track_Solo, track))
	case .Arm: light_flag(b.control, "Mixer.Arm", daw_flag(cs, .Track_Arm, track))
	case .Select: light_flag(b.control, "Mixer.Select", selected_track(cs) == track)
	}
}

// ── Device ────────────────────────────────────────────────────────────

// The selected device's parameters, a bank of `params` at a time: param
// i is parameter bank * params + i. Encoders step them (a stepped
// parameter by one step a tick), faders set them; controls with `ring` are
// sent the value. Slots "prev_bank", "next_bank", "prev_device",
// "next_device" (lit "Device.Bank.On" or "Device.Nav.On" when they can
// move), "on" (the device on or off: "Device.On.On"/".Off"). The device's
// name, and "Bank N", are notified when they change.
Device :: struct {
	using component: Component,
	params:      int,
	bank:        int,
	sensitivity: f64, // an encoder's step on a continuous parameter (0 = 1/200)
	controls:    [dynamic]^Control, // param i's (nil: none)
	device:      int, // the selected device we drew
	// The bank or device changed (or its parameters): for a display to follow.
	on_change:   proc(d: ^Device),
}

// A device component of `params` parameters a bank.
device_make :: proc(cs: ^Control_Surface, name: string, params := 8, priority := 0) -> ^Device {
	d := new(Device)
	component_init(cs, &d.component, name, priority)
	d.params = params
	d.device = -1
	d.controls = make([dynamic]^Control, params)
	d.daw_topics = {.Devices, .Parameters, .Tracks}
	d.on_free = proc(c: ^Component) { delete((^Device)(c).controls) }
	d.on_daw = proc(c: ^Component, e: abi.Daw_Event) {
		d := (^Device)(c)
		sel := int(daw_get(c.cs, .Selected_Device))
		if sel != d.device {
			d.device = sel
			d.bank = 0
		}
		redraw_owned(c)
		if d.on_change != nil do d.on_change(d)
	}
	d.on_activate = proc(c: ^Component) { (^Device)(c).device = int(daw_get(c.cs, .Selected_Device)) }
	d.on_owned = proc(c: ^Component, slot: string, control: ^Control) {
		d := (^Device)(c)
		cs := c.cs
		n := int(daw_get(cs, .Param_Count))
		switch slot {
		case "prev_bank": light_flag(control, "Device.Bank", d.bank > 0)
		case "next_bank": light_flag(control, "Device.Bank", (d.bank + 1) * d.params < n)
		case "prev_device": light_flag(control, "Device.Nav", d.device > 0)
		case "next_device": light_flag(control, "Device.Nav", d.device < int(daw_get(cs, .Device_Count)) - 1)
		case "on": light_flag(control, "Device.On", daw_flag(cs, .Device_On, d.device))
		case "param":
			p := device_param(d, control)
			if p < 0 || p >= n {
				light_off(control)
				return
			}
			v := f32(daw_get(cs, .Param_Value, p))
			set_value(control, v)
			if control.ring do set_position(control, v)
		}
	}
	d.on_event = proc(c: ^Component, e: Event) {
		d := (^Device)(c)
		cs := c.cs
		n := int(daw_get(cs, .Param_Count))
		if e.slot == "param" {
			p := device_param(d, e.control)
			if p < 0 || p >= n do return
			#partial switch e.kind {
			case .Value: daw_set(cs, .Param_Value, p, 0, f64(e.value))
			case .Delta:
				v := daw_get(cs, .Param_Value, p)
				if steps := int(daw_get(cs, .Param_Steps, p)); steps > 1 {
					k := clamp(int(math.round(v * f64(steps - 1))) + (1 if e.delta > 0 else -1), 0, steps - 1)
					v = f64(k) / f64(steps - 1)
				} else {
					step := d.sensitivity if d.sensitivity > 0 else 0.005
					v = clamp(v + f64(e.delta) * step, 0, 1)
				}
				daw_set(cs, .Param_Value, p, 0, v)
			}
			return
		}
		if e.kind != .Press do return
		switch e.slot {
		case "prev_bank", "next_bank":
			b := d.bank + (1 if e.slot == "next_bank" else -1)
			if b < 0 || b * d.params >= n do return
			d.bank = b
			notify(cs, fmt.tprintf("%s: Bank %d", daw_text(cs, .Device_Name, d.device), b + 1))
			redraw_owned(c)
			if d.on_change != nil do d.on_change(d)
		case "prev_device", "next_device":
			next := d.device + (1 if e.slot == "next_device" else -1)
			if next < 0 || next >= int(daw_get(cs, .Device_Count)) do return
			if daw_set(cs, .Selected_Device, 0, 0, f64(next)) {
				d.device = next
				d.bank = 0
				notify(cs, daw_text(cs, .Device_Name, next))
				redraw_owned(c)
				if d.on_change != nil do d.on_change(d)
			}
		case "on":
			daw_toggle(cs, .Device_On, d.device)
		}
	}
	return d
}

// Binds a control to the i-th parameter of the bank.
device_bind_param :: proc(d: ^Device, i: int, control: ^Control) {
	if i < 0 || i >= d.params do return
	d.controls[i] = control
	layer_bind(d.layer, "param", control)
}

@(private)
device_param :: proc(d: ^Device, c: ^Control) -> int {
	for x, i in d.controls do if x == c do return d.bank * d.params + i
	return -1
}

// ── Launcher ──────────────────────────────────────────────────────────

// A grid of clips: column = a track of the ring, row = a scene. A pad
// launches its clip; scene buttons (`launcher_bind_scene`) launch a scene,
// stop buttons (`launcher_bind_stop`) stop a track, slot "stop_all" stops
// everything. Clips light by state: "Session.Clip.Empty", ".Stopped",
// ".Playing", ".Queued", ".Recording", ".Record_Queued", ".Stopping"; a
// stopped clip in its colour instead when `palette` is set (the nearest
// index, as its value). Scenes "Session.Scene.On" (one is there)/".Off",
// stops "Session.Stop.On" (the track is playing)/".Off".
Launcher :: struct {
	using component: Component,
	clips:   ^Matrix,
	scenes:  [dynamic]^Control,
	stops:   [dynamic]^Control,
	palette: []RGB, // the device's, or nil
}

// A launcher on a matrix; the ring is sized to it if it isn't yet.
launcher_make :: proc(cs: ^Control_Surface, name: string, clips: ^Matrix, priority := 0) -> ^Launcher {
	l := new(Launcher)
	component_init(cs, &l.component, name, priority)
	l.clips = clips
	l.scenes = make([dynamic]^Control)
	l.stops = make([dynamic]^Control)
	layer_bind_matrix(l.layer, "clips", clips)
	l.daw_topics = {.Launcher, .Tracks}
	l.on_daw = proc(c: ^Component, e: abi.Daw_Event) { redraw_owned(c) }
	l.on_ring = proc(c: ^Component) { redraw_owned(c) }
	l.on_activate = proc(c: ^Component) {
		l := (^Launcher)(c)
		if c.cs.ring.tracks == 0 || c.cs.ring.scenes == 0 do ring_setup(c.cs, l.clips.cols, l.clips.rows)
	}
	l.on_free = proc(c: ^Component) {
		l := (^Launcher)(c)
		delete(l.scenes)
		delete(l.stops)
	}
	l.on_owned = proc(c: ^Component, slot: string, control: ^Control) {
		l := (^Launcher)(c)
		cs := c.cs
		r := cs.ring
		switch slot {
		case "clips":
			t, s := r.first_track + control.col, r.first_scene + control.row
			if t >= track_count(cs) || s >= scene_count(cs) {
				light_off(control)
				return
			}
			state := abi.Clip_State(u32(daw_get(cs, .Clip_State, t, s)))
			if state == .Stopped && l.palette != nil {
				i := nearest_in_palette(rgb_from_hex(u32(daw_get(cs, .Clip_Color, t, s))), l.palette)
				light_value(control, u8(max(i, 0)))
				return
			}
			names := [abi.Clip_State]string{
				.Empty = "Session.Clip.Empty", .Stopped = "Session.Clip.Stopped", .Playing = "Session.Clip.Playing",
				.Queued = "Session.Clip.Queued", .Recording = "Session.Clip.Recording",
				.Record_Queued = "Session.Clip.Record_Queued", .Stopping = "Session.Clip.Stopping",
			}
			light(control, names[state] if state <= .Stopping else "Session.Clip.Empty")
		case "scene":
			for x, i in l.scenes do if x == control do light_flag(control, "Session.Scene", r.first_scene + i < scene_count(cs))
		case "stop":
			for x, i in l.stops do if x == control {
				t := r.first_track + i
				playing := false
				if t < track_count(cs) do for s in 0 ..< scene_count(cs) {
					st := abi.Clip_State(u32(daw_get(cs, .Clip_State, t, s)))
					if st == .Playing || st == .Recording do playing = true
				}
				light_flag(control, "Session.Stop", playing)
			}
		case "stop_all":
			light(control, "Session.Stop_All")
		}
	}
	l.on_event = proc(c: ^Component, e: Event) {
		l := (^Launcher)(c)
		cs := c.cs
		if e.kind != .Press do return
		r := cs.ring
		switch e.slot {
		case "clips":
			t, s := r.first_track + e.col, r.first_scene + e.row
			if t < track_count(cs) && s < scene_count(cs) do daw_action(cs, .Launch_Clip, t, s)
		case "scene":
			for x, i in l.scenes do if x == e.control && r.first_scene + i < scene_count(cs) do daw_action(cs, .Launch_Scene, r.first_scene + i)
		case "stop":
			for x, i in l.stops do if x == e.control && r.first_track + i < track_count(cs) do daw_action(cs, .Stop_Track, r.first_track + i)
		case "stop_all":
			daw_action(cs, .Stop_All_Clips)
		}
	}
	return l
}

// Binds a button that launches the ring's i-th scene.
launcher_bind_scene :: proc(l: ^Launcher, i: int, control: ^Control) {
	for len(l.scenes) <= i do append(&l.scenes, nil)
	l.scenes[i] = control
	layer_bind(l.layer, "scene", control)
}

// Binds a button that stops the ring's i-th track.
launcher_bind_stop :: proc(l: ^Launcher, i: int, control: ^Control) {
	for len(l.stops) <= i do append(&l.stops, nil)
	l.stops[i] = control
	layer_bind(l.layer, "stop", control)
}

// ── Navigation ────────────────────────────────────────────────────────

// Moves the ring: slots "left", "right" (by `tracks`, 0 = the ring's
// width), "up", "down" (by `scenes`, 0 = its height). Lit "Navigation.On"
// when it can move that way.
Navigation :: struct {
	using component: Component,
	tracks, scenes: int,
}

// A navigation component.
navigation_make :: proc(cs: ^Control_Surface, name := "Navigation", tracks := 0, scenes := 0, priority := 0) -> ^Navigation {
	n := new(Navigation)
	component_init(cs, &n.component, name, priority)
	n.tracks = tracks
	n.scenes = scenes
	n.daw_topics = {.Tracks, .Launcher}
	n.on_daw = proc(c: ^Component, e: abi.Daw_Event) { redraw_owned(c) }
	n.on_ring = proc(c: ^Component) { redraw_owned(c) }
	n.on_owned = proc(c: ^Component, slot: string, control: ^Control) {
		dt, ds := nav_step((^Navigation)(c), slot)
		light_flag(control, "Navigation", ring_can_move(c.cs, dt, ds))
	}
	n.on_event = proc(c: ^Component, e: Event) {
		if e.kind != .Press do return
		dt, ds := nav_step((^Navigation)(c), e.slot)
		ring_move(c.cs, dt, ds)
	}
	return n
}

@(private)
nav_step :: proc(n: ^Navigation, slot: string) -> (int, int) {
	r := n.cs.ring
	t := n.tracks if n.tracks > 0 else max(r.tracks, 1)
	s := n.scenes if n.scenes > 0 else max(r.scenes, 1)
	switch slot {
	case "left": return -t, 0
	case "right": return t, 0
	case "up": return 0, -s
	case "down": return 0, s
	}
	return 0, 0
}

// ── Undo, redo, save, views ───────────────────────────────────────────

// Buttons for the host's own actions: slots "undo", "redo", "save",
// "mixer", "song", "launcher", "devices" (the views). Lit "App.On", and
// "App.Off" while it lacks them.
App :: struct {
	using component: Component,
}

// An app component.
app_make :: proc(cs: ^Control_Surface, name := "App", priority := 0) -> ^App {
	a := new(App)
	component_init(cs, &a.component, name, priority)
	a.on_owned = proc(c: ^Component, slot: string, control: ^Control) {
		light_flag(control, "App", has_daw(c.cs, .App))
	}
	a.on_event = proc(c: ^Component, e: Event) {
		if e.kind != .Press do return
		cs := c.cs
		switch e.slot {
		case "undo": daw_action(cs, .Undo)
		case "redo": daw_action(cs, .Redo)
		case "save": daw_action(cs, .Save)
		case "mixer": daw_action(cs, .Show_View, int(abi.Daw_View.Mixer))
		case "song": daw_action(cs, .Show_View, int(abi.Daw_View.Song))
		case "launcher": daw_action(cs, .Show_View, int(abi.Daw_View.Launcher))
		case "devices": daw_action(cs, .Show_View, int(abi.Daw_View.Devices))
		}
	}
	return a
}

// ── Note repeat ───────────────────────────────────────────────────────

// While active, held pads repeat their notes in time with the host's
// tempo, every `rate` beats (0.25 = sixteenths). The pads are claimed, and
// the notes given to the host with `inject` (so a little later than a
// remap: the surface thread's timing). Give it a higher priority than the
// pads' usual owner and activate it while a button is held (a Modifier).
// `note` gives a pad's note (nil: drum layout from 36). Lit "Repeat.Pad",
// and "Repeat.Hit" as each repeat sounds.
Note_Repeat :: struct {
	using component: Component,
	pads:     ^Matrix,
	rate:     f64, // in beats
	note:     proc(nr: ^Note_Repeat, row, col: int) -> int,
	held:     [dynamic]Repeat_Held,
}

@(private)
Repeat_Held :: struct {
	control:  ^Control,
	note:     u8,
	velocity: u8,
	task:     u32,
	sounding: bool,
}

// A note repeat over a matrix.
note_repeat_make :: proc(cs: ^Control_Surface, name: string, pads: ^Matrix, rate := 0.25, priority := 1) -> ^Note_Repeat {
	nr := new(Note_Repeat)
	component_init(cs, &nr.component, name, priority)
	nr.pads = pads
	nr.rate = rate
	nr.held = make([dynamic]Repeat_Held)
	layer_bind_matrix(nr.layer, "pads", pads)
	nr.on_free = proc(c: ^Component) { delete((^Note_Repeat)(c).held) }
	nr.on_owned = proc(c: ^Component, slot: string, control: ^Control) { light(control, "Repeat.Pad") }
	nr.on_deactivate = proc(c: ^Component) {
		nr := (^Note_Repeat)(c)
		for h in nr.held do repeat_off(nr, h)
		clear(&nr.held)
	}
	nr.on_event = proc(c: ^Component, e: Event) {
		nr := (^Note_Repeat)(c)
		#partial switch e.kind {
		case .Press:
			n := repeat_note(nr, e.control.row, e.control.col)
			if n < 0 do return
			h := Repeat_Held{control = e.control, note = u8(n), velocity = max(e.velocity, 1)}
			ms := u32(max(beat_ms(repeat_tempo(nr)) * nr.rate, 10))
			append(&nr.held, h)
			repeat_sound(nr, e.control)
			Tick :: struct { nr: ^Note_Repeat, c: ^Control }
			tk := new(Tick, c.cs.allocator)
			tk^ = {nr, e.control}
			nr.held[len(nr.held) - 1].task = task_add(c.cs, ms, u64(ms) * 1_000_000, proc(data: rawptr) {
				t := (^Tick)(data)
				repeat_sound(t.nr, t.c)
			}, tk, c, proc(data: rawptr) { free(data, (^Tick)(data).nr.cs.allocator) })
		case .Pressure:
			for &h in nr.held do if h.control == e.control do h.velocity = u8(max(e.value * 127, 1))
		case .Release:
			for h, i in nr.held do if h.control == e.control {
				repeat_off(nr, h)
				ordered_remove(&nr.held, i)
				light(e.control, "Repeat.Pad")
				break
			}
		}
	}
	return nr
}

@(private)
repeat_tempo :: proc(nr: ^Note_Repeat) -> f64 {
	t := daw_get(nr.cs, .Tempo)
	return t if t > 0 else 120
}

@(private)
repeat_note :: proc(nr: ^Note_Repeat, row, col: int) -> int {
	if nr.note != nil do return nr.note(nr, row, col)
	n := 36 + (nr.pads.rows - 1 - row) * nr.pads.cols + col
	return n if n <= 127 else -1
}

// Sounds a held pad's note again (the last one off first).
@(private)
repeat_sound :: proc(nr: ^Note_Repeat, c: ^Control) {
	for &h in nr.held do if h.control == c {
		ch := c.binding.channel
		if h.sounding {
			off := note_off(ch, h.note)
			inject(nr.cs, off[:], c.binding.port)
		}
		on := note_on(ch, h.note, h.velocity)
		inject(nr.cs, on[:], c.binding.port)
		h.sounding = true
		light(c, "Repeat.Hit")
	}
}

@(private)
repeat_off :: proc(nr: ^Note_Repeat, h: Repeat_Held) {
	task_cancel(nr.cs, h.task)
	if h.sounding {
		off := note_off(h.control.binding.channel, h.note)
		inject(nr.cs, off[:], h.control.binding.port)
	}
}
