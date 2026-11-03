# Builds build/acam with the Command Line Tools' swiftc. SwiftPM (`swift build`) is not used: with
# the Command Line Tools 14.3 alone it stops at its XCTest lookup (xcrun cannot report a macOS
# platform path without Xcode).
include ../mk/common.mk

SWIFTC     := $(TOOLCHAIN)/swiftc
SWIFTFLAGS := -sdk $(SDK) -target arm64-apple-macos13.0 -O -module-name acam
SOURCES    := $(sort $(wildcard Sources/acam/*.swift))

.PHONY: all clean
all: build/acam

build/acam: $(SOURCES)
	mkdir -p build
	$(SWIFTC) $(SWIFTFLAGS) $(SOURCES) -o $@

clean:
	rm -rf build
