# Shared build settings, included by kext/, test/ and tools/ as ../mk/common.mk.
#
# The kernel compiler and flags live here once, so the kext build and test/'s `make kernel`
# compile core/ identically.

# SDK and compiler: whatever xcrun selects (Command Line Tools or Xcode). Override with SDK=<path>.
SDK ?= $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
SDK := $(SDK)
ifeq ($(wildcard $(SDK)/System/Library/Frameworks/Kernel.framework/Headers),)
  $(error No macOS SDK with Kernel.framework found (SDK=$(SDK)). Install the Command Line Tools: xcode-select --install)
endif
TOOLCHAIN := $(patsubst %/,%,$(dir $(shell xcrun --sdk macosx -f clang)))

KERNEL_CC      := $(TOOLCHAIN)/clang
KERNEL_CXX     := $(TOOLCHAIN)/clang++
KERNEL_TARGET  := -target arm64e-apple-macos13.3
KERNEL_HEADERS := $(SDK)/System/Library/Frameworks/Kernel.framework/Headers

# Every object linked into the kext.
KERNEL_FLAGS    := $(KERNEL_TARGET) -isysroot $(SDK) -mkernel -nostdinc -I$(KERNEL_HEADERS) \
                   -DKERNEL -DAPPLE -DNeXT -O2 -g -Wall
KERNEL_CXXFLAGS := $(KERNEL_FLAGS) -std=gnu++17 -fapple-kext -fno-exceptions -fno-rtti \
                   -fno-threadsafe-statics

# core/ must build warning-free for the kernel.
CORE_KERNEL_CXXFLAGS := $(KERNEL_CXXFLAGS) -Wextra -Werror
