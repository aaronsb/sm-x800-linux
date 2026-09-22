/*
 * foliod - folio, lid and pen state daemon for the Galaxy Tab S8+ (ADR-002).
 *
 * Inputs: the presence of the pogo keyboard input device, the two
 * gpio-keys hall switches, and on every input transition and on a slow
 * heartbeat one magnetometer and one light sample through libssc. The
 * classifier in folio_state.c turns those into lid and pen state, which
 * this daemon publishes on a uinput device named "folio-state" carrying
 * SW_LID and SW_PEN_INSERTED. Every state change and every pen-forgotten
 * edge is logged to stderr, which the unit sends to the journal.
 *
 * Sensors are opened, read and closed per sample, so the SLPI is not kept
 * streaming (issue #46). The libssc calls are the asynchronous ones: when
 * hexagonrpcd is not serving, libssc retries sensor discovery once a
 * second for 100 s inside its synchronous wrappers, and a lid change must
 * not wait on that. A sample that does not complete within
 * SAMPLE_TIMEOUT_S is abandoned and the classifier runs on the hard
 * signals alone; the next trigger tries the sensors again.
 *
 * Settings come from the environment, and from /etc/conf.d/folio-state
 * for any key the environment does not set: HEARTBEAT_S, LIGHT_VETO_LUX,
 * PEN_DZ_BARE, PEN_DZ_DOCKED, REVERSED_DZ, REVERSED_DX, CLOSED_DZ,
 * BASE_Z_BARE, BASE_X_BARE, BASE_Z_DOCKED, MAG_SAMPLES, SAMPLE_TIMEOUT_S.
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

struct sample;

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

	struct sample *job;
	bool rerun;

	unsigned heartbeat_s;
	unsigned mag_samples;
	unsigned sample_timeout_s;

	bool once;
	GMainLoop *loop;
	int exit_code;

	bool published;
	struct folio_output last;
};

/* One sensor sample: magnetometer, then light. */
struct sample {
	struct daemon *d;
	bool abandoned;		/* timed out, callbacks only clean up */
	int inflight;		/* async calls not yet answered */
	guint timeout_id;
	const char *phase;

	SSCSensorMagnetometer *mag;
	gulong mag_sig;
	bool mag_open;
	unsigned mag_n;
	double mag_sx;
	double mag_sz;
	bool mag_ok;
	float mag_x;
	float mag_z;

	SSCSensorLight *light;
	gulong light_sig;
	bool light_open;
	bool light_ok;
	float light_lux;
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
static void schedule_rescan(struct daemon *d);

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
	d->mag_samples = 3;
	d->sample_timeout_s = 10;
	env_uint("HEARTBEAT_S", &d->heartbeat_s);
	env_uint("MAG_SAMPLES", &d->mag_samples);
	env_uint("SAMPLE_TIMEOUT_S", &d->sample_timeout_s);
	if (d->mag_samples == 0)
		d->mag_samples = 1;
	if (d->sample_timeout_s == 0)
		d->sample_timeout_s = 1;
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

static void step_and_publish(struct daemon *d, const struct sample *s)
{
	struct folio_input in = d->hard;
	struct folio_output o;

	in.mag_valid = s && s->mag_ok;
	in.mag_x = in.mag_valid ? s->mag_x : 0.0f;
	in.mag_z = in.mag_valid ? s->mag_z : 0.0f;
	in.light_valid = s && s->light_ok;
	in.light_lux = in.light_valid ? s->light_lux : 0.0f;

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
	if (o.pen_forgotten)
		logmsg("pen forgotten: lid closed and the last open sample saw no pen on the strip");

	publish(d, &o);
	d->last = o;
	d->published = true;

	if (d->rerun) {
		d->rerun = false;
		sample_start(d);
	}
}

/* ------------------------------------------------------------------ */
/* sensor sample                                                      */

static void sample_maybe_free(struct sample *s)
{
	if (!s->abandoned || s->inflight > 0 || s->mag || s->light)
		return;
	g_free(s);
}

static void sample_done(struct sample *s)
{
	struct daemon *d = s->d;

	if (s->abandoned) {
		sample_maybe_free(s);
		return;
	}
	if (s->timeout_id) {
		g_source_remove(s->timeout_id);
		s->timeout_id = 0;
	}
	d->job = NULL;
	step_and_publish(d, s);
	g_free(s);
}

/* light */

static void light_close_cb(GObject *src, GAsyncResult *res, gpointer data)
{
	struct sample *s = data;
	GError *err = NULL;

	s->inflight--;
	if (!ssc_sensor_light_close_finish(SSC_SENSOR_LIGHT(src), res, &err)) {
		logmsg("light close failed: %s", err ? err->message : "unknown");
		g_clear_error(&err);
	}
	s->light_open = false;
	g_clear_object(&s->light);
	sample_done(s);
}

static void light_close(struct sample *s)
{
	if (s->light_sig) {
		g_signal_handler_disconnect(s->light, s->light_sig);
		s->light_sig = 0;
	}
	s->inflight++;
	s->phase = "light close";
	ssc_sensor_light_close(s->light, NULL, light_close_cb, s);
}

static void light_measurement(SSCSensorLight *sensor, gfloat lux, gpointer data)
{
	struct sample *s = data;

	(void)sensor;
	if (s->abandoned || s->light_ok)
		return;
	s->light_ok = true;
	s->light_lux = lux;
	light_close(s);
}

static void light_open_cb(GObject *src, GAsyncResult *res, gpointer data)
{
	struct sample *s = data;
	GError *err = NULL;
	gboolean ok;

	s->inflight--;
	ok = ssc_sensor_light_open_finish(SSC_SENSOR_LIGHT(src), res, &err);
	if (!ok) {
		logmsg("light open failed: %s", err ? err->message : "unknown");
		g_clear_error(&err);
		if (s->light_sig)
			g_signal_handler_disconnect(s->light, s->light_sig);
		s->light_sig = 0;
		g_clear_object(&s->light);
		sample_done(s);
		return;
	}
	s->light_open = true;
	if (s->abandoned) {
		light_close(s);
		return;
	}
	s->phase = "light report";
	/* now waiting for the measurement signal */
}

static void light_new_cb(GObject *src, GAsyncResult *res, gpointer data)
{
	struct sample *s = data;
	GError *err = NULL;

	(void)src;
	s->inflight--;
	s->light = ssc_sensor_light_new_finish(res, &err);
	if (!s->light) {
		logmsg("light sensor unavailable: %s", err ? err->message : "unknown");
		g_clear_error(&err);
		sample_done(s);
		return;
	}
	if (s->abandoned) {
		g_clear_object(&s->light);
		sample_maybe_free(s);
		return;
	}
	s->light_sig = g_signal_connect(s->light, "measurement",
					G_CALLBACK(light_measurement), s);
	s->inflight++;
	s->phase = "light open";
	ssc_sensor_light_open(s->light, NULL, light_open_cb, s);
}

static void light_start(struct sample *s)
{
	if (s->abandoned) {
		sample_maybe_free(s);
		return;
	}
	s->inflight++;
	s->phase = "light discovery";
	ssc_sensor_light_new(NULL, light_new_cb, s);
}

/* magnetometer */

static void mag_close_cb(GObject *src, GAsyncResult *res, gpointer data)
{
	struct sample *s = data;
	GError *err = NULL;

	s->inflight--;
	if (!ssc_sensor_magnetometer_close_finish(SSC_SENSOR_MAGNETOMETER(src),
						  res, &err)) {
		logmsg("magnetometer close failed: %s", err ? err->message : "unknown");
		g_clear_error(&err);
	}
	s->mag_open = false;
	g_clear_object(&s->mag);
	light_start(s);
}

static void mag_close(struct sample *s)
{
	if (s->mag_sig) {
		g_signal_handler_disconnect(s->mag, s->mag_sig);
		s->mag_sig = 0;
	}
	s->inflight++;
	s->phase = "magnetometer close";
	ssc_sensor_magnetometer_close(s->mag, NULL, mag_close_cb, s);
}

static void mag_measurement(SSCSensorMagnetometer *sensor, gfloat x, gfloat y,
			    gfloat z, gpointer data)
{
	struct sample *s = data;

	(void)sensor;
	(void)y;
	if (s->abandoned || s->mag_ok)
		return;
	s->mag_sx += x;
	s->mag_sz += z;
	s->mag_n++;
	if (s->mag_n < s->d->mag_samples)
		return;
	s->mag_ok = true;
	s->mag_x = (float)(s->mag_sx / s->mag_n);
	s->mag_z = (float)(s->mag_sz / s->mag_n);
	mag_close(s);
}

static void mag_open_cb(GObject *src, GAsyncResult *res, gpointer data)
{
	struct sample *s = data;
	GError *err = NULL;
	gboolean ok;

	s->inflight--;
	ok = ssc_sensor_magnetometer_open_finish(SSC_SENSOR_MAGNETOMETER(src),
						 res, &err);
	if (!ok) {
		logmsg("magnetometer open failed: %s", err ? err->message : "unknown");
		g_clear_error(&err);
		if (s->mag_sig)
			g_signal_handler_disconnect(s->mag, s->mag_sig);
		s->mag_sig = 0;
		g_clear_object(&s->mag);
		light_start(s);
		return;
	}
	s->mag_open = true;
	if (s->abandoned) {
		mag_close(s);
		return;
	}
	s->phase = "magnetometer report";
}

static void mag_new_cb(GObject *src, GAsyncResult *res, gpointer data)
{
	struct sample *s = data;
	GError *err = NULL;

	(void)src;
	s->inflight--;
	s->mag = ssc_sensor_magnetometer_new_finish(res, &err);
	if (!s->mag) {
		logmsg("magnetometer unavailable: %s", err ? err->message : "unknown");
		g_clear_error(&err);
		light_start(s);
		return;
	}
	if (s->abandoned) {
		g_clear_object(&s->mag);
		sample_maybe_free(s);
		return;
	}
	s->mag_sig = g_signal_connect(s->mag, "measurement",
				      G_CALLBACK(mag_measurement), s);
	s->inflight++;
	s->phase = "magnetometer open";
	ssc_sensor_magnetometer_open(s->mag, NULL, mag_open_cb, s);
}

static gboolean sample_timeout(gpointer data)
{
	struct sample *s = data;
	struct daemon *d = s->d;

	s->timeout_id = 0;
	logmsg("sensor sample timed out after %u s during %s; classifying on the hard signals",
	       d->sample_timeout_s, s->phase);

	/* a partial magnetometer average is still a reading */
	if (!s->mag_ok && s->mag_n > 0) {
		s->mag_ok = true;
		s->mag_x = (float)(s->mag_sx / s->mag_n);
		s->mag_z = (float)(s->mag_sz / s->mag_n);
	}
	s->abandoned = true;
	d->job = NULL;
	step_and_publish(d, s);

	/* whatever is still open gets closed by its own callback */
	if (s->mag && s->mag_open && s->inflight == 0)
		mag_close(s);
	if (s->light && s->light_open && s->inflight == 0)
		light_close(s);
	sample_maybe_free(s);
	return G_SOURCE_REMOVE;
}

static void sample_start(struct daemon *d)
{
	struct sample *s;

	if (d->job) {
		d->rerun = true;
		return;
	}
	s = g_new0(struct sample, 1);
	s->d = d;
	d->job = s;
	s->timeout_id = g_timeout_add_seconds(d->sample_timeout_s, sample_timeout, s);
	s->inflight++;
	s->phase = "magnetometer discovery";
	ssc_sensor_magnetometer_new(NULL, mag_new_cb, s);
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
	trigger(data, "heartbeat");
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

	configure(&d);
	d.loop = g_main_loop_new(NULL, FALSE);

	if (!d.once) {
		if (uinput_create(&d) < 0)
			return 1;
		if (monitor_start(&d) < 0)
			return 1;
		g_unix_signal_add(SIGTERM, on_signal, &d);
		g_unix_signal_add(SIGINT, on_signal, &d);
		if (d.heartbeat_s > 0)
			d.heartbeat_id = g_timeout_add_seconds(d.heartbeat_s, heartbeat, &d);
		logmsg("heartbeat %u s, %u magnetometer readings per sample, sample timeout %u s, light veto above %g lux",
		       d.heartbeat_s, d.mag_samples, d.sample_timeout_s,
		       d.st.cfg.light_veto_lux);
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
	return d.exit_code;
}
