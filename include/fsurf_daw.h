/*
 * fsurf.daw: the standard extension, what most controllers need from a
 * DAW-like host, so a surface written against it works in any host that
 * offers it. MIT licence.
 *
 *   const fsurf_daw_t *daw = host->get_extension(host, FSURF_DAW_ID, FSURF_DAW_VERSION);
 *   if (daw && (daw->parts & FSURF_DAW_TRANSPORT))
 *       daw->set(host, FSURF_DAW_PLAYING, 0, 0, 1);
 *
 * The host's state is read and changed through ids (FSURF_DAW_*): `get`
 * gives a number, `get_text` its text (a name, or a value as the host
 * shows it: "-6.0 dB"), `set` changes it, `action` does something. Ids
 * take up to two indices: a track (0 = the first; FSURF_DAW_MASTER = the
 * master), a send, a scene, a device, a parameter. A host says which
 * parts it has (`parts`); an id it doesn't have reads 0 and NULL, and
 * can't be set.
 *
 * Normalized values (volume, pan, a parameter) are 0-1; pan's centre is
 * 0.5. Colours are 0xRRGGBB. Text belongs to the host and is valid until
 * the next call into this table.
 *
 * Changes come to a listener (`subscribe`) as events for the topics
 * asked for, on the surface thread, outside the surface's own calls (the
 * host gathers them and delivers them later, as a rule once a frame). An
 * event says what changed; the surface reads the new values. Meters have
 * no events: read them in on_idle.
 *
 * Threads, ownership and versions are as in fsurf.h. Version 1.
 */
#ifndef FSURF_DAW_H
#define FSURF_DAW_H

#include "fsurf.h"

#ifdef __cplusplus
extern "C" {
#endif

#define FSURF_DAW_ID "fsurf.daw"
#define FSURF_DAW_VERSION 1

/* The master track's index. */
#define FSURF_DAW_MASTER (-1)

/* What a host has (fsurf_daw_t.parts). */
enum {
	FSURF_DAW_TRANSPORT = 1 << 0,
	FSURF_DAW_TRACKS = 1 << 1,   /* tracks and their mixer */
	FSURF_DAW_DEVICES = 1 << 2,  /* the selected track's devices and their parameters */
	FSURF_DAW_LAUNCHER = 1 << 3, /* clips in scenes */
	FSURF_DAW_NOTES = 1 << 4,    /* the host's scale */
	FSURF_DAW_APP = 1 << 5,      /* undo, redo, save, views */
};

/* Values: get, get_text, set. (a, b) are the indices each takes. */
enum {
	/* Transport */
	FSURF_DAW_PLAYING = 0x100,     /* 0/1; set 1 plays, 0 stops */
	FSURF_DAW_RECORDING,           /* 0/1 */
	FSURF_DAW_LOOP,                /* 0/1 */
	FSURF_DAW_METRONOME,           /* 0/1 */
	FSURF_DAW_TEMPO,               /* beats a minute */
	FSURF_DAW_POSITION,            /* in beats from the start; set moves there */
	FSURF_DAW_SIGNATURE_NUMERATOR,
	FSURF_DAW_SIGNATURE_DENOMINATOR,

	/* Tracks */
	FSURF_DAW_TRACK_COUNT = 0x200,
	FSURF_DAW_TRACK_NAME,          /* (track): text */
	FSURF_DAW_TRACK_COLOR,         /* (track): 0xRRGGBB */
	FSURF_DAW_SELECTED_TRACK,      /* the index; set selects */
	FSURF_DAW_TRACK_MUTE,          /* (track): 0/1 */
	FSURF_DAW_TRACK_SOLO,          /* (track): 0/1 */
	FSURF_DAW_TRACK_ARM,           /* (track): 0/1 */
	FSURF_DAW_TRACK_VOLUME,        /* (track): 0-1; text "-6.0 dB" */
	FSURF_DAW_TRACK_PAN,           /* (track): 0-1, 0.5 = centre */
	FSURF_DAW_SEND_COUNT,          /* sends a track has */
	FSURF_DAW_TRACK_SEND,          /* (track, send): 0-1 */
	FSURF_DAW_TRACK_METER,         /* (track, channel 0/1): its peak, 0-1 (read only, no events) */

	/* Devices (of the selected track) */
	FSURF_DAW_DEVICE_COUNT = 0x300,
	FSURF_DAW_DEVICE_NAME,         /* (device): text */
	FSURF_DAW_SELECTED_DEVICE,     /* the index; set selects */
	FSURF_DAW_DEVICE_ON,           /* (device): 0/1 */
	FSURF_DAW_PARAM_COUNT,         /* the selected device's */
	FSURF_DAW_PARAM_NAME,          /* (param): text */
	FSURF_DAW_PARAM_VALUE,         /* (param): 0-1; text "440 Hz" */
	FSURF_DAW_PARAM_STEPS,         /* (param): its steps (a switch: 2), 0 = continuous */
	FSURF_DAW_PARAM_DEFAULT,       /* (param): 0-1 */
	FSURF_DAW_PARAM_AUTOMATED,     /* (param): 0/1 */

	/* Launcher */
	FSURF_DAW_SCENE_COUNT = 0x400,
	FSURF_DAW_SCENE_NAME,          /* (scene): text */
	FSURF_DAW_CLIP_STATE,          /* (track, scene): FSURF_DAW_CLIP_* */
	FSURF_DAW_CLIP_COLOR,          /* (track, scene): 0xRRGGBB */
	FSURF_DAW_CLIP_NAME,           /* (track, scene): text */

	/* Notes */
	FSURF_DAW_SCALE_ROOT = 0x500,  /* 0-11 (C = 0) */
	FSURF_DAW_SCALE_MASK,          /* bit n = the note n semitones above the root is in it */
	FSURF_DAW_SCALE_NAME,          /* text */
};

/* Actions. */
enum {
	FSURF_DAW_UNDO = 0x800,
	FSURF_DAW_REDO,
	FSURF_DAW_SAVE,
	FSURF_DAW_TAP_TEMPO,
	FSURF_DAW_LAUNCH_CLIP,         /* (track, scene) */
	FSURF_DAW_STOP_TRACK,          /* (track): its clip */
	FSURF_DAW_LAUNCH_SCENE,        /* (scene) */
	FSURF_DAW_STOP_ALL_CLIPS,
	FSURF_DAW_PARAM_RESET,         /* (param): to its default */
	FSURF_DAW_SHOW_VIEW,           /* (FSURF_DAW_VIEW_*) */
};

/* A clip's state (FSURF_DAW_CLIP_STATE). */
enum {
	FSURF_DAW_CLIP_EMPTY = 0,
	FSURF_DAW_CLIP_STOPPED = 1,
	FSURF_DAW_CLIP_PLAYING = 2,
	FSURF_DAW_CLIP_QUEUED = 3,         /* to play */
	FSURF_DAW_CLIP_RECORDING = 4,
	FSURF_DAW_CLIP_RECORD_QUEUED = 5,
	FSURF_DAW_CLIP_STOPPING = 6,       /* queued to stop */
};

/* Views (FSURF_DAW_SHOW_VIEW). */
enum {
	FSURF_DAW_VIEW_MIXER = 0,
	FSURF_DAW_VIEW_SONG = 1,     /* the arrangement */
	FSURF_DAW_VIEW_LAUNCHER = 2,
	FSURF_DAW_VIEW_DEVICES = 3,
};

/* Topics of events (subscribe). */
enum {
	FSURF_DAW_TOPIC_TRANSPORT = 1 << 0,  /* playing, recording, loop, metronome, tempo, signature (not the position) */
	FSURF_DAW_TOPIC_TRACKS = 1 << 1,     /* the tracks: added, removed, moved, named, coloured, selected */
	FSURF_DAW_TOPIC_MIXER = 1 << 2,      /* mute, solo, arm, volume, pan, sends */
	FSURF_DAW_TOPIC_DEVICES = 1 << 3,    /* the selected track's devices: which, their names, which is selected */
	FSURF_DAW_TOPIC_PARAMETERS = 1 << 4, /* the selected device's parameters' values */
	FSURF_DAW_TOPIC_LAUNCHER = 1 << 5,   /* scenes, clips and their states */
	FSURF_DAW_TOPIC_NOTES = 1 << 6,      /* the scale */
};

/* Something changed: `id` (0 = several things in the topic: read them
   all) and its indices. */
typedef struct fsurf_daw_event {
	uint32_t struct_size;
	uint32_t topic; /* one FSURF_DAW_TOPIC_* */
	uint32_t id;
	int32_t a;
	int32_t b;
} fsurf_daw_event_t;

/* Where events go: the surface's. */
typedef struct fsurf_daw_listener {
	void *user;
	void (*on_event)(const struct fsurf_daw_listener *listener, const fsurf_daw_event_t *event);
} fsurf_daw_listener_t;

typedef struct fsurf_daw {
	uint32_t struct_size;
	uint32_t parts; /* FSURF_DAW_TRANSPORT ... */

	double (*get)(const fsurf_host_t *host, uint32_t id, int32_t a, int32_t b);
	const char *(*get_text)(const fsurf_host_t *host, uint32_t id, int32_t a, int32_t b);
	bool (*set)(const fsurf_host_t *host, uint32_t id, int32_t a, int32_t b, double value);
	bool (*action)(const fsurf_host_t *host, uint32_t id, int32_t a, int32_t b);

	/* The surface's window on the tracks and scenes (Live's red box), so the
	   host can show it: `tracks` from `first_track`, `scenes` from
	   `first_scene` (0 and 0 = none). */
	void (*set_ring)(const fsurf_host_t *host, int32_t first_track, int32_t tracks, int32_t first_scene, int32_t scenes);

	/* Events of these topics (bits) to `listener` (valid until it subscribes
	   again; topics 0 = none). Replaces what it asked before. */
	void (*subscribe)(const fsurf_host_t *host, uint32_t topics, const fsurf_daw_listener_t *listener);
} fsurf_daw_t;

#ifdef __cplusplus
}
#endif

#endif
