/*
 * foliod - folio, lid and pen state daemon for the Galaxy Tab S8+ (ADR-002).
 *
 * Inputs: the presence of the pogo keyboard input device, the two
 * gpio-keys hall switches, and on every input transition and on a
 * heartbeat one magnetometer and one light sample through libssc. The
 * classifier in folio_state.c turns those into lid and pen state, which
 * this daemon publishes on a uinput device named "folio-state" carrying
 * SW_LID and SW_PEN_INSERTED. Every state change and every pen-forgotten
 * edge is logged to stderr, which the unit sends to the journal.
 *
 * The two libssc sensor objects are created once and kept for the life of
 * the process: each creation allocates a QMI client id on the SLPI that
 * unref does not give back, and creating per sample exhausted the ids in
 * minutes on the tablet (ClientIdsExhausted). Each sample opens, reads and
 * closes the same objects, so the SLPI is not kept streaming (issue #46).
 *
 * The libssc calls are the asynchronous ones: when hexagonrpcd is not
 * serving, libssc retries sensor discovery once a second for 100 s inside
 * its synchronous wrappers, and a lid change must not wait on that. A
 * sample that does not complete within SAMPLE_TIMEOUT_S is abandoned and
 * the classifier runs on the hard signals alone; the sequence still closes
 * whatever it opened, and the next trigger tries again.
 *
 * Heartbeat: while the folio is attached but not on the pogo pins
 * (keyboard absent, hall 23 asserted) closing or opening it changes only
 * the magnetometer, so that context samples every ATTACHED_HEARTBEAT_S;
 * bare and docked sample every HEARTBEAT_S. SIGUSR1 samples at once;
 * console-blank sends it when input arrives while the lid reads closed.
 *
 * Settings come from the environment, and from /etc/conf.d/folio-state
 * for any key the environment does not set: HEARTBEAT_S,
 * ATTACHED_HEARTBEAT_S, LIGHT_VETO_LUX, PEN_DZ_BARE, PEN_DZ_DOCKED,
 * REVERSED_DZ, REVERSED_DX, CLOSED_DZ, BASE_Z_BARE, BASE_X_BARE,
 * BASE_Z_DOCKED, MAG_SAMPLES, SAMPLE_TIMEOUT_S, PEN_FORGOTTEN.
 *
 * `foliod --once` samples, prints the inputs and the classification and
 * exits without creating the virtual device.
 *
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <glib.h>
#include <glib-unix.h>
#include <gio/gio.h>
#include <libevdev/libevdev.h>
#include <libevdev/libevdev-uinput.h>
#include <libssc-sensor-magnetometer.h>
#include <libssc-sensor-light.h>
#include <linux/input.h>

#include "folio_state.h"

#define CONF_FILE "/etc/conf.d/folio-state"
#define INPUT_DIR "/dev/input"
#define KEYBOARD_PREFIX "Book Cover Keyboard"
#define GPIO_KEYS_NAME "gpio-keys"
#define UINPUT_NAME "folio-state"
#define TRIGGER_DEBOUNCE_MS 200
#define RESCAN_DEBOUNCE_MS 300
#define FAIL_LOG_INTERVAL_S 60

/* where the sample sequence is */
enum phase {
	PH_IDLE,
	PH_WAIT_SENSORS,	/* sensor objects still being created */
	PH_MAG_OPEN,
	PH_MAG_COLLECT,
	PH_MAG_CLOSE,
	PH_LIGHT_OPEN,
	PH_LIGHT_COLLECT,
	PH_LIGHT_CLOSE,
};

struct daemon {
	struct folio_state st;
	struct folio_input hard;	/* keyboard_present, hall23, hall169 */
	bool hard_known;

	struct libevdev *gpio;
	int gpio_fd;
	guint gpio_watch;

	struct libevdev_uinput *uinput;
	GFileMonitor *monitor;
	guint rescan_id;
	guint trigger_id;
	guint heartbeat_id;
	const char *trigger_reason;

	/* sensors, created once */
	SSCSensorMagnetometer *mag;
	bool mag_creating;
	SSCSensorLight *light;
	bool light_creating;

	/* the sample in progress */
	enum phase phase;
	bool sampling;
	bool abandoned;		/* timed out and published; only closing now */
	bool rerun;		/* a trigger arrived during the sample */
	guint sample_timeout_id;
	unsigned mag_n;
	double mag_sx;
	double mag_sz;
	bool mag_ok;
	float mag_x;
	float mag_z;
	bool light_ok;
	float light_lux;
	char fail[256];		/* reasons this sample failed, for one log line */

	/* failure log rate limit */
	char last_fail[256];
	time_t last_fail_time;
	unsigned fail_suppressed;
	unsigned failed_samples;

	unsigned heartbeat_s;
	unsigned attached_heartbeat_s;
	unsigned mag_samples;
	unsigned sample_timeout_s;
	bool pen_forgotten_log;

	bool once;
	GMainLoop *loop;

	bool published;
	struct folio_output last;
};

static void logmsg(const char *fmt, ...) G_GNUC_PRINTF(1, 2);
static void logmsg(const char *fmt, ...)
{
	va_list ap;

	fputs("foliod: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	fflush(stderr);
}

static void sample_start(struct daemon *d);
static void sample_advance(struct daemon *d);
static void schedule_rescan(struct daemon *d);
static void arm_heartbeat(struct daemon *d);

/* ------------------------------------------------------------------ */
/* GLib log filter                                                    */

/* libssc warns "Mount matrix provided by firmware is all 0" on every open
 * of a sensor that has no mount matrix; two lines per sample at idle. */
static GLogWriterOutput log_writer(GLogLevelFlags level, const GLogField *fields,
				   gsize n_fields, gpointer user_data)
{
	gsize i;

	(void)user_data;
	for (i = 0; i < n_fields; i++) {
		if (strcmp(fields[i].key, "MESSAGE") == 0 && fields[i].value &&
		    fields[i].length == (gssize)-1 &&
		    strstr(fields[i].value, "Mount matrix provided by firmware is all 0"))
			return G_LOG_WRITER_HANDLED;
	}
	return g_log_writer_default(level, fields, n_fields, user_data);
}

/* ------------------------------------------------------------------ */
/* configuration                                                      */

/* Put KEY=VALUE lines from the conf file into the environment for keys
 * the environment does not already set, so `foliod --once` by hand reads
 * the same settings the unit does. */
static void load_conf_file(const char *path)
{
	FILE *f = fopen(path, "r");
	char line[256];

	if (!f)
		return;
	while (fgets(line, sizeof(line), f)) {
		char *s = line, *eq, *end;

		while (*s == ' ' || *s == '\t')
			s++;
		if (*s == '#' || *s == '\n' || *s == '\0')
			continue;
		eq = strchr(s, '=');
		if (!eq)
			continue;
		*eq = '\0';
		end = eq + 1 + strcspn(eq + 1, "\r\n");
		*end = '\0';
		if (eq[1] == '"' && end > eq + 2 && end[-1] == '"') {
			end[-1] = '\0';
			memmove(eq + 1, eq + 2, strlen(eq + 2) + 1);
		}
		if (!getenv(s))
			setenv(s, eq + 1, 0);
	}
	fclose(f);
}

static bool env_float(const char *key, float *out)
{
	const char *v = getenv(key);
	char *end;
	float f;

	if (!v || !*v)
		return false;
	f = strtof(v, &end);
	if (*end) {
		logmsg("%s='%s' is not a number, keeping %g", key, v, *out);
		return false;
	}
	*out = f;
	return true;
}

static bool env_uint(const char *key, unsigned *out)
{
	const char *v = getenv(key);
	char *end;
	unsigned long u;

	if (!v || !*v)
		return false;
	u = strtoul(v, &end, 10);
	if (*end) {
		logmsg("%s='%s' is not a whole number, keeping %u", key, v, *out);
		return false;
	}
	*out = (unsigned)u;
	return true;
}

static void configure(struct daemon *d)
{
	struct folio_config cfg;
	const char *v;

	load_conf_file(CONF_FILE);
	folio_config_defaults(&cfg);
	env_float("PEN_DZ_BARE", &cfg.pen_dz_bare);
	env_float("PEN_DZ_DOCKED", &cfg.pen_dz_docked);
	env_float("REVERSED_DZ", &cfg.reversed_dz);
	env_float("REVERSED_DX", &cfg.reversed_dx);
	env_float("CLOSED_DZ", &cfg.closed_dz);
	env_float("LIGHT_VETO_LUX", &cfg.light_veto_lux);
	env_float("BASE_Z_BARE", &cfg.base_z_bare);
	env_float("BASE_X_BARE", &cfg.base_x_bare);
	env_float("BASE_Z_DOCKED", &cfg.base_z_docked);
	folio_state_init(&d->st, &cfg);

	d->heartbeat_s = 60;
	d->attached_heartbeat_s = 3;
	d->mag_samples = 3;
	d->sample_timeout_s = 10;
	env_uint("HEARTBEAT_S", &d->heartbeat_s);
	env_uint("ATTACHED_HEARTBEAT_S", &d->attached_heartbeat_s);
	env_uint("MAG_SAMPLES", &d->mag_samples);
	env_uint("SAMPLE_TIMEOUT_S", &d->sample_timeout_s);
	if (d->mag_samples == 0)
		d->mag_samples = 1;
	if (d->sample_timeout_s == 0)
		d->sample_timeout_s = 1;

	/* off by default: the operator keeps the pen in the folio's holder,
	 * which the sensors cannot see, so every close would fire it */
	d->pen_forgotten_log = false;
	v = getenv("PEN_FORGOTTEN");
	if (v && *v) {
		if (strcmp(v, "strip") == 0)
			d->pen_forgotten_log = true;
		else if (strcmp(v, "off") != 0)
			logmsg("PEN_FORGOTTEN='%s' is not strip or off, keeping off", v);
	}
}

/* ------------------------------------------------------------------ */
/* output                                                             */

static int uinput_create(struct daemon *d)
{
	struct libevdev *dev = libevdev_new();
	int rc;

	libevdev_set_name(dev, UINPUT_NAME);
	libevdev_set_id_bustype(dev, BUS_VIRTUAL);
	libevdev_enable_event_type(dev, EV_SW);
	libevdev_enable_event_code(dev, EV_SW, SW_LID, NULL);
	libevdev_enable_event_code(dev, EV_SW, SW_PEN_INSERTED, NULL);
	rc = libevdev_uinput_create_from_device(dev, LIBEVDEV_UINPUT_OPEN_MANAGED,
						&d->uinput);
	libevdev_free(dev);
	if (rc < 0) {
		logmsg("cannot create the %s uinput device: %s", UINPUT_NAME,
		       strerror(-rc));
		return rc;
	}
	logmsg("virtual device %s at %s", UINPUT_NAME,
	       libevdev_uinput_get_devnode(d->uinput));
	return 0;
}

static void publish(struct daemon *d, const struct folio_output *o)
{
	if (!d->uinput)
		return;
	libevdev_uinput_write_event(d->uinput, EV_SW, SW_LID, o->lid_closed);
	libevdev_uinput_write_event(d->uinput, EV_SW, SW_PEN_INSERTED,
				    o->pen_docked);
	libevdev_uinput_write_event(d->uinput, EV_SYN, SYN_REPORT, 0);
}

static const char *pen_name(const struct folio_output *o)
{
	if (o->pen_docked)
		return "docked";
	if (o->pen_reversed)
		return "reversed";
	return "none";
}

static void print_once(const struct daemon *d, const struct folio_input *in,
		       const struct folio_output *o)
{
	printf("keyboard_present=%d\n", in->keyboard_present);
	printf("hall23=%d\n", in->hall23);
	printf("hall169=%d\n", in->hall169);
	if (in->mag_valid)
		printf("mag_x=%.1f\nmag_z=%.1f\n", in->mag_x, in->mag_z);
	else
		printf("mag=unavailable\n");
	if (in->light_valid)
		printf("light_lux=%.1f\n", in->light_lux);
	else
		printf("light=unavailable\n");
	printf("context=%s\n", folio_context_name(o->context));
	if (d->st.last_mag_used)
		printf("baseline_z=%.1f\ndz=%.1f\ndx=%.1f\n", d->st.last_base_z,
		       d->st.last_dz, d->st.last_dx);
	printf("lid=%s\n", o->lid_closed ? "closed" : "open");
	printf("pen=%s\n", pen_name(o));
	printf("pen_forgotten=%d\n", o->pen_forgotten);
}

/* Step the classifier with the hard signals and whatever the sample in
 * progress has collected, publish, and re-arm the heartbeat for the
 * context that came out. */
static void step_and_publish(struct daemon *d, bool use_sample)
{
	struct folio_input in = d->hard;
	struct folio_output o;

	in.mag_valid = use_sample && d->mag_ok;
	in.mag_x = in.mag_valid ? d->mag_x : 0.0f;
	in.mag_z = in.mag_valid ? d->mag_z : 0.0f;
	in.light_valid = use_sample && d->light_ok;
	in.light_lux = in.light_valid ? d->light_lux : 0.0f;

	folio_state_step(&d->st, &in, &o);

	if (d->once) {
		print_once(d, &in, &o);
		g_main_loop_quit(d->loop);
		return;
	}

	if (!d->published || o.lid_closed != d->last.lid_closed ||
	    o.pen_docked != d->last.pen_docked ||
	    o.pen_reversed != d->last.pen_reversed ||
	    o.context != d->last.context) {
		char light[16] = "n/a";

		if (in.light_valid)
			snprintf(light, sizeof(light), "%.0f", in.light_lux);
		if (in.mag_valid)
			logmsg("%s: lid %s, pen %s (kb %d hall23 %d hall169 %d, Z %.0f X %.0f, base Z %.0f dZ %.0f dX %.0f, light %s) [%s]",
			       folio_context_name(o.context),
			       o.lid_closed ? "closed" : "open", pen_name(&o),
			       in.keyboard_present, in.hall23, in.hall169,
			       in.mag_z, in.mag_x, d->st.last_base_z,
			       d->st.last_dz, d->st.last_dx, light,
			       d->trigger_reason ? d->trigger_reason : "start");
		else
			logmsg("%s: lid %s, pen %s (kb %d hall23 %d hall169 %d, no magnetometer sample) [%s]",
			       folio_context_name(o.context),
			       o.lid_closed ? "closed" : "open", pen_name(&o),
			       in.keyboard_present, in.hall23, in.hall169,
			       d->trigger_reason ? d->trigger_reason : "start");
	}
	if (o.pen_forgotten && d->pen_forgotten_log)
		logmsg("pen forgotten: lid closed and the last open sample saw no pen on the strip");

	publish(d, &o);
	d->last = o;
	d->published = true;
	arm_heartbeat(d);
}

/* ------------------------------------------------------------------ */
/* failure log, one line per distinct reason per minute               */

static void fail_add(struct daemon *d, const char *fmt, ...) G_GNUC_PRINTF(2, 3);
static void fail_add(struct daemon *d, const char *fmt, ...)
{
	size_t len = strlen(d->fail);
	va_list ap;

	if (len && len + 2 < sizeof(d->fail)) {
		strcat(d->fail, "; ");
		len += 2;
	}
	va_start(ap, fmt);
	vsnprintf(d->fail + len, sizeof(d->fail) - len, fmt, ap);
	va_end(ap);
}

static void fail_report(struct daemon *d)
{
	time_t now = time(NULL);

	if (!d->fail[0]) {
		if (d->failed_samples) {
			logmsg("sensors recovered after %u failed sample%s",
			       d->failed_samples, d->failed_samples == 1 ? "" : "s");
			if (d->fail_suppressed)
				logmsg("%u identical failure line%s suppressed",
				       d->fail_suppressed, d->fail_suppressed == 1 ? "" : "s");
		}
		d->failed_samples = 0;
		d->fail_suppressed = 0;
		d->last_fail[0] = '\0';
		return;
	}
	d->failed_samples++;
	if (strcmp(d->fail, d->last_fail) == 0 &&
	    now - d->last_fail_time < FAIL_LOG_INTERVAL_S) {
		d->fail_suppressed++;
		return;
	}
	if (d->fail_suppressed)
		logmsg("sample failed: %s (%u identical line%s suppressed)", d->fail,
		       d->fail_suppressed, d->fail_suppressed == 1 ? "" : "s");
	else
		logmsg("sample failed: %s", d->fail);
	d->fail_suppressed = 0;
	strncpy(d->last_fail, d->fail, sizeof(d->last_fail) - 1);
	d->last_fail[sizeof(d->last_fail) - 1] = '\0';
	d->last_fail_time = now;
}

/* ------------------------------------------------------------------ */
/* sensor objects, created once                                       */

static void mag_measurement(SSCSensorMagnetometer *sensor, gfloat x, gfloat y,
			    gfloat z, gpointer data)
{
	struct daemon *d = data;

	(void)sensor;
	(void)y;
	if (d->phase != PH_MAG_COLLECT)
		return;
	d->mag_sx += x;
	d->mag_sz += z;
	d->mag_n++;
	if (d->mag_n < d->mag_samples)
		return;
	d->mag_ok = true;
	d->mag_x = (float)(d->mag_sx / d->mag_n);
	d->mag_z = (float)(d->mag_sz / d->mag_n);
	d->phase = PH_MAG_CLOSE;
	sample_advance(d);
}

static void light_measurement(SSCSensorLight *sensor, gfloat lux, gpointer data)
{
	struct daemon *d = data;

	(void)sensor;
	if (d->phase != PH_LIGHT_COLLECT)
		return;
	d->light_ok = true;
	d->light_lux = lux;
	d->phase = PH_LIGHT_CLOSE;
	sample_advance(d);
}

static void sensors_created(struct daemon *d)
{
	if (d->mag_creating || d->light_creating)
		return;
	if (d->sampling && d->phase == PH_WAIT_SENSORS) {
		d->phase = PH_IDLE;
		sample_advance(d);
	}
}

static void mag_new_cb(GObject *src, GAsyncResult *res, gpointer data)
{
	struct daemon *d = data;
	GError *err = NULL;

	(void)src;
	d->mag_creating = false;
	d->mag = ssc_sensor_magnetometer_new_finish(res, &err);
	if (!d->mag) {
		fail_add(d, "magnetometer unavailable: %s", err ? err->message : "unknown");
		g_clear_error(&err);
	} else {
		g_signal_connect(d->mag, "measurement", G_CALLBACK(mag_measurement), d);
		logmsg("magnetometer sensor ready");
	}
	sensors_created(d);
}

static void light_new_cb(GObject *src, GAsyncResult *res, gpointer data)
{
	struct daemon *d = data;
	GError *err = NULL;

	(void)src;
	d->light_creating = false;
	d->light = ssc_sensor_light_new_finish(res, &err);
	if (!d->light) {
		fail_add(d, "light sensor unavailable: %s", err ? err->message : "unknown");
		g_clear_error(&err);
	} else {
		g_signal_connect(d->light, "measurement", G_CALLBACK(light_measurement), d);
		logmsg("light sensor ready");
	}
	sensors_created(d);
}

/* true when a creation is pending */
static bool ensure_sensors(struct daemon *d)
{
	if (!d->mag && !d->mag_creating) {
		d->mag_creating = true;
		ssc_sensor_magnetometer_new(NULL, mag_new_cb, d);
	}
	if (!d->light && !d->light_creating) {
		d->light_creating = true;
		ssc_sensor_light_new(NULL, light_new_cb, d);
	}
	return d->mag_creating || d->light_creating;
}

/* ------------------------------------------------------------------ */
/* the sample sequence                                                */

static void sample_finish(struct daemon *d)
{
	bool rerun = d->rerun;

	if (d->sample_timeout_id) {
		g_source_remove(d->sample_timeout_id);
		d->sample_timeout_id = 0;
	}
	if (!d->abandoned) {
		fail_report(d);
		step_and_publish(d, true);
	}
	d->phase = PH_IDLE;
	d->sampling = false;
	d->abandoned = false;
	d->rerun = false;
	if (rerun && !d->once)
		sample_start(d);
}

static void mag_open_cb(GObject *src, GAsyncResult *res, gpointer data)
{
	struct daemon *d = data;
	GError *err = NULL;

	if (!ssc_sensor_magnetometer_open_finish(SSC_SENSOR_MAGNETOMETER(src), res, &err)) {
		fail_add(d, "magnetometer open: %s", err ? err->message : "unknown");
		g_clear_error(&err);
		d->phase = PH_LIGHT_OPEN;
	} else {
		d->phase = d->abandoned ? PH_MAG_CLOSE : PH_MAG_COLLECT;
	}
	sample_advance(d);
}

static void mag_close_cb(GObject *src, GAsyncResult *res, gpointer data)
{
	struct daemon *d = data;
	GError *err = NULL;

	if (!ssc_sensor_magnetometer_close_finish(SSC_SENSOR_MAGNETOMETER(src), res, &err)) {
		fail_add(d, "magnetometer close: %s", err ? err->message : "unknown");
		g_clear_error(&err);
	}
	d->phase = PH_LIGHT_OPEN;
	sample_advance(d);
}

static void light_open_cb(GObject *src, GAsyncResult *res, gpointer data)
{
	struct daemon *d = data;
	GError *err = NULL;

	if (!ssc_sensor_light_open_finish(SSC_SENSOR_LIGHT(src), res, &err)) {
		fail_add(d, "light open: %s", err ? err->message : "unknown");
		g_clear_error(&err);
		d->phase = PH_IDLE;
		sample_finish(d);
		return;
	}
	d->phase = d->abandoned ? PH_LIGHT_CLOSE : PH_LIGHT_COLLECT;
	sample_advance(d);
}

static void light_close_cb(GObject *src, GAsyncResult *res, gpointer data)
{
	struct daemon *d = data;
	GError *err = NULL;

	if (!ssc_sensor_light_close_finish(SSC_SENSOR_LIGHT(src), res, &err)) {
		fail_add(d, "light close: %s", err ? err->message : "unknown");
		g_clear_error(&err);
	}
	d->phase = PH_IDLE;
	sample_finish(d);
}

/* Drive the sequence from the phase it is in. Phases that wait on a
 * callback or a signal return without doing anything. */
static void sample_advance(struct daemon *d)
{
	switch (d->phase) {
	case PH_IDLE:
		/* start: nothing created means nothing to sample */
		if (!d->mag && !d->light) {
			sample_finish(d);
			return;
		}
		if (d->abandoned) {
			sample_finish(d);
			return;
		}
		if (d->mag) {
			d->phase = PH_MAG_OPEN;
			ssc_sensor_magnetometer_open(d->mag, NULL, mag_open_cb, d);
		} else {
			d->phase = PH_LIGHT_OPEN;
			sample_advance(d);
		}
		return;
	case PH_WAIT_SENSORS:
	case PH_MAG_OPEN:
	case PH_MAG_COLLECT:
	case PH_LIGHT_COLLECT:
		return;
	case PH_MAG_CLOSE:
		ssc_sensor_magnetometer_close(d->mag, NULL, mag_close_cb, d);
		return;
	case PH_LIGHT_OPEN:
		if (!d->light || d->abandoned) {
			d->phase = PH_IDLE;
			sample_finish(d);
			return;
		}
		ssc_sensor_light_open(d->light, NULL, light_open_cb, d);
		return;
	case PH_LIGHT_CLOSE:
		ssc_sensor_light_close(d->light, NULL, light_close_cb, d);
		return;
	}
}

static const char *phase_name(enum phase p)
{
	switch (p) {
	case PH_IDLE: return "idle";
	case PH_WAIT_SENSORS: return "sensor discovery";
	case PH_MAG_OPEN: return "magnetometer open";
	case PH_MAG_COLLECT: return "magnetometer report";
	case PH_MAG_CLOSE: return "magnetometer close";
	case PH_LIGHT_OPEN: return "light open";
	case PH_LIGHT_COLLECT: return "light report";
	case PH_LIGHT_CLOSE: return "light close";
	}
	return "?";
}

static gboolean sample_timeout(gpointer data)
{
	struct daemon *d = data;

	d->sample_timeout_id = 0;
	fail_add(d, "timed out after %u s during %s", d->sample_timeout_s,
		 phase_name(d->phase));

	/* a partial magnetometer average is still a reading */
	if (!d->mag_ok && d->mag_n > 0) {
		d->mag_ok = true;
		d->mag_x = (float)(d->mag_sx / d->mag_n);
		d->mag_z = (float)(d->mag_sz / d->mag_n);
	}
	fail_report(d);
	step_and_publish(d, true);
	d->abandoned = true;

	/* a sensor left open waiting for a report is closed now; a phase
	 * with a callback in flight closes from that callback */
	if (d->phase == PH_MAG_COLLECT) {
		d->phase = PH_MAG_CLOSE;
		sample_advance(d);
	} else if (d->phase == PH_LIGHT_COLLECT) {
		d->phase = PH_LIGHT_CLOSE;
		sample_advance(d);
	}
	return G_SOURCE_REMOVE;
}

static void sample_start(struct daemon *d)
{
	if (d->sampling) {
		d->rerun = true;
		/* the sensors are known slow: do not hold the hard signals */
		if (d->abandoned || d->phase == PH_WAIT_SENSORS)
			step_and_publish(d, false);
		return;
	}
	d->sampling = true;
	d->abandoned = false;
	d->rerun = false;
	d->mag_n = 0;
	d->mag_sx = 0.0;
	d->mag_sz = 0.0;
	d->mag_ok = false;
	d->light_ok = false;
	d->fail[0] = '\0';
	d->sample_timeout_id = g_timeout_add_seconds(d->sample_timeout_s,
						     sample_timeout, d);
	if (ensure_sensors(d)) {
		d->phase = PH_WAIT_SENSORS;
		return;
	}
	d->phase = PH_IDLE;
	sample_advance(d);
}

/* ------------------------------------------------------------------ */
/* triggers                                                           */

static gboolean trigger_fire(gpointer data)
{
	struct daemon *d = data;

	d->trigger_id = 0;
	sample_start(d);
	return G_SOURCE_REMOVE;
}

static void trigger(struct daemon *d, const char *reason)
{
	d->trigger_reason = reason;
	if (d->trigger_id)
		return;
	d->trigger_id = g_timeout_add(TRIGGER_DEBOUNCE_MS, trigger_fire, d);
}

static gboolean heartbeat(gpointer data)
{
	struct daemon *d = data;

	d->heartbeat_id = 0;
	trigger(d, "heartbeat");
	return G_SOURCE_REMOVE;
}

/* One-shot, re-armed after every publish for the context in force. */
static void arm_heartbeat(struct daemon *d)
{
	unsigned s;

	if (d->once)
		return;
	if (d->heartbeat_id) {
		g_source_remove(d->heartbeat_id);
		d->heartbeat_id = 0;
	}
	s = d->last.context == FOLIO_CTX_ATTACHED ? d->attached_heartbeat_s
						  : d->heartbeat_s;
	if (s > 0)
		d->heartbeat_id = g_timeout_add_seconds(s, heartbeat, d);
}

static gboolean on_usr1(gpointer data)
{
	trigger(data, "SIGUSR1");
	return G_SOURCE_CONTINUE;
}

/* ------------------------------------------------------------------ */
/* inputs                                                             */

static void gpio_drop(struct daemon *d)
{
	if (d->gpio_watch) {
		g_source_remove(d->gpio_watch);
		d->gpio_watch = 0;
	}
	if (d->gpio) {
		libevdev_free(d->gpio);
		d->gpio = NULL;
	}
	if (d->gpio_fd >= 0) {
		close(d->gpio_fd);
		d->gpio_fd = -1;
	}
}

static bool handle_sw(struct daemon *d, const struct input_event *ev)
{
	if (ev->type != EV_SW)
		return false;
	if (ev->code == SW_PEN_INSERTED && d->hard.hall23 != !!ev->value) {
		d->hard.hall23 = !!ev->value;
		return true;
	}
	if (ev->code == SW_MACHINE_COVER && d->hard.hall169 != !!ev->value) {
		d->hard.hall169 = !!ev->value;
		return true;
	}
	return false;
}

static gboolean gpio_readable(gint fd, GIOCondition cond, gpointer data)
{
	struct daemon *d = data;
	struct input_event ev;
	bool changed = false;
	int rc;

	(void)fd;
	if (cond & (G_IO_ERR | G_IO_HUP)) {
		logmsg("%s went away", GPIO_KEYS_NAME);
		d->gpio_watch = 0;
		gpio_drop(d);
		schedule_rescan(d);
		return G_SOURCE_REMOVE;
	}
	for (;;) {
		rc = libevdev_next_event(d->gpio, LIBEVDEV_READ_FLAG_NORMAL, &ev);
		if (rc == LIBEVDEV_READ_STATUS_SUCCESS) {
			changed |= handle_sw(d, &ev);
		} else if (rc == LIBEVDEV_READ_STATUS_SYNC) {
			while (rc == LIBEVDEV_READ_STATUS_SYNC) {
				changed |= handle_sw(d, &ev);
				rc = libevdev_next_event(d->gpio,
							 LIBEVDEV_READ_FLAG_SYNC, &ev);
			}
		} else if (rc == -EAGAIN) {
			break;
		} else {
			logmsg("%s read failed: %s", GPIO_KEYS_NAME, strerror(-rc));
			d->gpio_watch = 0;
			gpio_drop(d);
			schedule_rescan(d);
			return G_SOURCE_REMOVE;
		}
	}
	if (changed)
		trigger(d, "hall switch");
	return G_SOURCE_CONTINUE;
}

static void gpio_adopt(struct daemon *d, int fd, struct libevdev *dev)
{
	gpio_drop(d);
	d->gpio_fd = fd;
	d->gpio = dev;
	if (libevdev_has_event_code(dev, EV_SW, SW_PEN_INSERTED))
		d->hard.hall23 = libevdev_get_event_value(dev, EV_SW, SW_PEN_INSERTED);
	if (libevdev_has_event_code(dev, EV_SW, SW_MACHINE_COVER))
		d->hard.hall169 = libevdev_get_event_value(dev, EV_SW, SW_MACHINE_COVER);
	if (!d->once)
		d->gpio_watch = g_unix_fd_add(fd, G_IO_IN | G_IO_ERR | G_IO_HUP,
					      gpio_readable, d);
}

/* Walk /dev/input/event*, note the keyboard, (re)open gpio-keys and read
 * the switch levels. Returns true when a hard signal changed. */
static bool scan_inputs(struct daemon *d)
{
	struct folio_input before = d->hard;
	DIR *dir = opendir(INPUT_DIR);
	struct dirent *de;
	bool keyboard = false;
	bool gpio_found = false;

	if (!dir) {
		logmsg("cannot open %s: %s", INPUT_DIR, strerror(errno));
		return false;
	}
	while ((de = readdir(dir))) {
		char path[PATH_MAX];
		struct libevdev *dev = NULL;
		const char *name;
		int fd, rc;

		if (strncmp(de->d_name, "event", 5) != 0)
			continue;
		snprintf(path, sizeof(path), "%s/%s", INPUT_DIR, de->d_name);
		fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0)
			continue;
		rc = libevdev_new_from_fd(fd, &dev);
		if (rc < 0) {
			close(fd);
			continue;
		}
		name = libevdev_get_name(dev);
		if (name && strncmp(name, KEYBOARD_PREFIX, strlen(KEYBOARD_PREFIX)) == 0)
			keyboard = true;
		if (name && strcmp(name, GPIO_KEYS_NAME) == 0 && !gpio_found) {
			gpio_found = true;
			gpio_adopt(d, fd, dev);
			continue;
		}
		libevdev_free(dev);
		close(fd);
	}
	closedir(dir);

	if (!gpio_found) {
		if (d->gpio)
			logmsg("%s disappeared", GPIO_KEYS_NAME);
		gpio_drop(d);
	}
	d->hard.keyboard_present = keyboard;

	if (!d->hard_known) {
		d->hard_known = true;
		logmsg("inputs: keyboard %s, %s %s, hall23 %d, hall169 %d",
		       keyboard ? "present" : "absent", GPIO_KEYS_NAME,
		       gpio_found ? "found" : "missing", d->hard.hall23,
		       d->hard.hall169);
		return true;
	}
	return before.keyboard_present != d->hard.keyboard_present ||
	       before.hall23 != d->hard.hall23 ||
	       before.hall169 != d->hard.hall169;
}

static gboolean rescan_fire(gpointer data)
{
	struct daemon *d = data;

	d->rescan_id = 0;
	if (scan_inputs(d))
		trigger(d, "input device change");
	return G_SOURCE_REMOVE;
}

static void schedule_rescan(struct daemon *d)
{
	if (d->rescan_id)
		return;
	d->rescan_id = g_timeout_add(RESCAN_DEBOUNCE_MS, rescan_fire, d);
}

static void dir_changed(GFileMonitor *mon, GFile *file, GFile *other,
			GFileMonitorEvent event, gpointer data)
{
	struct daemon *d = data;
	g_autofree char *base = NULL;

	(void)mon;
	(void)other;
	base = g_file_get_basename(file);
	if (!base || strncmp(base, "event", 5) != 0)
		return;
	if (event == G_FILE_MONITOR_EVENT_CREATED ||
	    event == G_FILE_MONITOR_EVENT_DELETED ||
	    event == G_FILE_MONITOR_EVENT_ATTRIBUTE_CHANGED)
		schedule_rescan(d);
}

static int monitor_start(struct daemon *d)
{
	g_autoptr(GFile) dir = g_file_new_for_path(INPUT_DIR);
	GError *err = NULL;

	d->monitor = g_file_monitor_directory(dir, G_FILE_MONITOR_NONE, NULL, &err);
	if (!d->monitor) {
		logmsg("cannot watch %s: %s", INPUT_DIR, err ? err->message : "unknown");
		g_clear_error(&err);
		return -1;
	}
	g_signal_connect(d->monitor, "changed", G_CALLBACK(dir_changed), d);
	return 0;
}

/* ------------------------------------------------------------------ */

static gboolean on_signal(gpointer data)
{
	struct daemon *d = data;

	logmsg("stopping");
	g_main_loop_quit(d->loop);
	return G_SOURCE_REMOVE;
}

static void usage(FILE *out)
{
	fprintf(out, "usage: foliod [--once]\n"
		     "  --once  sample the inputs, print the classification and exit\n");
}

int main(int argc, char **argv)
{
	struct daemon d;
	int i;

	memset(&d, 0, sizeof(d));
	d.gpio_fd = -1;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--once") == 0) {
			d.once = true;
		} else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
			usage(stdout);
			return 0;
		} else {
			usage(stderr);
			return 2;
		}
	}

	g_log_set_writer_func(log_writer, NULL, NULL);
	configure(&d);
	d.loop = g_main_loop_new(NULL, FALSE);

	if (!d.once) {
		if (uinput_create(&d) < 0)
			return 1;
		if (monitor_start(&d) < 0)
			return 1;
		g_unix_signal_add(SIGTERM, on_signal, &d);
		g_unix_signal_add(SIGINT, on_signal, &d);
		g_unix_signal_add(SIGUSR1, on_usr1, &d);
		logmsg("heartbeat %u s, %u s while attached, %u magnetometer readings per sample, sample timeout %u s, light veto above %g lux, pen forgotten %s",
		       d.heartbeat_s, d.attached_heartbeat_s, d.mag_samples,
		       d.sample_timeout_s, d.st.cfg.light_veto_lux,
		       d.pen_forgotten_log ? "logged" : "off");
	}

	scan_inputs(&d);
	d.trigger_reason = "start";
	sample_start(&d);

	g_main_loop_run(d.loop);

	gpio_drop(&d);
	if (d.monitor)
		g_object_unref(d.monitor);
	if (d.uinput)
		libevdev_uinput_destroy(d.uinput);
	g_main_loop_unref(d.loop);
	return 0;
}
