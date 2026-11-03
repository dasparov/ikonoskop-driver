// ik_core.cpp — virtual FAT32 / CinemaDNG volume of the Ikonoskop A-Cam dII card reader.
//
// Reconstruction of IkonoskopCardReader.kext v1.2 (x86_64): eeprom_*, update_fat32 and
// friends, fetch_sectors and the sector-assembly half of fpga_read_dma. Function names in
// comments refer to the original symbols; "this+0xNNN" to fields of the original
// com_Ikonoskop_driver_CardReader object. Cross-checked against the camera firmware 1.28
// implementation of the same logic (virtualfat32.ko / eeprom.ko).
//
// Kernel-safe: no STL, exceptions, RTTI or floating point; all tables live on the heap.
#include "ik_core.h"
#include "ik_dng_templates.h"

#include <string.h>

extern "C" int snprintf(char *str, size_t size, const char *format, ...);

namespace ik {

namespace {

// ---- Volume geometry (init_fat32 BPB, fetch_sectors LBA map) -------------------------------
const uint32_t kSectorBytes = 0x200;
const uint32_t kReservedSectors = 0x40;                          // BPB 0x0e, boot area LBAs
const uint32_t kFatSectors = 0xc880;                             // BPB 0x24, one FAT
const uint32_t kDataLba = kReservedSectors + kFatSectors;        // 0xc8c0, cluster 2
const uint32_t kSectorsPerCluster = 0x40;                        // BPB 0x0d
const uint32_t kClusterBytes = kSectorsPerCluster * kSectorBytes; // 0x8000
const uint32_t kDirClusterCount = 0x7fe;                         // clusters 2..0x7ff are directories
const uint32_t kMaxDirCluster = kDirClusterCount + 1;            // 0x7ff
const uint32_t kFileLba = kDataLba + kDirClusterCount * kSectorsPerCluster; // 0x2c840, cluster 0x800
const uint32_t kFileSectorsShift = 13;                           // 0x80 clusters (4 MiB) per frame file
const uint32_t kFileSectorSpan = 1u << kFileSectorsShift;        // 0x2000
const uint32_t kHeaderSectors = 8;                               // generated DNG header (4 KiB)
const uint32_t kHeaderBytes = kHeaderSectors * kSectorBytes;     // 0x1000
const uint32_t kRawSectors = kFrameDmaBytes / kSectorBytes;      // 0x19a8
const uint32_t kDngFileBytes = kHeaderBytes + kFrameDmaBytes;    // 0x336000
const uint32_t kDngFileClusters = (kDngFileBytes + kClusterBytes - 1) / kClusterBytes; // 103
const uint32_t kTotalSectors = 0x1900c8c0;                       // BPB 0x20
const uint32_t kClusterCount = (kTotalSectors - kDataLba) / kSectorsPerCluster; // 0x640000
const uint32_t kFatTableEntries = 0x800;                         // this+0x140: FAT sectors 0..15
const uint32_t kFatTableSectors = kFatTableEntries * 4 / kSectorBytes; // 16
const uint32_t kFatEoc = 0x0fffffff;
const uint32_t kFatChainEnd = 0x0ffffff8;                        // fetch_fat_sector, entry 127
const uint32_t kDirEntryBytes = 0x20;
const uint32_t kRootCluster = 2;
const uint32_t kImageCluster = 8;
const uint32_t kFirstTakeCluster = 9;
const uint32_t kFirstClusterFiles = 0x3fe;                       // '.' and '..' take two slots
const uint32_t kClusterFiles = kClusterBytes / kDirEntryBytes;   // 0x400
const uint32_t kMaxFramesPerTake = 100000;                       // update_fat32 sanity bound

// ---- Card metadata EEPROM (_ee_prom = read_buffer + 3) --------------------------------------
const uint32_t kEepromBytes = 0x2000;
const uint32_t kTakeTable = 0x18;
const uint32_t kTakeEntryBytes = 0x14;
const uint32_t kMaxTakes = 0x198;
const uint32_t kMaxFrames = 55000;                               // frame2page_table capacity
const uint32_t kPagesPerFrame = 0x335;                           // 0x335000 / 4 KiB

// Initial values of the original's g_erasable_blocks / g_erase_block_size / g_flash_size
// (__DATA 0xe020..0xe02b), i.e. the geometry of the 80 GB card; used until the FPGA reports one.
const uint32_t kDefaultErasableBlocks = 0x780;
const uint32_t kDefaultEraseBlockSize = 0x2800;
const uint32_t kDefaultFlashSize = 0x12c0000;

const uint32_t kRegFlashSize = 0x2c;                             // 4 KiB units
const uint32_t kRegEraseBlockSize = 0x30;

const uint32_t kNoFrame = 0xffffffffu;

// One entry of the directory-cluster table (this+0x148, 0x7fe x 0x14 bytes), indexed by
// cluster - 9. Written by update_fat32, read by create_dir_cluster.
struct DirClusterInfo {
    uint32_t flags;        // bit 0: first cluster of a take directory ('.' and '..' present)
    uint32_t firstFrame;   // global index of the first frame listed in this cluster
    uint32_t count;        // number of DNG entries in this cluster
    uint32_t takeOffset;   // index of firstFrame within its take (stored, never read)
    uint32_t take;         // take index (create time source)
};

inline void put16(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}

inline void put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

inline uint32_t get16(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8);
}

inline uint32_t get32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// strncpy(dst, src, n) into a zeroed buffer.
inline void copyName(uint8_t *dst, const char *src, uint32_t n) {
    for (uint32_t i = 0; i < n && src[i] != '\0'; i++) {
        dst[i] = (uint8_t)src[i];
    }
}

// One cached frame of raw DMA data.
struct FrameSlot {
    uint32_t frame;    // kNoFrame when empty
    uint64_t lastUse;  // CardState::frameClock at the last hit; 0 when empty
    uint8_t *data;     // kFrameDmaBytes
};

// All volume state; VirtualCard::State (opaque in the header) derives from it so the
// file-local helpers below can take it by pointer.
struct CardState {
    HwOps *hw;
    uint8_t *eeprom;              // _ee_prom, kEepromBytes
    uint8_t *bootSector;          // this+0x128
    uint8_t *fsInfo;              // this+0x130
    uint8_t *fatTable;            // this+0x140, kFatTableEntries x u32 (LE)
    DirClusterInfo *clusterInfo;  // this+0x148, kDirClusterCount entries
    uint8_t *rootDir;             // this+0x150, cluster 2
    uint8_t *imageDir;            // this+0x158, cluster 8
    uint8_t *dirCache;            // this+0x160, one generated directory cluster
    uint32_t dirCacheIndex;       // this+0x168, directory index (cluster - 2) held in dirCache
    uint32_t *takeFrames;         // this+400, frames per take, zero terminated
    uint32_t takeFramesEntries;
    uint32_t takeCount;           // this+0x198
    uint32_t frameCount;          // this+0x19c, frames with a flash page
    uint32_t listedFrames;        // DNG files listed in the take directories
    uint16_t cardNo;              // this+0x1a0, card number mod 1000
    uint32_t *frame2page;         // frame2page_table, kMaxFrames entries
    uint32_t eraseBlockSize;      // g_erase_block_size
    uint32_t flashSize;           // g_flash_size
    uint32_t erasableBlocks;      // g_erasable_blocks
    uint64_t sectorCount;         // this+0x1b0
    // Frame cache. The original kept only the frame in its DMA buffer (this+0x16c), so two
    // interleaved readers re-DMA'd a whole frame for every request (measured: 141 MB/s with one
    // reader, 26 MB/s with two). Frames are copied out of the DMA buffer into LRU slots.
    FrameSlot frames[kFrameCacheSlots];
    uint64_t frameClock;
    uint32_t headerFrame;         // frame whose DNG header is in `header`
    uint8_t *header;              // kHeaderBytes
};

} // namespace

struct VirtualCard::State : CardState {};

namespace {

typedef CardState State;

// ---- EEPROM accessors ------------------------------------------------------------------------

inline const uint8_t *takeEntry(const State *s, uint32_t take) {
    return s->eeprom + kTakeTable + take * kTakeEntryBytes;
}

// eeprom_refresh: read the whole EEPROM; retry once when the first bytes read back as zero.
// The original tested read_buffer[0..9], i.e. the 3 bytes clocked in during the SPI command
// phase plus _ee_prom[0..6]; HwOps::readEeprom drops the command-phase bytes, so only
// _ee_prom[0..6] can be tested here.
bool eepromLooksValid(const State *s) {
    for (uint32_t i = 0; i < 7; i++) {
        if (s->eeprom[i] != 0) {
            return true;
        }
    }
    return false;
}

int eepromRefresh(State *s) {
    int res = s->hw->readEeprom(0, s->eeprom, kEepromBytes);
    if (res != (int)kEepromBytes) {
        s->hw->log("eeprom_refresh: flash_eeprom_read returns: %d\n", res);
        return -1;
    }
    if (eepromLooksValid(s)) {
        return 0;
    }
    s->hw->log("Reading EEPROM failed, trying again ... \n");
    s->hw->readEeprom(0, s->eeprom, kEepromBytes);
    if (eepromLooksValid(s)) {
        return 0;
    }
    s->hw->log("Reading EEPROM failed !!!!!1\n");
    return -1;
}

// eeprom_init: read_buffer[0..0x13] = 0xfe (i.e. _ee_prom[0..0x10]) before the first read.
int eepromInit(State *s) {
    memset(s->eeprom, 0, kEepromBytes);
    memset(s->eeprom, 0xfe, 0x14 - 3);
    return eepromRefresh(s);
}

// eeprom_get_card_no
uint16_t eepromCardNo(const State *s) {
    return (uint16_t)get16(s->eeprom + 2);
}

// eeprom_get_create_time: high 16 bits = FAT time, low 16 bits = FAT date.
void eepromCreateTime(const State *s, uint32_t take, uint16_t *time, uint16_t *date) {
    uint32_t v = get32(takeEntry(s, take) + 10);
    *time = (uint16_t)(v >> 16);
    *date = (uint16_t)v;
}

// eeprom_get_white_balance: non-zero = tungsten.
uint32_t eepromWhiteBalance(const State *s, uint32_t take) {
    return takeEntry(s, take)[1] & 0x80;
}

struct DngInfo {
    uint32_t absTimecode;     // primary timecode, frames since 00:00:00:00
    uint32_t timecodeBase;    // primary timecode frame base
    uint8_t framerate;        // 0x1d = 29.97, 0x17 = 23.976, else integer fps
    uint32_t absTimecodeAux;  // auxiliary timecode, counted in `framerate` frames
    uint32_t tcSwap;          // non-zero: aux timecode stored first in TimeCodes
    uint16_t sensorType;      // 0xe = monochrome sensor
};

// eeprom_get_dng_info
void eepromDngInfo(const State *s, uint32_t take, DngInfo *info) {
    const uint8_t *e = takeEntry(s, take);
    uint32_t tc = get32(e + 6);
    uint32_t aux = get32(e + 16);
    info->absTimecode = tc & 0xffffff;
    info->timecodeBase = tc >> 24;
    info->absTimecodeAux = aux & 0xffffff;
    info->tcSwap = aux >> 24;
    info->framerate = e[1] & 0x7f;
    info->sensorType = (uint16_t)(get16(e + 14) & 0xf);
}

// Number of consecutive valid take entries (eeprom_get_take_array / frame2page loop guard).
uint32_t eepromValidTakes(const State *s) {
    uint32_t n = 0;
    while (n < kMaxTakes && takeEntry(s, n)[0] == 1) {
        n++;
    }
    return n;
}

// eeprom_get_take_array: frames per take; a take whose first erase block lies beyond the
// card counts as one frame. Also latches the flash geometry from the FPGA.
//
// Deviation: the original stored reg 0x30 unconditionally. Right after a Thunderbolt hot-plug
// the FPGA can still report 0 for both registers; an erase block size of 0 then put the first
// frame of every take at flash page 0, so takes 2+ served take 1's frames and data straddling
// take boundaries. A geometry the FPGA does not report keeps the defaults instead.
int eepromGetTakeArray(State *s) {
    uint32_t count = eepromValidTakes(s);
    uint32_t eraseBlockSize = s->hw->readReg(kRegEraseBlockSize);
    uint32_t flashSize = s->hw->readReg(kRegFlashSize);
    if (eraseBlockSize != 0 && flashSize / eraseBlockSize != 0) {
        s->eraseBlockSize = eraseBlockSize;
        s->flashSize = flashSize;
        s->erasableBlocks = flashSize / eraseBlockSize;
    } else {
        s->hw->log("flash geometry not reported (FLASH_SIZE 0x%x, FLASH_ERASE_SIZE 0x%x), using 0x%x / 0x%x\n",
                   flashSize, eraseBlockSize, s->flashSize, s->eraseBlockSize);
    }
    if (s->takeFrames) {
        platformFree(s->takeFrames, s->takeFramesEntries * sizeof(uint32_t));
        s->takeFrames = nullptr;
    }
    s->takeFramesEntries = count + 1;
    s->takeFrames = (uint32_t *)platformAlloc(s->takeFramesEntries * sizeof(uint32_t));
    if (!s->takeFrames) {
        s->takeFramesEntries = 0;
        return -1;
    }
    uint32_t i;
    for (i = 0; i < count; i++) {
        const uint8_t *e = takeEntry(s, i);
        uint32_t firstBlock = get16(e + 2);
        if (firstBlock < s->erasableBlocks) {
            s->takeFrames[i] = get16(e + 4);
        } else {
            s->hw->log("ERROR: eeprom_get_take_array:, take %u, first_block = %u\n", i, firstBlock);
            s->takeFrames[i] = 1;
        }
    }
    s->takeFrames[i] = 0;
    s->takeCount = count;
    return 0;
}

// eeprom_create_frame2page_table: flash page (4 KiB units) of every frame, in take order.
uint32_t eepromCreateFrame2PageTable(State *s) {
    uint32_t version = get16(s->eeprom);
    if (version == 0xffff) {
        return 0;
    }
    if (version == 0) {
        s->hw->log("No Flashcard detected!\n");
        return 0;
    }
    uint32_t frames = 0;
    bool corruptReported = false;
    for (uint32_t take = 0; take < kMaxTakes && takeEntry(s, take)[0] == 1; take++) {
        const uint8_t *e = takeEntry(s, take);
        uint32_t firstBlock = get16(e + 2);
        uint32_t takeFrames = get16(e + 4);
        for (uint32_t i = 0; i < takeFrames; i++) {
            if (firstBlock >= s->erasableBlocks) {
                s->hw->log("ERROR: eeprom_create_frame2page_table, corrupted data take %u, block =%u!\n",
                           take, firstBlock);
                if (frames < kMaxFrames) {
                    s->frame2page[frames++] = 0;
                    break;
                }
            }
            if (frames >= kMaxFrames) {
                s->hw->log("ERROR: eeprom_create_frame2page_table, corrupted data take %u!\n", take);
                break;
            }
            uint32_t page = firstBlock * s->eraseBlockSize + i * kPagesPerFrame;
            if (page >= s->eraseBlockSize * s->erasableBlocks && !corruptReported) {
                s->hw->log("ERROR: eeprom_create_frame2page_table, corrupted data frame %u!\n", frames);
                page = 0;
                corruptReported = true;
            }
            s->frame2page[frames++] = page;
        }
    }
    return frames;
}

// eeprom_get_page
uint32_t eepromGetPage(const State *s, uint32_t frame) {
    if (frame < kMaxFrames) {
        return s->frame2page[frame];
    }
    s->hw->log("eeprom_get_page, bad frame_nr, %u\n", frame);
    return 0;
}

// frame_to_take: take containing `frame`; *firstFrame = global index of its first frame.
uint32_t frameToTake(const State *s, uint32_t frame, uint32_t *firstFrame) {
    uint32_t sum = 0;
    *firstFrame = 0;
    for (uint32_t take = 0; take < s->takeCount; take++) {
        sum += s->takeFrames[take];
        if (frame < sum) {
            return take;
        }
        *firstFrame = sum;
    }
    return 0;
}

// ---- SMPTE timecode (abs_timecode_to_smpte + get_timecode_smpte) ------------------------------

// Packs an absolute frame count into the 8-byte SMPTE 12M form stored in the DNG TimeCodes
// tag: BCD frames, seconds, minutes, hours (hours wrap at 60 and keep 2 tens bits, as in the
// original), user bits zero. The original divided by `base` unguarded; base 0 yields zeros.
void absTimecodeToSmpte(int32_t abs, int32_t base, uint8_t out[8]) {
    memset(out, 0, 8);
    if (base == 0) {
        return;
    }
    int32_t frames = abs % base;
    int32_t secs = (abs - frames) / base;
    int32_t ss = secs % 60;
    secs /= 60;
    int32_t mm = secs % 60;
    int32_t hh = (secs / 60) % 60;
    out[0] = (uint8_t)((((frames / 10) & 3) << 4) | ((frames - (frames / 10) * 10) & 0xf));
    out[1] = (uint8_t)((((ss / 10) & 7) << 4) | ((ss - (ss / 10) * 10) & 0xf));
    out[2] = (uint8_t)((((mm / 10) & 7) << 4) | ((mm - (mm / 10) * 10) & 0xf));
    out[3] = (uint8_t)((((hh / 10) & 3) << 4) | ((hh - (hh / 10) * 10) & 0xf));
}

// ---- DNG header (create_dng_header) ----------------------------------------------------------

// Builds the 4 KiB header of a DNG file: template, frame rate, timecodes, reel name, zero
// padding. The original patched its static templates in place; every patched field is
// rewritten on each call, so building from the pristine template is equivalent — except for
// the monochrome "other frame rate" branch, where v1.2 stored the denominator 1 at template
// offset 0x25e (outside the 0x182-byte monochrome template, corrupting the tungsten template's
// DNGVersion entry) instead of 0x156. This follows camera firmware 1.28 and writes 0x156.
void createDngHeader(const State *s, uint32_t sensorType, uint32_t take, uint8_t framerate,
                     uint32_t tcSwap, const uint8_t prim[8], const uint8_t aux[8], uint8_t *out) {
    char reel[9];
    snprintf(reel, sizeof(reel), "AC%03d%03d   ", (int)s->cardNo, (int)(take + 1));

    const uint8_t *tpl;
    uint32_t len, rateOff, tcOff, reelOff;
    if (sensorType == 0xe) {
        tpl = dng::kMonochrome.bytes;
        len = sizeof(dng::kMonochrome.bytes);
        rateOff = 0x152;
        tcOff = 0x162;
        reelOff = 0x172;
    } else {
        tpl = eepromWhiteBalance(s, take) ? dng::kTungsten.bytes : dng::kDaylight.bytes;
        len = sizeof(dng::kDaylight.bytes);
        rateOff = 0x25a;
        tcOff = 0x26a;
        reelOff = 0x27a;
    }
    memcpy(out, tpl, len);
    memset(out + len, 0, kHeaderBytes - len);

    // FrameRate (SRATIONAL)
    uint32_t num = framerate, den = 1;
    if (framerate == 0x1d) {
        num = 2997;
        den = 100;
    } else if (framerate == 0x17) {
        num = 23976;
        den = 1000;
    }
    put32(out + rateOff, num);
    put32(out + rateOff + 4, den);

    // TimeCodes: primary first unless tc_swap.
    memcpy(out + tcOff + (tcSwap ? 8 : 0), prim, 8);
    memcpy(out + tcOff + (tcSwap ? 0 : 8), aux, 8);

    // ReelName
    memcpy(out + reelOff, reel, sizeof(reel));
}

// The header part of fpga_read_dma for one frame.
void buildHeader(State *s, uint32_t frame) {
    if (s->headerFrame == frame) {
        return;
    }
    uint32_t firstFrame;
    uint32_t take = frameToTake(s, frame, &firstFrame);
    DngInfo info;
    eepromDngInfo(s, take, &info);
    uint8_t prim[8], aux[8];
    absTimecodeToSmpte((int32_t)(frame - firstFrame + info.absTimecode), (int32_t)info.timecodeBase, prim);
    absTimecodeToSmpte((int32_t)(frame - firstFrame + info.absTimecodeAux), (int32_t)info.framerate, aux);
    createDngHeader(s, info.sensorType, take, info.framerate, info.tcSwap, prim, aux, s->header);
    s->headerFrame = frame;
}

void resetFrameCache(State *s) {
    for (uint32_t i = 0; i < kFrameCacheSlots; i++) {
        s->frames[i].frame = kNoFrame;
        s->frames[i].lastUse = 0;
    }
    s->frameClock = 0;
}

// Raw DMA data of `frame`: a cached slot, or one frame DMA (fpga_read_dma) copied into the
// least recently used slot. Returns nullptr when the DMA fails; the cache is left untouched.
const uint8_t *cachedFrame(State *s, uint32_t frame) {
    FrameSlot *victim = &s->frames[0];
    for (uint32_t i = 0; i < kFrameCacheSlots; i++) {
        FrameSlot *slot = &s->frames[i];
        if (slot->frame == frame) {
            slot->lastUse = ++s->frameClock;
            return slot->data;
        }
        if (slot->lastUse < victim->lastUse) {
            victim = slot;
        }
    }
    uint32_t page = eepromGetPage(s, frame);
    const uint8_t *data = s->hw->readFrame(page);
    if (!data) {
        s->hw->log("fpga_read_dma ERROR: frame %u (page %u) not read\n", frame, page);
        return nullptr;
    }
    memcpy(victim->data, data, kFrameDmaBytes);
    victim->frame = frame;
    victim->lastUse = ++s->frameClock;
    return victim->data;
}

// ---- FAT structures (init_fat32 / update_fat32 / create_*dir*) --------------------------------

// create_dir_ent: cluster 0 makes the volume label; size 0 makes a read-only directory.
// Timestamps come from take 0 once the take count is known, else date 0x22 (1980-01-02).
void createDirEnt(const State *s, uint8_t *ent, const char *name, uint32_t cluster, uint32_t size) {
    memset(ent, 0, kDirEntryBytes);
    copyName(ent, name, 11);
    if (s->takeCount == 0) {
        put16(ent + 0x18, 0x22);
    } else {
        uint16_t time, date;
        eepromCreateTime(s, 0, &time, &date);
        put16(ent + 0x18, date);
        put16(ent + 0x16, time);
    }
    if (cluster == 0) {
        ent[0xb] = 0x09;
    } else {
        put16(ent + 0x14, cluster >> 16);
        put16(ent + 0x1a, cluster);
        if (size == 0) {
            ent[0xb] = 0x11;
        } else {
            put32(ent + 0x1c, size);
        }
    }
}

void setEntTime(const State *s, uint8_t *ent, uint32_t take) {
    uint16_t time, date;
    eepromCreateTime(s, take, &time, &date);
    put16(ent + 0x18, date);
    put16(ent + 0x16, time);
}

inline void setFat(State *s, uint32_t cluster, uint32_t value) {
    put32(s->fatTable + cluster * 4, value);
}

void initBootSectors(State *s) {
    uint8_t *b = s->bootSector;
    memset(b, 0, kSectorBytes);
    b[0] = 0xeb;
    b[1] = 0x58;
    b[2] = 0x90;
    copyName(b + 3, "DCAM 1.0", 8);
    put16(b + 0x0b, kSectorBytes);
    b[0x0d] = kSectorsPerCluster;
    put16(b + 0x0e, kReservedSectors);
    b[0x10] = 1;                      // one FAT
    b[0x15] = 0xf0;                   // media descriptor
    put16(b + 0x18, 0x12);            // sectors per track
    put16(b + 0x1a, 2);               // heads
    put32(b + 0x20, kTotalSectors);   // total sectors (fixed, independent of the card)
    put32(b + 0x24, kFatSectors);
    put16(b + 0x28, 0);
    put32(b + 0x2c, kRootCluster);
    put16(b + 0x30, 1);               // FSInfo sector
    put16(b + 0x32, 6);               // backup boot sector
    b[0x42] = 0x29;
    put32(b + 0x43, 0);               // volume serial (this+0x138, always 0)
    copyName(b + 0x47, "ACAM FILES ", 11);
    copyName(b + 0x52, "FAT32   ", 8);
    put16(b + 0x1fe, 0xaa55);

    uint8_t *f = s->fsInfo;
    memset(f, 0, kSectorBytes);
    put32(f + 0x000, 0x41615252);
    put32(f + 0x1e4, 0x61417272);
    put32(f + 0x1e8, 0);              // free cluster count (set by updateFat32)
    put32(f + 0x1ec, 0xffffffff);     // next free cluster: unknown
    put32(f + 0x1fc, 0xaa550000);
}

int updateFat32(State *s) {
    resetFrameCache(s);
    s->headerFrame = kNoFrame;
    s->hw->log("Update FAT32\n");
    s->cardNo = (uint16_t)(eepromCardNo(s) % 1000);

    memset(s->fatTable, 0, kFatTableEntries * 4);
    memset(s->clusterInfo, 0, kDirClusterCount * sizeof(DirClusterInfo));
    memset(s->rootDir, 0, kClusterBytes);
    memset(s->imageDir, 0, kClusterBytes);
    memset(s->dirCache, 0, kClusterBytes);

    setFat(s, 0, 0x0fffff00 + s->bootSector[0x15]);
    setFat(s, 1, kFatEoc);
    setFat(s, kRootCluster, kFatEoc);

    char name[12];
    snprintf(name, sizeof(name), "ACAM %03d   ", (int)s->cardNo);
    createDirEnt(s, s->rootDir, name, 0, 0);
    static const char *const kRootDirs[] = {"CLIP       ", "VIDEO      ", "AUDIO      ",
                                            "ICON       ", "PROXY      ", "IMAGE      "};
    for (uint32_t i = 0; i < 6; i++) {
        createDirEnt(s, s->rootDir + (i + 1) * kDirEntryBytes, kRootDirs[i], 3 + i, 0);
        setFat(s, 3 + i, kFatEoc);
    }

    if (eepromGetTakeArray(s) != 0) {
        return -1;
    }
    s->frameCount = eepromCreateFrame2PageTable(s);
    s->hw->log("nr of frames=%u\n", s->frameCount);

    createDirEnt(s, s->imageDir, ".          ", kImageCluster, 0);
    createDirEnt(s, s->imageDir + kDirEntryBytes, "..         ", 1, 0);
    put16(s->imageDir + kDirEntryBytes + 0x1a, 0);

    uint32_t cluster = kFirstTakeCluster;
    uint32_t frameBase = 0;
    for (uint32_t take = 0; take < s->takeCount; take++) {
        uint32_t remaining = s->takeFrames[take];
        if (remaining == 0) {
            break;
        }
        if (remaining > kMaxFramesPerTake) {
            s->hw->log("Error in input, bailing out\n");
            break;
        }
        // The original had no bound here and would overrun its 0x800-entry FAT table and
        // 0x7fe-entry cluster table on corrupt metadata; stop listing takes instead.
        uint32_t needed = remaining <= kFirstClusterFiles
                              ? 1
                              : 1 + (remaining - kFirstClusterFiles + kClusterFiles - 1) / kClusterFiles;
        if (cluster + needed - 1 > kMaxDirCluster) {
            s->hw->log("update_fat32: directory clusters exhausted at take %u\n", take);
            break;
        }
        snprintf(name, sizeof(name), "AC%03d%03d   ", (int)s->cardNo, (int)(take + 1));
        uint8_t *ent = s->imageDir + (take + 2) * kDirEntryBytes;
        createDirEnt(s, ent, name, cluster, 0);
        setEntTime(s, ent, take);

        uint32_t takeOffset = 0;
        uint32_t capacity = kFirstClusterFiles;
        s->clusterInfo[cluster - kFirstTakeCluster].flags = 1;
        while (capacity < remaining) {
            DirClusterInfo *ci = &s->clusterInfo[cluster - kFirstTakeCluster];
            ci->firstFrame = frameBase;
            ci->count = capacity;
            ci->takeOffset = takeOffset;
            ci->take = take;
            remaining -= capacity;
            frameBase += capacity;
            takeOffset += capacity;
            setFat(s, cluster, cluster + 1);
            cluster++;
            capacity = kClusterFiles;
        }
        DirClusterInfo *ci = &s->clusterInfo[cluster - kFirstTakeCluster];
        ci->firstFrame = frameBase;
        ci->count = remaining;
        ci->takeOffset = takeOffset;
        ci->take = take;
        frameBase += remaining;
        setFat(s, cluster, kFatEoc);
        cluster++;
    }
    s->listedFrames = frameBase;

    // FSInfo free count. The original left it 0; with the exact chains of fetchFatSector the
    // true value is every cluster not used by a directory or a listed DNG file.
    uint64_t used = (uint64_t)(cluster - kRootCluster) + (uint64_t)frameBase * kDngFileClusters;
    put32(s->fsInfo + 0x1e8, used < kClusterCount ? (uint32_t)(kClusterCount - used) : 0);
    return 0;
}

// create_dir_cluster: directory index (cluster - 2) >= 7, a cluster of a take directory.
void createDirCluster(State *s, uint32_t dirIndex) {
    const DirClusterInfo *ci = &s->clusterInfo[dirIndex - (kFirstTakeCluster - 2)];
    uint32_t skip = 0;
    if (ci->flags & 1) {
        createDirEnt(s, s->dirCache, ".          ", dirIndex + 2, 0);
        createDirEnt(s, s->dirCache + kDirEntryBytes, "..         ", kImageCluster, 0);
        skip = 2;
    }
    char name[12];
    uint32_t i;
    for (i = 0; i < ci->count; i++) {
        uint32_t frame = ci->firstFrame + i;
        uint8_t *ent = s->dirCache + (i + skip) * kDirEntryBytes;
        snprintf(name, sizeof(name), "%03d%05dDNG", (int)s->cardNo, (int)(frame + 1));
        createDirEnt(s, ent, name, frame * 0x80 + 0x800, kDngFileBytes);
        setEntTime(s, ent, ci->take);
    }
    if (i + skip < kClusterFiles) {
        memset(s->dirCache + (i + skip) * kDirEntryBytes, 0, (kClusterFiles - i - skip) * kDirEntryBytes);
    }
    s->dirCacheIndex = dirIndex;
}

// create_empty_dir_cluster: CLIP/VIDEO/AUDIO/ICON/PROXY (directory index 1..5).
void createEmptyDirCluster(State *s, uint32_t dirIndex) {
    memset(s->dirCache, 0, kClusterBytes);
    createDirEnt(s, s->dirCache, ".          ", dirIndex + 2, 0);
    createDirEnt(s, s->dirCache + kDirEntryBytes, "..         ", 1, 0);
    put16(s->dirCache + kDirEntryBytes + 0x1a, 0);
    s->dirCacheIndex = dirIndex;
}

// ---- Sector fetch (fetch_sectors and helpers) -------------------------------------------------

// fetch_fat_sector: the first 16 FAT sectors map the directory clusters; FAT sector 16 + f
// holds the chain of frame file f, which starts at cluster (16 + f) * 128.
//
// Deviation (deliberate, see report): the original chained all 128 clusters of every FAT
// sector (entry 127 = 0x0ffffff8) whether or not the file exists, so fsck_msdos reported
// every DNG as "too many clusters allocated" (128 vs the 103 its 0x336000 bytes need) and
// millions of orphaned clusters. Here a listed file's chain ends after 103 clusters and all
// other entries are free. Cluster positions and file contents are unchanged.
void fetchFatSector(const State *s, uint8_t *dst, uint32_t fatSector) {
    if (fatSector < kFatTableSectors) {
        memcpy(dst, s->fatTable + fatSector * kSectorBytes, kSectorBytes);
        return;
    }
    memset(dst, 0, kSectorBytes);
    if (fatSector - kFatTableSectors >= s->listedFrames) {
        return;
    }
    for (uint32_t i = 0; i + 1 < kDngFileClusters; i++) {
        put32(dst + i * 4, fatSector * 128 + i + 1);
    }
    put32(dst + (kDngFileClusters - 1) * 4, kFatChainEnd);
}

// fetch_directory_sector
void fetchDirectorySector(State *s, uint8_t *dst, uint32_t dirIndex, uint32_t sector) {
    const uint8_t *src;
    if (dirIndex == 0) {
        src = s->rootDir;
    } else if (dirIndex < 6) {
        if (s->dirCacheIndex != dirIndex) {
            createEmptyDirCluster(s, dirIndex);
        }
        src = s->dirCache;
    } else if (dirIndex == 6) {
        src = s->imageDir;
    } else {
        if (s->dirCacheIndex != dirIndex) {
            createDirCluster(s, dirIndex);
        }
        src = s->dirCache;
    }
    memcpy(dst, src + sector * kSectorBytes, kSectorBytes);
}

// Sector assembly of fpga_read_dma for `n` sectors of frame file `frame`, starting at
// sector `sif` of the file (sif + n <= 0x2000): 8 generated header sectors, 0x19a8 raw DMA
// sectors, then zeros up to the 4 MiB cluster span.
int readFileSectors(State *s, uint32_t frame, uint32_t sif, uint32_t n, uint8_t *dst) {
    if (frame >= s->frameCount) {
        // No such file (no directory entry references it).
        memset(dst, 0, (size_t)n * kSectorBytes);
        return 0;
    }
    if (sif < kHeaderSectors) {
        buildHeader(s, frame);
        uint32_t k = kHeaderSectors - sif;
        if (k > n) {
            k = n;
        }
        memcpy(dst, s->header + sif * kSectorBytes, (size_t)k * kSectorBytes);
        dst += (size_t)k * kSectorBytes;
        sif += k;
        n -= k;
    }
    if (n == 0) {
        return 0;
    }
    uint32_t raw = sif - kHeaderSectors;
    uint32_t valid = 0;
    if (raw < kRawSectors) {
        valid = kRawSectors - raw;
        if (valid > n) {
            valid = n;
        }
    }
    if (valid != 0) {
        const uint8_t *data = cachedFrame(s, frame);
        if (!data) {
            return -1;
        }
        memcpy(dst, data + (size_t)raw * kSectorBytes, (size_t)valid * kSectorBytes);
        dst += (size_t)valid * kSectorBytes;
    }
    memset(dst, 0, (size_t)(n - valid) * kSectorBytes);
    return 0;
}

void freeBuffer(void *p, size_t bytes) {
    if (p) {
        platformFree(p, bytes);
    }
}

} // namespace

VirtualCard::VirtualCard() : state_(nullptr) {}

VirtualCard::~VirtualCard() {
    shutdown();
}

int VirtualCard::init(HwOps *hw) {
    shutdown();
    if (!hw) {
        return -1;
    }
    State *s = (State *)platformAlloc(sizeof(State));
    if (!s) {
        return -1;
    }
    memset(s, 0, sizeof(State));
    state_ = s;
    s->hw = hw;
    s->erasableBlocks = kDefaultErasableBlocks;
    s->eraseBlockSize = kDefaultEraseBlockSize;
    s->flashSize = kDefaultFlashSize;
    resetFrameCache(s);
    s->headerFrame = kNoFrame;

    s->eeprom = (uint8_t *)platformAlloc(kEepromBytes);
    s->bootSector = (uint8_t *)platformAlloc(kSectorBytes);
    s->fsInfo = (uint8_t *)platformAlloc(kSectorBytes);
    s->fatTable = (uint8_t *)platformAlloc(kFatTableEntries * 4);
    s->clusterInfo = (DirClusterInfo *)platformAlloc(kDirClusterCount * sizeof(DirClusterInfo));
    s->rootDir = (uint8_t *)platformAlloc(kClusterBytes);
    s->imageDir = (uint8_t *)platformAlloc(kClusterBytes);
    s->dirCache = (uint8_t *)platformAlloc(kClusterBytes);
    s->frame2page = (uint32_t *)platformAlloc(kMaxFrames * sizeof(uint32_t));
    s->header = (uint8_t *)platformAlloc(kHeaderBytes);
    bool framesOk = true;
    for (uint32_t i = 0; i < kFrameCacheSlots; i++) {
        s->frames[i].data = (uint8_t *)platformAlloc(kFrameDmaBytes);
        framesOk = framesOk && s->frames[i].data;
    }
    if (!s->eeprom || !s->bootSector || !s->fsInfo || !s->fatTable || !s->clusterInfo || !s->rootDir ||
        !s->imageDir || !s->dirCache || !s->frame2page || !s->header || !framesOk) {
        shutdown();
        return -1;
    }
    memset(s->frame2page, 0, kMaxFrames * sizeof(uint32_t));

    // start(): eeprom_init failure is logged and the volume is still built from whatever
    // the buffer holds (an unreadable card yields an empty IMAGE folder).
    if (eepromInit(s) != 0) {
        hw->log("cr_eeprom_init returns -1\n");
    }
    initBootSectors(s);
    if (updateFat32(s) != 0) {
        shutdown();
        return -1;
    }
    // start(): blockCount = ((flash bytes >> 9) << 10) / 0x335, i.e. 4 MiB per frame slot. The
    // original re-read reg 0x2c here; use the geometry the frame map was built with.
    uint64_t diskBytes = (uint64_t)s->flashSize * 0x1000;
    s->sectorCount = ((diskBytes >> 9) << 10) / kPagesPerFrame;
    // Deviation: the original's formula ignores that file data starts at kFileLba, so on a
    // nearly full card the last ~23 frame files lay past the end of the device and could not
    // be read. Grow the device just enough to cover every listed file.
    uint32_t files = s->listedFrames > s->frameCount ? s->listedFrames : s->frameCount;
    uint64_t lastFileEnd = kFileLba + (uint64_t)files * kFileSectorSpan;
    if (s->sectorCount < lastFileEnd) {
        s->sectorCount = lastFileEnd;
    }
    hw->log("card %u: %u takes, %u frames, blockCount 0x%llx\n", (unsigned)s->cardNo, s->takeCount,
            s->frameCount, (unsigned long long)s->sectorCount);
    return 0;
}

void VirtualCard::shutdown() {
    State *s = state_;
    if (!s) {
        return;
    }
    freeBuffer(s->eeprom, kEepromBytes);
    freeBuffer(s->bootSector, kSectorBytes);
    freeBuffer(s->fsInfo, kSectorBytes);
    freeBuffer(s->fatTable, kFatTableEntries * 4);
    freeBuffer(s->clusterInfo, kDirClusterCount * sizeof(DirClusterInfo));
    freeBuffer(s->rootDir, kClusterBytes);
    freeBuffer(s->imageDir, kClusterBytes);
    freeBuffer(s->dirCache, kClusterBytes);
    freeBuffer(s->takeFrames, s->takeFramesEntries * sizeof(uint32_t));
    freeBuffer(s->frame2page, kMaxFrames * sizeof(uint32_t));
    freeBuffer(s->header, kHeaderBytes);
    for (uint32_t i = 0; i < kFrameCacheSlots; i++) {
        freeBuffer(s->frames[i].data, kFrameDmaBytes);
    }
    platformFree(s, sizeof(State));
    state_ = nullptr;
}

uint64_t VirtualCard::sectorCount() const {
    return state_ ? state_->sectorCount : 0;
}

uint16_t VirtualCard::cardNumber() const {
    return state_ ? state_->cardNo : 0;
}

int VirtualCard::readSectors(uint64_t lba, uint32_t count, uint8_t *dst) {
    State *s = state_;
    if (!s || !dst || lba > s->sectorCount || count > s->sectorCount - lba) {
        return -1;
    }
    uint32_t i = 0;
    while (i < count) {
        uint64_t sector = lba + i;
        uint8_t *out = dst + (size_t)i * kSectorBytes;
        if (sector < kReservedSectors) {
            const uint8_t *src = nullptr;
            if (sector == 0 || sector == 6) {
                src = s->bootSector;
            } else if (sector == 1 || sector == 7) {
                src = s->fsInfo;
            }
            if (src) {
                memcpy(out, src, kSectorBytes);
            } else {
                memset(out, 0, kSectorBytes);
            }
            i++;
        } else if (sector < kDataLba) {
            fetchFatSector(s, out, (uint32_t)(sector - kReservedSectors));
            i++;
        } else if (sector < kFileLba) {
            uint32_t rel = (uint32_t)(sector - kDataLba);
            fetchDirectorySector(s, out, rel / kSectorsPerCluster, rel % kSectorsPerCluster);
            i++;
        } else {
            uint64_t rel = sector - kFileLba;
            uint64_t frame = rel >> kFileSectorsShift;
            uint32_t sif = (uint32_t)(rel & (kFileSectorSpan - 1));
            uint32_t n = kFileSectorSpan - sif;
            if (n > count - i) {
                n = count - i;
            }
            uint32_t frameIndex = frame < kMaxFrames ? (uint32_t)frame : kMaxFrames;
            if (readFileSectors(s, frameIndex, sif, n, out) != 0) {
                return -1;
            }
            i += n;
        }
    }
    return 0;
}

} // namespace ik
