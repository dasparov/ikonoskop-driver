// IkonoskopCardReader.cpp — arm64e port of com_Ikonoskop_driver_CardReader (v1.2, 2013).
//
// Reconstructed from the decompiled x86_64 kext. Function-level provenance is noted at each
// routine ("orig:"). Apple Silicon differences:
//   * memory + bus-lead enable are set explicitly (orig only called setMemoryEnable(true));
//   * the frame DMA buffer is ordinary kernel memory mapped through the device's DART via
//     IODMACommand (kMapped, 32 address bits); the FPGA receives IOVAs, never physical
//     addresses, and the command stays prepared for the driver's lifetime (orig released it
//     right after programming, which only worked because x86 had no IOMMU);
//   * all card work runs on a dedicated worker thread, never in interrupt/workloop context;
//   * surprise removal (Thunderbolt unplug) stops MMIO, wakes the DMA waiter and fails I/O.
//
// Read-only: no flash erase/program path exists in this file. The only register writes are
// the ones the original read path performed: SG table (0x118, 0x1000+, 0x2000+, 0x120),
// init (0x04, 0x14, 0x10c), frame fetch (0x04, 0x14, 0x110), abort (0x104) and the XPS SPI
// controller (0x260-0x270) used to clock out the EEPROM READ (0x03) command.

#include "IkonoskopCardReader.hpp"
#include "IkonoskopBlockDevice.hpp"
#include "ik_uc_shared.h"

#include <IOKit/IOMapper.h>
#include <kern/thread.h>
#include <kern/clock.h>
#include <libkern/OSAtomic.h>
#include <string.h>
#include <stdarg.h>

#define super IOService
OSDefineMetaClassAndStructors(org_ikonoskop_community_CardReader, IOService)

#define IKLOG(fmt, ...) IOLog("IkonoskopCardReader: " fmt "\n", ##__VA_ARGS__)

namespace {

// BAR0 register map (names from the original's log strings where available).
enum : uint32_t {
    kRegFlashPage      = 0x004,  // flash page / frame start for the next fetch
    kRegFetchStart     = 0x014,  // "Prefetch!": 1 = load page into FPGA
    kRegFlashSize      = 0x02c,  // FLASH_SIZE (4 KiB units)
    kRegFlashEraseSize = 0x030,  // FLASH_ERASE_SIZE
    kRegFlashVersion   = 0x04c,  // ADDR_FLASH_VER_NUM
    kRegDmaAbort       = 0x104,  // written 1 after a DMA timeout
    kRegInit10C        = 0x10c,  // written once in start() with this+0x110 (never assigned: 0)
    kRegDmaLength      = 0x110,  // write byte count -> starts DMA to host, MSI on completion
    kRegSgReset        = 0x118,  // written 1 before the SG table is (re)loaded
    kRegSgCount        = 0x120,  // number of SG entries
    kRegSgAddrBase     = 0x1000, // SG entry i bus address: 0x1000 + 4*i
    kRegSgLenBase      = 0x2000, // SG entry i length:      0x2000 + 4*i
    kSgMaxEntries      = (kRegSgLenBase - kRegSgAddrBase) / 4,

    // Xilinx XPS SPI core at BAR0 + 0x200.
    kSpiCR   = 0x260,  // control
    kSpiSR   = 0x264,  // status: bit0 RX empty, bit2 TX empty, bit3 TX full
    kSpiDTR  = 0x268,  // TX data
    kSpiDRR  = 0x26c,  // RX data
    kSpiSSR  = 0x270,  // slave select (active low)
};

enum : uint32_t {
    kISWaitingForInterrupt  = 0x100,
    kISInterruptHasOccurred = 0x200,
};

const uint32_t kDefaultDmaSegmentBytes = 4096;  // see setupDma()
const uint32_t kDmaTimeoutMs = 500;              // orig: 500000000 ns deadline
// The FPGA publishes the card's flash geometry (regs 0x2c/0x30) some time after the PCIe link
// comes up; right after a Thunderbolt hot-plug both still read 0. See waitForFlashGeometry().
const uint32_t kGeometryWaitMs = 5000;
const uint32_t kGeometryPollMs = 20;

// setup_xps_spi_dev(): per-chip-select mode. Only CS 0 (the metadata EEPROM) is used;
// bitmap 0x61 -> {lsb_first=0, cpha=0, cpol=0}; CS 24..27 would have lsb_first=1.
struct XpsSpiDev { int cs; int lsbFirst; int cpha; int cpol; };
const XpsSpiDev kEepromSpiDev = { 0, 0, 0, 0 };

} // namespace

// ---------------------------------------------------------------------------------------------
// ik::HwOps adapter and platform hooks
// ---------------------------------------------------------------------------------------------

class IkKextHwOps : public ik::HwOps {
public:
    explicit IkKextHwOps(org_ikonoskop_community_CardReader *drv) : fDrv(drv) {}
    int readEeprom(uint32_t addr, uint8_t *dst, uint32_t len) override {
        return fDrv->hwReadEeprom(addr, dst, len);
    }
    const uint8_t *readFrame(uint32_t flashPage) override { return fDrv->hwReadFrame(flashPage); }
    uint32_t readReg(uint32_t offset) override { return fDrv->hwReadReg(offset); }
    void log(const char *fmt, ...) override {
        char line[256];
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(line, sizeof(line), fmt, ap);
        va_end(ap);
        IOLog("IkonoskopCardReader[core]: %s", line);
    }
private:
    org_ikonoskop_community_CardReader *fDrv;
};

namespace ik {
void *platformAlloc(size_t bytes)
{
    if (bytes == 0) return NULL;
    void *p = IOMalloc(bytes);
    if (p) bzero(p, bytes);
    return p;
}
void platformFree(void *ptr, size_t bytes)
{
    if (ptr) IOFree(ptr, bytes);
}
} // namespace ik

// ---------------------------------------------------------------------------------------------
// Register access — orig: DeviceMemRead32 / DeviceMemWrite32 / kacamfpga_read_reg / _write_reg
// ---------------------------------------------------------------------------------------------

IOReturn org_ikonoskop_community_CardReader::regRead(uint32_t offset, uint32_t *value)
{
    if (!fRegs) return kIOReturnNotReady;              // orig err 1
    if (fRegLen == 0) return kIOReturnNoMemory;        // orig err 2
    if ((uint64_t)offset + 4 > fRegLen || (offset & 3)) return kIOReturnBadArgument; // orig err 3
    if (!value) return kIOReturnBadArgument;           // orig err 4
    if (fGone) { *value = 0xffffffffu; return kIOReturnNoDevice; }
    *value = *(volatile uint32_t *)(fRegs + offset);
    return kIOReturnSuccess;
}

IOReturn org_ikonoskop_community_CardReader::regWrite(uint32_t offset, uint32_t value)
{
    if (!fRegs) return kIOReturnNotReady;
    if (fRegLen == 0) return kIOReturnNoMemory;
    if ((uint64_t)offset + 4 > fRegLen || (offset & 3)) return kIOReturnBadArgument;
    if (fGone) return kIOReturnNoDevice;
    *(volatile uint32_t *)(fRegs + offset) = value;
    return kIOReturnSuccess;
}

uint32_t org_ikonoskop_community_CardReader::rd(uint32_t offset)
{
    uint32_t v = 0xffffffffu;
    regRead(offset, &v);
    return v;
}

void org_ikonoskop_community_CardReader::wr(uint32_t offset, uint32_t value)
{
    regWrite(offset, value);
}

// ---------------------------------------------------------------------------------------------
// XPS SPI — orig: crspi_init / setup_xps_spi_dev / xpsspi_rw / flash_eeprom_read
// ---------------------------------------------------------------------------------------------

// orig: xpsspi_rw(int cs, void *tx, void *rx, unsigned len). Returns bytes shifted out
// (len on success) or -1 if the SPI core is absent. Faithful register sequence; added guards:
// abort if the device disappears (all-ones reads) and never write past rx[len].
int org_ikonoskop_community_CardReader::xpsspiRW(int cs, const uint8_t *tx, uint8_t *rx, uint32_t len)
{
    const XpsSpiDev &dev = kEepromSpiDev;
    (void)cs;

    wr(kSpiSSR, ~(1u << (dev.cs & 0x1f)));
    uint32_t cr = rd(kSpiCR);
    if (cr == 0 || cr > 0xffff) return -1;

    uint32_t mode = (dev.lsbFirst ? 0x200 : 0) | (dev.cpha ? 0x10 : 0) | (dev.cpol ? 0x08 : 0);
    // 0x186 = master transaction inhibit | manual slave select | master | SPI enable
    wr(kSpiCR, mode | 0x186);

    uint32_t txLeft = len;
    uint32_t rxLeft = len;
    const uint8_t *txp = tx;
    uint8_t *rxp = rx;

    uint32_t sr = rd(kSpiSR);
    while (!(sr & 0x8) && txLeft > 0) {
        wr(kSpiDTR, *txp++);
        txLeft--;
        sr = rd(kSpiSR);
    }
    cr = rd(kSpiCR);
    wr(kSpiCR, cr & ~0x100u);                           // release inhibit: start shifting

    while (rxLeft != 0) {
        if (fGone) break;
        int polls = 0;
        do {
            IODelay(200);
            sr = rd(kSpiSR);
            polls++;
        } while (!(sr & 0x4) && polls < 50);
        if (polls > 49) break;                          // orig: 0x31 < local_6c
        if (sr == 0xffffffffu) break;                   // device gone

        cr = rd(kSpiCR);
        wr(kSpiCR, cr | 0x100);                         // inhibit while draining
        sr = rd(kSpiSR);
        if (sr == 0x107 || sr == 0xffffffffu) break;
        while (!(sr & 0x1)) {
            uint32_t v = rd(kSpiDRR);
            if (rxLeft == 0) break;
            if (rxp) *rxp++ = (uint8_t)v;
            rxLeft--;
            sr = rd(kSpiSR);
        }
        if ((int32_t)txLeft > 0) {
            sr = rd(kSpiSR);
            while (!(sr & 0x8) && txLeft > 0) {
                wr(kSpiDTR, *txp++);
                txLeft--;
                sr = rd(kSpiSR);
            }
            cr = rd(kSpiCR);
            wr(kSpiCR, cr & ~0x100u);
        }
    }

    cr = rd(kSpiCR);
    wr(kSpiCR, cr | 0x100);
    wr(kSpiSSR, 0xff);
    wr(kSpiCR, (cr & ~0x2u) | 0x100);                   // disable SPI core
    if (fGone) return -1;
    return (int)(len - txLeft);
}

// orig: flash_eeprom_read(char *buf, unsigned long len, unsigned addr). The original used one
// buffer for TX and RX, so EEPROM byte `addr` landed at buf[3] (_ee_prom = read_buffer + 3).
// Here dst receives exactly `len` data bytes starting at `addr`.
int org_ikonoskop_community_CardReader::flashEepromRead(uint8_t *dst, uint32_t len, uint32_t addr)
{
    if (!dst) return -1;
    if (len > kIkMaxEepromBytes) {
        IKLOG("eeprom_read: Max buf size= %d", kIkMaxEepromBytes);
        len = kIkMaxEepromBytes;
    }
    const uint32_t n = len + 3;
    uint8_t *tx = (uint8_t *)IOMalloc(n);
    uint8_t *rx = (uint8_t *)IOMalloc(n);
    int result = -1;
    if (tx && rx) {
        bzero(tx, n);
        bzero(rx, n);
        tx[0] = 0x03;                                   // SPI EEPROM READ
        tx[1] = (uint8_t)(addr >> 8);
        tx[2] = (uint8_t)addr;
        int r = xpsspiRW(kEepromSpiDev.cs, tx, rx, n);
        if (r == (int)n) {
            memcpy(dst, rx + 3, len);
            result = (int)len;
        } else {
            IKLOG("eeprom_read: Failed res= %d", r);
        }
    }
    if (tx) IOFree(tx, n);
    if (rx) IOFree(rx, n);
    return result;
}

int org_ikonoskop_community_CardReader::hwReadEeprom(uint32_t addr, uint8_t *dst, uint32_t len)
{
    if (fGone || fStopping) return -1;
    return flashEepromRead(dst, len, addr);
}

uint32_t org_ikonoskop_community_CardReader::hwReadReg(uint32_t offset)
{
    return rd(offset);
}

// ---------------------------------------------------------------------------------------------
// DMA — orig: start() buffer allocation + generateDMAAddresses()
// ---------------------------------------------------------------------------------------------

IOReturn org_ikonoskop_community_CardReader::setupDma(void)
{
    // Segment granularity handed to the FPGA. The original used maxSegmentSize 0 on x86 with
    // a 32-bit physical mask, i.e. one entry per physically contiguous run of 4 KiB pages
    // (its log line every 50 entries shows it expected hundreds of entries). Through the DART
    // the whole buffer is one contiguous IOVA range, so we split it into 4 KiB entries by
    // default (821 entries, all 4 KiB aligned) — the layout the FPGA certainly handled.
    // Override with the personality key IKDMASegmentBytes (0 = unlimited / single entry).
    fDmaSegMax = kDefaultDmaSegmentBytes;
    OSNumber *segProp = OSDynamicCast(OSNumber, getProperty("IKDMASegmentBytes"));
    if (segProp) fDmaSegMax = segProp->unsigned32BitValue();

    fDmaBuf = IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task, kIODirectionInOut,
                                                          ik::kFrameDmaBytes, 16384);
    if (!fDmaBuf) {
        IKLOG("DMA buffer allocation failed");
        return kIOReturnNoMemory;
    }
    fDmaVA = (uint8_t *)fDmaBuf->getBytesNoCopy();
    if (!fDmaVA) return kIOReturnNoMemory;
    bzero(fDmaVA, ik::kFrameDmaBytes);

    IOReturn ret = fDmaBuf->prepare(kIODirectionInOut);   // orig: buf->prepare(0)
    if (ret != kIOReturnSuccess) {
        IKLOG("DMA buffer prepare failed 0x%08x", ret);
        fDmaBuf->release();
        fDmaBuf = NULL;
        fDmaVA = NULL;
        return ret;
    }

    IOMapper *mapper = IOMapper::copyMapperForDevice(fPci);
    if (!mapper) IKLOG("no IOMapper for device; falling back to system mapper");
    fDmaCmd = IODMACommand::withSpecification(kIODMACommandOutputHost32,
                                              32,              // numAddressBits (orig 0x20)
                                              fDmaSegMax,      // maxSegmentSize
                                              IODMACommand::kMapped,
                                              0,               // maxTransferSize
                                              1,               // alignment
                                              mapper,
                                              NULL);
    if (mapper) mapper->release();
    if (!fDmaCmd) {
        IKLOG("IODMACommand::withSpecification failed");
        return kIOReturnNoResources;
    }
    ret = fDmaCmd->setMemoryDescriptor(fDmaBuf, false);
    if (ret != kIOReturnSuccess) {
        IKLOG("setMemoryDescriptor failed (0x%08x)", ret);
        fDmaCmd->release();
        fDmaCmd = NULL;
        return ret;
    }
    // orig: prepare(0, 0, flushCache=1, synchronize=1). Kept prepared until stop(): the DART
    // mapping (and therefore every IOVA programmed into the FPGA) lives exactly that long.
    ret = fDmaCmd->prepare(0, 0, true, true);
    if (ret != kIOReturnSuccess) {
        IKLOG("cmd->prepare() failed (0x%08x)", ret);
        fDmaCmd->clearMemoryDescriptor(false);
        fDmaCmd->release();
        fDmaCmd = NULL;
        return ret;
    }
    return programDmaTable();
}

// orig: generateDMAAddresses(). Writes 0x118 = 1, then for each Segment32 i:
// [0x1000 + 4i] = address, [0x2000 + 4i] = length, then [0x120] = segment count.
IOReturn org_ikonoskop_community_CardReader::programDmaTable(void)
{
    const UInt64 total = fDmaBuf->getLength();
    UInt64 offset = 0;
    uint32_t i = 0;
    IOReturn ret = kIOReturnSuccess;

    wr(kRegSgReset, 1);
    while (offset < total) {
        IODMACommand::Segment32 seg;
        UInt32 nsegs = 1;
        ret = fDmaCmd->gen32IOVMSegments(&offset, &seg, &nsegs);
        if (ret != kIOReturnSuccess || nsegs != 1) {
            IKLOG("gen32IOVMSegments failed (0x%08x, nsegs %u) at entry %u", ret, nsegs, i);
            if (ret == kIOReturnSuccess) ret = kIOReturnInternalError;
            break;
        }
        if (i >= kSgMaxEntries) {
            IKLOG("SG table overflow (> %u entries); raise IKDMASegmentBytes", kSgMaxEntries);
            ret = kIOReturnNoSpace;
            break;
        }
        if (i == 0) fFirstIova = seg.fIOVMAddr;
        if (i % 50 == 0) {
            IKLOG("i: %u gen32IOVMSegments addr 0x%08x, len %u offset: 0x%08llx",
                  i, seg.fIOVMAddr, seg.fLength, offset);
        }
        wr(kRegSgAddrBase + i * 4, seg.fIOVMAddr);
        wr(kRegSgLenBase + i * 4, seg.fLength);
        i++;
    }
    if (ret != kIOReturnSuccess) return ret;
    wr(kRegSgCount, i);
    fDmaSegments = i;
    IKLOG("SG numSegments: %u (max segment %u bytes)", i, fDmaSegMax);
    return kIOReturnSuccess;
}

void org_ikonoskop_community_CardReader::teardownDma(void)
{
    if (fDmaCmd) {
        fDmaCmd->complete(false, false);
        fDmaCmd->clearMemoryDescriptor(false);
        fDmaCmd->release();
        fDmaCmd = NULL;
    }
    if (fDmaBuf) {
        fDmaBuf->complete(kIODirectionInOut);
        fDmaBuf->release();
        fDmaBuf = NULL;
    }
    fDmaVA = NULL;
}

// orig: the register/DMA half of fpga_read_dma().
const uint8_t *org_ikonoskop_community_CardReader::hwReadFrame(uint32_t flashPage)
{
    if (fGone || fStopping || !fDmaCmd || !fDmaVA || !fIntSrc) return NULL;
    OSIncrementAtomic((volatile SInt32 *)&fStatDmaReads);

    // Arm before triggering (orig armed after writing 0x110, racing a fast interrupt).
    IOLockLock(fIrqLock);
    fIntStatus = kISWaitingForInterrupt;
    IOLockUnlock(fIrqLock);

    wr(kRegFlashPage, flashPage);
    wr(kRegFetchStart, 1);
    wr(kRegDmaLength, ik::kFrameDmaBytes);

    uint64_t deadline;
    clock_interval_to_deadline(kDmaTimeoutMs, kMillisecondScale, &deadline);

    bool done = false;
    IOLockLock(fIrqLock);
    while (fIntStatus == kISWaitingForInterrupt && !fGone) {
        fSleeping = true;
        int r = IOLockSleepDeadline(fIrqLock, (void *)&fIntStatus, deadline, THREAD_UNINT);
        fSleeping = false;
        if (r == THREAD_TIMED_OUT) break;
    }
    done = (fIntStatus == kISInterruptHasOccurred) && !fGone;
    IOLockUnlock(fIrqLock);

    if (!done) {
        OSIncrementAtomic((volatile SInt32 *)&fStatTimeouts);
        if (fGone) {
            IKLOG("fpga_read_dma: device gone (page %u)", flashPage);
            return NULL;
        }
        IKLOG("fpga_read_dma ERROR: no DMA interrupt within %u ms (page %u), aborting",
              kDmaTimeoutMs, flashPage);
        wr(kRegDmaAbort, 1);
        // Absorb a late completion of the aborted transfer so it cannot satisfy the next wait.
        IOSleep(5);
        IOLockLock(fIrqLock);
        fIntStatus = 0;
        IOLockUnlock(fIrqLock);
        return NULL;
    }
    fDmaCmd->synchronize(kIODirectionIn);
    return fDmaVA;
}

// ---------------------------------------------------------------------------------------------
// Interrupts — orig: start() index scan, filterInterrupt(), handleInterrupt()
// ---------------------------------------------------------------------------------------------

bool org_ikonoskop_community_CardReader::filterInterrupt(IOFilterInterruptEventSource *src)
{
    (void)src;
    return true;                                        // orig: always schedule the handler
}

void org_ikonoskop_community_CardReader::handleInterrupt(IOInterruptEventSource *src, int count)
{
    (void)src;
    (void)count;
    OSIncrementAtomic((volatile SInt32 *)&fStatInterrupts);
    IOLockLock(fIrqLock);
    if (fIntStatus == kISWaitingForInterrupt) {
        fIntStatus = kISInterruptHasOccurred;
        IOLockWakeup(fIrqLock, (void *)&fIntStatus, true);
    } else if (fIntStatus == kISInterruptHasOccurred) {
        IKLOG("interrupt status not cleared since last interrupt");
    }
    IOLockUnlock(fIrqLock);
}

IOReturn org_ikonoskop_community_CardReader::setupInterrupts(IOService *provider)
{
    int msiIndex = -1, levelIndex = -1, index = 0, type = 0;
    while (provider->getInterruptType(index, &type) == kIOReturnSuccess) {
        if (type & kIOInterruptTypeLevel) {
            if (levelIndex < 0) levelIndex = index;
            IKLOG("kIOInterruptTypeLevel index = 0x%x", index);
        } else if (type & kIOInterruptTypePCIMessaged) {
            msiIndex = index;                           // orig: last MSI index wins
            IKLOG("kIOInterruptTypePCIMessaged index = 0x%x", index);
        }
        index++;
    }
    int useIndex = msiIndex;
    fIntIsMSI = true;
    if (useIndex < 0) {
        // orig would pass -1 here and fail; fall back to the legacy source instead.
        useIndex = levelIndex;
        fIntIsMSI = false;
        IKLOG("no MSI interrupt source, falling back to index %d", useIndex);
    }
    if (useIndex < 0) return kIOReturnNoInterrupt;

    fWorkLoop = IOWorkLoop::workLoop();
    if (!fWorkLoop) {
        IKLOG("::start: Couldn't allocate workloop");
        return kIOReturnNoResources;
    }
    fIntSrc = IOFilterInterruptEventSource::filterInterruptEventSource(
        this,
        OSMemberFunctionCast(IOInterruptEventSource::Action, this,
                             &org_ikonoskop_community_CardReader::handleInterrupt),
        OSMemberFunctionCast(IOFilterInterruptEventSource::Filter, this,
                             &org_ikonoskop_community_CardReader::filterInterrupt),
        provider, useIndex);
    if (!fIntSrc) {
        IKLOG("::start: Couldn't allocate interrupt event source");
        return kIOReturnNoResources;
    }
    IOReturn ret = fWorkLoop->addEventSource(fIntSrc);
    if (ret != kIOReturnSuccess) {
        IKLOG("::start: Couldn't add interrupt event source (0x%08x)", ret);
        fIntSrc->release();
        fIntSrc = NULL;
        return ret;
    }
    fWorkLoop->enableAllInterrupts();
    return kIOReturnSuccess;
}

// ---------------------------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------------------------

bool org_ikonoskop_community_CardReader::start(IOService *provider)
{
    IKLOG("start (arm64e port of v1.2)");
    if (!super::start(provider)) return false;

    fPci = OSDynamicCast(IOPCIDevice, provider);
    if (!fPci) goto fail;

    fIrqLock = IOLockAlloc();
    fHwLock = IOLockAlloc();
    fQueueLock = IOLockAlloc();
    if (!fIrqLock || !fHwLock || !fQueueLock) {
        IKLOG("::start - Couldn't IOLockAlloc()");
        goto fail;
    }

    // orig: provider->setMemoryEnable(true) (vtable +0x8c8). Bus mastering is off by default
    // on Apple Silicon, so enable it explicitly for the FPGA's DMA engine.
    fPci->setMemoryEnable(true);
    fPci->setBusLeadEnable(true);
    IKLOG("Config register@0x4 = 0x%08x", fPci->configRead32(kIOPCIConfigCommand));

    fRegMap = fPci->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0);
    if (!fRegMap) {
        IKLOG("mapDeviceMemoryWithRegister(0x10) failed");
        goto fail;
    }
    fRegs = (volatile uint8_t *)fRegMap->getVirtualAddress();
    fRegLen = fRegMap->getLength();
    IKLOG("BAR0 0x%016llx mapped at %p, %llu bytes", (uint64_t)fRegMap->getPhysicalAddress(),
          (void *)fRegs, (uint64_t)fRegLen);

    fFlashSize = rd(kRegFlashSize);
    fFlashEraseSize = rd(kRegFlashEraseSize);
    fFlashVersion = rd(kRegFlashVersion);
    IKLOG("FLASH_SIZE: 0x%x FLASH_ERASE_SIZE: 0x%x ADDR_FLASH_VER_NUM: 0x%x",
          fFlashSize, fFlashEraseSize, fFlashVersion);
    if (fFlashSize == 0xffffffffu && fFlashVersion == 0xffffffffu) {
        IKLOG("device not responding (BAR0 reads all ones)");
        goto fail;
    }

    if (setupDma() != kIOReturnSuccess) goto fail;
    if (setupInterrupts(provider) != kIOReturnSuccess) goto fail;

    // orig: done when the 4 MiB contiguous buffer (this+0xe8, otherwise unused) was allocated.
    wr(kRegFlashPage, 0);
    wr(kRegFetchStart, 1);
    wr(kRegInit10C, 0);

    // Worker performs crspi_init/eeprom_init/metadata/init_fat32 (core) and publishes the nub.
    fWorkerRunning = true;
    retain();
    {
        thread_t thread = THREAD_NULL;
        if (kernel_thread_start(&org_ikonoskop_community_CardReader::workerEntry, this,
                                &thread) != KERN_SUCCESS) {
            fWorkerRunning = false;
            release();
            IKLOG("kernel_thread_start failed");
            goto fail;
        }
        thread_deallocate(thread);
    }

    registerService();
    IKLOG("::start end");
    return true;

fail:
    stop(provider);
    return false;
}

void org_ikonoskop_community_CardReader::markGone(const char *why)
{
    if (fGone) return;
    IKLOG("device removed (%s): stopping MMIO and failing I/O", why);
    fGone = true;
    if (fIrqLock) {
        IOLockLock(fIrqLock);
        IOLockWakeup(fIrqLock, (void *)&fIntStatus, false);
        IOLockUnlock(fIrqLock);
    }
    if (fQueueLock) {
        IOLockLock(fQueueLock);
        IOLockWakeup(fQueueLock, &fQueueHead, false);
        IOLockUnlock(fQueueLock);
    }
}

bool org_ikonoskop_community_CardReader::requestTerminate(IOService *provider, IOOptionBits options)
{
    if (provider == fPci) markGone("requestTerminate");
    return super::requestTerminate(provider, options);
}

bool org_ikonoskop_community_CardReader::willTerminate(IOService *provider, IOOptionBits options)
{
    if (provider == fPci) markGone("willTerminate");
    return super::willTerminate(provider, options);
}

void org_ikonoskop_community_CardReader::stop(IOService *provider)
{
    IKLOG("stop");
    // Stop the worker (it fails any queued request) and wait for it to exit. A DMA wait in
    // progress returns within 500 ms, or immediately if the device is gone.
    if (fQueueLock) {
        IOLockLock(fQueueLock);
        fStopping = true;
        IOLockWakeup(fQueueLock, &fQueueHead, false);
        IOLockUnlock(fQueueLock);
        if (fIrqLock) {
            IOLockLock(fIrqLock);
            IOLockWakeup(fIrqLock, (void *)&fIntStatus, false);
            IOLockUnlock(fIrqLock);
        }
        IOLockLock(fQueueLock);
        while (fWorkerRunning) IOLockSleep(fQueueLock, &fWorkerRunning, THREAD_UNINT);
        IOLockUnlock(fQueueLock);
    }

    if (fNub) {
        if (!fNub->isInactive()) fNub->terminate();
        fNub->release();
        fNub = NULL;
    }

    if (fCard) {
        if (fHwLock) IOLockLock(fHwLock);
        fCard->shutdown();
        delete fCard;
        fCard = NULL;
        if (fHwLock) IOLockUnlock(fHwLock);
    }
    if (fHwOps) {
        delete fHwOps;
        fHwOps = NULL;
    }
    fCardReady = false;

    if (fIntSrc) {
        fIntSrc->disable();
        if (fWorkLoop) fWorkLoop->removeEventSource(fIntSrc);
        fIntSrc->release();
        fIntSrc = NULL;
    }
    if (fWorkLoop) {
        fWorkLoop->release();
        fWorkLoop = NULL;
    }

    // No MMIO here (orig did none either); the FPGA is idle once the worker has exited.
    teardownDma();

    if (fRegMap) {
        fRegs = NULL;
        fRegLen = 0;
        fRegMap->release();
        fRegMap = NULL;
    }

    super::stop(provider);
}

void org_ikonoskop_community_CardReader::free(void)
{
    if (fIrqLock) { IOLockFree(fIrqLock); fIrqLock = NULL; }
    if (fHwLock) { IOLockFree(fHwLock); fHwLock = NULL; }
    if (fQueueLock) { IOLockFree(fQueueLock); fQueueLock = NULL; }
    super::free();
}

// ---------------------------------------------------------------------------------------------
// Worker thread
// ---------------------------------------------------------------------------------------------

void org_ikonoskop_community_CardReader::workerEntry(void *arg, wait_result_t wres)
{
    (void)wres;
    org_ikonoskop_community_CardReader *self = (org_ikonoskop_community_CardReader *)arg;
    self->workerMain();
    self->release();                                    // balances retain() in start()
}

void org_ikonoskop_community_CardReader::waitForFlashGeometry(void)
{
    for (uint32_t waited = 0;; waited += kGeometryPollMs) {
        if (fGone || fStopping) return;
        IOLockLock(fHwLock);
        uint32_t flash = rd(kRegFlashSize);
        uint32_t erase = rd(kRegFlashEraseSize);
        IOLockUnlock(fHwLock);
        if (flash != 0 && erase != 0) {
            if (waited != 0) {
                IKLOG("flash geometry reported after %u ms: FLASH_SIZE 0x%x FLASH_ERASE_SIZE 0x%x",
                      waited, flash, erase);
            }
            return;
        }
        if (waited >= kGeometryWaitMs) {
            IKLOG("no flash geometry within %u ms (FLASH_SIZE 0x%x FLASH_ERASE_SIZE 0x%x)",
                  kGeometryWaitMs, flash, erase);
            return;
        }
        IOSleep(kGeometryPollMs);
    }
}

void org_ikonoskop_community_CardReader::workerMain(void)
{
    // The frame map is built from the FPGA's flash geometry; let it report one first.
    waitForFlashGeometry();

    // orig start(): crspi_init(); eeprom_init(); metadata read; init_fat32(); disk size.
    IKLOG("crspi_init()/eeprom_init()/init_fat32() ...");
    IOLockLock(fHwLock);
    fHwOps = new IkKextHwOps(this);
    fCard = new ik::VirtualCard();
    int rc = (fHwOps && fCard) ? fCard->init(fHwOps) : -1;
    if (rc == 0) {
        fSectorCount = fCard->sectorCount();
        fCardNumber = fCard->cardNumber();
    }
    IOLockUnlock(fHwLock);

    if (rc != 0) {
        IKLOG("card init failed (%d); no volume will be published", rc);
    } else if (!fGone && !fStopping) {
        IKLOG("card %u: %llu sectors (%llu bytes)", fCardNumber, fSectorCount,
              fSectorCount * 512ULL);
        fCardReady = true;
        publishBlockDevice();
    }

    IOLockLock(fQueueLock);
    for (;;) {
        while (!fQueueHead && !fStopping) IOLockSleep(fQueueLock, &fQueueHead, THREAD_UNINT);
        ReadRequest *req = fQueueHead;
        if (!req) break;                                // stopping and drained
        fQueueHead = req->next;
        if (!fQueueHead) fQueueTail = NULL;
        IOLockUnlock(fQueueLock);
        serviceRead(req);
        IOLockLock(fQueueLock);
    }
    fWorkerRunning = false;
    IOLockWakeup(fQueueLock, &fWorkerRunning, false);
    IOLockUnlock(fQueueLock);
}

void org_ikonoskop_community_CardReader::publishBlockDevice(void)
{
    org_ikonoskop_community_CardReaderBlockDevice *nub =
        OSTypeAlloc(org_ikonoskop_community_CardReaderBlockDevice);
    if (!nub) return;
    if (!nub->init(NULL) || !nub->setDriver(this)) {
        nub->release();
        return;
    }
    bool attached = false;
    IOLockLock(fQueueLock);
    if (!fStopping && !fGone && !isInactive()) {
        attached = nub->attach(this);
        if (attached) fNub = nub;                       // keep our creation reference
    }
    IOLockUnlock(fQueueLock);
    if (!attached) {
        nub->release();
        return;
    }
    nub->registerService();
}

void org_ikonoskop_community_CardReader::submitRead(IOMemoryDescriptor *buffer, UInt64 block,
                                                    UInt64 nblks, IOStorageCompletion *completion)
{
    if (fGone || fStopping || isInactive() || !fCardReady) {
        IOStorage::complete(completion, kIOReturnNoDevice, 0);
        return;
    }
    ReadRequest *req = (ReadRequest *)IOMalloc(sizeof(ReadRequest));
    if (!req) {
        IOStorage::complete(completion, kIOReturnNoMemory, 0);
        return;
    }
    req->next = NULL;
    req->buffer = buffer;
    req->block = block;
    req->nblks = nblks;
    req->completion = *completion;
    buffer->retain();

    IOLockLock(fQueueLock);
    if (fStopping || !fWorkerRunning) {
        IOLockUnlock(fQueueLock);
        buffer->release();
        IOFree(req, sizeof(ReadRequest));
        IOStorage::complete(completion, kIOReturnNoDevice, 0);
        return;
    }
    if (fQueueTail) fQueueTail->next = req; else fQueueHead = req;
    fQueueTail = req;
    IOLockWakeup(fQueueLock, &fQueueHead, true);
    IOLockUnlock(fQueueLock);
}

// orig: MYIOBSD::doAsyncReadWrite() body + fetch_sectors(); error flag this+0x188 -> 0xe00002bc.
void org_ikonoskop_community_CardReader::serviceRead(ReadRequest *req)
{
    IOMemoryDescriptor *md = req->buffer;
    IOReturn status = kIOReturnSuccess;
    UInt64 bytes = 0;

    if (fGone || fStopping || !fCardReady || !fCard) {
        status = kIOReturnNoDevice;
    } else if (req->nblks == 0 || req->block + req->nblks > fSectorCount ||
               req->nblks > 0xffffffffULL ||
               md->getLength() < req->nblks * 512ULL) {
        status = kIOReturnBadArgument;
    } else {
        status = md->prepare(kIODirectionIn);
        if (status == kIOReturnSuccess) {
            IOMemoryMap *map = md->createMappingInTask(kernel_task, 0, kIOMapAnywhere, 0,
                                                       req->nblks * 512ULL);
            if (!map) {
                status = kIOReturnVMError;
            } else {
                uint8_t *dst = (uint8_t *)map->getVirtualAddress();
                IOLockLock(fHwLock);
                int rc = fGone ? -1 : fCard->readSectors(req->block, (uint32_t)req->nblks, dst);
                IOLockUnlock(fHwLock);
                map->release();
                if (rc == 0) {
                    bytes = req->nblks * 512ULL;
                } else {
                    status = fGone ? kIOReturnNoDevice : kIOReturnIOError;
                }
            }
            md->complete(kIODirectionIn);
        }
    }
    md->release();
    IOStorageCompletion completion = req->completion;
    IOFree(req, sizeof(ReadRequest));
    IOStorage::complete(&completion, status, bytes);
}

// ---------------------------------------------------------------------------------------------
// Debug user client backends
// ---------------------------------------------------------------------------------------------

IOReturn org_ikonoskop_community_CardReader::ucStatus(uint64_t *out, uint32_t count)
{
    if (!out || count < IK_STATUS_COUNT) return kIOReturnBadArgument;
    bzero(out, count * sizeof(uint64_t));

    IOLockLock(fHwLock);
    out[kIkStFlashSize] = rd(kRegFlashSize);
    out[kIkStFlashEraseSize] = rd(kRegFlashEraseSize);
    out[kIkStFlashVersion] = rd(kRegFlashVersion);
    out[kIkStPciCommandStatus] = 0xffffffffu;
    out[kIkStLinkStatus] = 0xffffffffu;
    out[kIkStLinkCap] = 0xffffffffu;
    if (!fGone && fPci) {
        out[kIkStPciCommandStatus] = fPci->configRead32(kIOPCIConfigCommand);
        UInt8 capOffset = 0;
        if (fPci->findPCICapability(kIOPCICapabilityIDPCIExpress, &capOffset) && capOffset) {
            out[kIkStLinkCap] = fPci->configRead32(capOffset + 0x0c);
            out[kIkStLinkStatus] = fPci->configRead16(capOffset + 0x12);
        }
    }
    IOLockUnlock(fHwLock);

    out[kIkStDmaSegments] = fDmaSegments;
    out[kIkStDmaSegmentBytes] = fDmaSegMax;
    out[kIkStFirstIova] = fFirstIova;
    out[kIkStFlags] = (fGone ? 1 : 0) | (fCardReady ? 2 : 0) | (fIntSrc ? 4 : 0) |
                      (fIntIsMSI ? 8 : 0);
    out[kIkStSectorCount] = fSectorCount;
    out[kIkStCardNumber] = fCardNumber;
    out[kIkStInterrupts] = fStatInterrupts;
    out[kIkStDmaTimeouts] = fStatTimeouts;
    out[kIkStDmaReads] = fStatDmaReads;
    return kIOReturnSuccess;
}

IOReturn org_ikonoskop_community_CardReader::ucReadEeprom(uint32_t addr, uint32_t len, uint8_t *dst)
{
    if (!dst || len == 0 || len > kIkMaxEepromBytes) return kIOReturnBadArgument;
    if (fGone || fStopping) return kIOReturnNoDevice;
    IOLockLock(fHwLock);
    int r = flashEepromRead(dst, len, addr);
    IOLockUnlock(fHwLock);
    return r == (int)len ? kIOReturnSuccess : kIOReturnIOError;
}

IOReturn org_ikonoskop_community_CardReader::ucReadFrame(uint32_t page, IOMemoryDescriptor *dst,
                                                         uint64_t *copied)
{
    if (!dst || dst->getLength() < ik::kFrameDmaBytes) return kIOReturnBadArgument;
    if (fGone || fStopping) return kIOReturnNoDevice;
    IOReturn ret = kIOReturnIOError;
    IOLockLock(fHwLock);
    const uint8_t *p = hwReadFrame(page);
    if (p) {
        IOByteCount n = dst->writeBytes(0, p, ik::kFrameDmaBytes);
        if (copied) *copied = n;
        ret = (n == ik::kFrameDmaBytes) ? kIOReturnSuccess : kIOReturnIOError;
    }
    IOLockUnlock(fHwLock);
    return ret;
}

IOReturn org_ikonoskop_community_CardReader::ucReadSectors(uint64_t lba, uint32_t count, uint8_t *dst)
{
    if (!dst || count == 0 || count > kIkMaxDebugSectors) return kIOReturnBadArgument;
    if (fGone || fStopping) return kIOReturnNoDevice;
    if (!fCardReady || !fCard) return kIOReturnNotReady;
    if (lba + count > fSectorCount) return kIOReturnBadArgument;
    IOLockLock(fHwLock);
    int rc = fCard->readSectors(lba, count, dst);
    IOLockUnlock(fHwLock);
    return rc == 0 ? kIOReturnSuccess : kIOReturnIOError;
}

IOReturn org_ikonoskop_community_CardReader::ucReadReg(uint32_t offset, uint32_t *value)
{
    IOLockLock(fHwLock);
    IOReturn ret = regRead(offset, value);
    IOLockUnlock(fHwLock);
    return ret;
}
