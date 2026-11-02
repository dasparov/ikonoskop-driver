// IkonoskopUserClient.hpp — root-only debug user client for tools/ikctl.
// (Replaces the original's SamplePCIUserClient-derived com_Ikonoskop_driver_CardReaderUserClient.)
#ifndef IKONOSKOP_USER_CLIENT_HPP
#define IKONOSKOP_USER_CLIENT_HPP

#include <IOKit/IOUserClient.h>

class org_ikonoskop_community_CardReader;

class org_ikonoskop_community_CardReaderUserClient : public IOUserClient {
    OSDeclareDefaultStructors(org_ikonoskop_community_CardReaderUserClient)

public:
    bool initWithTask(task_t owningTask, void *securityToken, UInt32 type,
                      OSDictionary *properties) APPLE_KEXT_OVERRIDE;
    bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
    IOReturn clientClose(void) APPLE_KEXT_OVERRIDE;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *arguments,
                            IOExternalMethodDispatch *dispatch, OSObject *target,
                            void *reference) APPLE_KEXT_OVERRIDE;

private:
    static IOReturn sStatus(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sEeprom(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sFrame(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sSectors(OSObject *target, void *ref, IOExternalMethodArguments *args);
    static IOReturn sReadReg(OSObject *target, void *ref, IOExternalMethodArguments *args);

    IOMemoryDescriptor *userBuffer(uint64_t address, uint64_t length);
    IOReturn copyToUser(uint64_t address, uint64_t length, const void *src, uint64_t n);

    static const IOExternalMethodDispatch sMethods[];

    task_t fTask;
    org_ikonoskop_community_CardReader *fDriver;
};

#endif
