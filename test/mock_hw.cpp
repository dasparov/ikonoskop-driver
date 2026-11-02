// mock_hw.cpp — synthetic EEPROM / frame data for the ik_core harness.
#include "mock_hw.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace ik {
void *platformAlloc(size_t bytes) {
    return malloc(bytes);
}
void platformFree(void *ptr, size_t) {
    free(ptr);
}
} // namespace ik

namespace iktest {

namespace {

uint16_t fatDate(int y, int m, int d) {
    return (uint16_t)(((y - 1980) << 9) | (m << 5) | d);
}

uint16_t fatTime(int h, int m, int s) {
    return (uint16_t)((h << 11) | (m << 5) | (s / 2));
}

// Timecode helpers for readable scenario definitions.
uint32_t tcFrames(int h, int m, int s, int f, int base) {
    return (uint32_t)(((h * 60 + m) * 60 + s) * base + f);
}

const Scenario kScenarios[] = {
    {
        "main",
        1042,                 // card number (shown mod 1000: 042)
        0x2800,               // erase block = 40 MiB
        100 * 0x2800,         // 100 erase blocks = 4000 MiB flash
        false,
        4,
        {
            // 3 frames, daylight, 25 fps, TC 10:00:00:07
            {0, 3, 25, false, 25, tcFrames(10, 0, 0, 7, 25), tcFrames(10, 0, 0, 0, 25), 0, 0x0123,
             fatTime(14, 22, 10), fatDate(2013, 4, 3), true},
            // 1030 frames (two directory clusters), tungsten, 29.97, TC crosses 02:00:00:00,
            // aux TC crosses 24h, timecodes swapped
            {1, 1030, 0x1d, true, 30, tcFrames(1, 59, 58, 25, 30), tcFrames(23, 59, 50, 3, 29), 1, 0xfff3,
             fatTime(15, 0, 0), fatDate(2013, 4, 4), false},
            // 2 frames, monochrome sensor, 23.976
            {84, 2, 0x17, true, 24, tcFrames(0, 0, 0, 0, 24), tcFrames(0, 59, 59, 22, 23), 0, 0x000e,
             fatTime(9, 5, 30), fatDate(2013, 4, 5), true},
            // corrupt take: first block beyond the card -> listed as one frame at page 0
            {0xffff, 5, 50, false, 50, tcFrames(12, 0, 0, 0, 50), tcFrames(12, 0, 0, 0, 50), 0, 0x0001,
             fatTime(23, 59, 58), fatDate(2013, 12, 31), true},
        },
    },
    {
        "bw25-then-tungsten",
        7,
        0x2800,
        4 * 0x2800,
        false,
        2,
        {
            {0, 2, 25, false, 25, tcFrames(1, 0, 0, 0, 25), tcFrames(1, 0, 0, 0, 25), 0, 0x000e,
             fatTime(10, 0, 0), fatDate(2012, 9, 3), true},
            {1, 2, 24, true, 24, tcFrames(2, 0, 0, 0, 24), tcFrames(2, 0, 0, 0, 24), 0, 0x0003,
             fatTime(11, 0, 0), fatDate(2012, 9, 3), true},
        },
    },
    {
        // Nearly full card: frame files run past the original blockCount formula, which
        // ignored that file data starts at LBA 0x2c840. Every file must still be readable.
        "near-full",
        3,
        0x2800,
        2 * 0x2800,
        false,
        1,
        {
            {0, 24, 25, false, 25, tcFrames(3, 0, 0, 0, 25), tcFrames(3, 0, 0, 0, 25), 0, 0x0003,
             fatTime(12, 0, 0), fatDate(2013, 6, 1), true},
        },
    },
    {
        // The FPGA has not published the flash geometry yet (regs 0x2c/0x30 read 0, seen right
        // after a Thunderbolt hot-plug). The card has the default 80 GB geometry; every take
        // must still map to its own erase block, including the last one (0x77f of 0x780).
        "geometry-unreported",
        5,
        0x2800,
        0x12c0000,
        true,
        3,
        {
            {0, 3, 25, false, 25, tcFrames(9, 0, 0, 0, 25), tcFrames(9, 0, 0, 0, 25), 0, 0x0003,
             fatTime(9, 0, 0), fatDate(2019, 10, 5), true},
            {1, 4, 25, true, 25, tcFrames(9, 10, 0, 0, 25), tcFrames(9, 10, 0, 0, 25), 0, 0x0003,
             fatTime(9, 10, 0), fatDate(2019, 10, 5), true},
            {0x77f, 2, 25, false, 25, tcFrames(9, 20, 0, 0, 25), tcFrames(9, 20, 0, 0, 25), 0, 0x0003,
             fatTime(9, 20, 0), fatDate(2019, 10, 5), true},
        },
    },
};

void put16(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}

void put32(uint8_t *p, uint32_t v) {
    put16(p, v);
    put16(p + 2, v >> 16);
}

uint32_t erasableBlocks(const Scenario &sc) {
    return sc.flashSize / sc.eraseBlockSize;
}

} // namespace

const Scenario &scenario(int index) {
    return kScenarios[index];
}

int scenarioCount() {
    return (int)(sizeof(kScenarios) / sizeof(kScenarios[0]));
}

void buildEeprom(const Scenario &sc, uint8_t *e) {
    memset(e, 0xff, 0x2000);           // erased EEPROM
    memset(e, 0, 0x18);
    put16(e + 0, 3);                    // metadata version 3
    put16(e + 2, sc.cardNo);
    put32(e + 4, 0x18);                 // header size / take table offset
    put32(e + 0x10, 0x18);
    put32(e + 0x14, sc.takeCount);      // nr_takes
    for (uint32_t i = 0; i < sc.takeCount; i++) {
        const TakeSpec &t = sc.takes[i];
        uint8_t *p = e + 0x18 + i * 0x14;
        memset(p, 0, 0x14);
        p[0] = 1;                                           // valid
        p[1] = (uint8_t)((t.fps & 0x7f) | (t.tungsten ? 0x80 : 0));
        put16(p + 2, t.firstBlock);
        put16(p + 4, t.frames);
        put32(p + 6, (t.absTimecode & 0xffffff) | ((uint32_t)t.timecodeBase << 24));
        put32(p + 10, ((uint32_t)t.fatTime << 16) | t.fatDate);
        put16(p + 14, t.sensorWord);
        put32(p + 16, (t.absTimecodeAux & 0xffffff) | ((uint32_t)t.tcSwap << 24));
    }
}

bool expectedFramePage(const Scenario &sc, uint32_t frame, uint32_t *page, uint32_t *take) {
    uint32_t base = 0;
    for (uint32_t i = 0; i < sc.takeCount; i++) {
        const TakeSpec &t = sc.takes[i];
        bool corrupt = t.firstBlock >= erasableBlocks(sc);
        uint32_t n = corrupt ? 1 : t.frames;
        if (frame < base + n) {
            *page = corrupt ? 0 : t.firstBlock * sc.eraseBlockSize + (frame - base) * 0x335;
            *take = i;
            return true;
        }
        base += n;
    }
    return false;
}

uint32_t expectedFrameCount(const Scenario &sc) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < sc.takeCount; i++) {
        n += sc.takes[i].firstBlock >= erasableBlocks(sc) ? 1 : sc.takes[i].frames;
    }
    return n;
}

void buildFrame(const Scenario &sc, uint32_t page, uint8_t *dst) {
    bool dense = true;
    for (uint32_t i = 0; i < sc.takeCount; i++) {
        const TakeSpec &t = sc.takes[i];
        uint32_t first = t.firstBlock * sc.eraseBlockSize;
        if (t.firstBlock < erasableBlocks(sc) && page >= first && page < first + t.frames * 0x335u) {
            dense = t.dense;
            break;
        }
    }
    if (dense) {
        uint64_t x = 0x9e3779b97f4a7c15ull ^ ((uint64_t)page * 0xbf58476d1ce4e5b9ull) ^ sc.cardNo;
        for (uint32_t i = 0; i < ik::kFrameDmaBytes; i += 8) {
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            uint64_t v = x * 0x2545f4914f6cdd1dull;
            memcpy(dst + i, &v, 8);
        }
    } else {
        memset(dst, 0, ik::kFrameDmaBytes);
        // Image data start and DNGPrivateData start (raw offset 0x333000) carry the tag.
        snprintf((char *)dst + 0x333000, 32, "IKMOCK-PRIV page=%08x", page);
    }
    snprintf((char *)dst, 32, "IKMOCK page=%08x %c", page, dense ? 'D' : 'S');
}

MockHw::MockHw(const Scenario &s)
    : sc(s), frame((uint8_t *)malloc(ik::kFrameDmaBytes)), frameReads(0), failPage(~0u), quiet(true) {
    buildEeprom(sc, eeprom);
}

MockHw::~MockHw() {
    free(frame);
}

int MockHw::readEeprom(uint32_t addr, uint8_t *dst, uint32_t len) {
    if (len > 0x2000 || addr + len > 0x2000) {
        return -1;
    }
    memcpy(dst, eeprom + addr, len);
    return (int)len;
}

const uint8_t *MockHw::readFrame(uint32_t flashPage) {
    frameReads++;
    if (flashPage == failPage) {
        return nullptr;
    }
    buildFrame(sc, flashPage, frame);
    return frame;
}

uint32_t MockHw::readReg(uint32_t offset) {
    switch (offset) {
    case 0x2c:
        return sc.geometryUnreported ? 0 : sc.flashSize;
    case 0x30:
        return sc.geometryUnreported ? 0 : sc.eraseBlockSize;
    default:
        return 0;
    }
}

void MockHw::log(const char *fmt, ...) {
    if (quiet) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

} // namespace iktest
