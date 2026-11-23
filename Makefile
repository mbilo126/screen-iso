.PHONY: lint format test build icon release clean

SWIFT_SOURCES := Package.swift Sources Tests

# Command Line Tools ship Swift Testing outside the default search paths, so the test build needs them explicitly.
CLT_DEVELOPER := /Library/Developer/CommandLineTools/Library/Developer
CLT_FRAMEWORKS := $(CLT_DEVELOPER)/Frameworks
TEST_FLAGS := -Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) \
	-Xlinker -F -Xlinker $(CLT_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(CLT_DEVELOPER)/usr/lib

lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

format:
	swift format --in-place --recursive $(SWIFT_SOURCES)

test:
	swift test $(TEST_FLAGS)

# Release binary plus build/ScreenISO.app with the bundled screen saver, signed ad-hoc.
build:
	./scripts/bundle.sh

# Regenerates Resources/AppIcon.icns from assets/logo.svg. Needed only when the logo changes.
icon:
	./scripts/icon.sh

# Publishes the version in Resources/Info.plist: GitHub Release plus the Homebrew cask. See scripts/release.sh.
release:
	./scripts/release.sh

clean:
	rm -rf .build build Saver/build
