/*
 * fire-surface: the protocol between a control-surface library (a .fsurf)
 * and the software that hosts it. MIT licence.
 *
 * A .fsurf is a dynamic library (with another extension, as a .clap is)
 * that exports one symbol, `fsurf_entry`. Through it the host reads the
 * library's factory, which lists its surfaces (one per controller model)
 * and makes them.
 *
 *   host                              surface library
 *   load library, read fsurf_entry
 *   entry.init(path)  ─────────────►  (sets itself up; no surface yet)
 *   entry.get_factory(FSURF_SURFACE_FACTORY_ID)
 *   factory.count / get_descriptor    (scanning stops here)
 *   factory.create(host, id) ──────►  an fsurf_surface_t
 *   surface.init                      builds its controls; may fail
 *   surface.activate(ports)           the device is there: hello, LEDs
 *     on_midi, on_timer, on_idle ...
 *   surface.deactivate                goodbye, LEDs off
 *   surface.destroy
 *   entry.deinit()
 *
 * Threads: the host calls every function of a surface, and of its entry
 * and factory, on one thread of its own (its surface thread: usually its
 * UI or control thread), never on an audio or MIDI driver thread. A
 * surface calls the host's functions on that thread only, while one of its
 * own functions is running.
 *
 * Strings are UTF-8 and null-terminated. What a call is given (a string,
 * an array) belongs to the caller and is valid until the call returns,
 * unless said otherwise. Descriptors and what they point to belong to the
 * library and stay valid until entry.deinit.
 *
 * Versions: every struct the two sides share begins with its size
 * (`struct_size`), so later minor versions can add fields at the end; a
 * reader checks the size before touching a field it is not sure of. Until
 * version 1.0 the ABI may change between minor versions: a host loads a
 * library built against its own major and minor version only
 * (fsurf_version_is_compatible).
 */
#ifndef FSURF_H
#define FSURF_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define FSURF_EXPORT __declspec(dllexport)
#else
#define FSURF_EXPORT __attribute__((visibility("default")))
#endif

/* ── Versions ─────────────────────────────────────────────────────────── */

#define FSURF_VERSION_MAJOR 0
#define FSURF_VERSION_MINOR 1
#define FSURF_VERSION_REVISION 0

typedef struct fsurf_version {
	uint32_t major;
	uint32_t minor;
	uint32_t revision;
} fsurf_version_t;

#define FSURF_VERSION_INIT {FSURF_VERSION_MAJOR, FSURF_VERSION_MINOR, FSURF_VERSION_REVISION}

/* Whether a host of this header's version loads a library built against
   `v`: before 1.0, the same major and minor; from 1.0, the same major. */
static inline bool fsurf_version_is_compatible(fsurf_version_t v) {
	if (v.major != FSURF_VERSION_MAJOR) return false;
	return FSURF_VERSION_MAJOR > 0 || v.minor == FSURF_VERSION_MINOR;
}

/* ── Streams (a project's state) ──────────────────────────────────────── */

typedef struct fsurf_ostream {
	void *ctx; /* the host's */
	/* Writes up to `size` bytes; returns how many it wrote, or -1. */
	int64_t (*write)(const struct fsurf_ostream *stream, const void *buffer, uint64_t size);
} fsurf_ostream_t;

typedef struct fsurf_istream {
	void *ctx;
	/* Reads up to `size` bytes; returns how many it read (0 at the end), or -1. */
	int64_t (*read)(const struct fsurf_istream *stream, void *buffer, uint64_t size);
} fsurf_istream_t;

/* ── Descriptors: what a library offers, read when scanning ───────────── */

/* A MIDI port pair a surface uses, by role ("main", "user", "display"). */
typedef struct fsurf_port_spec {
	uint32_t struct_size;
	const char *role;
	uint32_t flags; /* FSURF_PORT_* */
	/* Patterns for the device's MIDI port names, null-terminated arrays.
	   `*` matches any run of characters, case is ignored ("Push 2*Live
	   Port*"). A pattern may begin with "mac:", "win:" or "linux:" to apply
	   on that system only, as the names differ between them. */
	const char *const *input_names;
	const char *const *output_names;
} fsurf_port_spec_t;

enum {
	FSURF_PORT_INPUT = 1 << 0,    /* the surface reads this role's input */
	FSURF_PORT_OUTPUT = 1 << 1,   /* and writes its output */
	FSURF_PORT_OPTIONAL = 1 << 2, /* it activates without it */
};

/* How a host recognizes the device on its ports. */
typedef struct fsurf_identity {
	uint32_t struct_size;
	uint32_t method;       /* FSURF_IDENTIFY_* */
	const char *port_role; /* the pair asked on; NULL = the first port spec */
	/* FSURF_IDENTIFY_REQUEST: what to send; NULL = the universal identity
	   request, F0 7E 7F 06 01 F7. */
	const uint8_t *request;
	uint32_t request_size;
	/* The reply matches when, for each i < match_size,
	   (reply[i] & mask[i]) == (match[i] & mask[i]); mask NULL = all bits. */
	const uint8_t *match;
	const uint8_t *mask;
	uint32_t match_size;
	uint32_t delay_ms;   /* after the ports open, before the first request */
	uint32_t retry_ms;   /* between requests (0 = the host's default) */
	uint32_t retries;    /* requests after the first (0 = the host's default) */
} fsurf_identity_t;

enum {
	FSURF_IDENTIFY_NAMES = 0,   /* the port names alone */
	FSURF_IDENTIFY_REQUEST = 1, /* a request, and the reply matched */
	FSURF_IDENTIFY_SURFACE = 2, /* the surface does it, between init and activate:
	                               the host calls identify(), and it answers with
	                               host->identified() */
};

/* One kind of surface (a controller model). */
typedef struct fsurf_descriptor {
	uint32_t struct_size;
	fsurf_version_t fsurf_version; /* the header it was built against */
	const char *id;          /* reverse-DNS, stable: "com.example.mk2" */
	const char *name;        /* "Example MK2" */
	const char *vendor;
	const char *version;     /* the surface's own: "1.2.0" */
	const char *url;         /* or NULL */
	const char *description; /* or NULL */
	const fsurf_port_spec_t *ports;
	uint32_t port_count;
	const fsurf_identity_t *identity; /* NULL = by port names alone */
	/* Host extensions it can't work without ("fsurf.daw"), null-terminated
	   or NULL; a host lacking one doesn't offer the surface. */
	const char *const *required_extensions;
} fsurf_descriptor_t;

/* ── The host, as a surface sees it ───────────────────────────────────── */

enum {
	FSURF_LOG_DEBUG = 0,
	FSURF_LOG_INFO = 1,
	FSURF_LOG_WARNING = 2,
	FSURF_LOG_ERROR = 3,
};

#define FSURF_NO_PORT UINT32_MAX

typedef struct fsurf_host {
	uint32_t struct_size;
	fsurf_version_t fsurf_version;
	void *host_data; /* the host's */
	const char *name;    /* "Pads" */
	const char *vendor;
	const char *url;
	const char *version; /* "0.1.1-dev" */

	/* An extension of the host by id and version ("fsurf.daw", 1): its
	   function table, valid while the surface lives, or NULL. */
	const void *(*get_extension)(const struct fsurf_host *host, const char *id, uint32_t version);

	/* A line for the host's log. */
	void (*log)(const struct fsurf_host *host, int32_t level, const char *message);
	/* A short message for the user, shown for a moment ("Mixer", "Bank 2"). */
	void (*notify)(const struct fsurf_host *host, const char *text);

	/* MIDI to the device: a short message, or a whole SysEx (F0 ... F7), on
	   a port given at activate (fsurf_port_t.output). False when the port
	   is closed or the host's buffer is full. */
	bool (*send_midi)(const struct fsurf_host *host, uint32_t port, const uint8_t *bytes, uint32_t size);

	/* A repeating timer: on_timer(id) every `period_ms` (at the host's
	   resolution: at least once a host frame is not promised). 0 = none
	   made. Stopped with timer_stop, or when the surface is destroyed. */
	uint32_t (*timer_start)(const struct fsurf_host *host, uint32_t period_ms);
	void (*timer_stop)(const struct fsurf_host *host, uint32_t timer_id);
	/* The host's clock, in nanoseconds (the time on_midi gives). */
	uint64_t (*now_ns)(const struct fsurf_host *host);

	/* The surface's settings: one blob for this device (kept by the host
	   between runs, apart from any project). settings_get copies up to
	   `capacity` bytes into `buffer` and returns the whole size (0 = none);
	   settings_set keeps a copy. */
	uint32_t (*settings_get)(const struct fsurf_host *host, void *buffer, uint32_t capacity);
	bool (*settings_set)(const struct fsurf_host *host, const void *data, uint32_t size);

	/* FSURF_IDENTIFY_SURFACE: the device on the ports is (or is not) the
	   surface's. */
	void (*identified)(const struct fsurf_host *host, bool ok);
} fsurf_host_t;

/* ── A surface ────────────────────────────────────────────────────────── */

/* A port pair given at activate, by its role in the descriptor. */
typedef struct fsurf_port {
	const char *role;
	uint32_t input;  /* the id on_midi gives, or FSURF_NO_PORT */
	uint32_t output; /* the id send_midi takes, or FSURF_NO_PORT */
	const char *input_name;  /* the system's names, or NULL */
	const char *output_name;
} fsurf_port_t;

typedef struct fsurf_surface {
	uint32_t struct_size;
	const fsurf_descriptor_t *desc;
	void *surface_data; /* the surface's */

	/* After create: builds what it needs. False = it can't run; the host
	   calls destroy. */
	bool (*init)(const struct fsurf_surface *surface);
	/* Frees everything (deactivated first, if it was active). */
	void (*destroy)(const struct fsurf_surface *surface);

	/* FSURF_IDENTIFY_SURFACE only: the ports are open (as activate's);
	   identify the device and answer with host->identified. May be NULL. */
	void (*identify)(const struct fsurf_surface *surface, const fsurf_port_t *ports, uint32_t count);

	/* The device is there: `ports` in the descriptor's order (a missing
	   optional one has FSURF_NO_PORT). Sends its hello, lights its LEDs.
	   False = it couldn't start. */
	bool (*activate)(const struct fsurf_surface *surface, const fsurf_port_t *ports, uint32_t count);
	/* The device is gone, the user turned it off, or the host is quitting:
	   sends its goodbye if the ports are still there. */
	void (*deactivate)(const struct fsurf_surface *surface);

	/* MIDI from the device, while active: a short message or a whole SysEx;
	   `time_ns` on the host's clock (now_ns). */
	void (*on_midi)(const struct fsurf_surface *surface, uint32_t port, const uint8_t *bytes, uint32_t size, uint64_t time_ns);
	/* A timer from timer_start. */
	void (*on_timer)(const struct fsurf_surface *surface, uint32_t timer_id);
	/* Once a host frame (meters, blinking). May be NULL. */
	void (*on_idle)(const struct fsurf_surface *surface);

	/* Its part of a project: written when the project is saved, read when
	   one is opened (after init, before or while active). May be NULL. */
	bool (*project_save)(const struct fsurf_surface *surface, const fsurf_ostream_t *stream);
	bool (*project_load)(const struct fsurf_surface *surface, const fsurf_istream_t *stream);

	/* An extension of the surface by id, for the host, or NULL. May be NULL. */
	const void *(*get_extension)(const struct fsurf_surface *surface, const char *id);
} fsurf_surface_t;

/* ── The factory ──────────────────────────────────────────────────────── */

#define FSURF_SURFACE_FACTORY_ID "fsurf.surface-factory"

typedef struct fsurf_surface_factory {
	/* How many kinds of surface the library has. */
	uint32_t (*count)(const struct fsurf_surface_factory *factory);
	/* One of them, or NULL past the last. */
	const fsurf_descriptor_t *(*get_descriptor)(const struct fsurf_surface_factory *factory, uint32_t index);
	/* A new surface of that kind for `host` (which stays valid until the
	   surface is destroyed), or NULL. The host calls its init next. */
	const fsurf_surface_t *(*create)(const struct fsurf_surface_factory *factory, const fsurf_host_t *host, const char *surface_id);
} fsurf_surface_factory_t;

/* ── The entry ────────────────────────────────────────────────────────── */

typedef struct fsurf_entry {
	fsurf_version_t fsurf_version;
	/* Called once after loading, with the library's own path. False = the
	   host unloads it. */
	bool (*init)(const char *library_path);
	/* Called once before unloading, after every surface is destroyed. */
	void (*deinit)(void);
	/* A factory by id (FSURF_SURFACE_FACTORY_ID), or NULL. */
	const void *(*get_factory)(const char *factory_id);
} fsurf_entry_t;

/* The one export of a .fsurf. */
FSURF_EXPORT extern const fsurf_entry_t fsurf_entry;

#ifdef __cplusplus
}
#endif

#endif
