package surface

import "core:strings"

import abi "../abi"

/*
The standard extension, fsurf.daw (include/fsurf_daw.h), for the kit.

The kit asks the host for it when the surface is made (`cs.daw`, nil when
the host doesn't offer it: every procedure here then reads 0 and changes
nothing, so a surface still runs). Components say which topics they
follow (`Component.daw_topics`); while any active component follows a
topic, the kit subscribes to it, and gives each event to the active
components that follow its topic (`Component.on_daw`).

The ring is the surface's window on the tracks and scenes (Live's red
box): the Mixer's strips and the Launcher's grid show the tracks from
`ring.first_track`, and the host is told where it is, to show it.
*/

// The surface's window on the host's tracks and scenes.
Ring :: struct {
	first_track, tracks: int,
	first_scene, scenes: int,
}

@(private)
daw_init :: proc(cs: ^Control_Surface) {
	t := (^abi.Daw)(extension(cs, abi.DAW_ID, abi.DAW_VERSION))
	if t == nil || t.struct_size < size_of(abi.Daw) || t.get == nil || t.set == nil || t.action == nil || t.subscribe == nil do return
	cs.daw = t
	cs.daw_listener = {user = cs, on_event = daw_on_event}
}

// Whether the host offers fsurf.daw with this part.
has_daw :: proc(cs: ^Control_Surface, part: abi.Daw_Part) -> bool {
	return cs.daw != nil && part in cs.daw.parts
}

// A value of the host (0 without the extension).
daw_get :: proc(cs: ^Control_Surface, id: abi.Daw_Id, a: int = 0, b: int = 0) -> f64 {
	if cs.daw == nil do return 0
	return cs.daw.get(cs.host, id, i32(a), i32(b))
}

// A value's text ("" without it), in the temp allocator.
daw_text :: proc(cs: ^Control_Surface, id: abi.Daw_Id, a: int = 0, b: int = 0) -> string {
	if cs.daw == nil || cs.daw.get_text == nil do return ""
	t := cs.daw.get_text(cs.host, id, i32(a), i32(b))
	return strings.clone(string(t), context.temp_allocator) if t != nil else ""
}

// Changes a value of the host. False if it can't.
daw_set :: proc(cs: ^Control_Surface, id: abi.Daw_Id, a: int, b: int, value: f64) -> bool {
	if cs.daw == nil do return false
	return cs.daw.set(cs.host, id, i32(a), i32(b), value)
}

// Asks the host to do something. False if it can't.
daw_action :: proc(cs: ^Control_Surface, action: abi.Daw_Action, a: int = 0, b: int = 0) -> bool {
	if cs.daw == nil do return false
	return cs.daw.action(cs.host, action, i32(a), i32(b))
}

// A 0/1 value as a bool.
daw_flag :: proc(cs: ^Control_Surface, id: abi.Daw_Id, a: int = 0, b: int = 0) -> bool {
	return daw_get(cs, id, a, b) >= 0.5
}

// Turns a 0/1 value over. Its new state.
daw_toggle :: proc(cs: ^Control_Surface, id: abi.Daw_Id, a: int = 0, b: int = 0) -> bool {
	on := !daw_flag(cs, id, a, b)
	daw_set(cs, id, a, b, 1 if on else 0)
	return on
}

// The number of tracks (0 without the extension).
track_count :: proc(cs: ^Control_Surface) -> int { return int(daw_get(cs, .Track_Count)) }
// The number of scenes.
scene_count :: proc(cs: ^Control_Surface) -> int { return int(daw_get(cs, .Scene_Count)) }
// The selected track's index (-1 = the master, or none).
selected_track :: proc(cs: ^Control_Surface) -> int { return int(daw_get(cs, .Selected_Track)) }

// Sizes the ring (the tracks and scenes the surface shows at once), and
// tells the host. Components that use it (Mixer, Launcher) size it
// themselves if it is 0.
ring_setup :: proc(cs: ^Control_Surface, tracks, scenes: int) {
	cs.ring.tracks = max(tracks, 0)
	cs.ring.scenes = max(scenes, 0)
	ring_publish(cs)
}

// Moves the ring by tracks and scenes, kept on the host's tracks and
// scenes (its first one on one of them). Whether it moved.
ring_move :: proc(cs: ^Control_Surface, tracks, scenes: int) -> bool {
	r := &cs.ring
	t := clamp(r.first_track + tracks, 0, max(track_count(cs) - 1, 0))
	s := clamp(r.first_scene + scenes, 0, max(scene_count(cs) - 1, 0))
	if t == r.first_track && s == r.first_scene do return false
	r.first_track = t
	r.first_scene = s
	ring_publish(cs)
	return true
}

// Whether the ring can move that way (for a button's light).
ring_can_move :: proc(cs: ^Control_Surface, tracks, scenes: int) -> bool {
	r := cs.ring
	if tracks < 0 && r.first_track > 0 do return true
	if tracks > 0 && r.first_track < track_count(cs) - 1 && r.first_track + max(r.tracks, 1) < track_count(cs) do return true
	if scenes < 0 && r.first_scene > 0 do return true
	if scenes > 0 && r.first_scene < scene_count(cs) - 1 && r.first_scene + max(r.scenes, 1) < scene_count(cs) do return true
	return false
}

@(private)
ring_publish :: proc(cs: ^Control_Surface) {
	if cs.daw != nil && cs.daw.set_ring != nil && cs.active {
		r := cs.ring
		cs.daw.set_ring(cs.host, i32(r.first_track), i32(r.tracks), i32(r.first_scene), i32(r.scenes))
	}
	for c in cs.components do if c.active && c.on_ring != nil do c.on_ring(c)
}

// Subscribes to what the active components follow, if that changed.
@(private)
daw_update_subscription :: proc(cs: ^Control_Surface) {
	if cs.daw == nil do return
	topics: abi.Daw_Topics
	if cs.active do for c in cs.components do if c.active do topics += c.daw_topics
	if topics == cs.daw_subscribed && cs.daw_subscribe_sent do return
	cs.daw_subscribed = topics
	cs.daw_subscribe_sent = true
	cs.daw.subscribe(cs.host, topics, &cs.daw_listener if topics != {} else nil)
}

@(private)
daw_on_event :: proc "c" (l: ^abi.Daw_Listener, e: ^abi.Daw_Event) {
	cs := (^Control_Surface)(l.user)
	context = enter(cs)
	defer leave(cs)
	if !cs.active || e == nil do return
	ev := e^
	// (Components may come and go as they handle it: by index, as they are now.)
	for i := 0; i < len(cs.components); i += 1 {
		c := cs.components[i]
		if c.active && c.on_daw != nil && c.daw_topics & ev.topic != {} do c.on_daw(c, ev)
	}
	flush(cs)
}
