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
 * value and is replaced by the first sample the seed classifies as open
 * with no pen, then re-learned the same way after every context change.
 * The attached baseline is seeded from the docked baseline because the
 * attached-open row is unmeasured and closed is derived from docked-open.
 *
 * A light reading above light_veto_lux moves a magnetometer "closed" to
 * the open row of its context. Hall 169 is a hard signal and is not vetoed.
 * While the keyboard is present hall 23 is not consulted.
 *
 * Without a magnetometer sample the classifier runs on the hard signals:
 * keyboard present is open, hall 23 asserted without the keyboard is
 * closed, hall 23 clear is open. The pen cannot be seen and holds its last
 * value. The attached rows and the closed rows also hold the pen, since
 * neither can see the strip.
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
	cfg->reversed_dz = 15.0f;	/* half of -30 */
	cfg->reversed_dx = 25.0f;	/* half of -50 */
	cfg->closed_dz = 85.0f;		/* half of -170 */
	cfg->light_veto_lux = 2.0f;
	cfg->base_z_bare = 133.0f;
	cfg->base_x_bare = 206.0f;
	cfg->base_z_docked = -305.0f;
}

void folio_state_init(struct folio_state *st, const struct folio_config *cfg)
{
	memset(st, 0, sizeof(*st));
	st->cfg = *cfg;
	st->bare.z = cfg->base_z_bare;
	st->bare.x = cfg->base_x_bare;
	st->docked.z = cfg->base_z_docked;
	st->attached.z = cfg->base_z_docked;
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

static void learn(struct folio_baseline *b, float z, float x)
{
	if (b->learned)
		return;
	b->z = z;
	b->x = x;
	b->learned = true;
}

void folio_state_step(struct folio_state *st, const struct folio_input *in,
		      struct folio_output *out)
{
	const struct folio_config *cfg = &st->cfg;
	enum folio_context ctx = pick_context(in);
	struct folio_output o = st->out;
	bool pen_seen = false;	/* this step classified the pen */
	bool mag_closed = false;

	o.pen_forgotten = false;
	o.context = ctx;
	st->last_mag_used = in->mag_valid;
	st->last_dz = 0.0f;
	st->last_dx = 0.0f;

	/* A context change discards the learned baseline of the new context. */
	if (!st->have_prev || ctx != st->prev_context) {
		switch (ctx) {
		case FOLIO_CTX_BARE:
			st->bare.learned = false;
			break;
		case FOLIO_CTX_DOCKED:
			st->docked.learned = false;
			break;
		case FOLIO_CTX_ATTACHED:
			st->attached.z = st->docked.z;
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
				learn(&st->docked, in->mag_z, in->mag_x);
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
			o.pen_reversed = !o.pen_docked &&
					 dz <= -cfg->reversed_dz &&
					 dx <= -cfg->reversed_dx;
			pen_seen = true;
			if (!o.pen_docked && !o.pen_reversed)
				learn(&st->bare, in->mag_z, in->mag_x);
		}
		break;

	case FOLIO_CTX_ATTACHED:
		if (in->mag_valid) {
			float dz = in->mag_z - st->attached.z;

			st->last_dz = dz;
			st->last_base_z = st->attached.z;
			mag_closed = dz <= -cfg->closed_dz;
		} else {
			/* hard-signal fallback: no keyboard and a magnet at tlmm 23 */
			mag_closed = true;
		}
		/* a vetoed "closed" is still a closed reading, not a baseline */
		if (in->mag_valid && !mag_closed)
			learn(&st->attached, in->mag_z, in->mag_x);
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
