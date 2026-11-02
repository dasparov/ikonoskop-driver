# Userspace harness for core/ (ik::VirtualCard).
#
#   make            build, then run every check below
#   make fs         dump the virtual disk, fsck it, mount it read-only and verify the files
#   make diff       differential test against the original x86_64 kext code (Unicorn); skipped
#                   unless ORIGINAL points at the x86_64 slice of Ikonoskop's v1.2 kext
#   make kernel     compile core/ with exactly the kext's kernel compiler and flags (mk/common.mk)
#   make clean
#
# The scratch image (4.9 GiB sparse raw disk) lives in $(WORK) and is deleted after a pass.

include ../mk/common.mk

CXX      ?= clang++
CXXFLAGS ?= -std=c++17 -O2 -g -Wall -Wextra -Werror
CORE     := ../core
CORE_SRC := $(wildcard $(CORE)/*.cpp)
CORE_HDR := $(wildcard $(CORE)/*.h $(CORE)/*.inc)
WORK     ?= /tmp/ik_core_test
ORIGINAL ?= ../reference/IkonoskopCardReader12.x86_64
VENV     := .venv

all: check

check: kernel fs diff

ik_harness: harness.cpp mock_hw.cpp mock_hw.h $(CORE_SRC) $(CORE_HDR)
	$(CXX) $(CXXFLAGS) -o $@ harness.cpp mock_hw.cpp $(CORE_SRC)

libiktest.dylib: capi.cpp mock_hw.cpp mock_hw.h $(CORE_SRC) $(CORE_HDR)
	$(CXX) $(CXXFLAGS) -dynamiclib -o $@ capi.cpp mock_hw.cpp $(CORE_SRC)

fs: ik_harness
	./run_fs_test.sh $(WORK) 0
	./run_fs_test.sh $(WORK) 2
	./run_fs_test.sh $(WORK) 3

$(VENV)/bin/python:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q unicorn

ifeq ($(wildcard $(ORIGINAL)),)
diff:
	@echo "diff: skipped, no original v1.2 x86_64 binary at ORIGINAL=$(ORIGINAL)"
else
diff: libiktest.dylib $(VENV)/bin/python
	$(VENV)/bin/python diff_x86.py $(ORIGINAL) ./libiktest.dylib
endif

kernel:
	@mkdir -p $(WORK)/kobj
	for f in $(CORE_SRC); do \
	  $(KERNEL_CXX) $(CORE_KERNEL_CXXFLAGS) -c $$f -o $(WORK)/kobj/$$(basename $$f .cpp).o || exit 1; \
	done
	@nm -u $(WORK)/kobj/*.o | sort -u | tr '\n' ' ' | sed 's/^/kernel object imports: /'; echo

clean:
	rm -rf ik_harness ik_harness.dSYM libiktest.dylib libiktest.dylib.dSYM $(WORK)

.PHONY: all check fs diff kernel clean
