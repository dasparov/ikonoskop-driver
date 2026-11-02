// IkonoskopUserClient.cpp — root-only debug user client (status / EEPROM / frame / sectors).

#include "IkonoskopUserClient.hpp"
#include "IkonoskopCardReader.hpp"
#include "ik_uc_shared.h"

#include <IOKit/IOLib.h>
#include <IOKit/IOMemoryDescriptor.h>

#define super IOUserClient
OSDefineMetaClassAndStructors(org_ikonoskop_community_CardReaderUserClient, IOUserClient)

const IOExternalMethodDispatch org_ikonoskop_community_CardReaderUserClient::sMethods[kIkSelCount] = {
    // function, scalarIn, structIn, scalarOut, structOut
    { &org_ikonoskop_community_CardReaderUserClient::sStatus,  0, 0, IK_STATUS_COUNT, 0 },
    { &org_ikonoskop_community_CardReaderUserClient::sEeprom,  4, 0, 1, 0 },
    { &org_ikonoskop_community_CardReaderUserClient::sFrame,   3, 0, 1, 0 },
    { &org_ikonoskop_community_CardReaderUserClient::sSectors, 4, 0, 1, 0 },
    { &org_ikonoskop_community_CardReaderUserClient::sReadReg, 1, 0, 1, 0 },
};

bool org_ikonoskop_community_CardReaderUserClient::initWithTask(task_t owningTask, void *securityToken,
                                                               UInt32 type, OSDictionary *properties)
{
    if (clientHasPrivilege(securityToken, kIOClientPrivilegeAdministrator) != kIOReturnSuccess)
        return false;
    if (!super::initWithTask(owningTask, securityToken, type, properties)) return false;
    fTask = owningTask;
    fDriver = NULL;
    return true;
}

bool org_ikonoskop_community_CardReaderUserClient::start(IOService *provider)
{
    fDriver = OSDynamicCast(org_ikonoskop_community_CardReader, provider);
    if (!fDriver) return false;
    return super::start(provider);
}

void org_ikonoskop_community_CardReaderUserClient::stop(IOService *provider)
{
    super::stop(provider);
}

IOReturn org_ikonoskop_community_CardReaderUserClient::clientClose(void)
{
    if (!isInactive()) terminate();
    return kIOReturnSuccess;
}

IOReturn org_ikonoskop_community_CardReaderUserClient::externalMethod(uint32_t selector,
                                                                    IOExternalMethodArguments *arguments,
                                                                    IOExternalMethodDispatch *dispatch,
                                                                    OSObject *target, void *reference)
{
    if (selector >= kIkSelCount) return kIOReturnBadArgument;
    if (isInactive() || !fDriver) return kIOReturnNotAttached;
    dispatch = (IOExternalMethodDispatch *)&sMethods[selector];
    target = this;
    reference = NULL;
    return super::externalMethod(selector, arguments, dispatch, target, reference);
}

IOMemoryDescriptor *org_ikonoskop_community_CardReaderUserClient::userBuffer(uint64_t address,
                                                                             uint64_t length)
{
    if (!address || !length) return NULL;
    IOMemoryDescriptor *md = IOMemoryDescriptor::withAddressRange(address, length,
                                                                  kIODirectionIn, fTask);
    if (!md) return NULL;
    if (md->prepare(kIODirectionIn) != kIOReturnSuccess) {
        md->release();
        return NULL;
    }
    return md;
}

IOReturn org_ikonoskop_community_CardReaderUserClient::copyToUser(uint64_t address, uint64_t length,
                                                                 const void *src, uint64_t n)
{
    if (n > length) return kIOReturnNoSpace;
    IOMemoryDescriptor *md = userBuffer(address, length);
    if (!md) return kIOReturnVMError;
    IOByteCount w = md->writeBytes(0, src, n);
    md->complete(kIODirectionIn);
    md->release();
    return w == n ? kIOReturnSuccess : kIOReturnVMError;
}

IOReturn org_ikonoskop_community_CardReaderUserClient::sStatus(OSObject *target, void *ref,
                                                               IOExternalMethodArguments *args)
{
    (void)ref;
    org_ikonoskop_community_CardReaderUserClient *self =
        (org_ikonoskop_community_CardReaderUserClient *)target;
    return self->fDriver->ucStatus(args->scalarOutput, args->scalarOutputCount);
}

// in: addr, len, userBuf, userBufLen
IOReturn org_ikonoskop_community_CardReaderUserClient::sEeprom(OSObject *target, void *ref,
                                                               IOExternalMethodArguments *args)
{
    (void)ref;
    org_ikonoskop_community_CardReaderUserClient *self =
        (org_ikonoskop_community_CardReaderUserClient *)target;
    uint64_t addr = args->scalarInput[0], len = args->scalarInput[1];
    if (addr > 0xffff || len == 0 || len > kIkMaxEepromBytes) return kIOReturnBadArgument;
    uint8_t *buf = (uint8_t *)IOMalloc((vm_size_t)len);
    if (!buf) return kIOReturnNoMemory;
    IOReturn ret = self->fDriver->ucReadEeprom((uint32_t)addr, (uint32_t)len, buf);
    if (ret == kIOReturnSuccess)
        ret = self->copyToUser(args->scalarInput[2], args->scalarInput[3], buf, len);
    IOFree(buf, (vm_size_t)len);
    args->scalarOutput[0] = (ret == kIOReturnSuccess) ? len : 0;
    return ret;
}

// in: flashPage, userBuf, userBufLen
IOReturn org_ikonoskop_community_CardReaderUserClient::sFrame(OSObject *target, void *ref,
                                                              IOExternalMethodArguments *args)
{
    (void)ref;
    org_ikonoskop_community_CardReaderUserClient *self =
        (org_ikonoskop_community_CardReaderUserClient *)target;
    uint64_t page = args->scalarInput[0];
    if (page > 0xffffffffULL) return kIOReturnBadArgument;
    if (args->scalarInput[2] < kIkFrameBytes) return kIOReturnNoSpace;
    IOMemoryDescriptor *md = self->userBuffer(args->scalarInput[1], args->scalarInput[2]);
    if (!md) return kIOReturnVMError;
    uint64_t copied = 0;
    IOReturn ret = self->fDriver->ucReadFrame((uint32_t)page, md, &copied);
    md->complete(kIODirectionIn);
    md->release();
    args->scalarOutput[0] = copied;
    return ret;
}

// in: lba, count, userBuf, userBufLen
IOReturn org_ikonoskop_community_CardReaderUserClient::sSectors(OSObject *target, void *ref,
                                                                IOExternalMethodArguments *args)
{
    (void)ref;
    org_ikonoskop_community_CardReaderUserClient *self =
        (org_ikonoskop_community_CardReaderUserClient *)target;
    uint64_t lba = args->scalarInput[0], count = args->scalarInput[1];
    if (count == 0 || count > kIkMaxDebugSectors) return kIOReturnBadArgument;
    uint64_t bytes = count * 512ULL;
    if (args->scalarInput[3] < bytes) return kIOReturnNoSpace;
    uint8_t *buf = (uint8_t *)IOMalloc((vm_size_t)bytes);
    if (!buf) return kIOReturnNoMemory;
    IOReturn ret = self->fDriver->ucReadSectors(lba, (uint32_t)count, buf);
    if (ret == kIOReturnSuccess)
        ret = self->copyToUser(args->scalarInput[2], args->scalarInput[3], buf, bytes);
    IOFree(buf, (vm_size_t)bytes);
    args->scalarOutput[0] = (ret == kIOReturnSuccess) ? bytes : 0;
    return ret;
}

// in: offset; out: value
IOReturn org_ikonoskop_community_CardReaderUserClient::sReadReg(OSObject *target, void *ref,
                                                                IOExternalMethodArguments *args)
{
    (void)ref;
    org_ikonoskop_community_CardReaderUserClient *self =
        (org_ikonoskop_community_CardReaderUserClient *)target;
    uint64_t off = args->scalarInput[0];
    if (off > 0xffffffffULL) return kIOReturnBadArgument;
    uint32_t v = 0;
    IOReturn ret = self->fDriver->ucReadReg((uint32_t)off, &v);
    args->scalarOutput[0] = v;
    return ret;
}
