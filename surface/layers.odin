package surface

/*
Components own controls through layers. A layer names slots ("play")
bound to controls, and has a priority. Each control keeps a stack of the
layers that want it; while they are active, the highest priority has it
(of equal ones, the last activated). When that layer goes, the control
returns to the next one down, and its new owner redraws it. A control
nobody owns is dark, and its messages are the surface's (or the host's,
with `Spec.pass_unowned`).

Shift overlays, modes and momentary views are all layers coming and going.
*/

// Named slots bound to controls, with a priority. Made with its component.
Layer :: struct {
	name:      string,
	priority:  int,
	component: ^Component,
	slots:     [dynamic]Slot,
	active:    bool,
}

// A slot of a layer: a control, or a matrix (each of its controls).
Slot :: struct {
	name:    string,
	control: ^Control,
	grid:  ^Matrix,
}

@(private)
Ownership :: struct {
	layer:    ^Layer,
	slot:     string,
	sequence: int,
}

// A group of controls (through its layer) and the logic that gives them
// meaning. Embed it first in a struct of your own (the built-in ones do)
// or use `user`.
Component :: struct {
	cs:       ^Control_Surface,
	name:     string,
	layer:    ^Layer,
	children: [dynamic]^Component, // activated and deactivated with it
	active:   bool,
	user:     rawptr,

	// An owned control did something.
	on_event:      proc(c: ^Component, e: Event),
	// It now owns this control (activated, or the control came back to
	// it): draw it, and set its route if not Claim.
	on_owned:      proc(c: ^Component, slot: string, control: ^Control),
	on_activate:   proc(c: ^Component),
	on_deactivate: proc(c: ^Component),
	// Frees what it holds, when the surface is destroyed (built-in ones
	// free themselves).
	on_free:       proc(c: ^Component),
}

// A component and its layer (of `priority`). The surface frees it.
component_make :: proc(cs: ^Control_Surface, name: string, priority := 0) -> ^Component {
	return component_init(cs, new(Component), name, priority)
}

// Sets up a component embedded first in a struct of the caller's
// (allocated with `new`): the built-ins do this. The surface frees it.
component_init :: proc(cs: ^Control_Surface, c: ^Component, name: string, priority := 0) -> ^Component {
	c.cs = cs
	c.name = name
	c.children = make([dynamic]^Component)
	c.layer = new(Layer)
	c.layer^ = {name = name, priority = priority, component = c}
	c.layer.slots = make([dynamic]Slot)
	append(&cs.components, c)
	return c
}

@(private)
component_free :: proc(c: ^Component) {
	if c.on_free != nil do c.on_free(c)
	delete(c.layer.slots)
	free(c.layer)
	delete(c.children)
	free(c)
}

// Binds a control to a slot of a layer.
layer_bind :: proc(l: ^Layer, slot: string, control: ^Control) {
	append(&l.slots, Slot{name = slot, control = control})
	if l.active do own(l, slot, control)
}

// Binds every control of a matrix to a slot (events carry row and column).
layer_bind_matrix :: proc(l: ^Layer, slot: string, m: ^Matrix) {
	append(&l.slots, Slot{name = slot, grid = m})
	if l.active do for c in m.controls do own(l, slot, c)
}

// The control in a slot (the first, for a matrix: use `layer_matrix`), or nil.
layer_control :: proc(l: ^Layer, slot: string) -> ^Control {
	for s in l.slots do if s.name == slot do return s.control if s.control != nil else (s.grid.controls[0] if s.grid != nil && len(s.grid.controls) > 0 else nil)
	return nil
}

// The matrix in a slot, or nil.
layer_matrix :: proc(l: ^Layer, slot: string) -> ^Matrix {
	for s in l.slots do if s.name == slot do return s.grid
	return nil
}

// Whether a component has a control now (its layer is the control's owner).
owns :: proc(comp: ^Component, c: ^Control) -> bool {
	o := top_owner(c)
	return o != nil && o.layer == comp.layer
}

// Activates a component: its layer takes its controls, then its children.
component_activate :: proc(c: ^Component) {
	if c.active do return
	c.active = true
	layer_activate(c.layer)
	if c.on_activate != nil do c.on_activate(c)
	for ch in c.children do component_activate(ch)
}

// Deactivates a component: its children, then its tasks are cancelled
// and its layer gives its controls back.
component_deactivate :: proc(c: ^Component) {
	if !c.active do return
	#reverse for ch in c.children do component_deactivate(ch)
	if c.on_deactivate != nil do c.on_deactivate(c)
	tasks_cancel_owner(c.cs, c)
	layer_deactivate(c.layer)
	c.active = false
}

// Adds a child, activated and deactivated with the component.
component_add :: proc(parent, child: ^Component) {
	append(&parent.children, child)
	if parent.active do component_activate(child)
}

@(private)
layer_activate :: proc(l: ^Layer) {
	if l.active do return
	l.active = true
	for s in l.slots {
		if s.control != nil do own(l, s.name, s.control)
		if s.grid != nil do for c in s.grid.controls do own(l, s.name, c)
	}
}

@(private)
layer_deactivate :: proc(l: ^Layer) {
	if !l.active do return
	l.active = false
	for s in l.slots {
		if s.control != nil do disown(l, s.control)
		if s.grid != nil do for c in s.grid.controls do disown(l, c)
	}
}

@(private)
top_owner :: proc(c: ^Control) -> ^Ownership {
	best: ^Ownership
	for &o in c.owners {
		if best == nil || o.layer.priority > best.layer.priority || (o.layer.priority == best.layer.priority && o.sequence > best.sequence) do best = &o
	}
	return best
}

@(private)
own :: proc(l: ^Layer, slot: string, c: ^Control) {
	before := top_owner(c)
	before_layer := before.layer if before != nil else nil
	c.cs.sequence += 1
	append(&c.owners, Ownership{layer = l, slot = slot, sequence = c.cs.sequence})
	owner_changed(c, before_layer)
}

@(private)
disown :: proc(l: ^Layer, c: ^Control) {
	before := top_owner(c)
	before_layer := before.layer if before != nil else nil
	for o, i in c.owners do if o.layer == l { ordered_remove(&c.owners, i); break }
	owner_changed(c, before_layer)
}

@(private)
owner_changed :: proc(c: ^Control, before: ^Layer) {
	now := top_owner(c)
	now_layer := now.layer if now != nil else nil
	if now_layer == before do return
	c.route = .Claim
	c.remap_note = 0
	c.remap_channel = 0
	c.velocity_map = nil
	c.cs.rules_dirty = true
	if now == nil {
		light_off(c)
		return
	}
	comp := now_layer.component
	if comp.on_owned != nil do comp.on_owned(comp, now.slot, c)
}

// Sets where a control's messages go while its owner has it (the claim
// table follows). Call it in `on_owned`.
set_route :: proc(c: ^Control, mode: Route_Mode, note: u8 = 0, channel: u8 = 0, velocity_map: ^[128]u8 = nil) {
	if c.route == mode && c.remap_note == note && c.remap_channel == channel && c.velocity_map == velocity_map do return
	c.route = mode
	c.remap_note = note
	c.remap_channel = channel
	c.velocity_map = velocity_map
	c.cs.rules_dirty = true
}
