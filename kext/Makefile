# Builds build/IkonoskopCardReader.kext (arm64e, ad-hoc signed) with the Command Line Tools,
# compiling every core/*.cpp into the kext, plus tools/ikctl.
#
#   make            kext + ikctl
#   make kext       kext only
#   make check      kmutil libraries + print-diagnostics + codesign -dv (no loading)
#   make clean

include ../mk/common.mk

CLANG_RES  := $(shell $(KERNEL_CC) -print-resource-dir)

KEXT_NAME  := IkonoskopCardReader
BUNDLE_ID  := org.ikonoskop.community.CardReader
VERSION    := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)

BUILD      := build
OBJDIR     := $(BUILD)/obj
KEXT       := $(BUILD)/$(KEXT_NAME).kext
BINARY     := $(KEXT)/Contents/MacOS/$(KEXT_NAME)

CORE_DIR   := ../core
CORE_SRCS  := $(sort $(wildcard $(CORE_DIR)/*.cpp))
KEXT_SRCS  := IkonoskopCardReader.cpp IkonoskopBlockDevice.cpp IkonoskopUserClient.cpp
OBJS       := $(patsubst %.cpp,$(OBJDIR)/%.o,$(KEXT_SRCS)) \
              $(patsubst $(CORE_DIR)/%.cpp,$(OBJDIR)/core_%.o,$(CORE_SRCS)) \
              $(OBJDIR)/kmod_info.o

# core/ objects use CORE_KERNEL_CXXFLAGS unchanged (the flags test/'s `make kernel` checks).
KEXT_FLAGS := -I. -I$(CORE_DIR) -Wno-unused-parameter -Wno-deprecated-declarations
CXXFLAGS   := $(KERNEL_CXXFLAGS) $(KEXT_FLAGS) -Wno-inconsistent-missing-override
CFLAGS     := $(KERNEL_FLAGS) $(KEXT_FLAGS) -std=gnu11 \
              -DKEXT_BUNDLE_ID='$(BUNDLE_ID)' -DKEXT_VERSION='"$(VERSION)"'
LDFLAGS    := $(KERNEL_TARGET) -isysroot $(SDK) -nostdlib -Xlinker -kext -L$(SDK)/usr/lib \
              -lkmodc++ -lkmod $(CLANG_RES)/lib/darwin/libclang_rt.cc_kext.a

.PHONY: all kext tools check clean

all: kext tools

kext: $(KEXT)/Contents/_CodeSignature/CodeResources

$(OBJDIR)/%.o: %.cpp $(wildcard *.hpp) ik_uc_shared.h $(CORE_DIR)/ik_core.h | $(OBJDIR)
	$(KERNEL_CXX) $(CXXFLAGS) -c $< -o $@

$(OBJDIR)/core_%.o: $(CORE_DIR)/%.cpp $(wildcard $(CORE_DIR)/*.h $(CORE_DIR)/*.inc) | $(OBJDIR)
	$(KERNEL_CXX) $(CORE_KERNEL_CXXFLAGS) -c $< -o $@

$(OBJDIR)/kmod_info.o: kmod_info.c Info.plist | $(OBJDIR)
	$(KERNEL_CC) $(CFLAGS) -c $< -o $@

$(OBJDIR):
	mkdir -p $@

# ZERO_AR_DATE=1: ld64 writes 0 instead of each object's mtime into the debug map, so rebuilding
# unchanged source gives the same binary and CDHash. macOS approves ad-hoc kexts per CDHash.
$(BINARY): $(OBJS)
	mkdir -p $(KEXT)/Contents/MacOS
	ZERO_AR_DATE=1 $(KERNEL_CXX) $(LDFLAGS) $(OBJS) -o $@

$(KEXT)/Contents/Info.plist: Info.plist
	mkdir -p $(KEXT)/Contents
	cp Info.plist $@

$(KEXT)/Contents/_CodeSignature/CodeResources: $(BINARY) $(KEXT)/Contents/Info.plist
	codesign --force --sign - --timestamp=none $(KEXT)

tools:
	$(MAKE) -C ../tools

# Every undefined symbol must be found by kmutil in a declared OSBundleLibraries kext.
# print-diagnostics reports ownership (needs root:wheel) and, for ad-hoc signatures,
# "Bad code signature" until kext signature enforcement is lowered; both are expected here.
check: kext
	@undef=$$(nm -u $(BINARY) | wc -l | tr -d ' '); \
	 found=$$(kmutil libraries -p $(KEXT) --all-symbols 2>/dev/null | grep -c ' in /'); \
	 echo "undefined symbols: $$undef, resolved via kmutil: $$found"; \
	 test "$$undef" = "$$found"
	kmutil libraries -p $(KEXT) --xml
	-kmutil print-diagnostics -p $(KEXT)
	codesign -dv $(KEXT)
	codesign --verify --strict --verbose=2 $(KEXT)

clean:
	rm -rf $(BUILD)
	$(MAKE) -C ../tools clean
