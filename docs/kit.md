# The Odin kit

The `surface` package is a framework for writing a surface in Odin. It is
compiled into the surface's own library and speaks to the host only
through the protocol ([protocol.md](protocol.md)), so a host never depends
on the kit's version. [`examples/grid_odin`](../examples/grid_odin/grid.odin)
uses most of it, and [`tests/kit`](../tests/kit) tests it all.

## A surface

A surface is a `Spec` and a `setup` procedure:

```odin
import abi "fire-surface/abi"
import kit "fire-surface/surface"

spec := kit.Spec{
	id = "com.example.grid", name = "Grid", vendor = "Example", version = "1.0",
	ports    = {{role = "main", inputs = {"Grid*"}, outputs = {"Grid*"}}},
	identity = &identity,                   // or nil: by port names
	hello    = {{0xF0, 0x00, 0x20, 0x29, 0x01, 0xF7}},
	goodbye  = {{0xF0, 0x00, 0x20, 0x29, 0x00, 0xF7}},
	setup    = setup,
}
library := kit.Library{specs = {&spec}}

@(export, link_name = abi.ENTRY_SYMBOL)
fsurf_entry := abi.Entry{
	fsurf_version = abi.VERSION,
	init        = proc "c" (path: cstring) -> bool { return kit.library_init(&library) },
	deinit      = proc "c" () { kit.library_deinit(&library) },
	get_factory = proc "c" (id: cstring) -> rawptr { return kit.library_factory(&library, id) },
}
```

`odin build . -build-mode:dll -out:Grid.fsurf` makes the library; one
library can hold several specs. The same entry works linked into an app
(`host.library_static(&fsurf_entry)`) or a test. To link several surfaces
into one app, export the symbol only in a .fsurf build, as the examples do:

```odin
ENTRY_NAME :: abi.ENTRY_SYMBOL when ODIN_BUILD_MODE == .Dynamic else "grid_entry"
@(export = ODIN_BUILD_MODE == .Dynamic, link_name = ENTRY_NAME)
fsurf_entry := abi.Entry{...}
```

`setup` builds the surface's controls, components and modes. The spec's
other procedures (`on_activate`, `on_deactivate`, `on_idle`, `on_midi`
for raw messages, `identify`, `save` and `load` for project state,
`on_destroy`) are optional. `cs.user` holds the surface's own state.

What the kit does for it:
- Builds the descriptor.
- Sends the hello on activate. On deactivate it turns every light off,
  then sends the goodbye.
- Sends every light again after the device reconnects.
- Gives each message to its control.
- Works out the claim table from who owns what, and sends it only when
  it changes.
- Runs tasks on one host timer.
- Frees its temporary memory after each call from the host (use
  `context.temp_allocator` freely).

## Controls

A control is one piece of hardware: its binding (`bind_note`, `bind_cc`,
`bind_cc14`, `bind_pitch_bend`, `bind_channel_pressure`, `bind_program`,
`bind_sysex`, each with a channel and a port), how it decodes what it
sends, and how it shows a value back.

| Made with | Events |
|---|---|
| `button` (momentary, or `toggle`) | `Press`, `Release`, `Hold` (after `hold_ms`), `Double_Press` (within `double_ms`) |
| `pad` | `Press` with velocity, `Release`, `Pressure` |
| `encoder`, `touch_encoder`, `jog_wheel` | `Delta` (relative: two's complement, signed bit, binary offset; `acceleration`) or `Value` (absolute); `Touch`, `Untouch` |
| `fader`, `touch_strip`, `pitch_wheel`, `mod_wheel`, `pedal` | `Value` (7 or 14 bits); with `pickup`, only once it reaches `set_value`'s value |
| `sysex_control` | `Sysex` (the longest matching prefix wins) |
| `matrix_make` | a grid of pads or buttons: events carry `row` and `col` |

Feedback:
- `light(c, "Transport.Play.On")` sends a value from the skin.
- `light_value(c, v, channel)` sends a raw value. Many devices blink or
  pulse on other channels.
- `set_position(c, v)` drives a fader motor or an encoder ring, at
  14 bits where the binding has them.
- `light_off(c)` turns it off.

Nothing is sent again while it is unchanged.

## Components and layers

A component groups controls and the logic that gives them meaning. It owns
its controls through its **layer**: named slots bound to controls (or to
a whole matrix), with a priority.

```odin
t := kit.component_make(cs, "Transport")
kit.layer_bind(t.layer, "play", play_button)
t.on_event = proc(c: ^kit.Component, e: kit.Event) { if e.slot == "play" && e.kind == .Press { ... } }
t.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) { kit.light(control, "Transport.Play.Off") }
kit.surface_add(cs, t)   // active while the surface is
```

- **Owner stacks**: each control keeps the layers that want it. Of the
  active ones, the highest priority has it; of equal priority, the one
  activated last. When that layer goes, the control returns to the next
  one down, whose component redraws it (`on_owned`). A control nobody
  owns is dark, and its messages are still the surface's (a button
  doesn't play a note), unless the spec sets `pass_unowned`.
- **Releases** go to whoever got the press, even if the owner changed in
  between.
- **Children** (`component_add`) are activated and deactivated with their
  parent. Deactivating a component cancels its tasks.

## Routing: the claim table from owners

An owned control's messages are claimed by default. The owner can change
that in `on_owned` with `set_route(c, mode, ...)`:

| Mode | Its messages |
|---|---|
| `Claim` | to the surface only |
| `Observe` | to the host and the surface |
| `Remap` | to the host as another note or channel, through a velocity map, with no added latency; a copy to the surface (to light the pad) |
| `Pass` | to the host only |

The kit turns this into the claim table:
- Neighbouring controls routed the same way share one rule with a range.
- Remapped controls share one rule and its note map.
- The table is sent again only when it changes.

A note held across a mode change ends where it began; the host's router
sees to that.

## Modes

```odin
m := kit.modes_make(cs, "Pads")
kit.modes_add(m, "drum", {drums}, drum_button, .Hybrid)
kit.modes_add(m, "keys", {keyboard, octave}, keys_button, .Hybrid)
kit.modes_cycle_button(m, next_button)   // optional
m.on_change = proc(m: ^kit.Modes, from, to: int) { kit.notify(m.cs, kit.modes_current(m)) }
```

One mode is active at a time; selecting one deactivates the components the
new one lacks and activates its own. Behaviours for a mode's button:

| Behaviour | |
|---|---|
| `Latching` | a press selects it |
| `Momentary` | selected while held |
| `Toggle` | pressed again, back to the mode before |
| `Hybrid` | momentary if held (`hybrid_ms`, 300), latching if tapped |

A surface can have several Modes components, and a mode can hold another
Modes component, which remembers its own mode. Mode buttons light with
`"<name>.Mode.On"`/`".Off"`, or `"Mode.On"`/`"Mode.Off"`.

## Built-in components

- `modifier_make`: Shift, Select, Delete. While its button is held, its
  components are active: an overlay, when their layers' priority is
  higher.
- `drum_pads_make`: a matrix as drum pads, from a base note, along each
  row from the bottom left. They are remapped, and lit `"Drum.Pad"`, or
  `"Drum.Hit"` while played. `drum_pads_set_base` pages through banks.
- `keyboard_make`: a matrix as a keyboard, either in key (each pad a
  degree of the scale, each row up a fourth) or chromatic. Pads are lit
  `"Keyboard.Root"`, `".In_Scale"` or `".Out_Of_Scale"`, and every pad of
  a note being played lights `".Playing"`. `keyboard_set` changes the
  scale, root, octave or layout.

Components on the host's DAW (Transport, Mixer, Device, Launcher,
Navigation, App, Note_Repeat, and a Keyboard in the host's scale) use the
`fsurf.daw` extension: see [daw.md](daw.md).

## Skins

A skin maps names to what a control is sent: a value (a velocity or a
palette index), on its own channel or another, or a SysEx instead (RGB).
That keeps raw MIDI values out of the logic.

```odin
skin := kit.skin_make()
kit.skin_set(skin, "Transport.Play.On", 21)
kit.skin_set(skin, "Session.Clip.Playing", 21, channel = 2)   // pulsing, on this device
kit.set_skin(cs, skin)   // the surface's; free it in on_destroy
```

A name the skin lacks is 127 if it ends in `.On`, else 0.

## Tasks

The kit's tasks run on one host timer:
- `task_after(cs, ms, fn, data, owner)` runs once.
- `task_every(cs, ms, fn, data, owner)` repeats.
- `task_cancel(cs, id)` stops one.
- `send_sequence(cs, messages, gap_ms)` sends messages spaced apart, for
  a device whose hello needs time between messages.
- `blink(c, on, off, ms, owner)` blinks a control.

A task with an owner ends when its owner is deactivated, and every task
ends when the surface is.

## Helpers

- **MIDI:**
  - `parse` reads a message.
  - Builders: `note_on`, `control_change`, `pitch_bend` and the rest.
  - `Parser` handles running status, real-time bytes and SysEx in
    pieces.
  - 14 bits: `join14`, `split14`.
  - `rpn` and `nrpn`, read back with `Parameter_Reader`.
  - SysEx: `sysex`, `pack7`/`unpack7`, `nibbles`, `roland_checksum`,
    `has_prefix`.
- **Music:**
  - `midi_note_to_freq` and `freq_to_midi_note`.
  - `note_name` and `note_number`, with middle C as C3 or C4.
  - `SCALES` (modes, pentatonics, blues...) with `scale_named`,
    `scale_note` and `in_scale`; `CHORDS`.
  - Velocity curves: `velocity_curve` (a map for remapped pads) and
    `velocity_fixed`.
  - Tempo: `beat_ms`, `clock_tick_ms`, and `Tap_Tempo` with `tap`.
- **Colour:**
  - Conversions: `hsv_to_rgb`, `rgb_to_hsv`, `hsl_to_rgb`, `rgb_to_hsl`.
  - `brightness` and `scale_brightness`.
  - `rgb7` for SysEx.
  - `nearest_in_palette`, for a device's palette.

## Testing a surface

The `testing` package is a headless host for a surface's tests:

```odin
import fst "fire-surface/testing"

@(test)
play_lights :: proc(t: ^testing.T) {
	th: fst.Test_Host
	fst.start(&th, &my_surface.fsurf_entry, "com.example.grid")   // made and activated
	defer fst.stop(&th)
	r := fst.midi_in(&th, {0xB0, 85, 127})   // through the claim table, as a host would
	testing.expect(t, r.surface && r.host == nil)
	testing.expect(t, fst.sent_has(&th, {0xB0, 85, 127}))
	fst.advance(&th, 500)                     // time, by hand: holds, tasks
	testing.expect(t, fst.reconnect(&th))     // unplugged and back
}
```

It also offers:
- `add_extension`, to fake a host's extensions.
- `notified` and `last_notified`, for what the surface told the user.
- `project_save` and `project_load`.
- `kit_surface(&th)`, for the surface's own state.
