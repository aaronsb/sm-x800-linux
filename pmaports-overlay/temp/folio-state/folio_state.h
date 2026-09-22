/*
 * folio_state.h - folio, lid and pen classifier for the Galaxy Tab S8+
 * Book Cover Keyboard (ADR-002).
 *
 * Plain C, no GLib or libevdev. The daemon (foliod.c) feeds the hard
 * signals and the sensor samples in; this file decides lid, pen and the
 * pen-forgotten edge. It is unit-tested on the host by test_folio_state.c
 * against the 2026-09-22 readings from issue #33.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef FOLIO_STATE_H
#define FOLIO_STATE_H

#include <stdbool.h>

/*
 * Context: chosen by the two hard signals alone. The magnetometer decides
 * only within a context.
 */
enum folio_context {
	FOLIO_CTX_BARE,		/* keyboard absent, hall 23 clear */
	FOLIO_CTX_DOCKED,	/* keyboard device present (seated on the pogo pins) */
	FOLIO_CTX_ATTACHED,	/* keyboard absent, hall 23 asserted */
};

struct folio_input {
	bool keyboard_present;	/* a "Book Cover Keyboard*" input device exists */
	bool hall23;		/* gpio-keys SW_PEN_INSERTED, tlmm 23, asserted */
	bool hall169;		/* gpio-keys SW_MACHINE_COVER, tlmm 169, asserted */
	bool mag_valid;		/* mag_x and mag_z hold a fresh sample */
	float mag_x;		/* raw magnetometer, microtesla */
	float mag_z;
	bool light_valid;	/* light_lux holds a fresh sample */
	float light_lux;
	bool sensors_absent;	/* the daemon has no magnetometer object at all */
};

struct folio_output {
	bool lid_closed;	/* SW_LID on the virtual device */
	bool pen_docked;	/* SW_PEN_INSERTED on the virtual device */
	bool pen_reversed;	/* pen on the strip, point the wrong way (bare only) */
	bool pen_forgotten;	/* edge: this step closed the lid with no pen on the strip */
	enum folio_context context;
};

/*
 * Thresholds are deltas from a per-context baseline, in microtesla. The
 * defaults are half the differences between rows of the 2026-09-22 table,
 * except the reversed margins, which are widened against the 50 microtesla
 * a rotation moves between axes. The base_* values seed each baseline
 * until a sample re-learns it.
 */
struct folio_config {
	float pen_dz_bare;	/* bare: pen on the strip adds about +225 on Z */
	float pen_dz_docked;	/* docked: about +265 on Z */
	float reversed_dz;	/* bare, reversed pen: about -30 on Z ... */
	float reversed_dx;	/* ... with X down about 50 */
	float closed_dz;	/* closed: about -170 on Z below the attached-open baseline */
	float light_veto_lux;	/* lux strictly above this vetoes lid closed */
	float base_z_bare;	/* 2026-09-22: bare, pen away, Z 133 */
	float base_x_bare;	/* X 206 */
	float base_z_docked;	/* in folio, open, docked, pen away, Z -305 */
	float baseline_window;	/* a baseline may sit at most this far from its seed on Z */
	unsigned fallback_after;	/* consecutive samples without a magnetometer before hall 23 alone means closed */
};

struct folio_baseline {
	float z;
	float x;
	float seed_z;		/* what the baseline started from in this context */
	bool learned;		/* set by the first open, no-pen sample after a context change, then tracked */
};

enum folio_pen_seen {
	FOLIO_PEN_UNKNOWN,
	FOLIO_PEN_ABSENT,
	FOLIO_PEN_PRESENT,
};

struct folio_state {
	struct folio_config cfg;
	struct folio_baseline bare;
	struct folio_baseline docked;
	struct folio_baseline attached;
	bool have_prev;
	enum folio_context prev_context;
	struct folio_output out;	/* last output, pen_forgotten cleared */
	enum folio_pen_seen last_open_pen;	/* pen state at the last open sample that could see it */
	unsigned reversed_streak;	/* consecutive bare samples that look reversed */
	unsigned failed_streak;	/* consecutive steps without a magnetometer sample */
	/* diagnostics from the last step, for --once and the journal */
	float last_dz;
	float last_dx;
	float last_base_z;
	bool last_mag_used;
};

void folio_config_defaults(struct folio_config *cfg);
void folio_state_init(struct folio_state *st, const struct folio_config *cfg);
void folio_state_step(struct folio_state *st, const struct folio_input *in,
		      struct folio_output *out);
const char *folio_context_name(enum folio_context ctx);

#endif
