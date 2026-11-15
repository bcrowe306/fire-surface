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

Status: stage 1 of [the design](docs/design.md) is built: the protocol
(version 0.1: loading, lifecycle, MIDI out, timers, settings, project
state, extensions), the Odin host library, and examples in C and Odin.
See [docs/protocol.md](docs/protocol.md).

```
include/fsurf.h      the protocol (C)
abi/                 the same in Odin
host/                the host side, for Odin hosts: scan, load, run surfaces
examples/            hello_c, hello_odin
tests/host           the host library with both examples; Odin vs the header's layout
```

```bash
./scripts/build.sh   # examples and the layout printer, into .build/
./scripts/test.sh    # build, then the tests
```

MIT licence.
