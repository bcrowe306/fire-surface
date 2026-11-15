/*
 * The smallest useful surface, in C against fsurf.h. examples/hello_odin
 * does the same in Odin, and tests/host checks both.
 *
 * - init: logs, and pings the host's "org.fsurf.test" extension if it has one.
 * - activate: sends a hello (F0 7D 01 F7), counts its activations in its
 *   settings, starts a 10 ms timer.
 * - a note on lights the pad (the same note back, velocity 127); a SysEx
 *   is answered with a notify("sysex").
 * - each tick sends CC 16 with the tick count.
 * - deactivate: sends a goodbye (F0 7D 00 F7).
 * - its project state is its tick count ("ticks=N").
 *
 * MIT licence.
 */
#define _CRT_SECURE_NO_WARNINGS /* MSVC: sscanf and snprintf are fine here */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsurf.h"

/* What a host offers as "org.fsurf.test" version 1 (the tests do). */
typedef struct test_ext {
	void (*ping)(const fsurf_host_t *host, const char *what);
} test_ext_t;

typedef struct hello {
	fsurf_surface_t surface;
	const fsurf_host_t *host;
	uint32_t out_port;
	uint32_t timer;
	uint32_t ticks;
} hello_t;

static const char *const in_names[] = {"Hello*", NULL};
static const char *const out_names[] = {"Hello*", NULL};

static const fsurf_port_spec_t ports[] = {{
	.struct_size = sizeof(fsurf_port_spec_t),
	.role = "main",
	.flags = FSURF_PORT_INPUT | FSURF_PORT_OUTPUT,
	.input_names = in_names,
	.output_names = out_names,
}};

/* The identity reply: F0 7E <any channel> 06 02 7D ... */
static const uint8_t id_match[] = {0xF0, 0x7E, 0x00, 0x06, 0x02, 0x7D};
static const uint8_t id_mask[] = {0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0xFF};

static const fsurf_identity_t identity = {
	.struct_size = sizeof(fsurf_identity_t),
	.method = FSURF_IDENTIFY_REQUEST,
	.match = id_match,
	.mask = id_mask,
	.match_size = sizeof(id_match),
};

static const fsurf_descriptor_t descriptor = {
	.struct_size = sizeof(fsurf_descriptor_t),
	.fsurf_version = FSURF_VERSION_INIT,
	.id = "org.fsurf.example.hello-c",
	.name = "Hello (C)",
	.vendor = "fire-surface",
	.version = "0.1.0",
	.url = "https://github.com/bcrowe306/fire-surface",
	.description = "The smallest useful surface, in C",
	.ports = ports,
	.port_count = 1,
	.identity = &identity,
	.required_extensions = NULL,
};

static hello_t *self(const fsurf_surface_t *s) { return (hello_t *)s->surface_data; }

static void send(hello_t *h, const uint8_t *bytes, uint32_t size) {
	if (h->out_port != FSURF_NO_PORT) h->host->send_midi(h->host, h->out_port, bytes, size);
}

static bool hello_init(const fsurf_surface_t *s) {
	hello_t *h = self(s);
	h->host->log(h->host, FSURF_LOG_INFO, "hello init");
	const test_ext_t *ext = h->host->get_extension(h->host, "org.fsurf.test", 1);
	if (ext) ext->ping(h->host, "init");
	return true;
}

static void hello_destroy(const fsurf_surface_t *s) { free(self(s)); }

static bool hello_activate(const fsurf_surface_t *s, const fsurf_port_t *p, uint32_t count) {
	hello_t *h = self(s);
	if (count != 1) return false;
	h->out_port = p[0].output;
	static const uint8_t hi[] = {0xF0, 0x7D, 0x01, 0xF7};
	send(h, hi, sizeof hi);
	uint32_t n = 0;
	if (h->host->settings_get(h->host, &n, sizeof n) != sizeof n) n = 0;
	n++;
	h->host->settings_set(h->host, &n, sizeof n);
	h->timer = h->host->timer_start(h->host, 10);
	return true;
}

static void hello_deactivate(const fsurf_surface_t *s) {
	hello_t *h = self(s);
	static const uint8_t bye[] = {0xF0, 0x7D, 0x00, 0xF7};
	send(h, bye, sizeof bye);
	h->host->timer_stop(h->host, h->timer);
	h->timer = 0;
	h->out_port = FSURF_NO_PORT;
}

static void hello_on_midi(const fsurf_surface_t *s, uint32_t port, const uint8_t *b, uint32_t size, uint64_t time_ns) {
	(void)port; (void)time_ns;
	hello_t *h = self(s);
	if (size == 3 && (b[0] & 0xF0) == 0x90 && b[2] > 0) {
		uint8_t lit[3] = {b[0], b[1], 127};
		send(h, lit, 3);
	} else if (size > 0 && b[0] == 0xF0) {
		h->host->notify(h->host, "sysex");
	}
}

static void hello_on_timer(const fsurf_surface_t *s, uint32_t id) {
	hello_t *h = self(s);
	if (id != h->timer) return;
	h->ticks++;
	uint8_t cc[3] = {0xB0, 16, (uint8_t)(h->ticks & 127)};
	send(h, cc, 3);
}

static bool hello_save(const fsurf_surface_t *s, const fsurf_ostream_t *st) {
	char buf[32];
	int n = snprintf(buf, sizeof buf, "ticks=%u", self(s)->ticks);
	return st->write(st, buf, (uint64_t)n) == n;
}

static bool hello_load(const fsurf_surface_t *s, const fsurf_istream_t *st) {
	hello_t *h = self(s);
	char buf[32] = {0};
	int64_t n = st->read(st, buf, sizeof buf - 1);
	unsigned t;
	if (n <= 0 || sscanf(buf, "ticks=%u", &t) != 1) return false;
	h->ticks = t;
	char msg[48];
	snprintf(msg, sizeof msg, "loaded %u", t);
	h->host->notify(h->host, msg);
	return true;
}

static uint32_t factory_count(const fsurf_surface_factory_t *f) { (void)f; return 1; }

static const fsurf_descriptor_t *factory_descriptor(const fsurf_surface_factory_t *f, uint32_t i) {
	(void)f;
	return i == 0 ? &descriptor : NULL;
}

static const fsurf_surface_t *factory_create(const fsurf_surface_factory_t *f, const fsurf_host_t *host, const char *id) {
	(void)f;
	if (strcmp(id, descriptor.id) != 0 || !fsurf_version_is_compatible(host->fsurf_version)) return NULL;
	hello_t *h = calloc(1, sizeof *h);
	if (!h) return NULL;
	h->host = host;
	h->out_port = FSURF_NO_PORT;
	h->surface = (fsurf_surface_t){
		.struct_size = sizeof(fsurf_surface_t),
		.desc = &descriptor,
		.surface_data = h,
		.init = hello_init,
		.destroy = hello_destroy,
		.activate = hello_activate,
		.deactivate = hello_deactivate,
		.on_midi = hello_on_midi,
		.on_timer = hello_on_timer,
		.project_save = hello_save,
		.project_load = hello_load,
	};
	return &h->surface;
}

static const fsurf_surface_factory_t factory = {
	.count = factory_count,
	.get_descriptor = factory_descriptor,
	.create = factory_create,
};

static bool entry_init(const char *path) { (void)path; return true; }
static void entry_deinit(void) {}
static const void *entry_factory(const char *id) {
	return strcmp(id, FSURF_SURFACE_FACTORY_ID) == 0 ? &factory : NULL;
}

FSURF_EXPORT const fsurf_entry_t fsurf_entry = {
	.fsurf_version = FSURF_VERSION_INIT,
	.init = entry_init,
	.deinit = entry_deinit,
	.get_factory = entry_factory,
};
