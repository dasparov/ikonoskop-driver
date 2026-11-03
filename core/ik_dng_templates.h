// ik_dng_templates.h — CinemaDNG header templates (monochrome, tungsten, daylight), built at
// compile time from the tag tables below.
//
// createDngHeader() starts every DNG file with one of these, sets FrameRate, TimeCodes and
// ReelName, and zero-pads it to 4 KiB. The tables reproduce the headers of Ikonoskop's v1.2
// driver byte for byte, so the files match the ones it produced, quirks included:
//   - the monochrome and tungsten IFDs end with an all-zero entry; the daylight IFD has a
//     second, identical WhiteLevel entry in that slot;
//   - CalibrationIlluminant1/2 are 0x8000 + 5500 and 0x8000 + 3400, which are not EXIF
//     LightSource codes (they read as 5500 K and 3400 K with bit 15 set);
//   - 8 zero bytes separate the IFD from the value area, which is not in tag order.
// test/harness.cpp checks each template's SHA-256 against the original driver's;
// test/diff_x86.py compares every header served with the original driver's output.
//
// Layout: TIFF header (little-endian, IFD at offset 8), the IFD, 8 zero bytes, then every
// value longer than 4 bytes, packed in the template's value order.
//
// Kernel-safe: constexpr only, no STL, no floating point.
#ifndef IK_DNG_TEMPLATES_H
#define IK_DNG_TEMPLATES_H

#include <stddef.h>
#include <stdint.h>

namespace ik {
namespace dng {

// TIFF field types.
enum : uint16_t { kByte = 1, kAscii = 2, kShort = 3, kLong = 4, kRational = 5, kSRational = 10 };

// TIFF 6.0, TIFF/EP, DNG 1.2 and CinemaDNG tags.
enum : uint16_t {
    kNewSubfileType = 0x00fe,
    kImageWidth = 0x0100,
    kImageLength = 0x0101,
    kBitsPerSample = 0x0102,
    kCompression = 0x0103,
    kPhotometricInterpretation = 0x0106,
    kFillOrder = 0x010a,
    kStripOffsets = 0x0111,
    kOrientation = 0x0112,
    kSamplesPerPixel = 0x0115,
    kRowsPerStrip = 0x0116,
    kStripByteCounts = 0x0117,
    kPlanarConfiguration = 0x011c,
    kCfaRepeatPatternDim = 0x828d,
    kCfaPattern = 0x828e,
    kDngVersion = 0xc612,
    kUniqueCameraModel = 0xc614,
    kBlackLevelRepeatDim = 0xc619,
    kBlackLevel = 0xc61a,
    kWhiteLevel = 0xc61d,
    kDefaultCropOrigin = 0xc61f,
    kDefaultCropSize = 0xc620,
    kColorMatrix1 = 0xc621,
    kColorMatrix2 = 0xc622,
    kAsShotNeutral = 0xc628,
    kBayerGreenSplit = 0xc62d,
    kDngPrivateData = 0xc634,
    kCalibrationIlluminant1 = 0xc65a,
    kCalibrationIlluminant2 = 0xc65b,
    kTimeCodes = 0xc763,
    kFrameRate = 0xc764,
    kReelName = 0xc789,
};

const uint32_t kMaxValues = 9; // ColorMatrix: 3 x 3

// One IFD entry. Rationals are written in 1/10000 (four decimals, the precision of the factory
// calibration) and stored reduced: 1.0048 -> 10048 -> 628/625.
struct Field {
    uint16_t tag;
    uint16_t type;
    uint32_t count;
    int32_t values[kMaxValues]; // the first min(count, kMaxValues) values; the rest are zero
    const char *text;           // kAscii value, NUL-padded to count
    uint32_t fileOffset;        // non-zero: the value lies at this file offset, after the header
};

template <uint32_t N>
constexpr Field field(uint16_t tag, uint16_t type, const int32_t (&v)[N]) {
    static_assert(N <= kMaxValues, "more values than a Field holds");
    Field f{};
    f.tag = tag;
    f.type = type;
    f.count = N;
    for (uint32_t i = 0; i < N; i++) {
        f.values[i] = v[i];
    }
    return f;
}

constexpr Field text(uint16_t tag, uint32_t count, const char *s) {
    Field f{};
    f.tag = tag;
    f.type = kAscii;
    f.count = count;
    f.text = s;
    return f;
}

// `count` zero values, which createDngHeader() fills in for each file.
constexpr Field perFile(uint16_t tag, uint16_t type, uint32_t count) {
    Field f{};
    f.tag = tag;
    f.type = type;
    f.count = count;
    return f;
}

// A value that lies in the file after the header.
constexpr Field afterHeader(uint16_t tag, uint16_t type, uint32_t count, uint32_t offset) {
    Field f = perFile(tag, type, count);
    f.fileOffset = offset;
    return f;
}

// ---- Layout ---------------------------------------------------------------------------------

const uint32_t kIfdOffset = 8;
const uint32_t kIfdGap = 8; // zero bytes between the IFD and the value area

constexpr uint32_t typeBytes(uint16_t type) {
    return type == kByte || type == kAscii             ? 1
           : type == kShort                            ? 2
           : type == kLong                             ? 4
           : type == kRational || type == kSRational   ? 8
                                                       : 0;
}

constexpr uint32_t valueBytes(const Field &f) {
    return typeBytes(f.type) * f.count;
}

// Values longer than 4 bytes go in the value area, unless they lie after the header.
constexpr bool inValueArea(const Field &f) {
    return f.fileOffset == 0 && valueBytes(f) > 4;
}

constexpr uint32_t valueAreaStart(uint32_t entries) {
    return kIfdOffset + 2 + 12 * entries + 4 + kIfdGap;
}

// Offset of the value of `tag`: the value area holds the values of the tags in `order`, packed.
template <uint32_t F, uint32_t V>
constexpr uint32_t valueOffset(const Field (&fields)[F], const uint16_t (&order)[V], uint16_t tag) {
    uint32_t at = valueAreaStart(F);
    for (uint32_t k = 0; k < V && order[k] != tag; k++) {
        for (uint32_t i = 0; i < F; i++) {
            if (fields[i].tag == order[k] && inValueArea(fields[i])) {
                at += valueBytes(fields[i]);
            }
        }
    }
    return at;
}

constexpr uint32_t textLength(const char *s) {
    uint32_t n = 0;
    while (s[n]) {
        n++;
    }
    return n;
}

// Size of the template the tables describe, or 0 if they are inconsistent: a value-area field
// missing from `order` or listed twice, a tag in `order` without a value-area field, or text
// that does not fit its count with a NUL.
template <uint32_t F, uint32_t V>
constexpr uint32_t layoutSize(const Field (&fields)[F], const uint16_t (&order)[V]) {
    uint32_t size = valueAreaStart(F);
    for (uint32_t k = 0; k < V; k++) {
        uint32_t found = 0;
        for (uint32_t i = 0; i < F; i++) {
            if (fields[i].tag == order[k] && inValueArea(fields[i])) {
                found++;
                size += valueBytes(fields[i]);
            }
        }
        if (found != 1) {
            return 0;
        }
    }
    for (uint32_t i = 0; i < F; i++) {
        uint32_t listed = 0;
        for (uint32_t k = 0; k < V; k++) {
            if (order[k] == fields[i].tag) {
                listed++;
            }
        }
        if (listed != (inValueArea(fields[i]) ? 1u : 0u)) {
            return 0;
        }
        if (fields[i].text && textLength(fields[i].text) >= fields[i].count) {
            return 0;
        }
    }
    return size;
}

// ---- Encoding -------------------------------------------------------------------------------

template <uint32_t Size>
struct Template {
    uint8_t bytes[Size];
};

constexpr void put16(uint8_t *b, uint32_t at, uint32_t v) {
    b[at] = (uint8_t)v;
    b[at + 1] = (uint8_t)(v >> 8);
}

constexpr void put32(uint8_t *b, uint32_t at, uint32_t v) {
    put16(b, at, v & 0xffff);
    put16(b, at + 2, v >> 16);
}

constexpr uint32_t gcd(uint32_t a, uint32_t b) {
    while (b) {
        uint32_t r = a % b;
        a = b;
        b = r;
    }
    return a;
}

constexpr void putValues(uint8_t *b, uint32_t at, const Field &f) {
    if (f.text) {
        for (uint32_t i = 0; f.text[i]; i++) {
            b[at + i] = (uint8_t)f.text[i];
        }
        return;
    }
    uint32_t size = typeBytes(f.type);
    for (uint32_t i = 0; i < f.count && i < kMaxValues; i++) {
        int32_t v = f.values[i];
        uint32_t p = at + i * size;
        if (size == 1) {
            b[p] = (uint8_t)v;
        } else if (size == 2) {
            put16(b, p, (uint32_t)v);
        } else if (size == 4) {
            put32(b, p, (uint32_t)v);
        } else { // rational: v / 10000, reduced
            uint32_t g = gcd((uint32_t)(v < 0 ? -v : v), 10000);
            put32(b, p, (uint32_t)(v / (int32_t)g));
            put32(b, p + 4, 10000 / g);
        }
    }
}

template <uint32_t Size, uint32_t F, uint32_t V>
constexpr Template<Size> build(const Field (&fields)[F], const uint16_t (&order)[V]) {
    Template<Size> t{};
    put16(t.bytes, 0, 0x4949); // "II": little-endian
    put16(t.bytes, 2, 42);
    put32(t.bytes, 4, kIfdOffset);
    put16(t.bytes, kIfdOffset, F);
    for (uint32_t i = 0; i < F; i++) {
        const Field &f = fields[i];
        uint32_t entry = kIfdOffset + 2 + 12 * i;
        put16(t.bytes, entry, f.tag);
        put16(t.bytes, entry + 2, f.type);
        put32(t.bytes, entry + 4, f.count);
        if (f.fileOffset) {
            put32(t.bytes, entry + 8, f.fileOffset);
        } else if (inValueArea(f)) {
            uint32_t at = valueOffset(fields, order, f.tag);
            put32(t.bytes, entry + 8, at);
            putValues(t.bytes, at, f);
        } else {
            putValues(t.bytes, entry + 8, f);
        }
    }
    return t; // the next-IFD offset (none) and the gap after the IFD stay zero
}

// ---- Templates ------------------------------------------------------------------------------

// Factory colour matrices (XYZ to camera) for CalibrationIlluminant1 and 2.
constexpr int32_t kColorMatrix1Values[] = {10048, -2724, -500, -5656, 13498, 2078, -2916, 3498, 6394};
constexpr int32_t kColorMatrix2Values[] = {13328, -5606, 1145, -4340, 12479, 4138, -1563, 2192, 8677};

// Monochrome sensor (sensor type 0xe).
constexpr Field kMonochromeFields[] = {
    field(kNewSubfileType, kLong, {0}),
    field(kImageWidth, kLong, {2048}),
    field(kImageLength, kLong, {1092}),
    field(kBitsPerSample, kShort, {12}),
    field(kCompression, kShort, {1}),                    // uncompressed
    field(kPhotometricInterpretation, kShort, {34892}),  // LinearRaw
    field(kFillOrder, kShort, {1}),
    field(kStripOffsets, kLong, {0x1000}),               // the image follows the 4 KiB header
    field(kOrientation, kShort, {1}),
    field(kSamplesPerPixel, kShort, {1}),
    field(kRowsPerStrip, kLong, {1092}),
    field(kStripByteCounts, kLong, {0x333000}),          // 2048 x 1092 x 12 bits
    field(kPlanarConfiguration, kShort, {1}),
    field(kDngVersion, kByte, {1, 2, 0, 0}),
    text(kUniqueCameraModel, 16, "Ikonoskop A-CAM"),
    field(kBlackLevelRepeatDim, kShort, {2, 2}),
    field(kBlackLevel, kShort, {60, 60, 60, 60}),
    field(kWhiteLevel, kShort, {4095}),
    field(kDefaultCropOrigin, kShort, {0, 0}),
    field(kDefaultCropSize, kShort, {2048, 1092}),
    afterHeader(kDngPrivateData, kByte, 0x2000, 0x334000), // the frame's 8 KiB after the image
    perFile(kTimeCodes, kByte, 16),
    field(kFrameRate, kSRational, {250000}),             // 25 fps until the take's rate is set
    perFile(kReelName, kAscii, 16),
    Field{},                                             // all-zero entry
};
constexpr uint16_t kMonochromeOrder[] = {kUniqueCameraModel, kFrameRate, kBlackLevel, kTimeCodes,
                                         kReelName};

// Colour sensor (Bayer GRBG), camera set to tungsten white balance.
constexpr Field kTungstenFields[] = {
    field(kNewSubfileType, kLong, {0}),
    field(kImageWidth, kLong, {2048}),
    field(kImageLength, kLong, {1092}),
    field(kBitsPerSample, kShort, {12}),
    field(kCompression, kShort, {1}),
    field(kPhotometricInterpretation, kShort, {32803}),  // CFA
    field(kFillOrder, kShort, {1}),
    field(kStripOffsets, kLong, {0x1000}),
    field(kOrientation, kShort, {1}),
    field(kSamplesPerPixel, kShort, {1}),
    field(kRowsPerStrip, kLong, {1092}),
    field(kStripByteCounts, kLong, {0x333000}),
    field(kPlanarConfiguration, kShort, {1}),
    field(kCfaRepeatPatternDim, kShort, {2, 2}),
    field(kCfaPattern, kByte, {1, 0, 2, 1}),             // G R / B G
    field(kDngVersion, kByte, {1, 2, 0, 0}),
    text(kUniqueCameraModel, 16, "Ikonoskop A-CAM"),
    field(kBlackLevelRepeatDim, kShort, {2, 2}),
    field(kBlackLevel, kShort, {80, 80, 90, 80}),
    field(kWhiteLevel, kShort, {4095}),
    field(kDefaultCropOrigin, kShort, {0, 0}),
    field(kDefaultCropSize, kShort, {2048, 1092}),
    field(kColorMatrix1, kSRational, kColorMatrix1Values),
    field(kColorMatrix2, kSRational, kColorMatrix2Values),
    field(kAsShotNeutral, kRational, {8881, 10000, 4865}),
    field(kBayerGreenSplit, kLong, {300}),
    afterHeader(kDngPrivateData, kByte, 0x2000, 0x334000),
    field(kCalibrationIlluminant1, kShort, {0x8000 + 5500}),
    field(kCalibrationIlluminant2, kShort, {0x8000 + 3400}),
    perFile(kTimeCodes, kByte, 16),
    field(kFrameRate, kSRational, {250000}),
    perFile(kReelName, kAscii, 16),
    Field{},                                             // all-zero entry
};

// Colour sensor, camera set to daylight white balance.
constexpr Field kDaylightFields[] = {
    field(kNewSubfileType, kLong, {0}),
    field(kImageWidth, kLong, {2048}),
    field(kImageLength, kLong, {1092}),
    field(kBitsPerSample, kShort, {12}),
    field(kCompression, kShort, {1}),
    field(kPhotometricInterpretation, kShort, {32803}),
    field(kFillOrder, kShort, {1}),
    field(kStripOffsets, kLong, {0x1000}),
    field(kOrientation, kShort, {1}),
    field(kSamplesPerPixel, kShort, {1}),
    field(kRowsPerStrip, kLong, {1092}),
    field(kStripByteCounts, kLong, {0x333000}),
    field(kPlanarConfiguration, kShort, {1}),
    field(kCfaRepeatPatternDim, kShort, {2, 2}),
    field(kCfaPattern, kByte, {1, 0, 2, 1}),
    field(kDngVersion, kByte, {1, 2, 0, 0}),
    text(kUniqueCameraModel, 16, "Ikonoskop A-CAM"),
    field(kBlackLevelRepeatDim, kShort, {2, 2}),
    field(kBlackLevel, kShort, {80, 90, 90, 80}),
    field(kWhiteLevel, kShort, {4095}),
    field(kWhiteLevel, kShort, {4095}),                  // duplicate, in the all-zero entry's slot
    field(kDefaultCropOrigin, kShort, {0, 0}),
    field(kDefaultCropSize, kShort, {2048, 1092}),
    field(kColorMatrix1, kSRational, kColorMatrix1Values),
    field(kColorMatrix2, kSRational, kColorMatrix2Values),
    field(kAsShotNeutral, kRational, {6350, 10000, 6554}),
    field(kBayerGreenSplit, kLong, {300}),
    afterHeader(kDngPrivateData, kByte, 0x2000, 0x334000),
    field(kCalibrationIlluminant1, kShort, {0x8000 + 5500}),
    field(kCalibrationIlluminant2, kShort, {0x8000 + 3400}),
    perFile(kTimeCodes, kByte, 16),
    field(kFrameRate, kSRational, {250000}),
    perFile(kReelName, kAscii, 16),
};

constexpr uint16_t kColorOrder[] = {kColorMatrix1, kColorMatrix2, kAsShotNeutral, kUniqueCameraModel,
                                    kFrameRate,    kBlackLevel,   kTimeCodes,     kReelName};

static_assert(layoutSize(kMonochromeFields, kMonochromeOrder) == 0x182, "monochrome template layout");
static_assert(layoutSize(kTungstenFields, kColorOrder) == 0x28a, "tungsten template layout");
static_assert(layoutSize(kDaylightFields, kColorOrder) == 0x28a, "daylight template layout");

constexpr Template<0x182> kMonochrome = build<0x182>(kMonochromeFields, kMonochromeOrder);
constexpr Template<0x28a> kTungsten = build<0x28a>(kTungstenFields, kColorOrder);
constexpr Template<0x28a> kDaylight = build<0x28a>(kDaylightFields, kColorOrder);

} // namespace dng
} // namespace ik

#endif // IK_DNG_TEMPLATES_H
