package surface

// How a mode's button selects it.
Behaviour :: enum u8 {
	Latching,  // a press selects it
	Momentary, // selected while held; released, the mode before comes back
	Toggle,    // a press selects it; pressed again, the mode before comes back
	Hybrid,    // momentary if held (longer than Modes.hybrid_ms), latching if tapped
}

// A mode: the components active together while it is.
Mode :: struct {
	name:       string,
	components: [dynamic]^Component,
	button:     ^Control, // or nil
	behaviour:  Behaviour,
}

// Named modes, one active at a time. A surface can have several (a main
// mode and an encoder mode), and a mode can hold another Modes (they nest).
// Its buttons light with the skin's "<name>.Mode.On" or "Mode.On" (and
// ".Off").
Modes :: struct {
	using component: Component,
	modes:        [dynamic]Mode,
	current:      int, // -1 = none
	previous:     int,
	hybrid_ms:    u32, // 0 = 300
	held:         int, // the mode whose button is held (-1)
	held_from:    int, // what was selected before it
	held_ns:      u64,
	cycle_button: ^Control,
	// After the mode changed.
	on_change:    proc(m: ^Modes, from, to: int),
}

// A Modes component. Add modes with `modes_add`; the first is selected when
// it is activated (unless one was chosen with `modes_select`).
modes_make :: proc(cs: ^Control_Surface, name: string, priority := 0) -> ^Modes {
	m := new(Modes)
	component_init(cs, &m.component, name, priority)
	m.modes = make([dynamic]Mode)
	m.current = -1
	m.previous = -1
	m.held = -1
	m.on_event = modes_event
	m.on_owned = modes_owned
	m.on_activate = proc(c: ^Component) {
		m := (^Modes)(c)
		if len(m.modes) == 0 do return
		target := m.current if m.current >= 0 else 0
		m.current = -1
		modes_select(m, target)
	}
	m.on_deactivate = proc(c: ^Component) {
		m := (^Modes)(c)
		if m.current >= 0 do for comp in m.modes[m.current].components do component_deactivate(comp)
		m.held = -1
	}
	m.on_free = proc(c: ^Component) {
		m := (^Modes)(c)
		for &mode in m.modes do delete(mode.components)
		delete(m.modes)
	}
	return m
}

// Adds a mode of these components, selected by `button` (or nil) with a
// behaviour. Its index.
modes_add :: proc(m: ^Modes, name: string, components: []^Component, button: ^Control = nil, behaviour := Behaviour.Latching) -> int {
	mode := Mode{name = name, button = button, behaviour = behaviour}
	mode.components = make([dynamic]^Component)
	append(&mode.components, ..components)
	append(&m.modes, mode)
	if button != nil do layer_bind(m.layer, name, button)
	return len(m.modes) - 1
}

// A button that selects the next mode, round.
modes_cycle_button :: proc(m: ^Modes, button: ^Control) {
	m.cycle_button = button
	layer_bind(m.layer, "cycle", button)
}

// The index of a mode by name, or -1.
modes_find :: proc(m: ^Modes, name: string) -> int {
	for mode, i in m.modes do if mode.name == name do return i
	return -1
}

// The current mode's name ("" for none).
modes_current :: proc(m: ^Modes) -> string {
	return m.modes[m.current].name if m.current >= 0 else ""
}

// Selects a mode: the components of the old one that the new one lacks
// are deactivated, then the new one's activated. (Before the Modes is
// active, it only chooses which mode it starts in.)
modes_select :: proc(m: ^Modes, index: int) {
	if index < 0 || index >= len(m.modes) || index == m.current do return
	if !m.active {
		m.current = index
		return
	}
	from := m.current
	if from >= 0 {
		for c in m.modes[from].components {
			keep := false
			for n in m.modes[index].components do if n == c do keep = true
			if !keep do component_deactivate(c)
		}
	}
	m.previous = from
	m.current = index
	for c in m.modes[index].components do component_activate(c)
	modes_redraw(m)
	if m.on_change != nil do m.on_change(m, from, index)
}

@(private)
modes_redraw :: proc(m: ^Modes) {
	for mode, i in m.modes {
		if mode.button == nil || !owns(&m.component, mode.button) do continue
		modes_light(m, mode.button, i == m.current)
	}
	if m.cycle_button != nil && owns(&m.component, m.cycle_button) do modes_light(m, m.cycle_button, m.current >= 0)
}

@(private)
modes_light :: proc(m: ^Modes, c: ^Control, on: bool) {
	name := m.name
	own_name := concat(name, ".Mode.On" if on else ".Mode.Off")
	if _, ok := m.cs.skin.values[own_name]; ok {
		light(c, own_name)
	} else {
		light(c, "Mode.On" if on else "Mode.Off")
	}
}

@(private)
concat :: proc(a, b: string) -> string {
	buf := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(buf, a)
	copy(buf[len(a):], b)
	return string(buf)
}

@(private)
modes_owned :: proc(c: ^Component, slot: string, control: ^Control) {
	m := (^Modes)(c)
	if control == m.cycle_button {
		modes_light(m, control, m.current >= 0)
		return
	}
	i := modes_find(m, slot)
	if i >= 0 do modes_light(m, control, i == m.current)
}

@(private)
modes_event :: proc(c: ^Component, e: Event) {
	m := (^Modes)(c)
	if e.control == m.cycle_button {
		if e.kind == .Press && len(m.modes) > 0 do modes_select(m, (m.current + 1) % len(m.modes))
		return
	}
	i := modes_find(m, e.slot)
	if i < 0 do return
	mode := m.modes[i]
	#partial switch e.kind {
	case .Press:
		switch mode.behaviour {
		case .Latching:
			modes_select(m, i)
		case .Toggle:
			if m.current == i && m.previous >= 0 {
				modes_select(m, m.previous)
			} else {
				modes_select(m, i)
			}
		case .Momentary, .Hybrid:
			m.held = i
			m.held_from = m.current
			m.held_ns = e.time_ns
			modes_select(m, i)
		}
	case .Release:
		if m.held != i do return
		m.held = -1
		back := m.held_from
		hybrid := u64(m.hybrid_ms if m.hybrid_ms > 0 else 300) * 1_000_000
		switch mode.behaviour {
		case .Latching, .Toggle:
		case .Momentary:
			if back >= 0 do modes_select(m, back)
		case .Hybrid:
			if back >= 0 && e.time_ns - m.held_ns >= hybrid do modes_select(m, back)
		}
	}
}

// ── Modifier ──────────────────────────────────────────────────────────

// A modifier button (Shift, Select, Delete): while held, its components are
// active (an overlay: give their layers a higher priority than what they
// cover). Lit with "<name>.On"/"<name>.Off" (or "Modifier.On"/"Off").
Modifier :: struct {
	using component: Component,
	button:     ^Control,
	while_held: [dynamic]^Component,
	held:       bool,
}

// A modifier on a button, activating `while_held` while it is held.
modifier_make :: proc(cs: ^Control_Surface, name: string, button: ^Control, while_held: []^Component = nil, priority := 0) -> ^Modifier {
	m := new(Modifier)
	component_init(cs, &m.component, name, priority)
	m.button = button
	m.while_held = make([dynamic]^Component)
	append(&m.while_held, ..while_held)
	layer_bind(m.layer, "button", button)
	m.on_event = proc(c: ^Component, e: Event) {
		m := (^Modifier)(c)
		#partial switch e.kind {
		case .Press: modifier_set(m, true)
		case .Release: modifier_set(m, false)
		}
	}
	m.on_owned = proc(c: ^Component, slot: string, control: ^Control) { modifier_light((^Modifier)(c)) }
	m.on_deactivate = proc(c: ^Component) { modifier_set((^Modifier)(c), false) }
	m.on_free = proc(c: ^Component) { delete((^Modifier)(c).while_held) }
	return m
}

@(private)
modifier_set :: proc(m: ^Modifier, held: bool) {
	if m.held == held do return
	m.held = held
	for c in m.while_held {
		if held do component_activate(c)
		else do component_deactivate(c)
	}
	modifier_light(m)
}

@(private)
modifier_light :: proc(m: ^Modifier) {
	if !owns(&m.component, m.button) do return
	name := concat(m.name, ".On" if m.held else ".Off")
	if _, ok := m.cs.skin.values[name]; ok {
		light(m.button, name)
	} else {
		light(m.button, "Modifier.On" if m.held else "Modifier.Off")
	}
}
