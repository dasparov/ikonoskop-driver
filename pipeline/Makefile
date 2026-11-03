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

.PHONY: all check clean
all: build/acam

check: build/acam-tests
	build/acam-tests

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

clean:
	rm -rf build
