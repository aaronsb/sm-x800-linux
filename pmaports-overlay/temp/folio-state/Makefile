# folio-state: foliod daemon and the host test for its classifier.
#
# foliod needs glib, gio, libssc and libevdev. test_folio_state needs only
# a C11 compiler, so `make check` runs on the build host.

CC ?= cc
PKG_CONFIG ?= pkg-config
PREFIX ?= /usr
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra

PKGS = glib-2.0 gio-2.0 libssc libevdev
PKG_CFLAGS = $(shell $(PKG_CONFIG) --cflags $(PKGS))
PKG_LIBS = $(shell $(PKG_CONFIG) --libs $(PKGS))

all: foliod

foliod: foliod.c folio_state.c folio_state.h
	$(CC) $(CFLAGS) $(PKG_CFLAGS) -o $@ foliod.c folio_state.c $(LDFLAGS) $(PKG_LIBS)

test_folio_state: test_folio_state.c folio_state.c folio_state.h
	$(CC) $(CFLAGS) -o $@ test_folio_state.c folio_state.c $(LDFLAGS)

check: test_folio_state
	./test_folio_state

install: foliod
	install -Dm755 foliod $(DESTDIR)$(PREFIX)/bin/foliod

clean:
	rm -f foliod test_folio_state

.PHONY: all check install clean
