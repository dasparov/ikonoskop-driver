// harness.cpp — exercises ik::VirtualCard against MockHw.
//
//   ik_harness dump <image>        check the DNG header templates, build the virtual disk, write
//                                  it as a sparse raw image and self-check random access, DMA
//                                  caching and error paths
//   ik_harness verify <mountpoint> check the mounted volume: tree, names, sizes, DNG/TIFF
//                                  structure, header fields and raw payload bytes
#include "mock_hw.h"
#include "../core/ik_dng_templates.h"

#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <string>
#include <vector>

using namespace iktest;

namespace {

const uint32_t kSector = 512;
const uint64_t kFileLba = 0x2c840;
const uint32_t kFileSpan = 0x2000;
const uint32_t kDngBytes = 0x336000;

int g_failures = 0;

void fail(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void fail(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "FAIL: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    if (++g_failures > 50) {
        fprintf(stderr, "too many failures\n");
        exit(1);
    }
}

#define CHECK(cond, ...)       \
    do {                       \
        if (!(cond)) {         \
            fail(__VA_ARGS__); \
        }                      \
    } while (0)

uint32_t rd16(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8);
}
uint32_t rd32(const uint8_t *p) {
    return rd16(p) | (rd16(p + 2) << 16);
}

bool allZero(const uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (p[i]) {
            return false;
        }
    }
    return true;
}

uint64_t rng = 0x1234567887654321ull;
uint64_t nextRand() {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}

// ---- DNG header templates ------------------------------------------------------------------

// core/ik_dng_templates.h must reproduce the three header templates of Ikonoskop's v1.2 driver
// byte for byte: SHA-256 of its __DATA templates at 0xe040, 0xe1e0 and 0xe480.
void checkDngTemplates() {
    struct Expect {
        const char *name;
        const uint8_t *bytes;
        size_t len;
        const char *sha256;
    };
    const Expect expect[] = {
        {"monochrome", ik::dng::kMonochrome.bytes, sizeof(ik::dng::kMonochrome.bytes),
         "35b87e01dbff45e8ffb8a2fb7b27315dc73ff4d3d3fab3a12cfc98df82d276c2"},
        {"tungsten", ik::dng::kTungsten.bytes, sizeof(ik::dng::kTungsten.bytes),
         "118e7fe91a4bd8f3f13137684f149b5a72515fdd846ad79732448b5cc63874b5"},
        {"daylight", ik::dng::kDaylight.bytes, sizeof(ik::dng::kDaylight.bytes),
         "d4b5c50c99757ae139707c7c2a738203fe4bf0ecd6f54887967c913d962e611b"},
    };
    const int before = g_failures;
    for (const Expect &e : expect) {
        uint8_t digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(e.bytes, (CC_LONG)e.len, digest);
        char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
            snprintf(hex + 2 * i, 3, "%02x", digest[i]);
        }
        CHECK(strcmp(hex, e.sha256) == 0, "%s DNG header template: SHA-256 %s, want %s", e.name, hex,
              e.sha256);
    }
    if (g_failures == before) {
        printf("DNG header templates: SHA-256 identical to the original driver's\n");
    }
}

// ---- dump ---------------------------------------------------------------------------------

int cmdDump(const Scenario &sc, const char *path) {
    checkDngTemplates();
    MockHw hw(sc);
    ik::VirtualCard card;
    if (card.init(&hw) != 0) {
        fail("VirtualCard::init");
        return 1;
    }
    const uint64_t sectors = card.sectorCount();
    const uint32_t frames = expectedFrameCount(sc);
    const uint64_t formula = (((uint64_t)sc.flashSize * 0x1000) >> 9 << 10) / 0x335;
    const uint64_t filesEnd = kFileLba + (uint64_t)frames * kFileSpan;
    const uint64_t blockCountExpect = formula > filesEnd ? formula : filesEnd;
    CHECK(sectors == blockCountExpect, "sectorCount %llu != %llu", (unsigned long long)sectors,
          (unsigned long long)blockCountExpect);
    CHECK(card.cardNumber() == sc.cardNo % 1000, "cardNumber %u", card.cardNumber());
    CHECK(kFileLba + (uint64_t)frames * kFileSpan <= sectors, "scenario files exceed the disk");
    printf("scenario %s: card %u, %u frames, %llu sectors (%.2f GiB)\n", sc.name, card.cardNumber(), frames,
           (unsigned long long)sectors, sectors * 512.0 / (1ull << 30));

    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        fail("open %s: %s", path, strerror(errno));
        return 1;
    }
    // Size the file first so that skipped all-zero blocks stay holes.
    if (ftruncate(fd, (off_t)(sectors * kSector)) != 0) {
        fail("ftruncate: %s", strerror(errno));
        return 1;
    }
    const uint32_t chunk = 2048;
    std::vector<uint8_t> buf((size_t)chunk * kSector);
    for (uint64_t lba = 0; lba < sectors; lba += chunk) {
        uint32_t n = (uint32_t)(sectors - lba < chunk ? sectors - lba : chunk);
        if (card.readSectors(lba, n, buf.data()) != 0) {
            fail("readSectors(%llu, %u)", (unsigned long long)lba, n);
            return 1;
        }
        for (uint32_t off = 0; off < n * kSector; off += 4096) {
            uint32_t len = n * kSector - off < 4096 ? n * kSector - off : 4096;
            if (!allZero(buf.data() + off, len) &&
                pwrite(fd, buf.data() + off, len, (off_t)(lba * kSector + off)) != (ssize_t)len) {
                fail("pwrite: %s", strerror(errno));
                return 1;
            }
        }
    }
    // Sequential reading DMAs every frame exactly once (frame cache, header without DMA).
    CHECK(hw.frameReads == frames, "sequential dump issued %u frame DMAs for %u frames", hw.frameReads, frames);

    // Random access with a fresh instance must match the sequential image byte for byte,
    // including requests that straddle region, header/raw, raw/tail and file boundaries.
    {
        MockHw hw2(sc);
        ik::VirtualCard card2;
        CHECK(card2.init(&hw2) == 0, "init #2");
        const uint64_t edges[] = {0, 6, 0x40, 0xc8c0 - 3, 0xc8c0, 0xc8c0 + 0x40 * 7 - 2, kFileLba - 5,
                                  kFileLba, kFileLba + 8, kFileLba + 8 + 0x19a8 - 4, kFileLba + kFileSpan - 3,
                                  kFileLba + (uint64_t)(frames - 1) * kFileSpan + 0x19a0,
                                  kFileLba + (uint64_t)frames * kFileSpan - 2, sectors - 300};
        std::vector<uint8_t> got(600 * kSector), want(600 * kSector);
        const uint64_t hot = kFileLba + (uint64_t)frames * kFileSpan + 64;
        for (int i = 0; i < 4000; i++) {
            uint64_t lba;
            uint64_t r = nextRand();
            if (i < 200) {
                lba = edges[i % (sizeof(edges) / sizeof(edges[0]))] + (r % 9);
            } else if (r % 4 == 0) {
                lba = r % sectors;
            } else {
                lba = (r >> 8) % hot;
            }
            uint32_t n = 1 + (uint32_t)((r >> 40) % ((r & 1) ? 16 : 600));
            if (lba + n > sectors) {
                lba = sectors - n;
            }
            if (card2.readSectors(lba, n, got.data()) != 0) {
                fail("random readSectors(%llu, %u)", (unsigned long long)lba, n);
                continue;
            }
            ssize_t rd = pread(fd, want.data(), (size_t)n * kSector, (off_t)(lba * kSector));
            if (rd != (ssize_t)(n * kSector) || memcmp(got.data(), want.data(), (size_t)n * kSector) != 0) {
                fail("random read mismatch at lba %llu count %u", (unsigned long long)lba, n);
            }
        }
        printf("random access: 4000 requests match the sequential image (%u frame DMAs)\n", hw2.frameReads);
    }

    // Interleaved readers (Finder copying several files while thumbnailing others): up to
    // kFrameCacheSlots files read round-robin in 300 KiB requests, the size msdosfs issued on
    // the real reader. Each frame must be DMA'd once and the bytes must match.
    {
        MockHw hw5(sc);
        ik::VirtualCard card5;
        CHECK(card5.init(&hw5) == 0, "init #5");
        const uint32_t streams = std::min(frames, ik::kFrameCacheSlots);
        const uint32_t chunk = 600;
        std::vector<uint8_t> got(chunk * kSector), want(chunk * kSector);
        for (uint32_t off = 0; off < kFileSpan; off += chunk) {
            const uint32_t n = std::min(chunk, kFileSpan - off);
            for (uint32_t k = 0; k < streams; k++) {
                const uint64_t lba = kFileLba + (uint64_t)k * kFileSpan + off;
                const size_t bytes = (size_t)n * kSector;
                if (card5.readSectors(lba, n, got.data()) != 0 ||
                    pread(fd, want.data(), bytes, (off_t)(lba * kSector)) != (ssize_t)bytes ||
                    memcmp(got.data(), want.data(), bytes) != 0) {
                    fail("interleaved read mismatch at lba %llu count %u", (unsigned long long)lba, n);
                }
            }
        }
        CHECK(hw5.frameReads == streams, "%u interleaved readers issued %u frame DMAs", streams, hw5.frameReads);
        printf("interleaved readers: %u files round-robin, %u frame DMAs\n", streams, hw5.frameReads);
    }

    // DMA failure: the raw part fails, the generated header still reads, and the frame is
    // re-read (not served from a stale cache) once the hardware recovers.
    {
        MockHw hw3(sc);
        ik::VirtualCard card3;
        CHECK(card3.init(&hw3) == 0, "init #3");
        uint32_t page = 0, take = 0;
        uint32_t frame = frames - 1;
        expectedFramePage(sc, frame, &page, &take);
        uint64_t lba = kFileLba + (uint64_t)frame * kFileSpan;
        std::vector<uint8_t> b(16 * kSector), want(16 * kSector);
        hw3.failPage = page;
        CHECK(card3.readSectors(lba, 16, b.data()) != 0, "read of a failing frame succeeded");
        CHECK(card3.readSectors(lba, 8, b.data()) == 0, "header read of a failing frame failed");
        hw3.failPage = ~0u;
        CHECK(card3.readSectors(lba, 16, b.data()) == 0, "read after recovery failed");
        CHECK(pread(fd, want.data(), want.size(), (off_t)(lba * kSector)) == (ssize_t)want.size() &&
                  memcmp(b.data(), want.data(), b.size()) == 0,
              "data after recovery differs");
        CHECK(card3.readSectors(sectors - 1, 1, b.data()) == 0, "last sector unreadable");
        CHECK(card3.readSectors(sectors - 1, 2, b.data()) != 0, "read past the end accepted");
        CHECK(card3.readSectors(sectors, 1, b.data()) != 0, "read at sectorCount accepted");
        printf("error paths: DMA failure reported, header unaffected, recovery re-reads the frame\n");
    }

    // Unreadable EEPROM: the volume still exists, with an empty IMAGE folder.
    {
        struct DeadEeprom : MockHw {
            explicit DeadEeprom(const Scenario &s) : MockHw(s) {}
            int readEeprom(uint32_t, uint8_t *, uint32_t) override { return -1; }
        } hw4(sc);
        ik::VirtualCard card4;
        CHECK(card4.init(&hw4) == 0, "init with dead EEPROM");
        std::vector<uint8_t> b(64 * kSector);
        CHECK(card4.readSectors(0xc8c0 + 6 * 0x40, 64, b.data()) == 0, "IMAGE dir read");
        CHECK(memcmp(b.data(), ".          ", 11) == 0 && memcmp(b.data() + 32, "..         ", 11) == 0 &&
                  allZero(b.data() + 64, b.size() - 64),
              "IMAGE folder not empty with dead EEPROM");
        printf("dead EEPROM: empty IMAGE folder\n");
    }
    close(fd);
    printf("dump: wrote %s\n", path);
    return g_failures ? 1 : 0;
}

// ---- verify --------------------------------------------------------------------------------

std::vector<std::string> listDir(const std::string &path) {
    std::vector<std::string> names;
    DIR *d = opendir(path.c_str());
    if (!d) {
        fail("opendir %s: %s", path.c_str(), strerror(errno));
        return names;
    }
    while (struct dirent *e = readdir(d)) {
        if (e->d_name[0] != '.') {
            names.push_back(e->d_name);
        }
    }
    closedir(d);
    std::sort(names.begin(), names.end());
    return names;
}

void smpte(uint32_t abs, uint32_t base, uint8_t out[8]) {
    memset(out, 0, 8);
    if (!base) {
        return;
    }
    uint32_t f = abs % base, s = abs / base;
    uint32_t ss = s % 60, mm = s / 60 % 60, hh = s / 3600 % 60;
    out[0] = (uint8_t)(((f / 10 & 3) << 4) | f % 10);
    out[1] = (uint8_t)(((ss / 10) << 4) | ss % 10);
    out[2] = (uint8_t)(((mm / 10) << 4) | mm % 10);
    out[3] = (uint8_t)(((hh / 10 & 3) << 4) | hh % 10);
}

struct Tag {
    uint32_t type, count, value;
    const uint8_t *data;
};

// Minimal TIFF IFD0 reader over the 4 KiB DNG header; returns false on structural errors.
bool parseTiff(const uint8_t *h, size_t len, Tag *tags, uint32_t maxTag, const char *file) {
    static const uint32_t kTypeSize[] = {0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8};
    if (memcmp(h, "II*\0", 4) != 0) {
        fail("%s: not a little-endian TIFF", file);
        return false;
    }
    uint32_t ifd = rd32(h + 4);
    if (ifd + 2 > len) {
        fail("%s: IFD0 offset %u out of header", file, ifd);
        return false;
    }
    uint32_t n = rd16(h + ifd);
    if (ifd + 2 + n * 12 + 4 > len) {
        fail("%s: IFD0 overruns the header", file);
        return false;
    }
    for (uint32_t i = 0; i < n; i++) {
        const uint8_t *e = h + ifd + 2 + i * 12;
        uint32_t tag = rd16(e), type = rd16(e + 2), count = rd32(e + 4), value = rd32(e + 8);
        if (tag == 0 && type == 0) {
            continue;   // the original templates carry one all-zero IFD entry
        }
        if (type == 0 || type > 12) {
            fail("%s: tag %u has bad type %u", file, tag, type);
            return false;
        }
        uint64_t size = (uint64_t)kTypeSize[type] * count;
        const uint8_t *data = size <= 4 ? e + 8 : nullptr;
        if (size > 4) {
            if (value + size <= len) {
                data = h + value;
            } else if (value + size > kDngBytes) {
                fail("%s: tag %u data [%u,+%llu) outside the file", file, tag, value, (unsigned long long)size);
                return false;
            }
        }
        if (tag < maxTag) {
            tags[tag] = Tag{type, count, value, data};
        }
    }
    if (rd32(h + ifd + 2 + n * 12) != 0) {
        fail("%s: unexpected IFD1", file);
    }
    return true;
}

void checkDng(const Scenario &sc, uint32_t frame, const std::string &path, std::vector<uint8_t> &file,
              std::vector<uint8_t> &frameData) {
    uint32_t page = 0, take = 0;
    if (!expectedFramePage(sc, frame, &page, &take)) {
        fail("%s: unexpected frame", path.c_str());
        return;
    }
    const TakeSpec &t = sc.takes[take];
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        fail("open %s: %s", path.c_str(), strerror(errno));
        return;
    }
    ssize_t got = 0;
    while (got < (ssize_t)kDngBytes) {
        ssize_t r = read(fd, file.data() + got, kDngBytes - got);
        if (r <= 0) {
            break;
        }
        got += r;
    }
    close(fd);
    if (got != (ssize_t)kDngBytes) {
        fail("%s: read %zd bytes", path.c_str(), got);
        return;
    }
    const char *name = path.c_str();
    static Tag tags[0x10000];
    memset(tags, 0, sizeof(tags));
    if (!parseTiff(file.data(), 4096, tags, 0x10000, name)) {
        return;
    }
    CHECK(tags[256].value == 2048 && tags[257].value == 1092, "%s: dimensions", name);
    CHECK(tags[258].value == 12, "%s: bits per sample", name);
    CHECK(tags[273].value == 4096 && tags[279].value == 0x333000, "%s: strip", name);
    CHECK(tags[50740].count == 8192 && tags[50740].value == 0x334000, "%s: DNGPrivateData", name);
    bool mono = (t.sensorWord & 0xf) == 0xe;
    CHECK(tags[262].value == (mono ? 34892u : 32803u), "%s: photometric interpretation", name);
    if (!mono) {
        const uint8_t *n = tags[50728].data;   // AsShotNeutral, first rational
        uint32_t num = n ? rd32(n) : 0;
        CHECK(num == (t.tungsten ? 8881u : 127u), "%s: white balance template (AsShotNeutral %u)", name, num);
        CHECK(tags[50706].data && memcmp(tags[50706].data, "\x01\x02\x00\x00", 4) == 0, "%s: DNGVersion", name);
    }
    // FrameRate
    uint32_t num = t.fps, den = 1;
    if (t.fps == 0x1d) {
        num = 2997;
        den = 100;
    } else if (t.fps == 0x17) {
        num = 23976;
        den = 1000;
    }
    const uint8_t *fr = tags[51044].data;
    CHECK(tags[51044].type == 10 && fr && rd32(fr) == num && rd32(fr + 4) == den, "%s: FrameRate", name);
    // TimeCodes
    uint32_t firstFrame = 0, page2, take2;
    while (expectedFramePage(sc, firstFrame, &page2, &take2) && take2 < take) {
        firstFrame++;
    }
    uint8_t prim[8], aux[8];
    smpte(frame - firstFrame + t.absTimecode, t.timecodeBase, prim);
    smpte(frame - firstFrame + t.absTimecodeAux, t.fps, aux);
    const uint8_t *tc = tags[51043].data;
    CHECK(tc && tags[51043].count == 16, "%s: TimeCodes tag", name);
    if (tc) {
        CHECK(memcmp(tc, t.tcSwap ? aux : prim, 8) == 0 && memcmp(tc + 8, t.tcSwap ? prim : aux, 8) == 0,
              "%s: TimeCodes %02x:%02x:%02x:%02x", name, tc[3], tc[2], tc[1], tc[0]);
    }
    // ReelName
    char reel[16] = {0};
    snprintf(reel, sizeof(reel), "AC%03u%03u", sc.cardNo % 1000, take + 1);
    CHECK(tags[51081].data && memcmp(tags[51081].data, reel, 9) == 0, "%s: ReelName", name);
    // Header tail and raw payload
    uint32_t tplLen = mono ? 0x182 : 0x28a;
    CHECK(allZero(file.data() + tplLen, 4096 - tplLen), "%s: header padding not zero", name);
    buildFrame(sc, page, frameData.data());
    CHECK(memcmp(file.data() + 4096, frameData.data(), ik::kFrameDmaBytes) == 0, "%s: payload != frame page %u",
          name, page);
}

int cmdVerify(const Scenario &sc, const char *mnt) {
    std::string root = mnt;
    std::vector<std::string> top = listDir(root);
    const char *expectTop[] = {"AUDIO", "CLIP", "ICON", "IMAGE", "PROXY", "VIDEO"};
    CHECK(top.size() == 6, "root has %zu entries", top.size());
    for (size_t i = 0; i < top.size() && i < 6; i++) {
        CHECK(top[i] == expectTop[i], "root entry %s", top[i].c_str());
    }
    for (const char *d : {"AUDIO", "CLIP", "ICON", "PROXY", "VIDEO"}) {
        CHECK(listDir(root + "/" + d).empty(), "%s not empty", d);
    }
    std::vector<std::string> takes = listDir(root + "/IMAGE");
    CHECK(takes.size() == sc.takeCount, "IMAGE has %zu takes", takes.size());
    std::vector<uint8_t> file(kDngBytes), frameData(ik::kFrameDmaBytes);
    uint32_t frame = 0, files = 0;
    for (uint32_t t = 0; t < sc.takeCount && t < takes.size(); t++) {
        char want[16];
        snprintf(want, sizeof(want), "AC%03u%03u", sc.cardNo % 1000, t + 1);
        CHECK(takes[t] == want, "take dir %s, want %s", takes[t].c_str(), want);
        std::string dir = root + "/IMAGE/" + takes[t];
        std::vector<std::string> dngs = listDir(dir);
        uint32_t page, take;
        uint32_t n = 0;
        while (expectedFramePage(sc, frame + n, &page, &take) && take == t) {
            n++;
        }
        CHECK(dngs.size() == n, "%s has %zu files, want %u", dir.c_str(), dngs.size(), n);
        printf("  IMAGE/%s: %zu files (%s .. %s)\n", takes[t].c_str(), dngs.size(),
               dngs.empty() ? "" : dngs.front().c_str(), dngs.empty() ? "" : dngs.back().c_str());
        for (uint32_t i = 0; i < n && i < dngs.size(); i++) {
            char fname[16];
            snprintf(fname, sizeof(fname), "%03u%05u.DNG", sc.cardNo % 1000, frame + i + 1);
            CHECK(dngs[i] == fname, "file %s, want %s", dngs[i].c_str(), fname);
            std::string path = dir + "/" + dngs[i];
            struct stat st;
            CHECK(stat(path.c_str(), &st) == 0 && st.st_size == kDngBytes, "%s: size %lld", path.c_str(),
                  (long long)st.st_size);
            checkDng(sc, frame + i, path, file, frameData);
            files++;
        }
        frame += n;
    }
    printf("verify: %u DNG files checked (TIFF structure, tags, timecodes, payload)\n", files);
    return g_failures ? 1 : 0;
}

} // namespace

int main(int argc, char **argv) {
    int sc = 0;
    if (argc >= 5 && strcmp(argv[3], "--scenario") == 0) {
        sc = atoi(argv[4]);
    }
    if (argc < 3 || sc < 0 || sc >= scenarioCount()) {
        fprintf(stderr, "usage: %s dump <image> | verify <mountpoint> [--scenario N]\n", argv[0]);
        return 2;
    }
    int rc;
    if (strcmp(argv[1], "dump") == 0) {
        rc = cmdDump(scenario(sc), argv[2]);
    } else if (strcmp(argv[1], "verify") == 0) {
        rc = cmdVerify(scenario(sc), argv[2]);
    } else {
        fprintf(stderr, "unknown command %s\n", argv[1]);
        return 2;
    }
    if (rc != 0 || g_failures) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    return 0;
}
