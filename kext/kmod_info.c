/* kmod_info.c — equivalent of the Xcode-generated <Product>_info.c for a C++ IOKit kext.
 * KEXT_BUNDLE_ID / KEXT_VERSION come from the Makefile (must match Info.plist). */
#include <mach/mach_types.h>

extern kern_return_t _start(kmod_info_t *ki, void *data);
extern kern_return_t _stop(kmod_info_t *ki, void *data);

/* Indirection so KEXT_BUNDLE_ID is expanded before KMOD_EXPLICIT_DECL stringizes it. */
#define IK_KMOD_DECL(name, version, start, stop) KMOD_EXPLICIT_DECL(name, version, start, stop)

__attribute__((visibility("default")))
IK_KMOD_DECL(KEXT_BUNDLE_ID, KEXT_VERSION, _start, _stop)

__private_extern__ kmod_start_func_t *_realmain = 0;
__private_extern__ kmod_stop_func_t *_antimain = 0;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
