/* ik_uc_shared.h — ABI between the kext's debug user client and tools/ikctl.
 * C-compatible; included by both the kext (C++) and the CLI (C). */
#ifndef IK_UC_SHARED_H
#define IK_UC_SHARED_H

#define IK_DRIVER_CLASS "org_ikonoskop_community_CardReader"

/* External method selectors (all scalar-only; bulk data goes to a caller buffer whose
 * user address and length are passed as scalars). Every selector is root-only. */
enum {
    /* in: none. out: IK_STATUS_COUNT scalars (see IkStatusIndex). */
    kIkSelStatus = 0,
    /* in: eepromAddr, length (<= 0x2000), userBuf, userBufLen. out: bytes copied. */
    kIkSelEeprom = 1,
    /* in: flashPage, userBuf, userBufLen (>= kIkFrameBytes). out: bytes copied. */
    kIkSelFrame = 2,
    /* in: lba, count (<= kIkMaxDebugSectors), userBuf, userBufLen. out: bytes copied. */
    kIkSelSectors = 3,
    /* in: BAR0 offset (4-byte aligned). out: value. Read-only. */
    kIkSelReadReg = 4,
    kIkSelCount
};

enum IkStatusIndex {
    kIkStFlashSize = 0,    /* reg 0x2c (units of 4 KiB) */
    kIkStFlashEraseSize,   /* reg 0x30 */
    kIkStFlashVersion,     /* reg 0x4c */
    kIkStPciCommandStatus, /* config dword 0x04 */
    kIkStLinkStatus,       /* PCIe Link Status (cap + 0x12), 0xffffffff if unknown */
    kIkStLinkCap,          /* PCIe Link Capabilities (cap + 0x0c) */
    kIkStDmaSegments,      /* entries programmed at 0x1000/0x2000 (reg 0x120) */
    kIkStDmaSegmentBytes,  /* max segment size used for the table (0 = unlimited) */
    kIkStFirstIova,        /* first DMA segment address handed to the FPGA */
    kIkStFlags,            /* bit0 device gone, bit1 card ready, bit2 interrupt source ok, bit3 MSI */
    kIkStSectorCount,      /* VirtualCard::sectorCount() */
    kIkStCardNumber,       /* VirtualCard::cardNumber() */
    kIkStInterrupts,       /* interrupts handled */
    kIkStDmaTimeouts,      /* 500 ms DMA deadlines missed (reg 0x104 abort written) */
    kIkStDmaReads,         /* frame DMAs started */
    IK_STATUS_COUNT
};

#define kIkFrameBytes       0x335000u
#define kIkMaxEepromBytes   0x2000u
#define kIkMaxDebugSectors  0x2000u

#endif /* IK_UC_SHARED_H */
