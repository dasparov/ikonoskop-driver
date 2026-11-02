include ../mk/common.mk

CC     := $(TOOLCHAIN)/clang
CFLAGS := -isysroot $(SDK) -mmacosx-version-min=13.0 -arch arm64 -O2 -Wall -Wextra -I../kext

.PHONY: all clean
all: ikctl

ikctl: ikctl.c ../kext/ik_uc_shared.h
	$(CC) $(CFLAGS) ikctl.c -framework IOKit -framework CoreFoundation -o $@

clean:
	rm -f ikctl
