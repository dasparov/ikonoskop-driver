// Test helper: the camera's DNG header templates, from the driver's own generator in core/.
#include "../../core/ik_dng_templates.h"

#include <string.h>

// kind 0 = monochrome, 1 = tungsten, 2 = daylight. Returns the template length (0 if `capacity`
// is too small).
extern "C" size_t acam_test_camera_header(int kind, unsigned char *out, size_t capacity) {
    const uint8_t *bytes = ik::dng::kDaylight.bytes;
    size_t len = sizeof(ik::dng::kDaylight.bytes);
    if (kind == 0) {
        bytes = ik::dng::kMonochrome.bytes;
        len = sizeof(ik::dng::kMonochrome.bytes);
    } else if (kind == 1) {
        bytes = ik::dng::kTungsten.bytes;
        len = sizeof(ik::dng::kTungsten.bytes);
    }
    if (len > capacity) {
        return 0;
    }
    memcpy(out, bytes, len);
    return len;
}
