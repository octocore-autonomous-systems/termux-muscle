# SPDX-License-Identifier: MPL-2.0
SHELL := bash
CC ?= cc
PKG_CONFIG ?= pkg-config
VERSION := $(strip $(shell cat VERSION))
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Wpedantic
CPPFLAGS += -Isrc -DTM_VERSION='"$(VERSION)"' $(shell $(PKG_CONFIG) --cflags json-c libarchive libcrypto)
LDLIBS += $(shell $(PKG_CONFIG) --libs json-c libarchive libcrypto)
SOURCES := $(wildcard src/*.c)
OBJECTS := $(patsubst src/%.c,build/%.o,$(SOURCES))
LIB_OBJECTS := $(filter-out build/main.o,$(OBJECTS))
UNIT_SOURCES := $(wildcard tests/test_*.c)
UNITS := $(patsubst tests/%.c,build/tests/%,$(UNIT_SOURCES))
# Preserve literal dollars in destination paths instead of interpreting Make syntax.
override DESTDIR := $(value DESTDIR)
export DESTDIR

.PHONY: all check check-deps stage clean dist release
all: build/tm-core

check-deps:
	@command -v $(CC) >/dev/null || { echo 'A C11 compiler is required (Termux package: clang).' >&2; exit 1; }
	@$(PKG_CONFIG) --exists json-c libarchive libcrypto || { echo 'Install json-c, libarchive, openssl and pkg-config development files.' >&2; exit 1; }

build/%.o: src/%.c src/tm.h | check-deps
	@mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@

build/tm-core: $(OBJECTS) | check-deps
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) $(OBJECTS) $(LDLIBS) -o $@

build/tests/%: tests/%.c $(LIB_OBJECTS) src/tm.h | check-deps
	@mkdir -p build/tests
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) $< $(LIB_OBJECTS) $(LDLIBS) -o $@

check: all $(UNITS)
	@bash tests/run.sh

# Only stage into a fresh explicit destination; the CLI owns installation.
stage: all
	@bash -eu -c 'test -n "$${DESTDIR:-}" || { echo "DESTDIR must name a private staging directory" >&2; exit 1; }; case "$$DESTDIR" in /|.|..) exit 1;; esac; test ! -L "$$DESTDIR"; if test -d "$$DESTDIR"; then shopt -s nullglob dotglob; entries=("$$DESTDIR"/*); test "$${#entries[@]}" -eq 0 || { echo "DESTDIR must be empty" >&2; exit 1; }; fi; mkdir -p "$$DESTDIR/libexec"; cp -R bin lib docs "$$DESTDIR/"; cp build/tm-core "$$DESTDIR/libexec/tm-core"; cp VERSION compatibility.json README.md CONTRIBUTING.md LICENSE CREDITS.md "$$DESTDIR/"; chmod 755 "$$DESTDIR/bin/termux-muscle" "$$DESTDIR/libexec/tm-core"'

dist: all
	@bash scripts/build_release.sh --output dist

release: check
	@bash scripts/build_release.sh --output dist --release

clean:
	rm -rf build

-include $(OBJECTS:.o=.d)
