// IkonoskopCardReader.hpp — arm64e port of com_Ikonoskop_driver_CardReader (v1.2).
//
// PCI driver for the Ikonoskop A-Cam dII memory card (Xilinx 10EE:0007 behind Thunderbolt).
// Hardware access (BAR0 registers, XPS SPI EEPROM, frame DMA) is reconstructed from the
// original kext; the virtual FAT32/DNG layer lives in core/ (ik::VirtualCard).
#ifndef IKONOSKOP_CARD_READER_HPP
#define IKONOSKOP_CARD_READER_HPP

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/IOFilterInterruptEventSource.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IODMACommand.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/storage/IOStorage.h>

#include "../core/ik_core.h"

class org_ikonoskop_community_CardReaderBlockDevice;
class IkKextHwOps;

class org_ikonoskop_community_CardReader : public IOService {
    OSDeclareDefaultStructors(org_ikonoskop_community_CardReader)

public:
    // IOService
    bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
    void free(void) APPLE_KEXT_OVERRIDE;
    bool requestTerminate(IOService *provider, IOOptionBits options) APPLE_KEXT_OVERRIDE;
    bool willTerminate(IOService *provider, IOOptionBits options) APPLE_KEXT_OVERRIDE;

    // Block device (org_ikonoskop_community_CardReaderBlockDevice) interface.
    // Queues a read; completion is always delivered exactly once (possibly synchronously).
    void submitRead(IOMemoryDescriptor *buffer, UInt64 block, UInt64 nblks,
                    IOStorageCompletion *completion);
    UInt64 sectorCount(void) const { return fSectorCount; }
    UInt32 flashVersion(void) const { return fFlashVersion; }
    bool deviceGone(void) const { return fGone; }

    // Debug user client interface (thread context, may block).
    IOReturn ucStatus(uint64_t *out, uint32_t count);
    IOReturn ucReadEeprom(uint32_t addr, uint32_t len, uint8_t *dst);
    IOReturn ucReadFrame(uint32_t page, IOMemoryDescriptor *dst, uint64_t *copied);
    IOReturn ucReadSectors(uint64_t lba, uint32_t count, uint8_t *dst);
    IOReturn ucReadReg(uint32_t offset, uint32_t *value);

    // ik::HwOps backends. Caller holds fHwLock.
    int hwReadEeprom(uint32_t addr, uint8_t *dst, uint32_t len);
    const uint8_t *hwReadFrame(uint32_t flashPage);
    uint32_t hwReadReg(uint32_t offset);

private:
    struct ReadRequest {
        ReadRequest *next;
        IOMemoryDescriptor *buffer;
        UInt64 block;
        UInt64 nblks;
        IOStorageCompletion completion;
    };

    // Register access (DeviceMemRead32 / DeviceMemWrite32 / kacamfpga_*_reg).
    IOReturn regRead(uint32_t offset, uint32_t *value);
    IOReturn regWrite(uint32_t offset, uint32_t value);
    uint32_t rd(uint32_t offset);
    void wr(uint32_t offset, uint32_t value);

    // XPS SPI (crspi_init / setup_xps_spi_dev / xpsspi_rw / flash_eeprom_read).
    int xpsspiRW(int cs, const uint8_t *tx, uint8_t *rx, uint32_t len);
    int flashEepromRead(uint8_t *dst, uint32_t len, uint32_t addr);

    // generateDMAAddresses
    IOReturn setupDma(void);
    void teardownDma(void);
    IOReturn programDmaTable(void);

    // Interrupts
    IOReturn setupInterrupts(IOService *provider);
    void handleInterrupt(IOInterruptEventSource *src, int count);
    bool filterInterrupt(IOFilterInterruptEventSource *src);

    // Worker thread: card init, nub publication, block reads.
    static void workerEntry(void *arg, wait_result_t wr);
    void workerMain(void);
    void waitForFlashGeometry(void);
    void serviceRead(ReadRequest *req);
    void failAllQueued(IOReturn status);
    void markGone(const char *why);
    void publishBlockDevice(void);

    IOPCIDevice *fPci;
    IOMemoryMap *fRegMap;
    volatile uint8_t *fRegs;
    IOByteCount fRegLen;

    IOBufferMemoryDescriptor *fDmaBuf;
    IODMACommand *fDmaCmd;
    uint8_t *fDmaVA;
    uint32_t fDmaSegMax;
    uint32_t fDmaSegments;
    uint32_t fFirstIova;

    IOWorkLoop *fWorkLoop;
    IOFilterInterruptEventSource *fIntSrc;
    bool fIntIsMSI;

    IOLock *fIrqLock;               // original this+0xc0 (DMA wait lock)
    IOLock *fHwLock;                // original this+0xc8 (kacamfpga_lock / threadSafe)
    IOLock *fQueueLock;
    volatile uint32_t fIntStatus;   // original this+0x118: 0x100 waiting, 0x200 occurred
    volatile bool fSleeping;        // original this+0xd0
    volatile bool fGone;
    volatile bool fStopping;

    ReadRequest *fQueueHead;
    ReadRequest *fQueueTail;
    bool fWorkerRunning;

    ik::VirtualCard *fCard;
    IkKextHwOps *fHwOps;
    volatile bool fCardReady;
    UInt64 fSectorCount;
    uint16_t fCardNumber;

    uint32_t fFlashSize;
    uint32_t fFlashEraseSize;
    uint32_t fFlashVersion;

    volatile uint32_t fStatInterrupts;
    volatile uint32_t fStatTimeouts;
    volatile uint32_t fStatDmaReads;

    org_ikonoskop_community_CardReaderBlockDevice *fNub;
};

#endif
