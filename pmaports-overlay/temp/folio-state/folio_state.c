/*
 * folio_state.c - folio, lid and pen classifier (ADR-002).
 *
 * Two hard signals pick the context, the magnetometer decides inside it,
 * the light sensor can only veto "closed". Readings are the 2026-09-22
 * table from issue #33, raw microtesla, tablet landscape on one desk:
 *
 *   state                                        X     Y     Z
 *   bare, pen away                              206   113   133
 *   bare, pen on the back strip, correct        158   117   359
 *   bare, pen on the back strip, reversed       158   122   100
 *   in folio, open, docked, pen away            289   211  -305
 *   in folio, open, docked, pen on the strip    229   169   -38
 *   folio closed, pen away                      209   187  -477
 *   folio closed, pen in the folio holder       214   174  -462
 *
 * Classification, one context at a time:
 *
 *   context                          test                          state
 *   hall 169 asserted                any                           plain cover closed
 *   keyboard present                 dZ >= pen_dz_docked           lid open, pen docked
 *   keyboard present                 otherwise                     lid open, no pen
 *   keyboard absent, hall 23 set     dZ <= -closed_dz              lid closed
 *   keyboard absent, hall 23 set     otherwise                     attached, off the pins, open
 *   keyboard absent, hall 23 clear   dZ >= pen_dz_bare             bare, pen docked
 *   keyboard absent, hall 23 clear   dZ <= -reversed_dz and
 *                                    dX <= -reversed_dx            bare, pen reversed
 *   keyboard absent, hall 23 clear   otherwise                     bare, no pen
 *
 * dZ and dX are the sample minus the context's baseline. The clear-air
 * total moved from 147 to 270 microtesla across two days on this sensor,
 * so absolute numbers are only seeds: each baseline starts at the table
 * value, is set by the first sample the seed classifies as open with no
 * pen, and from then on follows such samples with an exponential moving
 * average of weight 1/8, so slow drift is tracked. A sample farther than
 * baseline_window from the seed on Z is never learned, so a transitional
 * reading during a lift cannot become the baseline. A context change
 * starts the learning over. The attached baseline is seeded from the
 * docked baseline because the attached-open row is unmeasured and closed
 * is derived from docked-open.
 *
 * The reversed verdict has the thinnest margin, 33 on Z and 48 on X
 * against a 50 microtesla rotation effect, so it needs two consecutive
 * samples before it is published or stops the baseline from learning.
 *
 * A light reading above light_veto_lux moves a magnetometer "closed" to
 * the open row of its context. Hall 169 is a hard signal and is not vetoed.
 * While the keyboard is present hall 23 is not consulted.
 *
 * Without a magnetometer sample the keyboard still means open and hall 23
 * clear still means open. In the attached context the lid holds its last
 * value until fallback_after consecutive samples have failed, or the
 * daemon reports that it has no magnetometer at all; then hall 23 asserted
 * without the keyboard means closed. The pen cannot be seen and holds its
 * last value. The attached rows and the closed rows also hold the pen,
 * since neither can see the strip.
 *
 * pen_forgotten is an edge: true on the step that closes the lid when the
 * last open sample that could see the pen saw none.
 *
 * SPDX-License-Identifier: MIT
 */
#include "folio_state.h"

#include <string.h>

void folio_config_defaults(struct folio_config *cfg)
{
	cfg->pen_dz_bare = 112.0f;	/* half of +225 */
	cfg->pen_dz_docked = 130.0f;	/* half of +265 */
	cfg->reversed_dz = 25.0f;	/* measured -33 */
	cfg->reversed_dx = 40.0f;	/* measured -48 */
	cfg->closed_dz = 85.0f;		/* half of -170 */
	cfg->light_veto_lux = 2.0f;
	cfg->base_z_bare = 133.0f;
	cfg->base_x_bare = 206.0f;
	cfg->base_z_docked = -305.0f;
	cfg->baseline_window = 150.0f;
	cfg->fallback_after = 3;
}

void folio_state_init(struct folio_state *st, const struct folio_config *cfg)
{
	memset(st, 0, sizeof(*st));
	st->cfg = *cfg;
	st->bare.z = cfg->base_z_bare;
	st->bare.x = cfg->base_x_bare;
	st->bare.seed_z = cfg->base_z_bare;
	st->docked.z = cfg->base_z_docked;
	st->docked.seed_z = cfg->base_z_docked;
	st->attached.z = cfg->base_z_docked;
	st->attached.seed_z = cfg->base_z_docked;
	st->last_open_pen = FOLIO_PEN_UNKNOWN;
}

const char *folio_context_name(enum folio_context ctx)
{
	switch (ctx) {
	case FOLIO_CTX_BARE:
		return "bare";
	case FOLIO_CTX_DOCKED:
		return "docked";
	case FOLIO_CTX_ATTACHED:
		return "attached";
	}
	return "?";
}

static enum folio_context pick_context(const struct folio_input *in)
{
	if (in->keyboard_present)
		return FOLIO_CTX_DOCKED;
	if (in->hall23)
		return FOLIO_CTX_ATTACHED;
	return FOLIO_CTX_BARE;
}

/* Feed an open, no-pen sample to a baseline: the first one sets it, later
 * ones move it by an eighth of the difference. Samples too far from the
 * seed are transitional readings and are ignored. */
static void learn(struct folio_baseline *b, float window, float z, float x)
{
	float off = z - b->seed_z;

	if (off > window || off < -window)
		return;
	if (!b->learned) {
		b->z = z;
		b->x = x;
		b->learned = true;
		return;
	}
	b->z += (z - b->z) / 8.0f;
	b->x += (x - b->x) / 8.0f;
}


void folio_state_step(struct folio_state *st, const struct folio_input *in,
		      struct folio_output *out)
{
	const struct folio_config *cfg = &st->cfg;
	enum folio_context ctx = pick_context(in);
	struct folio_output o = st->out;
	bool pen_seen = false;	/* this step classified the pen */
	bool looks_reversed = false;
	bool mag_closed = false;

	o.pen_forgotten = false;
	o.context = ctx;
	st->last_mag_used = in->mag_valid;
	st->last_dz = 0.0f;
	st->last_dx = 0.0f;

	if (in->mag_valid)
		st->failed_streak = 0;
	else
		st->failed_streak++;

	/* A context change discards the learned baseline of the new context. */
	if (!st->have_prev || ctx != st->prev_context) {
		st->reversed_streak = 0;
		switch (ctx) {
		case FOLIO_CTX_BARE:
			st->bare.learned = false;
			break;
		case FOLIO_CTX_DOCKED:
			st->docked.learned = false;
			break;
		case FOLIO_CTX_ATTACHED:
			st->attached.z = st->docked.z;
			st->attached.seed_z = st->docked.z;
			st->attached.learned = false;
			break;
		}
	}

	switch (ctx) {
	case FOLIO_CTX_DOCKED:
		o.lid_closed = false;
		o.pen_reversed = false;
		if (in->mag_valid) {
			float dz = in->mag_z - st->docked.z;

			st->last_dz = dz;
			st->last_base_z = st->docked.z;
			o.pen_docked = dz >= cfg->pen_dz_docked;
			pen_seen = true;
			if (!o.pen_docked)
				learn(&st->docked, cfg->baseline_window,
				      in->mag_z, in->mag_x);
		}
		break;

	case FOLIO_CTX_BARE:
		o.lid_closed = false;
		if (in->mag_valid) {
			float dz = in->mag_z - st->bare.z;
			float dx = in->mag_x - st->bare.x;

			st->last_dz = dz;
			st->last_dx = dx;
			st->last_base_z = st->bare.z;
			o.pen_docked = dz >= cfg->pen_dz_bare;
			looks_reversed = !o.pen_docked &&
					 dz <= -cfg->reversed_dz &&
					 dx <= -cfg->reversed_dx;
			st->reversed_streak = looks_reversed ? st->reversed_streak + 1 : 0;
			o.pen_reversed = st->reversed_streak >= 2;
			pen_seen = true;
			if (!o.pen_docked && !o.pen_reversed)
				learn(&st->bare, cfg->baseline_window,
				      in->mag_z, in->mag_x);
		}
		break;

	case FOLIO_CTX_ATTACHED:
		if (in->mag_valid) {
			float dz = in->mag_z - st->attached.z;

			st->last_dz = dz;
			st->last_base_z = st->attached.z;
			mag_closed = dz <= -cfg->closed_dz;
		} else if (in->sensors_absent ||
			   st->failed_streak >= cfg->fallback_after) {
			/* hard-signal fallback: no keyboard and a magnet at tlmm 23 */
			mag_closed = true;
		} else {
			/* one missed sample is not a lid change */
			mag_closed = st->have_prev && st->out.lid_closed;
		}
		/* a vetoed "closed" is still a closed reading, not a baseline */
		if (in->mag_valid && !mag_closed)
			learn(&st->attached, cfg->baseline_window,
			      in->mag_z, in->mag_x);
		if (mag_closed && in->light_valid &&
		    in->light_lux > cfg->light_veto_lux)
			mag_closed = false;
		o.lid_closed = mag_closed;
		break;
	}

	if (in->hall169)
		o.lid_closed = true;

	if (!o.lid_closed && pen_seen)
		st->last_open_pen = o.pen_docked ? FOLIO_PEN_PRESENT
						 : FOLIO_PEN_ABSENT;

	if (o.lid_closed && !(st->have_prev && st->out.lid_closed) &&
	    st->last_open_pen == FOLIO_PEN_ABSENT)
		o.pen_forgotten = true;

	st->out = o;
	st->out.pen_forgotten = false;
	st->have_prev = true;
	st->prev_context = ctx;
	*out = o;
}
