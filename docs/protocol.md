# The protocol (version 0.1)

What a `.fsurf` library and its host agree on. The authority is the
header, [`include/fsurf.h`](../include/fsurf.h); the Odin package
[`abi`](../abi/abi.odin) declares the same things for Odin, and a test
checks the two have the same layout. This page is the tour.

Version 0.1 is stage 1 of [the design](design.md): loading, the
lifecycle, MIDI out, timers, settings and project state, extensions.
Detection, the claim table, the kit, `fsurf.daw` and displays come in
later stages.

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

## The host library

[`host`](../host) does the host side for Odin hosts:

- `library_load`, `library_unload`, `library_find`
- `scan(folders)`, `default_folders()` (`FSURF_PATH`, then the user's and
  the system's folders)
- `host_init` with a `Host_Config` (the app's `send_midi`,
  `get_extension`, `log`, `notify`, clock), `host_update` once a frame
  (timers, `on_idle`)
- `instance_create`, `instance_activate`, `instance_deactivate`,
  `instance_midi`, `instance_identify`, settings and project state,
  `instance_destroy`

| System | Folders (after `FSURF_PATH`) |
|---|---|
| macOS | `~/Library/Audio/Plug-Ins/fsurf`, `/Library/Audio/Plug-Ins/fsurf` |
| Windows | `%LOCALAPPDATA%\Programs\Common\fsurf`, `%COMMONPROGRAMFILES%\fsurf` |
| Linux | `~/.fsurf`, `/usr/lib/fsurf` |

## Examples

- [`examples/hello_c`](../examples/hello_c/hello.c): a surface in C.
- [`examples/hello_odin`](../examples/hello_odin/hello.odin): the same in
  Odin (`odin build examples/hello_odin -build-mode:dll -out:hello.fsurf`).

```bash
./scripts/build.sh   # the examples and the layout printer, into .build/
./scripts/test.sh    # build, then the tests at -o:none and -o:speed
```
