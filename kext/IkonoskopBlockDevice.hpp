// IkonoskopBlockDevice.hpp — port of com_Ikonoskop_driver_CardReader_MYIOBSD.
//
// Read-only, write-protected, removable IOBlockStorageDevice nub exposing the virtual
// FAT32 volume synthesized by ik::VirtualCard. IOBlockStorageDriver matches on it.
#ifndef IKONOSKOP_BLOCK_DEVICE_HPP
#define IKONOSKOP_BLOCK_DEVICE_HPP

#include <IOKit/storage/IOBlockStorageDevice.h>

class org_ikonoskop_community_CardReader;

class org_ikonoskop_community_CardReaderBlockDevice : public IOBlockStorageDevice {
    OSDeclareDefaultStructors(org_ikonoskop_community_CardReaderBlockDevice)

public:
    bool init(OSDictionary *properties = NULL) APPLE_KEXT_OVERRIDE;
    void free(void) APPLE_KEXT_OVERRIDE;
    // Equivalent of MYIOBSD::setProvider(): binds the PCI driver (retained).
    bool setDriver(org_ikonoskop_community_CardReader *driver);

    IOReturn doEjectMedia(void) APPLE_KEXT_OVERRIDE;
    IOReturn doFormatMedia(UInt64 byteCapacity) APPLE_KEXT_OVERRIDE;
    UInt32 doGetFormatCapacities(UInt64 *capacities, UInt32 capacitiesMaxCount) const APPLE_KEXT_OVERRIDE;
    char *getVendorString(void) APPLE_KEXT_OVERRIDE;
    char *getProductString(void) APPLE_KEXT_OVERRIDE;
    char *getRevisionString(void) APPLE_KEXT_OVERRIDE;
    char *getAdditionalDeviceInfoString(void) APPLE_KEXT_OVERRIDE;
    IOReturn reportBlockSize(UInt64 *blockSize) APPLE_KEXT_OVERRIDE;
    IOReturn reportEjectability(bool *isEjectable) APPLE_KEXT_OVERRIDE;
    IOReturn reportMaxValidBlock(UInt64 *maxBlock) APPLE_KEXT_OVERRIDE;
    IOReturn reportMediaState(bool *mediaPresent, bool *changedState = 0) APPLE_KEXT_OVERRIDE;
    IOReturn reportRemovability(bool *isRemovable) APPLE_KEXT_OVERRIDE;
    IOReturn reportWriteProtection(bool *isWriteProtected) APPLE_KEXT_OVERRIDE;
    IOReturn getWriteCacheState(bool *enabled) APPLE_KEXT_OVERRIDE;
    IOReturn setWriteCacheState(bool enabled) APPLE_KEXT_OVERRIDE;
    IOReturn doAsyncReadWrite(IOMemoryDescriptor *buffer, UInt64 block, UInt64 nblks,
                              IOStorageAttributes *attributes,
                              IOStorageCompletion *completion) APPLE_KEXT_OVERRIDE;
    IOReturn doSynchronize(UInt64 block, UInt64 nblks,
                           IOStorageSynchronizeOptions options = 0) APPLE_KEXT_OVERRIDE;
    IOReturn doUnmap(IOBlockStorageDeviceExtent *extents, UInt32 extentsCount,
                     IOStorageUnmapOptions options = 0) APPLE_KEXT_OVERRIDE;
    IOReturn requestIdle(void) APPLE_KEXT_OVERRIDE;

private:
    org_ikonoskop_community_CardReader *fDriver;
    char fRevision[16];
};

#endif
