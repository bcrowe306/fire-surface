# fsurf.daw (version 1)

The standard extension: what most controllers need from a DAW-like host.
A surface written against it works in any host that offers it. The
authority is [`include/fsurf_daw.h`](../include/fsurf_daw.h); the Odin
package [`abi`](../abi/daw.odin) declares the same, and a test checks
their layouts and every id's value.

```c
const fsurf_daw_t *daw = host->get_extension(host, FSURF_DAW_ID, FSURF_DAW_VERSION);
if (daw && (daw->parts & FSURF_DAW_TRANSPORT))
	daw->set(host, FSURF_DAW_PLAYING, 0, 0, 1);
```

A surface that can't work without it lists `"fsurf.daw"` in its
descriptor's `required_extensions`, so a host lacking it doesn't offer the
surface. One that can (a grid's drum pads play anyway) leaves it out and
checks for it.

## Reading and changing the host

Everything goes through ids:

| Function | |
|---|---|
| `get(id, a, b)` | a number |
| `get_text(id, a, b)` | its text: a name, or a value as the host shows it ("-6.0 dB"); valid until the next call |
| `set(id, a, b, value)` | changes it; false if it can't |
| `action(id, a, b)` | does something |
| `set_ring(first_track, tracks, first_scene, scenes)` | the surface's window on the tracks and scenes, so the host can show it |
| `subscribe(topics, listener)` | events for these topics |

`a` and `b` are indices:
- a track (0 = the first; `FSURF_DAW_MASTER` = the master)
- a send
- a scene
- a device
- a parameter

Normalized values (volume, pan, parameters) are 0-1, and pan's centre is
0.5. Colours are 0xRRGGBB.

A host says which parts it has (`parts`). An id it doesn't have reads 0
and NULL, and can't be set.

| Part | Values | Actions |
|---|---|---|
| Transport | playing, recording, loop, metronome, tempo, position (beats), signature | tap tempo |
| Tracks | count, name, colour, the selected one, mute, solo, arm, volume, pan, sends, meters | |
| Devices (the selected track's) | count, name, the selected one, on; the selected device's parameters: count, name, value, steps, default, automated | reset a parameter |
| Launcher | scenes and their names; clips' state, colour, name | launch a clip or scene, stop a track or everything |
| Notes | the scale's root, notes (a 12-bit mask) and name | |
| App | | undo, redo, save, show a view |

## Events

A listener gets an event for each change in the topics it subscribed to:

- transport
- tracks (added, removed, renamed, selected)
- mixer
- devices
- parameters
- launcher
- notes

An event names what changed (an id and its indices, or 0 for several
things), and the surface reads the new values.

Events come on the surface thread, outside the surface's own calls. As a
rule the host gathers them and delivers them on its next frame, so a
surface that changes a value sees its own change as an event too. Meters
have no events: read them in `on_idle`.

## In the kit

The kit asks for the extension when a surface is made (`cs.daw`; nil
without it). Its components subscribe to what they show while they are
active:

| Component | |
|---|---|
| `transport_make` | slots "play", "stop" (stopped: back to the start), "record", "loop", "metronome", "tap" (the host's, or the kit's tap tempo) |
| `mixer_make` | strips on the ring's tracks, or one on the selected track: volume, pan and sends from faders (picked up) or encoders; mute, solo, arm, select |
| `device_make` | the selected device's parameters, a bank at a time (a stepped one a step a tick); banks, devices, on/off |
| `launcher_make` | a grid of the ring's clips (rows: scenes, columns: tracks) lit by state (or colour, with a palette); scene and stop buttons |
| `navigation_make` | arrows that move the ring |
| `app_make` | undo, redo, save, views |
| `note_repeat_make` | held pads repeat in time with the tempo (an overlay over drum pads) |
| `keyboard_follow_host` | a Keyboard in the host's scale |

Without the extension they do nothing and light nothing. A component of
your own follows topics with `daw_topics` and `on_daw`, and uses
`daw_get`, `daw_text`, `daw_set`, `daw_action`, `daw_toggle`,
`ring_move`. See [kit.md](kit.md) and the examples
[`keys_odin`](../examples/keys_odin/keys.odin) and
[`grid_odin`](../examples/grid_odin/grid.odin).

## In the test host

`fst.daw_enable(&th, tracks, scenes, params)` offers a fake fsurf.daw: an
in-memory DAW whose model a test reads and changes (`th.daw.tracks[2].mute`).
It holds:
- tracks with clips and a device each
- scenes
- a scale
- what the surface asked it to do (`last_action`)

`daw_changed` queues an event, as a host does, and events are delivered
after each update.
