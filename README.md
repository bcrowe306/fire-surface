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

Status: design. See [docs/design.md](docs/design.md).

MIT licence.
