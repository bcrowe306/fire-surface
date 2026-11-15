# fire-surface

An open protocol and SDK for control surfaces: hardware controllers
(MIDI first, also pixel displays over USB and HID) programmed by anyone,
built into a dynamic library (`.fsurf`), and loaded at runtime by any
host that implements the protocol.

- **The protocol**: a versioned C ABI (`include/fsurf.h`), so any host
  or language can implement it, as with CLAP.
- **The Odin kit**: ControlSurface, Controls, Components, Layers and
  Modes, skins, tasks, MIDI, music and colour helpers, and a draw kit for
  displays, compiled into a surface's library.
- **Extensions**: a standard `fsurf.daw` (transport, tracks, devices, a
  launcher) and each host's own (for Pads: `fire.pads`).

Status: stages 1 to 5 of [the design](docs/design.md) are built:
- the protocol (version 0.2: loading, lifecycle, MIDI out, timers,
  settings, project state, extensions, the claim table)
- the Odin host library (scanning, detection by port names and identity
  replies, hot plug, the claim table on the MIDI path)
- the Odin kit (controls, layers and owner stacks, components, modes,
  skins, tasks, the claim table worked out from owners, helpers) with a
  test host
- the standard extension `fsurf.daw` (transport, tracks and mixer,
  devices, launcher, scale, app), its kit components, and a fake DAW for
  tests
- developer tools: hot reload, the MIDI monitor, the virtual controller
  (from a surface's `fsurf.layout`), and the `fsurf` command-line tool
- examples in C and Odin

See [protocol.md](docs/protocol.md), [kit.md](docs/kit.md),
[daw.md](docs/daw.md) and [tools.md](docs/tools.md).

```
include/fsurf.h      the protocol (C)
include/fsurf_daw.h  the standard extension, fsurf.daw
include/fsurf_layout.h  a surface's description of its hardware, for tools
abi/                 the same in Odin
host/                the host side, for Odin hosts: scan, load, detect, route MIDI, run surfaces;
                     the monitor, the virtual controller, hot reload
tools/fsurf          the command-line tool: scan, info, run a surface from a script
surface/             the Odin kit, compiled into a surface
testing/             a headless host for a surface's tests, with a fake fsurf.daw
examples/            hello_c, hello_odin (the protocol by hand); grid_odin, keys_odin (the kit)
tests/host           the host library with the examples and linked-in test surfaces; Odin vs the header's layout
tests/kit            the kit, its helpers, fsurf.daw, and the kit examples through the test host
```

```bash
./scripts/build.sh   # examples and the layout printer, into .build/
./scripts/test.sh    # build, then the tests
```

MIT licence.
