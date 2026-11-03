// C code used from the Swift tests: the product's bridging header plus the camera-header helper.
#include "../Sources/ACamKit/Bridging.h"

#include <stddef.h>

size_t acam_test_camera_header(int kind, unsigned char *out, size_t capacity);
