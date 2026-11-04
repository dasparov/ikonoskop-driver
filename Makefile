# Ikonoskop A-Cam dII Express Card Reader driver (Apple silicon).
#
#   make            build the kext and tools/ikctl
#   make check      test suite (core/ kernel compile, fs scenarios, x86 differential if the
#                   original binary is present), then kext checks
#   make install    make check, then install the kext (sudo; restart required)
#   make uninstall  remove the installed kext (sudo; restart required)
#   make release    make check, then dist/IkonoskopCardReader-<version>.zip (kext, scripts, docs)
#   make pipeline        build the acam card tool (pipeline/, Swift) into pipeline/build/acam
#   make pipeline-check  build and run the acam tests
#   make app             build the ACam Mac app into pipeline/build/ACam.app
#   make app-release     its tests, then dist/ACam-<version>.zip (the app, its manual, the licence)
#   make clean
#
# Shared compiler settings: mk/common.mk.

VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' kext/Info.plist)
DIST    := IkonoskopCardReader-$(VERSION)
# The app's version is acamVersion in pipeline/Sources/ACamKit/Report.swift.
APP_VERSION := $(shell sed -n 's/^let acamVersion = "\(.*\)"/\1/p' pipeline/Sources/ACamKit/Report.swift)
APP_DIST    := ACam-$(APP_VERSION)

.PHONY: all check install uninstall release pipeline pipeline-check app app-release clean

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

pipeline-check:
	$(MAKE) -C pipeline check

app:
	$(MAKE) -C pipeline app

app-release: pipeline-check
	$(MAKE) -C pipeline app
	@test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' pipeline/build/ACam.app/Contents/Info.plist)" = "$(APP_VERSION)" \
	  || { echo "pipeline/Sources/ACamApp/Info.plist does not say $(APP_VERSION)"; exit 1; }
	rm -rf dist/$(APP_DIST) dist/$(APP_DIST).zip
	mkdir -p dist/$(APP_DIST)
	ditto pipeline/build/ACam.app dist/$(APP_DIST)/ACam.app
	cp docs/ACam-manual.md LICENSE dist/$(APP_DIST)/
	cd dist && ditto -c -k --keepParent $(APP_DIST) $(APP_DIST).zip
	@cd dist && shasum -a 256 $(APP_DIST).zip

clean:
	$(MAKE) -C kext clean
	$(MAKE) -C test clean
	$(MAKE) -C pipeline clean
	rm -rf dist
