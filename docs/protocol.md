# The protocol (version 0.2)

What a `.fsurf` library and its host agree on. The authority is the
header, [`include/fsurf.h`](../include/fsurf.h); the Odin package
[`abi`](../abi/abi.odin) declares the same things for Odin, and a test
checks the two have the same layout. This page is the tour.

Version 0.2 is stages 1 and 2 of [the design](design.md): loading, the
lifecycle, MIDI out, timers, settings and project state, extensions,
detection and the claim table. The kit, `fsurf.daw` and displays come in
later stages. (0.2 added `set_rules` and `inject_midi` to the host; a 0.1
library doesn't load in a 0.2 host, as before 1.0 minor versions differ.)

## A library

A `.fsurf` is a dynamic library (`.dylib`, `.so` or `.dll` underneath,
renamed) exporting one symbol: `fsurf_entry`, an `fsurf_entry_t`.

```c
FSURF_EXPORT const fsurf_entry_t fsurf_entry = {
	.fsurf_version = FSURF_VERSION_INIT,
	.init = entry_init,         /* once, after loading */
	.deinit = entry_deinit,     /* once, before unloading */
	.get_factory = entry_factory,
};
```

`get_factory(FSURF_SURFACE_FACTORY_ID)` returns its surface factory:
`count`, `get_descriptor(i)`, and `create(host, id)`. A descriptor
describes one controller model: its id (reverse-DNS, stable), name,
vendor, version, its MIDI ports by role (with name patterns per system),
how it is identified (port names, an identity request and the reply's
bytes, or the surface's own handshake), and the host extensions it
requires.

Scanning loads a library, calls `init`, reads the descriptors, calls
`deinit` and unloads it. No surface is made.

## A surface's life

```
create(host, id) → init → [identify] → activate(ports) ⇄ deactivate → destroy
```

- `init` builds what the surface needs; false and the host destroys it.
- `identify` (only with `FSURF_IDENTIFY_SURFACE`): the surface talks to
  the device itself and answers with `host->identified(ok)`.
- `activate(ports)`: its device is there. `ports` follows the
  descriptor's port specs, each with an input id (what `on_midi` gives)
  and an output id (what `send_midi` takes).
- While active: `on_midi`, `on_timer`, `on_idle`.
- `deactivate`: the device went away, the user turned it off, or the host
  is quitting. It can be activated again.
- `destroy`: deactivated first if it was active.

## What a surface can ask of its host

| Function | |
|---|---|
| `get_extension(id, version)` | an extension's function table (`fsurf.daw`, `fire.pads`), or NULL |
| `log(level, message)` | a line in the host's log |
| `notify(text)` | a short message for the user |
| `send_midi(port, bytes, size)` | MIDI to the device, on one of its own output ports |
| `timer_start(ms)`, `timer_stop(id)` | a repeating timer: `on_timer(id)` |
| `now_ns()` | the host's clock (`on_midi`'s times) |
| `settings_get`, `settings_set` | a blob the host keeps for this device between runs |
| `identified(ok)` | the answer to `identify` |
| `set_rules(rules, count)` | its claim table: where MIDI from its device goes |
| `inject_midi(port, bytes, size)` | hands a message it claimed on to the host |

A project's part comes through `project_save(stream)` and
`project_load(stream)`.

## Rules

- **One thread.** The host calls a surface, its factory and its entry on
  one thread (its surface thread, usually its UI thread), never an audio
  or MIDI driver thread. The surface calls the host back on that thread,
  during its own calls.
- **Ownership.** Whatever a call is given belongs to the caller and is
  valid until it returns. Descriptors belong to the library and are valid
  until its `deinit`. A host's extension tables are valid while the
  surface lives.
- **Sizes and versions.** Shared structs start with `struct_size`, so a
  later minor version can add fields at the end. Before 1.0 a host loads
  libraries of its own major and minor version only
  (`fsurf_version_is_compatible`); from 1.0, of its major version.

## The claim table

MIDI from a surface's device never waits for the surface. The surface
publishes rules (`set_rules`, usually in `activate`, and again when its
mode changes); the host applies them to each message as it arrives, on
its MIDI path, before its own MIDI handling sees it. The first rule that
matches decides; a message no rule matches goes to the host untouched.

| Action | The message goes |
|---|---|
| `FSURF_RULE_PASS` | to the host, untouched |
| `FSURF_RULE_CLAIM` | to the surface only |
| `FSURF_RULE_OBSERVE` | to both |
| `FSURF_RULE_REMAP` | to the host, changed: data byte 1 through `note_map`, byte 2 through `value_map`, another `channel`; with `FSURF_RULE_FLAG_COPY` the surface gets the original too |
| `FSURF_RULE_DROP` | nowhere |

A rule matches by port (or all the surface's inputs), the kinds of
message (`FSURF_MSG_*`), channels (a bit each), a range of data byte 1
(`first` to `end - 1`: notes, CC or program numbers), and for SysEx its
leading bytes.

```c
static const uint8_t own[] = {0xF0, 0x7D};
static const fsurf_rule_t rules[] = {
	{.port = FSURF_NO_PORT, .messages = FSURF_MSG_NOTES, .first = 36, .end = 52, .action = FSURF_RULE_CLAIM},
	{.port = FSURF_NO_PORT, .messages = FSURF_MSG_SYSEX, .sysex = own, .sysex_size = 2, .action = FSURF_RULE_CLAIM},
};
host->set_rules(host, rules, 2);   /* pads and its own SysEx: the surface's; keys and the rest: the host's */
```

- What the surface gets comes to `on_midi` on its thread, a moment later.
  Only what its rules send it: an active surface with no rules gets
  nothing.
- A note off (or a note on of velocity 0), and a note's polyphonic
  pressure, go where their note on went, even if the rules changed in
  between, so a mode change never leaves a note stuck.
- A surface that wants to decide in code claims a message and hands it on
  with `inject_midi`, later than a rule would (by its thread's latency).

## Finding a controller

1. The host matches the system's MIDI port names against each
   descriptor's patterns, and pairs each input with an output: one of the
   same name if there is one, else the next. The n-th pair of every port
   spec makes the n-th controller of that model (two of the same get a
   surface each); one missing a required pair isn't there.
2. It identifies each candidate by its descriptor's identity:
   - `FSURF_IDENTIFY_NAMES` (or no identity): the names are enough.
   - `FSURF_IDENTIFY_REQUEST`: it sends the request (by default the
     universal `F0 7E 7F 06 01 F7`) on the identity port's output after
     `delay_ms`, and again every `retry_ms` (300) up to `retries` (2)
     times, and matches the reply under the mask.
   - `FSURF_IDENTIFY_SURFACE`: it makes the surface and calls `identify`;
     the surface sees everything from its ports while it identifies, and
     answers with `identified`.
3. When several surfaces fit the same ports, it waits for all of them to
   answer and starts the most specific: a reply matching more bits, then
   a surface's own identification, then names alone. The others are
   passed over.
4. Unplugged, a controller's surface is deactivated and kept; plugged in
   again (ports of the same names), it is identified and activated again.
5. The user can assign a surface to ports by hand (it takes them from any
   found there), or turn detection off for a surface.

## The host library

[`host`](../host) does the host side for Odin hosts:

- `library_load`, `library_unload`, `library_find`; `library_static`
  for a surface linked into the app (its entry, used as a loaded one's)
- `scan(folders)`, `default_folders()` (`FSURF_PATH`, then the user's and
  the system's folders)
- `host_init` with a `Host_Config` (the app's `send_midi`, `inject_midi`,
  `get_extension`, `has_extension`, `log`, `notify`, clock, and for
  detection `on_device` and `device_settings`), `host_update` once a
  frame (MIDI queued for surfaces, timers, identification, `on_idle`)
- detection: `host_add_library`, `host_set_ports` (every time the
  system's ports change), `host_devices`, `host_assign`,
  `host_unassign`, `host_set_auto_detect`; and its parts, `name_matches`,
  `find_matches`, `identity_matches`
- `route(host, port, bytes, time, &out)` on the app's MIDI thread: the
  claim table applied, lock-free and without allocating; what the app's
  own MIDI handling gets, and whether a surface got it
- surfaces by hand: `instance_create`, `instance_activate`,
  `instance_deactivate`, `instance_midi`, `instance_identify`, settings
  and project state, `instance_destroy`

```odin
h: host.Host
host.host_init(&h, {name = "My DAW", send_midi = to_device, inject_midi = to_engine})
host.host_add_library(&h, lib)
host.host_set_ports(&h, inputs, outputs)      // at start, and when ports change

// The MIDI thread, for each message from any input:
out: [3]u8
r := host.route(&h, port, bytes, now_ns, &out)
if len(r.host) > 0 do to_engine(port, r.host)

// The surface thread, once a frame:
host.host_update(&h)
```

| System | Folders (after `FSURF_PATH`) |
|---|---|
| macOS | `~/Library/Audio/Plug-Ins/fsurf`, `/Library/Audio/Plug-Ins/fsurf` |
| Windows | `%LOCALAPPDATA%\Programs\Common\fsurf`, `%COMMONPROGRAMFILES%\fsurf` |
| Linux | `~/.fsurf`, `/usr/lib/fsurf` |

## Examples

- [`examples/hello_c`](../examples/hello_c/hello.c): a surface in C.
- [`examples/hello_odin`](../examples/hello_odin/hello.odin): the same in
  Odin (`odin build examples/hello_odin -build-mode:dll -out:hello.fsurf`).
- [`examples/grid_odin`](../examples/grid_odin/grid.odin) and
  [`examples/keys_odin`](../examples/keys_odin/keys.odin): surfaces made
  with the Odin kit ([kit.md](kit.md)) on the standard extension
  ([daw.md](daw.md)).

```bash
./scripts/build.sh   # the examples and the layout printer, into .build/
./scripts/test.sh    # build, then the tests at -o:none and -o:speed
```
