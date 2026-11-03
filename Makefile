# Ikonoskop A-Cam dII Express Card Reader driver (Apple silicon).
#
#   make            build the kext and tools/ikctl
#   make check      test suite (core/ kernel compile, fs scenarios, x86 differential if the
#                   original binary is present), then kext checks
#   make install    make check, then install the kext (sudo; restart required)
#   make uninstall  remove the installed kext (sudo; restart required)
#   make release    make check, then dist/IkonoskopCardReader-<version>.zip (kext, scripts, docs)
#   make pipeline   build the acam card tool (pipeline/, Swift) into pipeline/build/acam
#   make clean
#
# Shared compiler settings: mk/common.mk.

VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' kext/Info.plist)
DIST    := IkonoskopCardReader-$(VERSION)

.PHONY: all check install uninstall release pipeline clean

all:
	$(MAKE) -C kext

check:
	$(MAKE) -C test check
	$(MAKE) -C kext check

install: check
	scripts/install.sh

uninstall:
	scripts/uninstall.sh

release: check
	rm -rf dist/$(DIST) dist/$(DIST).zip
	mkdir -p dist/$(DIST)
	ditto kext/build/IkonoskopCardReader.kext dist/$(DIST)/IkonoskopCardReader.kext
	cp scripts/install.sh scripts/uninstall.sh README.md LICENSE dist/$(DIST)/
	cd dist && ditto -c -k --keepParent $(DIST) $(DIST).zip
	@codesign -dvvv dist/$(DIST)/IkonoskopCardReader.kext 2>&1 | grep '^CDHash='
	@cd dist && shasum -a 256 $(DIST).zip

pipeline:
	$(MAKE) -C pipeline

clean:
	$(MAKE) -C kext clean
	$(MAKE) -C test clean
	$(MAKE) -C pipeline clean
	rm -rf dist
