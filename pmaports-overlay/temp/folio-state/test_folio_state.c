/*
 * test_folio_state.c - host test for the folio classifier.
 *
 * Feeds the seven rows measured on 2026-09-22 (issue #33) through
 * folio_state_step in the order an operator would produce them and checks
 * each classification, the pen-forgotten edge and the light veto. Builds
 * with any C11 compiler: `make check`.
 *
 * SPDX-License-Identifier: MIT
 */
#include "folio_state.h"

#include <stdio.h>
#include <stdlib.h>

/* 2026-09-22 rows: X, Z. Y is not used by the classifier. */
#define BARE_X 206.0f
#define BARE_Z 133.0f
#define BARE_PEN_X 158.0f
#define BARE_PEN_Z 359.0f
#define BARE_REV_X 158.0f
#define BARE_REV_Z 100.0f
#define DOCK_X 289.0f
#define DOCK_Z -305.0f
#define DOCK_PEN_X 229.0f
#define DOCK_PEN_Z -38.0f
#define CLOSED_X 209.0f
#define CLOSED_Z -477.0f
#define CLOSED_HOLDER_X 214.0f
#define CLOSED_HOLDER_Z -462.0f
#define LIGHT_OPEN 5.0f
#define LIGHT_CLOSED 0.0f

static int failures;
static int checks;

#define CHECK(cond) do { \
	checks++; \
	if (!(cond)) { \
		failures++; \
		fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
	} \
} while (0)

static struct folio_state st;

static struct folio_output step(bool kb, bool h23, bool h169,
				float x, float z, bool light_valid, float lux)
{
	struct folio_input in = {
		.keyboard_present = kb,
		.hall23 = h23,
		.hall169 = h169,
		.mag_valid = true,
		.mag_x = x,
		.mag_z = z,
		.light_valid = light_valid,
		.light_lux = lux,
	};
	struct folio_output out;

	folio_state_step(&st, &in, &out);
	return out;
}

static struct folio_output step_nomag(bool kb, bool h23, bool h169)
{
	struct folio_input in = {
		.keyboard_present = kb,
		.hall23 = h23,
		.hall169 = h169,
	};
	struct folio_output out;

	folio_state_step(&st, &in, &out);
	return out;
}

static void reset(void)
{
	struct folio_config cfg;

	folio_config_defaults(&cfg);
	folio_state_init(&st, &cfg);
}

/* Bare tablet on the desk: pen away, on the strip, reversed, away. */
static void test_bare_pen(void)
{
	struct folio_output o;

	reset();
	o = step(false, false, false, BARE_X, BARE_Z, true, LIGHT_OPEN);
	CHECK(o.context == FOLIO_CTX_BARE);
	CHECK(!o.lid_closed && !o.pen_docked && !o.pen_reversed);
	CHECK(st.bare.learned && st.bare.z == BARE_Z);

	o = step(false, false, false, BARE_PEN_X, BARE_PEN_Z, true, LIGHT_OPEN);
	CHECK(!o.lid_closed && o.pen_docked && !o.pen_reversed);

	/* reversed needs two consecutive samples */
	o = step(false, false, false, BARE_REV_X, BARE_REV_Z, true, LIGHT_OPEN);
	CHECK(!o.lid_closed && !o.pen_docked && !o.pen_reversed);
	o = step(false, false, false, BARE_REV_X, BARE_REV_Z, true, LIGHT_OPEN);
	CHECK(!o.lid_closed && !o.pen_docked && o.pen_reversed);

	o = step(false, false, false, BARE_X, BARE_Z, true, LIGHT_OPEN);
	CHECK(!o.lid_closed && !o.pen_docked && !o.pen_reversed);
	CHECK(!o.pen_forgotten);
}

/* One reversed-looking sample is published as no pen and does not stop
 * the baseline from learning; two in a row do. */
static void test_reversed_streak(void)
{
	struct folio_output o;
	float z_after_one;

	reset();
	step(false, false, false, BARE_X, BARE_Z, true, LIGHT_OPEN);
	o = step(false, false, false, BARE_REV_X, BARE_REV_Z, true, LIGHT_OPEN);
	CHECK(!o.pen_reversed);
	z_after_one = st.bare.z;
	CHECK(z_after_one < BARE_Z && z_after_one > BARE_REV_Z);
	o = step(false, false, false, BARE_REV_X, BARE_REV_Z, true, LIGHT_OPEN);
	CHECK(o.pen_reversed);
	CHECK(st.bare.z == z_after_one);
	/* a no-pen sample in between resets the streak */
	step(false, false, false, BARE_X, BARE_Z, true, LIGHT_OPEN);
	o = step(false, false, false, BARE_REV_X, BARE_REV_Z, true, LIGHT_OPEN);
	CHECK(!o.pen_reversed);
}

/* Bare with the pen already on the strip at the first sample: the seed
 * baseline classifies it and the baseline is learned only once the pen
 * comes off. */
static void test_bare_pen_first(void)
{
	struct folio_output o;

	reset();
	o = step(false, false, false, BARE_PEN_X, BARE_PEN_Z, true, LIGHT_OPEN);
	CHECK(o.pen_docked && !st.bare.learned);
	o = step(false, false, false, BARE_X, BARE_Z, true, LIGHT_OPEN);
	CHECK(!o.pen_docked && st.bare.learned);
}

/* Dock the tablet, pen on and off the strip while docked. */
static void test_docked_pen(void)
{
	struct folio_output o;

	reset();
	step(false, false, false, BARE_X, BARE_Z, true, LIGHT_OPEN);

	/* hall 23 read both ways while docked; neither may matter */
	o = step(true, true, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);
	CHECK(o.context == FOLIO_CTX_DOCKED);
	CHECK(!o.lid_closed && !o.pen_docked);
	CHECK(st.docked.learned && st.docked.z == DOCK_Z);

	o = step(true, false, false, DOCK_PEN_X, DOCK_PEN_Z, true, LIGHT_OPEN);
	CHECK(!o.lid_closed && o.pen_docked);

	o = step(true, true, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);
	CHECK(!o.lid_closed && !o.pen_docked);
}

/* Close the folio with the pen away: closed, and pen forgotten fires once. */
static void test_close_pen_forgotten(void)
{
	struct folio_output o;

	reset();
	step(true, false, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);

	o = step(false, true, false, CLOSED_X, CLOSED_Z, true, LIGHT_CLOSED);
	CHECK(o.context == FOLIO_CTX_ATTACHED);
	CHECK(o.lid_closed);
	CHECK(!o.pen_docked);
	CHECK(o.pen_forgotten);

	/* heartbeat while closed: no second edge */
	o = step(false, true, false, CLOSED_X, CLOSED_Z, true, LIGHT_CLOSED);
	CHECK(o.lid_closed && !o.pen_forgotten);

	/* pen slid into the holder while closed: still closed, no edge */
	o = step(false, true, false, CLOSED_HOLDER_X, CLOSED_HOLDER_Z, true, LIGHT_CLOSED);
	CHECK(o.lid_closed && !o.pen_forgotten);

	/* open and dock again */
	o = step(true, false, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);
	CHECK(!o.lid_closed && !o.pen_forgotten);
}

/* Close the folio with the pen on the strip: closed, no pen forgotten. */
static void test_close_with_pen(void)
{
	struct folio_output o;

	reset();
	step(true, false, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);
	o = step(true, false, false, DOCK_PEN_X, DOCK_PEN_Z, true, LIGHT_OPEN);
	CHECK(o.pen_docked);

	o = step(false, true, false, CLOSED_X, CLOSED_Z, true, LIGHT_CLOSED);
	CHECK(o.lid_closed);
	CHECK(!o.pen_forgotten);
	/* the closed rows cannot see the strip: the pen holds */
	CHECK(o.pen_docked);
}

/* Pen moved from the strip to the holder before closing: the last open
 * sample saw no pen, so the edge fires. ADR-002 leaves the 15 microtesla
 * holder difference unused. */
static void test_close_pen_in_holder(void)
{
	struct folio_output o;

	reset();
	step(true, false, false, DOCK_PEN_X, DOCK_PEN_Z, true, LIGHT_OPEN);
	step(true, false, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);
	o = step(false, true, false, CLOSED_HOLDER_X, CLOSED_HOLDER_Z, true, LIGHT_CLOSED);
	CHECK(o.lid_closed && o.pen_forgotten);
}

/* A light reading of 5 vetoes closed; 0 lets it through. */
static void test_light_veto(void)
{
	struct folio_output o;

	reset();
	step(true, false, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);

	o = step(false, true, false, CLOSED_X, CLOSED_Z, true, LIGHT_OPEN);
	CHECK(o.context == FOLIO_CTX_ATTACHED);
	CHECK(!o.lid_closed);
	CHECK(!o.pen_forgotten);

	o = step(false, true, false, CLOSED_X, CLOSED_Z, true, LIGHT_CLOSED);
	CHECK(o.lid_closed);
	CHECK(o.pen_forgotten);

	/* no light sample at all: the magnetometer decides */
	o = step(false, true, false, CLOSED_X, CLOSED_Z, false, 0.0f);
	CHECK(o.lid_closed);
}

/* Attached and lifted off the pins, open. Unmeasured row: ADR-002 expects
 * it near the docked-open reading and above -400 on Z. */
static void test_attached_open(void)
{
	struct folio_output o;

	reset();
	step(true, false, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);
	o = step(false, true, false, DOCK_X, DOCK_Z - 20.0f, true, LIGHT_OPEN);
	CHECK(o.context == FOLIO_CTX_ATTACHED);
	CHECK(!o.lid_closed);
	CHECK(st.attached.learned);

	o = step(false, true, false, CLOSED_X, CLOSED_Z, true, LIGHT_CLOSED);
	CHECK(o.lid_closed);
}

/* Daemon restarted while the folio is closed: the seed baseline classifies
 * closed, and pen forgotten cannot fire because no open sample was seen. */
static void test_start_closed(void)
{
	struct folio_output o;

	reset();
	o = step(false, true, false, CLOSED_X, CLOSED_Z, true, LIGHT_CLOSED);
	CHECK(o.lid_closed && !o.pen_forgotten);
	o = step(true, false, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);
	CHECK(!o.lid_closed);
}

/* Hall 169: the plain Book Cover magnet forces closed in any context. */
static void test_hall169(void)
{
	struct folio_output o;

	reset();
	step(false, false, false, BARE_X, BARE_Z, true, LIGHT_OPEN);
	o = step(false, false, true, BARE_X, BARE_Z, true, LIGHT_OPEN);
	CHECK(o.lid_closed && o.pen_forgotten);
	o = step(false, false, false, BARE_X, BARE_Z, true, LIGHT_OPEN);
	CHECK(!o.lid_closed);
}

/* SLPI down: keyboard and hall 23 clear still mean open, the pen holds,
 * and hall 23 asserted means closed only once fallback_after samples in
 * a row have failed. */
static void test_no_magnetometer(void)
{
	struct folio_output o;

	reset();
	o = step(false, false, false, BARE_PEN_X, BARE_PEN_Z, true, LIGHT_OPEN);
	CHECK(o.pen_docked);

	o = step_nomag(true, true, false);
	CHECK(!o.lid_closed && o.pen_docked);
	o = step_nomag(false, true, false);
	CHECK(!o.lid_closed && o.pen_docked);
	o = step_nomag(false, true, false);
	CHECK(o.lid_closed && o.pen_docked && !o.pen_forgotten);
	o = step_nomag(false, false, false);
	CHECK(!o.lid_closed && o.pen_docked);
}

/* Attached and open, then the sensors miss: the lid holds open for two
 * samples and falls back to closed on the third. */
static void test_fallback_count(void)
{
	struct folio_output o;

	reset();
	step(true, false, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);
	o = step(false, true, false, DOCK_X, DOCK_Z - 20.0f, true, LIGHT_OPEN);
	CHECK(o.context == FOLIO_CTX_ATTACHED && !o.lid_closed);

	o = step_nomag(false, true, false);
	CHECK(!o.lid_closed);
	o = step_nomag(false, true, false);
	CHECK(!o.lid_closed);
	o = step_nomag(false, true, false);
	CHECK(o.lid_closed);

	/* a good sample resets the count */
	o = step(false, true, false, DOCK_X, DOCK_Z - 20.0f, true, LIGHT_OPEN);
	CHECK(!o.lid_closed);
	o = step_nomag(false, true, false);
	CHECK(!o.lid_closed);
}

/* No magnetometer object at all: the fallback applies at once. */
static void test_sensors_absent(void)
{
	struct folio_input in = { .hall23 = true, .sensors_absent = true };
	struct folio_output o;

	reset();
	step(true, false, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);
	folio_state_step(&st, &in, &o);
	CHECK(o.context == FOLIO_CTX_ATTACHED && o.lid_closed);
}

/* A sample outside baseline_window of the seed is never a baseline, and
 * the closed reading that follows still reads closed. */
static void test_baseline_window(void)
{
	struct folio_output o;

	reset();
	step(true, false, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);

	/* -400 against seed -305: a closed reading, not a baseline */
	o = step(false, true, false, CLOSED_X, -400.0f, true, LIGHT_CLOSED);
	CHECK(o.lid_closed && !st.attached.learned);
	o = step(false, true, false, CLOSED_X, CLOSED_Z, true, LIGHT_CLOSED);
	CHECK(o.lid_closed);

	/* -100 classifies open but sits 205 from the seed: rejected */
	reset();
	step(true, false, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);
	o = step(false, true, false, DOCK_X, -100.0f, true, LIGHT_OPEN);
	CHECK(!o.lid_closed && !st.attached.learned && st.attached.z == DOCK_Z);
	o = step(false, true, false, CLOSED_X, CLOSED_Z, true, LIGHT_CLOSED);
	CHECK(o.lid_closed);
}

/* A learned baseline follows slow drift with weight 1/8. */
static void test_baseline_drift(void)
{
	struct folio_output o;
	int i;

	reset();
	step(true, false, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);
	CHECK(st.docked.z == DOCK_Z);
	for (i = 0; i < 20; i++)
		step(true, false, false, DOCK_X, DOCK_Z + 40.0f, true, LIGHT_OPEN);
	CHECK(st.docked.z > DOCK_Z + 35.0f && st.docked.z < DOCK_Z + 40.0f);
	/* the pen threshold moved with it */
	o = step(true, false, false, DOCK_PEN_X, DOCK_PEN_Z, true, LIGHT_OPEN);
	CHECK(o.pen_docked);
}

/* The bare baseline is re-learned after a trip through the dock. */
static void test_relearn(void)
{
	struct folio_output o;

	reset();
	step(false, false, false, BARE_X, BARE_Z, true, LIGHT_OPEN);
	step(true, false, false, DOCK_X, DOCK_Z, true, LIGHT_OPEN);
	CHECK(st.bare.learned);
	o = step(false, false, false, BARE_X + 10.0f, BARE_Z + 20.0f, true, LIGHT_OPEN);
	CHECK(!o.pen_docked && !o.pen_reversed);
	CHECK(st.bare.learned && st.bare.z == BARE_Z + 20.0f);
}

int main(void)
{
	test_bare_pen();
	test_bare_pen_first();
	test_docked_pen();
	test_close_pen_forgotten();
	test_close_with_pen();
	test_close_pen_in_holder();
	test_light_veto();
	test_attached_open();
	test_start_closed();
	test_hall169();
	test_no_magnetometer();
	test_fallback_count();
	test_sensors_absent();
	test_baseline_window();
	test_baseline_drift();
	test_reversed_streak();
	test_relearn();

	printf("folio_state: %d checks, %d failures\n", checks, failures);
	return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
