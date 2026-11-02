// IkonoskopBlockDevice.cpp — port of com_Ikonoskop_driver_CardReader_MYIOBSD (v1.2).

#include "IkonoskopBlockDevice.hpp"
#include "IkonoskopCardReader.hpp"

#include <IOKit/IOLib.h>
#include <IOKit/storage/IOStorageProtocolCharacteristics.h>
#include <IOKit/storage/IOStorageDeviceCharacteristics.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSString.h>

#define super IOBlockStorageDevice
OSDefineMetaClassAndStructors(org_ikonoskop_community_CardReaderBlockDevice, IOBlockStorageDevice)

static char sVendor[] = "Ikonoskop";
static char sProduct[] = "a-cam dII Memory Card";
static char sAdditional[] = "getAdditionalDeviceInfoString";   // orig returned this literal

static void setStringInDict(OSDictionary *dict, const char *key, const char *value)
{
    OSString *s = OSString::withCString(value);
    if (s) {
        dict->setObject(key, s);
        s->release();
    }
}

bool org_ikonoskop_community_CardReaderBlockDevice::init(OSDictionary *properties)
{
    if (!super::init(properties)) return false;
    fDriver = NULL;
    fRevision[0] = '0';
    fRevision[1] = 0;

    // orig MYIOBSD::init(): transfer limits = one frame's worth of sectors.
    setProperty("IOMaximumByteCountRead", 0x334000ULL, 64);
    setProperty("IOMaximumBlockCountRead", 0x19a0ULL, 64);
    setProperty("IOMaximumSegmentCountRead", 0x334ULL, 64);

    OSDictionary *proto = OSDictionary::withCapacity(2);
    if (proto) {
        setStringInDict(proto, kIOPropertyPhysicalInterconnectTypeKey,
                        kIOPropertyPhysicalInterconnectTypePCIExpress);
        setStringInDict(proto, kIOPropertyPhysicalInterconnectLocationKey,
                        kIOPropertyExternalKey);
        setProperty(kIOPropertyProtocolCharacteristicsKey, proto);
        proto->release();
    }
    OSDictionary *dev = OSDictionary::withCapacity(3);
    if (dev) {
        setStringInDict(dev, kIOPropertyVendorNameKey, sVendor);
        setStringInDict(dev, kIOPropertyProductNameKey, sProduct);
        setStringInDict(dev, kIOPropertyMediumTypeKey, kIOPropertyMediumTypeSolidStateKey);
        setProperty(kIOPropertyDeviceCharacteristicsKey, dev);
        dev->release();
    }
    return true;
}

bool org_ikonoskop_community_CardReaderBlockDevice::setDriver(org_ikonoskop_community_CardReader *driver)
{
    if (!driver || fDriver) return false;
    fDriver = driver;
    fDriver->retain();
    snprintf(fRevision, sizeof(fRevision), "0x%x", driver->flashVersion());  // orig: this+0x114
    return true;
}

void org_ikonoskop_community_CardReaderBlockDevice::free(void)
{
    if (fDriver) {
        fDriver->release();
        fDriver = NULL;
    }
    super::free();
}

IOReturn org_ikonoskop_community_CardReaderBlockDevice::doEjectMedia(void)
{
    return kIOReturnSuccess;                            // orig: no-op success
}

IOReturn org_ikonoskop_community_CardReaderBlockDevice::doFormatMedia(UInt64 byteCapacity)
{
    (void)byteCapacity;
    return kIOReturnNotWritable;                        // read-only port (orig: no-op success)
}

UInt32 org_ikonoskop_community_CardReaderBlockDevice::doGetFormatCapacities(UInt64 *capacities,
                                                                           UInt32 capacitiesMaxCount) const
{
    (void)capacities;
    (void)capacitiesMaxCount;
    return 0;                                           // orig: 0
}

char *org_ikonoskop_community_CardReaderBlockDevice::getVendorString(void) { return sVendor; }
char *org_ikonoskop_community_CardReaderBlockDevice::getProductString(void) { return sProduct; }
char *org_ikonoskop_community_CardReaderBlockDevice::getRevisionString(void) { return fRevision; }
char *org_ikonoskop_community_CardReaderBlockDevice::getAdditionalDeviceInfoString(void) { return sAdditional; }

IOReturn org_ikonoskop_community_CardReaderBlockDevice::reportBlockSize(UInt64 *blockSize)
{
    if (blockSize) *blockSize = 512;
    return kIOReturnSuccess;
}

IOReturn org_ikonoskop_community_CardReaderBlockDevice::reportEjectability(bool *isEjectable)
{
    // orig returned success without writing the flag; report ejectable explicitly.
    if (isEjectable) *isEjectable = true;
    return kIOReturnSuccess;
}

IOReturn org_ikonoskop_community_CardReaderBlockDevice::reportMaxValidBlock(UInt64 *maxBlock)
{
    UInt64 n = fDriver ? fDriver->sectorCount() : 0;
    if (maxBlock) *maxBlock = n ? n - 1 : 0;
    return kIOReturnSuccess;
}

IOReturn org_ikonoskop_community_CardReaderBlockDevice::reportMediaState(bool *mediaPresent,
                                                                         bool *changedState)
{
    if (mediaPresent) *mediaPresent = fDriver && !fDriver->deviceGone();
    if (changedState) *changedState = false;
    return kIOReturnSuccess;
}

IOReturn org_ikonoskop_community_CardReaderBlockDevice::reportRemovability(bool *isRemovable)
{
    if (isRemovable) *isRemovable = true;
    return kIOReturnSuccess;
}

IOReturn org_ikonoskop_community_CardReaderBlockDevice::reportWriteProtection(bool *isWriteProtected)
{
    if (isWriteProtected) *isWriteProtected = true;
    return kIOReturnSuccess;
}

IOReturn org_ikonoskop_community_CardReaderBlockDevice::getWriteCacheState(bool *enabled)
{
    (void)enabled;
    return kIOReturnUnsupported;                        // orig: 0xe00002c7
}

IOReturn org_ikonoskop_community_CardReaderBlockDevice::setWriteCacheState(bool enabled)
{
    (void)enabled;
    return kIOReturnUnsupported;
}

// Completion is always delivered exactly once via `completion` (never also via the return
// value), and the actual work runs on the driver's worker thread.
IOReturn org_ikonoskop_community_CardReaderBlockDevice::doAsyncReadWrite(IOMemoryDescriptor *buffer,
                                                                         UInt64 block, UInt64 nblks,
                                                                         IOStorageAttributes *attributes,
                                                                         IOStorageCompletion *completion)
{
    (void)attributes;
    if (!buffer || !completion) return kIOReturnBadArgument;
    if (isInactive() || !fDriver) {
        IOStorage::complete(completion, kIOReturnNoDevice, 0);
        return kIOReturnSuccess;
    }
    if (buffer->getDirection() != kIODirectionIn) {
        IOStorage::complete(completion, kIOReturnNotWritable, 0);
        return kIOReturnSuccess;
    }
    fDriver->submitRead(buffer, block, nblks, completion);
    return kIOReturnSuccess;
}

IOReturn org_ikonoskop_community_CardReaderBlockDevice::doSynchronize(UInt64 block, UInt64 nblks,
                                                                      IOStorageSynchronizeOptions options)
{
    (void)block;
    (void)nblks;
    (void)options;
    return kIOReturnSuccess;                            // nothing cached, nothing written
}

IOReturn org_ikonoskop_community_CardReaderBlockDevice::doUnmap(IOBlockStorageDeviceExtent *extents,
                                                                UInt32 extentsCount,
                                                                IOStorageUnmapOptions options)
{
    (void)extents;
    (void)extentsCount;
    (void)options;
    return kIOReturnNotWritable;
}

IOReturn org_ikonoskop_community_CardReaderBlockDevice::requestIdle(void)
{
    return kIOReturnSuccess;
}
