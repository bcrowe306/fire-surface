package surface

import "core:strings"

// What a control is sent for a named state: a value (a velocity or a
// palette index) on its own channel or another (blink, pulse), or a SysEx
// instead (RGB).
Skin_Value :: struct {
	value:   u8,
	channel: i8, // -1 = the control's own
	sysex:   []u8,
}

// Names ("Transport.Play.On", "Session.Clip.Playing") to what a control is
// sent, so a component's logic never holds raw MIDI values.
Skin :: struct {
	values: map[string]Skin_Value,
}

// A skin. Free with `skin_destroy` (a spec's skin is the author's).
skin_make :: proc() -> ^Skin {
	s := new(Skin)
	s.values = make(map[string]Skin_Value)
	return s
}

// Frees a skin.
skin_destroy :: proc(s: ^Skin) {
	for k, v in s.values {
		delete(k)
		delete(v.sysex)
	}
	delete(s.values)
	free(s)
}

// Sets a name's value (the name and SysEx are copied).
skin_set :: proc(s: ^Skin, name: string, value: u8, channel: i8 = -1, sysex: []u8 = nil) {
	v := Skin_Value{value = value, channel = channel, sysex = clone_bytes(sysex) if len(sysex) > 0 else nil}
	if old, ok := s.values[name]; ok {
		delete(old.sysex)
		s.values[name] = v
		return
	}
	s.values[strings.clone(name)] = v
}

// A name's value in the surface's skin. A name it lacks: "*.On" is 127,
// anything else 0.
skin_value :: proc(cs: ^Control_Surface, name: string) -> Skin_Value {
	if v, ok := cs.skin.values[name]; ok do return v
	return {value = 127 if strings.has_suffix(name, ".On") else 0, channel = -1}
}

// Gives the surface a skin of the caller's (who frees it, after the
// surface is destroyed or another is set).
set_skin :: proc(cs: ^Control_Surface, s: ^Skin) {
	if cs.own_skin do skin_destroy(cs.skin)
	cs.own_skin = false
	cs.skin = s
}
