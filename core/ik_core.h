// ik_core.h — portable reconstruction of the Ikonoskop A-Cam dII card reader logic.
//
// Reconstructed from IkonoskopCardReader.kext v1.2 (x86_64, 2013). This layer has no
// IOKit dependency: it compiles both inside the arm64e kext (-mkernel -fapple-kext) and in
// userspace test harnesses. No STL, no exceptions, no RTTI, no floating point, no libc
// beyond memcpy/memset/memcmp/snprintf-style helpers declared below.
//
// Ownership: core/ owns this header. kext/ implements HwOps and the platform hooks.
#ifndef IK_CORE_H
#define IK_CORE_H

#include <stdint.h>
#include <stddef.h>

namespace ik {

// Size of one DMA frame transfer programmed by the original driver (reg 0x110).
static const uint32_t kFrameDmaBytes = 0x335000;

// Frames kept by VirtualCard (LRU), so that interleaved readers (Finder copying several files
// while it thumbnails others) do not re-DMA a whole frame for every request. 8 x 3.2 MiB.
static const uint32_t kFrameCacheSlots = 8;

// Hardware access supplied by the platform (kext or test mock).
class HwOps {
public:
    virtual ~HwOps() {}
    // SPI READ (opcode 0x03, 16-bit address) from the card metadata EEPROM on chip-select 0,
    // as flash_eeprom_read() did. len <= 0x2000. Returns bytes read, or < 0 on failure.
    virtual int readEeprom(uint32_t addr, uint8_t *dst, uint32_t len) = 0;
    // DMA one frame from card flash page `flashPage` (reg 0x04 = page, reg 0x14 = 1,
    // reg 0x110 = kFrameDmaBytes, wait for interrupt, 500 ms timeout, reg 0x104 = 1 on abort).
    // Returns a pointer to kFrameDmaBytes bytes valid until the next call, or nullptr on failure.
    virtual const uint8_t *readFrame(uint32_t flashPage) = 0;
    // 32-bit read of a BAR0 register (e.g. 0x2c = flash size in 4 KiB units).
    virtual uint32_t readReg(uint32_t offset) = 0;
    virtual void log(const char *fmt, ...) __attribute__((format(printf, 2, 3))) = 0;
};

// Platform hooks (kext: IOMalloc/IOFree; userspace: malloc/free).
void *platformAlloc(size_t bytes);
void platformFree(void *ptr, size_t bytes);

// The synthesized read-only FAT32 volume ("DCAM", IMAGE folder of CinemaDNG files)
// that the original driver exposed as an IOBlockStorageDevice.
class VirtualCard {
public:
    VirtualCard();
    ~VirtualCard();
    // eeprom_init + metadata read + init_fat32. Returns 0 on success.
    int init(HwOps *hw);
    // Releases all allocations (cleanup_fat32 etc.). Safe to call twice.
    void shutdown();
    // Number of 512-byte sectors exposed (reportMaxValidBlock + 1 in the original).
    uint64_t sectorCount() const;
    // fetch_sectors: fill `count` 512-byte sectors starting at `lba` into dst.
    // Returns 0 on success, non-zero on a hardware/DMA failure (maps to kIOReturnIOError).
    int readSectors(uint64_t lba, uint32_t count, uint8_t *dst);
    // Card number programmed in the camera (eeprom_get_card_no), for logging/volume naming.
    uint16_t cardNumber() const;

private:
    VirtualCard(const VirtualCard &);
    VirtualCard &operator=(const VirtualCard &);
    struct State;
    State *state_;
};

} // namespace ik

#endif // IK_CORE_H
