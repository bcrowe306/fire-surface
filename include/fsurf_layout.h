/*
 * fsurf.layout: a surface describes its hardware to the host, for tools:
 * where each control is and what it looks like, which control a message
 * is, which component has it now, and what it shows. A host uses it to
 * draw a stand-in for the device (a virtual controller, usable with the
 * mouse) and to say, in a MIDI monitor, what each message was. MIT
 * licence.
 *
 * It is the surface's extension, not the host's:
 *
 *   const fsurf_layout_t *l = surface->get_extension(surface, FSURF_LAYOUT_ID);
 *
 * Every call is on the surface thread. Strings belong to the surface and
 * are valid until the next call into this table. Version 1.
 */
#ifndef FSURF_LAYOUT_H
#define FSURF_LAYOUT_H

#include "fsurf.h"

#ifdef __cplusplus
extern "C" {
#endif

#define FSURF_LAYOUT_ID "fsurf.layout"

/* What a control is (how to draw it, and use it with a mouse). */
enum {
	FSURF_LAYOUT_BUTTON = 0,  /* pressed and released */
	FSURF_LAYOUT_PAD = 1,     /* pressed with a velocity */
	FSURF_LAYOUT_ENCODER = 2, /* turned */
	FSURF_LAYOUT_FADER = 3,   /* moved along its longer side (faders, sliders, strips, wheels) */
	FSURF_LAYOUT_OTHER = 4,   /* not used with a mouse (a SysEx control) */
	FSURF_LAYOUT_DISPLAY = 5, /* a display: `number` is its index (display_mirror shows it) */
};

/* How an encoder sends its turns (fsurf_layout_control_t.encoding). */
enum {
	FSURF_LAYOUT_ABSOLUTE = 0,        /* a position, 0-127 */
	FSURF_LAYOUT_TWOS_COMPLEMENT = 1, /* 1..63 up, 127..65 down */
	FSURF_LAYOUT_SIGNED_BIT = 2,      /* 1..63 up, 65..127 down */
	FSURF_LAYOUT_BINARY_OFFSET = 3,   /* 64 = none */
};

enum {
	FSURF_LAYOUT_FOURTEEN_BIT = 1 << 0, /* a CC pair: number (MSB) and number + 32 (LSB) */
	FSURF_LAYOUT_TOGGLE = 1 << 1, /* a button that the surface treats as a switch */
};

/* One control. Its place is in the device's units (millimetres, as a
   rule), from the top left; w or h 0 = not placed. */
typedef struct fsurf_layout_control {
	uint32_t struct_size;
	const char *name;
	uint32_t kind;     /* FSURF_LAYOUT_BUTTON ... */
	float x, y, w, h;
	uint32_t port;     /* its port spec's index */
	uint32_t message;  /* what it sends: FSURF_MSG_NOTE_ON (notes), _CONTROL, _PITCH_BEND, _CHANNEL_PRESSURE, _PROGRAM, _SYSEX */
	uint8_t channel;   /* 0-15 */
	uint8_t number;    /* a note or CC */
	uint8_t encoding;  /* FSURF_LAYOUT_ABSOLUTE ... */
	uint8_t flags;     /* FSURF_LAYOUT_FOURTEEN_BIT ... */
} fsurf_layout_control_t;

/* What a control shows now. */
typedef struct fsurf_layout_state {
	uint32_t struct_size;
	uint32_t value;   /* the last light value sent, 0-127 */
	int32_t channel;  /* the channel it was sent on, or -1 for none sent */
	uint32_t rgb;     /* 0xRRGGBB, when has_rgb */
	bool has_rgb;     /* the surface knows the colour it shows */
	bool pressed;     /* held now */
	float position;   /* 0-1: a fader's, an encoder's (absolute, or its ring) */
} fsurf_layout_state_t;

typedef struct fsurf_layout {
	uint32_t struct_size;
	float width, height; /* the device's size, in its units (0 = not given) */
	uint32_t (*count)(const fsurf_surface_t *surface);
	/* Control `index`'s description into `out` (its struct_size set by the
	   caller). False past the last. */
	bool (*get)(const fsurf_surface_t *surface, uint32_t index, fsurf_layout_control_t *out);
	/* Which control a message is, or -1: one from the device on an input
	   id (output false), or one to it on an output id (output true). */
	int32_t (*find)(const fsurf_surface_t *surface, bool output, uint32_t port, const uint8_t *bytes, uint32_t size);
	/* The name of the component that has the control now, or NULL. */
	const char *(*owner)(const fsurf_surface_t *surface, uint32_t index);
	/* What the control shows now into `out`. False past the last. */
	bool (*state)(const fsurf_surface_t *surface, uint32_t index, fsurf_layout_state_t *out);
} fsurf_layout_t;

#ifdef __cplusplus
}
#endif

#endif
