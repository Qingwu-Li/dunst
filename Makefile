# dunst - Notification-daemon
# See LICENSE file for copyright and license details.

include config.mk

VERSION := "$(shell ./get-version.sh)"

SYSTEMD ?= $(shell $(PKG_CONFIG) --silence-errors ${SYSTEMDAEMON} || echo 0)

ifneq (0,${WAYLAND})
DATA_DIR_WAYLAND_PROTOCOLS ?= $(shell $(PKG_CONFIG) wayland-protocols --variable=pkgdatadir)
DATA_DIR_WAYLAND_PROTOCOLS := ${DATA_DIR_WAYLAND_PROTOCOLS}
ifeq (,${DATA_DIR_WAYLAND_PROTOCOLS})
$(warning "Failed to query $(PKG_CONFIG) for package 'wayland-protocols'!")
endif
endif

LIBS := $(shell $(PKG_CONFIG) --libs   ${pkg_config_packs})
INCS := $(shell $(PKG_CONFIG) --cflags ${pkg_config_packs})

ifneq (clean, $(MAKECMDGOALS))
ifeq ($(and $(INCS),$(LIBS)),)
$(error "$(PKG_CONFIG) failed!")
endif
endif

SYSCONF_FORCE_NEW ?= $(shell [ -f ${DESTDIR}${SYSCONFFILE} ] || echo 1)

ifneq (0,${DUNSTIFY})
DUNSTIFY_CFLAGS  := ${DEFAULT_CFLAGS} ${CFLAGS} ${CPPFLAGS} $(shell $(PKG_CONFIG) --cflags libnotify)
DUNSTIFY_LDFLAGS := ${DEFAULT_LDFLAGS} ${LDFLAGS} $(shell $(PKG_CONFIG) --libs libnotify)
endif

CPPFLAGS := ${DEFAULT_CPPFLAGS} ${CPPFLAGS}
CFLAGS   := ${DEFAULT_CFLAGS} ${CFLAGS} ${INCS} -MMD -MP
LDFLAGS  := ${DEFAULT_LDFLAGS} ${LDFLAGS} ${LIBS}

SRC := $(sort $(shell ${FIND} src/ ! \( -path src/wayland -prune -o -path src/x11 -prune \) -name '*.c'))

ifneq (0,${WAYLAND})
# with Wayland support
CPPFLAGS += -DHAVE_WL_CURSOR_SHAPE -DHAVE_WL_EXT_IDLE_NOTIFY
SRC += $(sort $(shell ${FIND} src/wayland -name '*.c'))
endif

ifneq (0,${X11})
SRC += $(sort $(shell ${FIND} src/x11 -name '*.c'))
endif

ifeq (0,${X11})
ifeq (0,${WAYLAND})
$(error You have to compile at least one output (X11, Wayland))
endif
endif

OBJ := ${SRC:.c=.o}
TEST_SRC := $(sort $(shell ${FIND} test/ -name '*.c'))
TEST_OBJ := $(TEST_SRC:.c=.o)
DEPS := ${SRC:.c=.d} ${TEST_SRC:.c=.d}


.PHONY: all debug
all: doc dunst service

debug: CPPFLAGS += ${CPPFLAGS_DEBUG}
debug: CFLAGS   += ${CFLAGS_DEBUG}
debug: LDFLAGS  += ${LDFLAGS_DEBUG}
debug: all

-include $(DEPS)

${OBJ} ${TEST_OBJ}: Makefile config.mk

DATE_FMT = +%Y-%m-%d
ifdef SOURCE_DATE_EPOCH
	BUILD_DATE ?= $(shell date -u -d "@$(SOURCE_DATE_EPOCH)" "$(DATE_FMT)" 2>/dev/null || date -u -r "$(SOURCE_DATE_EPOCH)" "$(DATE_FMT)" 2>/dev/null || date -u "$(DATE_FMT)")
else
	BUILD_DATE ?= $(shell date "$(DATE_FMT)")
endif
src/dunst.o: src/dunst.c
	${CC} -o $@ -c $< ${CPPFLAGS} ${CFLAGS} \
		-D_CCDATE="${BUILD_DATE}" -D_CFLAGS="$(filter-out $(filter -I%,${INCS}) -fdebug-prefix-map% -fmacro-prefix-map% -ffile-prefix-map%,${CFLAGS})" -D_LDFLAGS="$(filter-out -fdebug-prefix-map% -fmacro-prefix-map% -ffile-prefix-map%,${LDFLAGS})"

%.o: %.c
	${CC} -o $@ -c $< ${CPPFLAGS} ${CFLAGS}

dunst: ${OBJ} main.o
	${CC} -o ${@} ${OBJ} main.o ${CFLAGS} ${LDFLAGS}

ifneq (0,${DUNSTIFY})
all: dunstify
dunstify: dunstify.o
	${CC} -o ${@} dunstify.o ${DUNSTIFY_CFLAGS} ${DUNSTIFY_LDFLAGS}
endif

.PHONY: test test-valgrind test-coverage functional-tests
test: test/test clean-coverage-run
	# Make sure an error code is returned when the test fails
	/usr/bin/env bash -c 'set -euo pipefail;\
	TESTDIR=./test ./test/test -v | ./test/greenest.awk '

test-valgrind: test/test
	TESTDIR=./test ${VALGRIND} \
		--suppressions=.valgrind.suppressions \
		--leak-check=full \
		--show-leak-kinds=definite \
		--errors-for-leak-kinds=definite \
		--num-callers=40 \
		--error-exitcode=123 \
		./test/test -v

test-coverage: CFLAGS += -fprofile-arcs -ftest-coverage -O0
test-coverage: test

test-coverage-report: test-coverage
	mkdir -p docs/internal/coverage
	${GCOVR} \
		-r . \
		--exclude=test \
		--html \
		--html-details \
		-o docs/internal/coverage/index.html

test/%.o: test/%.c src/%.c
	${CC} -o $@ -c $< ${CFLAGS} ${CPPFLAGS}

test/test: ${OBJ} ${TEST_OBJ}
	${CC} -o ${@} ${TEST_OBJ} $(filter-out ${TEST_OBJ:test/%=src/%},${OBJ}) ${CFLAGS} ${LDFLAGS}

functional-tests: dunst dunstify
	PREFIX=. ./test/functional-tests/test.sh

.PHONY: doc doc-doxygen
doc: docs/dunst.1 docs/dunst.5 docs/dunstctl.1 docs/dunstify.1

# Can't dedup this as we need to explicitly provide the name and title text to
# pod2man :(
docs/dunst.1.pod: docs/dunst.1.pod.in
	${SED} "s|@sysconfdir@|${SYSCONFDIR}|" $< > $@
docs/dunst.1: docs/dunst.1.pod
	${POD2MAN} --name=dunst -c "Dunst Reference" --section=1 --release=${VERSION} $< > $@
docs/dunst.5: docs/dunst.5.pod
	${POD2MAN} --name=dunst -c "Dunst Reference" --section=5 --release=${VERSION} $< > $@
docs/dunstctl.1: docs/dunstctl.pod
	${POD2MAN} --name=dunstctl -c "Dunstctl Reference" --section=1 --release=${VERSION} $< > $@
docs/dunstify.1: docs/dunstify.pod
	${POD2MAN} --name=dunstify -c "Dunstify Reference" --section=1 --release=${VERSION} $< > $@

doc-doxygen:
	${DOXYGEN} docs/internal/Doxyfile

.PHONY: service service-dbus service-systemd wayland-protocols
service: service-dbus
service-dbus:
	@${SED} "s|@bindir@|$(BINDIR)|" org.knopwob.dunst.service.in > org.knopwob.dunst.service
ifneq (0,${SYSTEMD})
service: service-systemd
service-systemd:
	@${SED} "s|@bindir@|$(BINDIR)|" dunst.systemd.service.in > dunst.systemd.service
endif

ifneq (0,${WAYLAND})
wayland-protocols: src/wayland/protocols/wlr-layer-shell-unstable-v1.xml src/wayland/protocols/wlr-foreign-toplevel-management-unstable-v1.xml
	# TODO: write this shorter
	mkdir -p src/wayland/protocols
	wayland-scanner private-code ${DATA_DIR_WAYLAND_PROTOCOLS}/stable/xdg-shell/xdg-shell.xml src/wayland/protocols/xdg-shell.h
	wayland-scanner client-header ${DATA_DIR_WAYLAND_PROTOCOLS}/stable/xdg-shell/xdg-shell.xml src/wayland/protocols/xdg-shell-client-header.h
	wayland-scanner client-header src/wayland/protocols/wlr-layer-shell-unstable-v1.xml src/wayland/protocols/wlr-layer-shell-unstable-v1-client-header.h
	wayland-scanner private-code src/wayland/protocols/wlr-layer-shell-unstable-v1.xml src/wayland/protocols/wlr-layer-shell-unstable-v1.h
	wayland-scanner client-header src/wayland/protocols/idle.xml src/wayland/protocols/idle-client-header.h
	wayland-scanner private-code src/wayland/protocols/idle.xml src/wayland/protocols/idle.h
	wayland-scanner client-header src/wayland/protocols/wlr-foreign-toplevel-management-unstable-v1.xml src/wayland/protocols/wlr-foreign-toplevel-management-unstable-v1-client-header.h
	wayland-scanner private-code src/wayland/protocols/wlr-foreign-toplevel-management-unstable-v1.xml src/wayland/protocols/wlr-foreign-toplevel-management-unstable-v1.h
	# wayland-protocols >= 1.27
ifneq (,$(wildcard ${DATA_DIR_WAYLAND_PROTOCOLS}/staging/ext-idle-notify/ext-idle-notify-v1.xml))
	wayland-scanner client-header ${DATA_DIR_WAYLAND_PROTOCOLS}/staging/ext-idle-notify/ext-idle-notify-v1.xml src/wayland/protocols/ext-idle-notify-v1-client-header.h
	wayland-scanner private-code ${DATA_DIR_WAYLAND_PROTOCOLS}/staging/ext-idle-notify/ext-idle-notify-v1.xml src/wayland/protocols/ext-idle-notify-v1.h
endif
	# wayland-protocols >= 1.32
ifneq (,$(wildcard ${DATA_DIR_WAYLAND_PROTOCOLS}/staging/cursor-shape/cursor-shape-v1.xml))
	wayland-scanner client-header ${DATA_DIR_WAYLAND_PROTOCOLS}/staging/cursor-shape/cursor-shape-v1.xml src/wayland/protocols/cursor-shape-v1-client-header.h
	wayland-scanner private-code ${DATA_DIR_WAYLAND_PROTOCOLS}/staging/cursor-shape/cursor-shape-v1.xml src/wayland/protocols/cursor-shape-v1.h
	wayland-scanner client-header ${DATA_DIR_WAYLAND_PROTOCOLS}/unstable/tablet/tablet-unstable-v2.xml src/wayland/protocols/tablet-unstable-v2-client-header.h
	wayland-scanner private-code ${DATA_DIR_WAYLAND_PROTOCOLS}/unstable/tablet/tablet-unstable-v2.xml src/wayland/protocols/tablet-unstable-v2.h
endif
endif

.PHONY: clean clean-dunst clean-dunstify clean-doc clean-tests clean-coverage clean-coverage-run clean-wayland-protocols
clean: clean-dunst clean-dunstify clean-doc clean-tests clean-coverage clean-coverage-run

clean-dunst:
	rm -f dunst ${OBJ} main.o main.d ${DEPS}
	rm -f org.knopwob.dunst.service
	rm -f dunst.systemd.service

clean-dunstify:
	rm -f dunstify.o
	rm -f dunstify.d
	rm -f dunstify

clean-doc:
	rm -f docs/dunst.1
	rm -f docs/dunst.1.pod
	rm -f docs/dunst.5
	rm -f docs/dunstctl.1
	rm -f docs/dunstify.1
	rm -fr docs/internal/html
	rm -fr docs/internal/coverage

clean-tests:
	rm -f test/test test/*.o test/*.d

clean-coverage: clean-coverage-run
	${FIND} . -type f -name '*.gcno' -delete
	${FIND} . -type f -name '*.gcna' -delete
# Cleans the coverage data before every run to not double count any lines
clean-coverage-run:
	${FIND} . -type f -name '*.gcov' -delete
	${FIND} . -type f -name '*.gcda' -delete

clean-wayland-protocols:
	rm -f src/wayland/protocols/*.h

.PHONY: install install-dunst install-dunstctl install-dunstrc \
	install-service install-service-dbus install-service-systemd \
	uninstall uninstall-dunstctl uninstall-dunstrc \
	uninstall-service uninstall-service-dbus uninstall-service-systemd \
	uninstall-keepconf uninstall-purge
install: install-dunst install-dunstctl install-dunstrc install-service

install-dunst: dunst doc
	install -Dm755 dunst ${DESTDIR}${BINDIR}/dunst
	install -Dm644 docs/dunst.1 ${DESTDIR}${MANPREFIX}/man1/dunst.1
	install -Dm644 docs/dunst.5 ${DESTDIR}${MANPREFIX}/man5/dunst.5
	install -Dm644 docs/dunstctl.1 ${DESTDIR}${MANPREFIX}/man1/dunstctl.1
	install -Dm644 docs/dunstify.1 ${DESTDIR}${MANPREFIX}/man1/dunstify.1

install-dunstctl: dunstctl
	install -Dm755 dunstctl ${DESTDIR}${BINDIR}/dunstctl

ifeq (1,${SYSCONF_FORCE_NEW})
install-dunstrc:
	install -Dm644 dunstrc ${DESTDIR}${SYSCONFFILE}
endif

install-service: install-service-dbus
install-service-dbus: service-dbus
	install -Dm644 org.knopwob.dunst.service ${DESTDIR}${SERVICEDIR_DBUS}/org.knopwob.dunst.service
ifneq (0,${SYSTEMD})
install-service: install-service-systemd
install-service-systemd: service-systemd
	install -Dm644 dunst.systemd.service ${DESTDIR}${SERVICEDIR_SYSTEMD}/dunst.service
endif

ifneq (0,${DUNSTIFY})
install: install-dunstify
install-dunstify: dunstify
	install -Dm755 dunstify ${DESTDIR}${BINDIR}/dunstify
endif

ifneq (0,${COMPLETIONS})
install: install-completions
install-completions:
	install -Dm644 completions/dunst.bashcomp ${DESTDIR}${BASHCOMPLETIONDIR}/dunst
	install -Dm644 completions/dunstctl.bashcomp ${DESTDIR}${BASHCOMPLETIONDIR}/dunstctl
	install -Dm644 completions/_dunst.zshcomp ${DESTDIR}${ZSHCOMPLETIONDIR}/_dunst
	install -Dm644 completions/_dunstctl.zshcomp ${DESTDIR}${ZSHCOMPLETIONDIR}/_dunstctl
	install -Dm644 completions/dunst.fishcomp ${DESTDIR}${FISHCOMPLETIONDIR}/dunst.fish
	install -Dm644 completions/dunstctl.fishcomp ${DESTDIR}${FISHCOMPLETIONDIR}/dunstctl.fish

ifneq (0,${DUNSTIFY})
install: install-completions-dunstify
install-completions-dunstify:
	install -Dm644 completions/dunstify.fishcomp ${DESTDIR}${FISHCOMPLETIONDIR}/dunstify.fish
endif
endif

uninstall: uninstall-keepconf
uninstall-purge: uninstall-keepconf uninstall-dunstrc
uninstall-keepconf: uninstall-service uninstall-dunstctl uninstall-completions
	rm -f ${DESTDIR}${BINDIR}/dunst
	rm -f ${DESTDIR}${BINDIR}/dunstify
	rm -f ${DESTDIR}${MANPREFIX}/man1/dunst.1
	rm -f ${DESTDIR}${MANPREFIX}/man5/dunst.5
	rm -f ${DESTDIR}${MANPREFIX}/man1/dunstctl.1
	rm -f ${DESTDIR}${MANPREFIX}/man1/dunstify.1

uninstall-dunstrc:
	rm -f ${DESTDIR}${SYSCONFFILE}
	rmdir --ignore-fail-on-non-empty ${DESTDIR}${SYSCONFDIR}/dunst

uninstall-dunstctl:
	rm -f ${DESTDIR}${BINDIR}/dunstctl

uninstall-service: uninstall-service-dbus
uninstall-service-dbus:
	rm -f ${DESTDIR}${SERVICEDIR_DBUS}/org.knopwob.dunst.service

ifneq (0,${SYSTEMD})
uninstall-service: uninstall-service-systemd
uninstall-service-systemd:
	rm -f ${DESTDIR}${SERVICEDIR_SYSTEMD}/dunst.service
endif

uninstall-completions:
	rm -f ${DESTDIR}${BASHCOMPLETIONDIR}/dunst
	rm -f ${DESTDIR}${BASHCOMPLETIONDIR}/dunstctl
	rm -f ${DESTDIR}${ZSHCOMPLETIONDIR}/_dunst
	rm -f ${DESTDIR}${ZSHCOMPLETIONDIR}/_dunstctl
	rm -f ${DESTDIR}${FISHCOMPLETIONDIR}/dunst.fish
	rm -f ${DESTDIR}${FISHCOMPLETIONDIR}/dunstctl.fish
	rm -f ${DESTDIR}${FISHCOMPLETIONDIR}/dunstify.fish
