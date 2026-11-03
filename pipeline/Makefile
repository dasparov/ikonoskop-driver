# Builds the acam tool and its tests with the Command Line Tools' swiftc. SwiftPM (`swift build`)
# is not used: with the Command Line Tools 14.3 alone it stops at its XCTest lookup (xcrun cannot
# report a macOS platform path without Xcode). XCTest is missing too, so the tests are a plain
# program (Tests/Harness.swift).
#
#   make          build/acam
#   make check    build and run build/acam-tests (scratch files: build/test-scratch)
include ../mk/common.mk

CC         := $(TOOLCHAIN)/clang
SWIFTC     := $(TOOLCHAIN)/swiftc
TARGET     := arm64-apple-macos13.0
BRIDGE     := Sources/ACamKit/Bridging.h
SWIFTFLAGS := -sdk $(SDK) -target $(TARGET) -O -import-objc-header $(BRIDGE)
KIT        := $(sort $(wildcard Sources/ACamKit/*.swift))
CLI        := $(sort $(wildcard Sources/acam/*.swift))
TESTS      := $(sort $(wildcard Tests/*.swift))
XXHASH     := build/xxhash.o

.PHONY: all check clean
all: build/acam

check: build/acam-tests
	build/acam-tests

$(XXHASH): Sources/ACamKit/xxhash.c Vendor/xxhash/xxhash.h
	mkdir -p build
	$(CC) -isysroot $(SDK) -target $(TARGET) -O2 -Wall -c $< -o $@

build/acam: $(KIT) $(CLI) $(XXHASH) $(BRIDGE)
	$(SWIFTC) $(SWIFTFLAGS) -module-name acam $(KIT) $(CLI) $(XXHASH) -o $@

build/acam-tests: $(KIT) $(TESTS) $(XXHASH) $(BRIDGE)
	$(SWIFTC) $(SWIFTFLAGS) -module-name acamtests $(KIT) $(TESTS) $(XXHASH) -o $@

clean:
	rm -rf build
