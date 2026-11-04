# Builds the acam tool and its tests with the Command Line Tools' swiftc. SwiftPM (`swift build`)
# is not used: with the Command Line Tools 14.3 alone it stops at its XCTest lookup (xcrun cannot
# report a macOS platform path without Xcode). XCTest is missing too, so the tests are a plain
# program (Tests/Harness.swift).
#
#   make          build/acam
#   make check    build and run build/acam-tests (scratch files: build/test-scratch)
include ../mk/common.mk

CC         := $(TOOLCHAIN)/clang
CXX        := $(TOOLCHAIN)/clang++
SWIFTC     := $(TOOLCHAIN)/swiftc
TARGET     := arm64-apple-macos13.0
BRIDGE     := Sources/ACamKit/Bridging.h
SWIFTFLAGS := -sdk $(SDK) -target $(TARGET) -O
KIT        := $(sort $(wildcard Sources/ACamKit/*.swift))
CLI        := $(sort $(wildcard Sources/acam/*.swift))
TESTS      := $(sort $(wildcard Tests/*.swift))
XXHASH     := build/xxhash.o
# The tests also get the camera's DNG header templates from the driver's generator (core/).
CAMERA     := build/camera_headers.o
APP        := $(sort $(wildcard Sources/ACamApp/*.swift))
IKCTL      := ../tools/ikctl

.PHONY: all check app clean
all: build/acam

check: build/acam-tests
	build/acam-tests

app: build/ACam.app

$(XXHASH): Sources/ACamKit/xxhash.c Vendor/xxhash/xxhash.h
	mkdir -p build
	$(CC) -isysroot $(SDK) -target $(TARGET) -O2 -Wall -c $< -o $@

$(CAMERA): Tests/CameraHeaders.cpp ../core/ik_dng_templates.h
	mkdir -p build
	$(CXX) -isysroot $(SDK) -target $(TARGET) -std=c++17 -O2 -Wall -Wextra -c $< -o $@

build/acam: $(KIT) $(CLI) $(XXHASH) $(BRIDGE)
	$(SWIFTC) $(SWIFTFLAGS) -import-objc-header $(BRIDGE) -module-name acam $(KIT) $(CLI) $(XXHASH) -o $@

build/acam-tests: $(KIT) $(TESTS) $(XXHASH) $(CAMERA) $(BRIDGE) Tests/TestBridging.h
	$(SWIFTC) $(SWIFTFLAGS) -import-objc-header Tests/TestBridging.h -module-name acamtests $(KIT) $(TESTS) \
	  $(XXHASH) $(CAMERA) -o $@

# The Mac app: the same ACamKit sources with a SwiftUI front end. Resources: tools/ikctl for the
# take-table check, the Phase 5 colour profiles and the icon (drawn by icon/make-icon.swift).
build/ACam.app: $(KIT) $(APP) $(XXHASH) $(BRIDGE) Sources/ACamApp/Info.plist Sources/ACamApp/AppIcon.icns $(IKCTL) $(wildcard colour/profiles/*/*)
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Resources/profiles
	cp Sources/ACamApp/Info.plist $@/Contents/Info.plist
	cp Sources/ACamApp/AppIcon.icns $@/Contents/Resources/AppIcon.icns
	cp $(IKCTL) $@/Contents/Resources/ikctl
	for p in colour/profiles/*/; do cp -R "$${p%/}" $@/Contents/Resources/profiles/; done
	$(SWIFTC) $(SWIFTFLAGS) -parse-as-library -import-objc-header $(BRIDGE) -module-name ACam $(KIT) $(APP) \
	  $(XXHASH) -o $@/Contents/MacOS/ACam
	codesign --force --sign - $@

$(IKCTL):
	$(MAKE) -C ../tools

clean:
	rm -rf build
