# fire-surface: design

A protocol and an SDK for **control surfaces**: hardware controllers
(MIDI first, also pixel displays over USB and HID) programmed by anyone,
built into a dynamic library, and loaded at runtime by any software that
hosts the protocol. Ableton's MIDI Remote Scripts and FL Studio's MIDI
scripting are the inspiration; CLAP is the model for how it is
packaged, versioned and adopted.

Status: stages 1 to 4 built (2026-11-15): see [protocol.md](protocol.md), [kit.md](kit.md) and [daw.md](daw.md). The rest is the plan.

## Goals

1. **An open protocol.** Anyone can write a surface for their controller,
   or for hardware they build, and it works in any host that implements
   fire-surface. Pads (Fire Engine) is the first host, not the only one.
2. **Dynamic libraries, found at runtime.** A surface is a `.fsurf` file
   (a dynamic library with another extension, as a `.clap` is). Hosts
   scan for them, so new hardware needs no new host release.
3. **Host APIs as extensions.** A surface gets what it controls from the
   host through named, versioned extensions: a standard one any DAW-like
   host can offer (`fsurf.daw`), and the host's own (`fire.pads`: the
   Pads API).
4. **Host-neutral.** No dependency on Pads or Fire Engine. MIT.
5. **More than MIDI.** Devices like Push 2/3 or MPC Studio Mk2 are MIDI
   devices with screens driven over other channels. Version 1 has MIDI,
   SysEx and a display kit (framebuffers sent over USB bulk or HID).
6. **Interception.** MIDI from the controller is offered to the surface
   first. What the surface claims doesn't reach the host's normal MIDI
   handling. What it doesn't claim goes on as if no surface were there,
   with no added latency.
7. **Building blocks.** ControlSurface, Controls, Components, Layers and
   Modes, with built-in ones for common hardware and common jobs, all
   made from primitives a surface author can use to build their own.
8. **Plug in and play.** The host recognizes a controller from its port
   names and its SysEx identity reply, and starts the right surface.

## Not in version 1

- MIDI 2.0 / UMP (the message type field leaves room for it).
- Serial and network transports (the transport layer leaves room).
- Surfaces running in a separate process, to survive their crashes.
- Signing or a catalogue of surfaces.

## Layers of the design

```
  surface author's code (Odin)                       any language
  ┌───────────────────────────────────────┐        ┌──────────────┐
  │ Odin kit: ControlSurface, Controls,   │        │  C, C++,     │
  │ Components, Layers, Modes, Skins,     │        │  Rust, Zig   │
  │ Tasks, MIDI/music/colour helpers,     │        │  (raw ABI)   │
  │ draw kit, declarative spec            │        │              │
  └──────────────────┬────────────────────┘        └──────┬───────┘
                     │   fsurf.h: the C ABI (the protocol)│
  ═══════════════════╪════════════════════════════════════╪════════
                     │                                    │
  ┌──────────────────┴────────────────────────────────────┴───────┐
  │ host: scan, detect, lifecycle, claim table on the MIDI path,  │
  │ MIDI/USB/HID I/O, timers, saved state, extensions             │
  │   fsurf.daw (standard)      fire.pads (Pads' own API)         │
  └───────────────────────────────────────────────────────────────┘
```

- **The protocol** is a versioned C header, `include/fsurf.h`: plain
  structs of function pointers, sizes and versions, no allocator or
  string shared across the boundary. Hosts implement only this. A
  surface written straight against it in C works.
- **The Odin kit** (`surface` package) is a framework compiled into the
  surface's own library. It speaks to the host only through the header,
  so a host never depends on the kit's version.
- **The host library** (`host` package, Odin) is an optional,
  reusable implementation of the host side: scanning, detection, the
  claim table, lifecycle. Fire Engine's `fire:surface` becomes a thin
  layer on it. Other hosts can use it, or implement the header
  themselves.

## The protocol

### The library and its descriptors

A `.fsurf` exports one symbol, `fsurf_entry`, a struct with the ABI
version, `init(host_info)`, `deinit()` and `get_factory(id)`, as CLAP
does. Scanning reads the descriptors and runs no surface code beyond
`init`. Each descriptor:

- `id` (reverse-DNS, `com.example.mk2`), name, vendor, version, URL.
- **Ports**: the MIDI ports it uses, by role (`main`, `user`, `display`),
  each with port-name patterns per OS (CoreMIDI, WinMM/WinRT, ALSA names
  differ), input and output paired.
- **Identification**: the identity request to send (the universal
  `F0 7E 7F 06 01 F7` by default, or a custom message), what the reply
  must match (manufacturer, family, model, with masks), how often to
  retry, and a delay. Or none: matched by port names alone.
- **Devices** other than MIDI: USB (vendor and product id, interface,
  endpoint) or HID (vendor, product, usage page), for displays.
- **Displays**: width, height, pixel format, frame rate, and the channel
  each goes over (SysEx text, USB bulk, HID).
- Flags: needs `fsurf.daw`, or names other extensions it needs or can use.

### Finding and starting a controller

1. A MIDI port appears (at start, or plugged in). The host matches its
   name against every descriptor's patterns, and pairs the input and
   output of one device.
2. For each candidate it opens the ports and sends the identity request.
   A reply that matches selects the surface. With several matches the
   most specific wins (model over family over name).
3. Two of the same controller get an instance each (`device_index`).
4. The user can also assign a surface to ports by hand (Settings), turn
   auto-detection off for a surface, or pick between candidates.
5. A port that goes away deactivates its surface; when it comes back,
   the same instance is identified and activated again.

### Lifecycle

| Call | When | A surface does |
|---|---|---|
| `create(host)` | the library's surface is chosen | allocates, reads its saved state, builds its controls and components |
| `activate(ports)` | its device is identified and its ports open | sends hello messages, publishes its claim table, lights its LEDs |
| `deactivate()` | its device is gone, the user turns it off, or the host quits | sends goodbye messages (LEDs off, the device's own mode) |
| `destroy()` | unloaded | frees everything |

Identification can run in the surface instead (for devices whose
handshake is more than one request and reply): a flag in the descriptor
hands it the ports first, and it calls `host.identified(ok)`.

### Threads

Every call into a surface happens on one thread, the host's **surface
thread** (its control or UI thread). No surface code ever runs on the
audio thread or a MIDI driver's thread. The claim table is what lets the
host decide, without the surface, where each message goes.

### MIDI in: the claim table

The surface publishes a table of rules; the host applies it to each
incoming message on its MIDI path (in Pads, before the engine's audio
thread sees it), so a decision costs a table lookup, not a round trip to
the surface's thread:

| Rule | The message | Use |
|---|---|---|
| `claim` | goes to the surface only (queued, timestamped, to its thread) | buttons, encoders, a pad grid in a session mode |
| `pass` (the default) | goes to the host as usual, untouched | a keyboard's keys |
| `observe` | goes to both | lighting a pad when it is played |
| `remap` | goes to the host changed (note or CC number, channel, velocity curve, note to a scale or drum layout) | a pad grid as drum pads or a scale keyboard, with no latency |
| `drop` | goes nowhere | noise from a controller |

A rule matches by port, message type, channel and a range of data byte 1
(notes or CC numbers). SysEx is matched by its leading bytes. A surface
replaces the whole table at once (a new version swaps in atomically);
messages already on their way are judged by the table they met. In the
Odin kit the table is never written by hand: it is worked out from
which controls the active layers own, and what each control does with
its messages (a pad matrix in drum mode remaps, in session mode
claims).

A claimed message can't be passed on afterwards without latency. A
surface that wants to decide in code can claim a message and re-send it
to the host itself (`host.inject_midi`), with control-thread latency;
the docs say so.

Later (not version 1): a `map` rule mapping a CC straight to a host
parameter, applied on the audio thread, as Live's direct mappings are.

### MIDI out

`host.send_midi(port, bytes)`, any length (SysEx included). The kit keeps
the last value sent for each LED and sends only changes, and resends
everything after the device reconnects. The host may pace large SysEx.

### Other host services

- **Timers**: `host.timer(ms)` → `on_timer(id)`; and `on_idle` each host
  frame. The kit's tasks (delays, sequences, blinking, hold and
  double-press timing) run on these.
- **Saved state**: a blob per surface instance kept by the host
  (settings: a chosen mode, a velocity curve), and a blob per project
  (`save`/`load` when the project is).
- **Messages**: `host.log(level, text)`; `host.notify(text)` shows a
  short message in the host's UI ("Mixer", "Bank 2").
- **USB and HID**: the host opens the devices a descriptor names and
  gives the surface `host.device_write(device, bytes)` and
  `on_device_read`. The host owns libusb/hidapi, so every surface doesn't
  bundle its own.
- **Displays**: `on_display_frame(display)` at the descriptor's rate; the
  surface draws and sends the frame over its channel. The host can mirror
  a display (the virtual controller).
- **Extensions**: `host.get_extension(name, version)` returns a function
  table or null; a surface can offer its own back to the host
  (`fsurf.layout`: its controls' positions and shapes, for the virtual
  controller and the MIDI monitor).

### Versions

Every struct begins with its size and version, so a newer host loads an
older surface and the reverse, as CLAP does. Extensions version
separately (`fsurf.daw` 1, 2; `fire.pads` 1).

### Crashes

A surface runs in the host's process: a crash takes the host down, as a
plug-in's does. The host marks a library while it starts a surface and
skips a library that didn't finish, the next time, asking the user.

## The standard extension: `fsurf.daw`

What most controllers need, so a surface written against it alone works
in any host that offers it. Each part is optional; a host says which it
has.

- **Transport**: play, stop, record, loop, metronome, tempo, position,
  tap tempo, nudge; changes pushed to the surface.
- **Tracks**: count, name, colour, selected, mute, solo, arm, volume,
  pan, sends, meters; a **ring** (a window of N tracks the surface pages
  through, Live's red box) owned by the host, so a host can draw it.
- **Devices**: the selected track's devices; the selected device's
  parameters in banks of 8 (names, values as text and normalized,
  automation state); nudging by relative steps.
- **Launcher**: a grid of clips and scenes (launch, stop, state, colour)
  for hosts that have one.
- **Notes**: the host's current scale and root, to light a grid.
- **Undo, redo, save**; the host's views (show the mixer).

Values cross the boundary as numbers and short UTF-8 strings the host
owns until the next call. Changes arrive as `on_daw_event` on the
surface thread for the topics a surface subscribes to.

## Pads' extension: `fire.pads`

The Pads API as it is (`pads_api.h`, `get_extension("fire.pads", 1)`), so
a surface for Pads reaches everything Pads does: pads, sequences, the
song, Perform, the mixer, effects. A surface may use both: `fsurf.daw`
for the transport and mixer, `fire.pads` for pads and sequences.

## The Odin kit

### ControlSurface

A surface is a struct embedding `surface.Control_Surface`, made from a
**spec** (the declarative part, like Live's
`ControlSurfaceSpecification`): its controls, identity, hello and
goodbye messages, skin, which components and modes exist. Its own
procedures override `init`, `activate`, `deactivate`, `deinit`. The kit
writes the `fsurf_entry` export for it.

### Controls

A control is one piece of hardware: its MIDI binding (port, type,
channel, number), how it decodes what it sends, how it shows a value
back (LED, colour, ring), and its hooks. Active or not; only active,
owned controls claim messages.

Built in:

- `Button` (momentary or toggle; press, release, hold after N ms,
  double press; LED on/off or colour through the skin).
- `Pad` (velocity, polyphonic or channel aftertouch, colour).
- `Matrix` (a grid of buttons or pads, addressed by row and column).
- `Encoder` (absolute, or relative: two's complement, signed bit,
  binary offset; acceleration; LED ring).
- `Touch_Encoder` (an encoder and the touch note that comes with it).
- `Fader` / `Slider` (7- or 14-bit, pickup or soft takeover).
- `Touch_Strip` (position, touch, its LEDs).
- `Jog_Wheel`, `Pedal`, `Pitch_Bend`, `Mod_Wheel`.
- `Sysex_Control` (a message by its leading bytes).
- `Display` (text by SysEx, or a pixel framebuffer).

A custom control is a struct with a decode and an encode procedure, or a
composition of others (a button with a touch sensor).

### Components and layers

A component is a group of controls and the logic that gives them
meaning (Transport: Play, Stop and Record buttons calling
`daw.transport.play`). Activating a component activates its controls;
deactivating it frees them.

A component doesn't own controls directly; it gets them through a
**layer**: named slots (`play_button`) bound to controls, with a
priority. A control has a stack of owners; the highest-priority active
layer has it, and when that layer goes, the control returns to the next
one down, its LEDs redrawn by that owner. Shift overlays, modes and
momentary views all work this way, and the claim table follows the
owners.

Built in: `Transport`, `Mixer` and `Channel_Strip`, `Ring` (paging
tracks), `Device` (parameter banks), `Launcher` (clip grid and scenes),
`Drum_Pads` and `Keyboard` (a grid remapped to notes, a scale or a drum
layout, claim-table `remap`), `Navigation`, `Undo`, `Modifier` (Shift,
Select, Delete held), `Note_Repeat`, and for Pads: `Pads_Grid`,
`Sequence`, `Perform`.

### Modes

A `Modes` component holds named modes, each a list of components and
layers to activate together; one mode is active at a time, and a surface
can have several Modes components (a main mode and an encoder mode).
Modes have **behaviours** for their buttons: latching, momentary while
held, toggle back to the previous mode, cycle, and "momentary if held,
latching if tapped". A mode button's LED shows whether its mode is on.
Modes can nest (a mode holding another Modes component).

### Skins and colour

A skin maps names (`Transport.Play.On`, `Session.Clip.Playing`) to what a
control is sent (a velocity, a palette index, RGB SysEx, blink or pulse
codes), so the logic never holds raw MIDI values. Colour helpers: RGB,
HSV and HSL conversions, brightness, the nearest index in a device's
palette (palettes for common devices included), a host track's colour to
the device's palette.

### MIDI and music helpers

Message builders and parsers; running status; 14-bit CC, RPN and NRPN;
SysEx builders (manufacturer ids, 7-bit packing, nibbles, checksums);
note names and numbers; `midi_note_to_freq`, `freq_to_midi_note`;
scales, modes and chords; velocity curves; tempo and tap-tempo maths.

### Tasks

Delays, sequences and repeating tasks on the host's timers (hello
sequences, blinking, holding a button to scroll faster), cancelled with
their component.

### The draw kit

Framebuffers in a device's pixel format (RGB565, Push 2's BGR565 with
its XOR mask, 1-bit OLED), shapes, lines, bitmap and anti-aliased fonts
(one bundled), images, and widgets: meters, knob arcs, parameter labels,
waveforms (from host data), dirty-region tracking so a frame sends only
what changed when the device allows it.

## Developer tools (version 1)

- **Test host** (`surface/testing`): a headless host in a test: feed
  MIDI in, read the MIDI sent, the claim table, the extension calls made
  (a fake `fsurf.daw`), the frames drawn; time stepped by hand.
- **Hot reload**: the host copies a library before loading it, watches
  the original, and on a rebuild deactivates the surface, saves its
  state, loads the new copy and activates it with that state.
- **MIDI monitor**: a host panel (in Pads) showing each message in and
  out, which rule took it, which control and component, and what the
  surface sent back.
- **Virtual controller**: from a surface's `fsurf.layout`, an on-screen
  stand-in for the hardware: its controls drawn where they are on the
  device, its LEDs and displays mirrored, usable with the mouse.

## In Fire Engine and Pads

- fire-surface comes in as a git submodule; `fire:surface` (ABI 2, the
  flat controls and fixed transport) is replaced by a host built on
  the `host` package, and `examples/pads_surface/pads_mini.c` is ported.
- Pads' MIDI path applies the claim table before the engine; controller
  ports are found and paired by the descriptors.
- Pads offers `fsurf.daw` (from the Pads API) and `fire.pads`.
- Settings → Control Surfaces: detected devices, which surface each has,
  assigning by hand, auto-detection on or off, the MIDI monitor and the
  virtual controller.
- libusb (LGPL-2.1) and hidapi (BSD) for displays: fine in Pads (GPL);
  the host library takes them as optional, so an MIT host can leave them
  out or link them dynamically.

## Stages

Each is built, tested (the test host, and Pads' tests where it reaches
Pads), documented, and pushed.

1. **The protocol** (built): `fsurf.h`, its Odin declarations (`abi`),
   the entry and factory, descriptors (ports and identity; devices and
   displays come with stage 6), lifecycle, MIDI out, timers, settings
   and project state, log and notify; the host library (`host`):
   scanning and loading; surfaces in C and Odin, and tests that run
   them and check the Odin layout against the header's.
2. **Detection and the claim table** (built): port matching and pairing,
   identity request and reply, the surface's own handshake, the most
   specific surface picked, hot plug, assigning by hand; the claim table
   and its rules (`set_rules`, `inject_midi`; protocol 0.2) applied by
   the host library's `route`, lock-free, notes following their note on;
   surfaces linked in (`library_static`). Wiring `route` into Pads' MIDI
   path moved to stage 7, with the rest of Pads' side.
3. **The kit's core** (built): Control_Surface and the spec, controls,
   layers and owner stacks, components, modes and behaviours, skins,
   tasks, the claim table worked out from owners; the MIDI, music and
   colour helpers; the test host (`testing`); the built-ins that need no
   host extension (Modes, Modifier, Drum_Pads, Keyboard) and an example
   (`grid_odin`). Device palettes wait for the devices that need them
   (see the questions below); Note_Repeat comes with `fsurf.daw`'s
   transport.
4. **`fsurf.daw`** (built): the extension's header (`fsurf_daw.h`: ids
   read and set, actions, the ring, events by topic) and the kit's
   wrappers; built-in components on it (Transport, Mixer and channel
   strips, Device, Launcher, Navigation, App, Note_Repeat, a Keyboard in
   the host's scale); a fake DAW in the test host; examples: a keyboard
   with transport, faders and knobs (`keys_odin`, any host with the
   extension) and the grid with session, drum and keyboard modes
   (`grid_odin`). Pads offering it from the Pads API moved to stage 7,
   with the rest of Pads' side.
5. **Tools**: hot reload, the MIDI monitor, the virtual controller
   (`fsurf.layout`).
6. **Displays**: the draw kit, USB bulk and HID through the host, frame
   pacing, mirrored in the virtual controller; an example display
   surface.
7. **Pads moves over**: `fire:surface` replaced, `route` on Pads' MIDI
   path before the engine, controller ports found by `host_set_ports`,
   `fsurf.daw` offered from the Pads API, `pads_mini` ported,
   `fire.pads` components, Settings → Control Surfaces, the guides.

## Questions for later

- Windows: WinMM MIDI ports are exclusive to one process, so a
  controller Pads holds can't be shared with other software at the same
  time (Windows MIDI Services lifts this).
- Windows USB bulk needs the WinUSB driver bound to the display
  interface (Push 2 ships one); macOS HID may need the Input Monitoring
  permission; Linux needs udev rules for USB and HID access.
- Which device palettes and display formats to include first.
- Whether `fsurf.daw` also covers arrangement views (markers, a
  timeline) or leaves them to hosts' own extensions.
