PRODUCT_NAME = sfind
PREFIX ?= /usr/local
BINDIR = $(DESTDIR)$(PREFIX)/bin
MANDIR = $(DESTDIR)$(PREFIX)/share/man/man1
SWIFT ?= swift
SWIFT_BUILD_FLAGS = --configuration release --disable-sandbox

.PHONY: build test integration-test lint format install uninstall universal clean

build:
	$(SWIFT) build $(SWIFT_BUILD_FLAGS)

test:
	$(SWIFT) test

# Runs the Spotlight-backed integration suite. Fixtures are created (and removed) under
# $$HOME because /tmp and $$TMPDIR are not usefully indexed.
integration-test:
	SFIND_INTEGRATION=1 $(SWIFT) test --no-parallel --filter IntegrationTests

lint:
	$(SWIFT) format lint --strict --recursive Sources Tests Package.swift

format:
	$(SWIFT) format --in-place --recursive Sources Tests Package.swift

install: build
	install -d "$(BINDIR)" "$(MANDIR)"
	install -m 0755 "$$($(SWIFT) build --show-bin-path $(SWIFT_BUILD_FLAGS))/$(PRODUCT_NAME)" "$(BINDIR)/"
	install -m 0644 docs/$(PRODUCT_NAME).1 "$(MANDIR)/"

uninstall:
	rm -f "$(BINDIR)/$(PRODUCT_NAME)" "$(MANDIR)/$(PRODUCT_NAME).1"

universal:
	./scripts/build-universal.sh

clean:
	$(SWIFT) package clean
	rm -rf release
