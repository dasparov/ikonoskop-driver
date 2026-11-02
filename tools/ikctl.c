/* ikctl — debug CLI for the org.ikonoskop.community.CardReader kext (root only).
 *
 *   ikctl status
 *   ikctl reg <offset>
 *   ikctl eeprom <addr> <len>              hex dump (len <= 0x2000)
 *   ikctl frame <page> <outfile>           raw 0x335000-byte frame DMA of a flash page
 *   ikctl sectors <lba> <count> <outfile>  sectors of the synthesized FAT32 volume
 *
 * Numbers accept 0x-prefixed hex. Everything is read-only.
 */
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include "ik_uc_shared.h"

static void usage(void)
{
    fprintf(stderr,
            "usage: ikctl status\n"
            "       ikctl reg <offset>\n"
            "       ikctl eeprom <addr> <len>\n"
            "       ikctl frame <page> <outfile>\n"
            "       ikctl sectors <lba> <count> <outfile>\n");
    exit(2);
}

static uint64_t num(const char *s)
{
    char *end = NULL;
    errno = 0;
    unsigned long long v = strtoull(s, &end, 0);
    if (errno || !end || *end) {
        fprintf(stderr, "ikctl: bad number '%s'\n", s);
        exit(2);
    }
    return v;
}

static io_connect_t open_driver(void)
{
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching(IK_DRIVER_CLASS));
    if (!svc) {
        fprintf(stderr, "ikctl: %s not found (kext not loaded or card not attached)\n",
                IK_DRIVER_CLASS);
        exit(1);
    }
    io_connect_t conn = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "ikctl: IOServiceOpen failed: 0x%08x%s\n", kr,
                kr == kIOReturnNotPrivileged ? " (run as root)" : "");
        exit(1);
    }
    return conn;
}

static void check(kern_return_t kr, const char *what)
{
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "ikctl: %s failed: 0x%08x (%s)\n", what, kr, mach_error_string(kr));
        exit(1);
    }
}

static void hexdump(const uint8_t *p, size_t n, uint64_t base)
{
    for (size_t i = 0; i < n; i += 16) {
        printf("%06llx ", (unsigned long long)(base + i));
        for (size_t j = 0; j < 16; j++) {
            if (i + j < n) printf(" %02x", p[i + j]); else printf("   ");
        }
        printf("  |");
        for (size_t j = 0; j < 16 && i + j < n; j++) {
            uint8_t c = p[i + j];
            putchar(c >= 0x20 && c < 0x7f ? c : '.');
        }
        printf("|\n");
    }
}

static void write_file(const char *path, const void *buf, size_t n)
{
    FILE *f = fopen(path, "wb");
    if (!f) {
        perror(path);
        exit(1);
    }
    if (fwrite(buf, 1, n, f) != n) {
        perror(path);
        exit(1);
    }
    fclose(f);
}

static void cmd_status(io_connect_t c)
{
    uint64_t out[IK_STATUS_COUNT] = {0};
    uint32_t cnt = IK_STATUS_COUNT;
    check(IOConnectCallScalarMethod(c, kIkSelStatus, NULL, 0, out, &cnt), "status");
    uint64_t fl = out[kIkStFlags];
    printf("FLASH_SIZE         0x%08llx (%llu MiB)\n", out[kIkStFlashSize],
           (out[kIkStFlashSize] * 4096ULL) >> 20);
    printf("FLASH_ERASE_SIZE   0x%08llx\n", out[kIkStFlashEraseSize]);
    printf("FLASH_VER_NUM      0x%08llx\n", out[kIkStFlashVersion]);
    printf("PCI cmd/status     0x%08llx (mem %s, bus-lead %s)\n", out[kIkStPciCommandStatus],
           (out[kIkStPciCommandStatus] & 2) ? "on" : "off",
           (out[kIkStPciCommandStatus] & 4) ? "on" : "off");
    if (out[kIkStLinkStatus] != 0xffffffffULL) {
        uint64_t ls = out[kIkStLinkStatus], lc = out[kIkStLinkCap];
        printf("PCIe link          gen%llu x%llu (cap gen%llu x%llu)%s\n", ls & 0xf,
               (ls >> 4) & 0x3f, lc & 0xf, (lc >> 4) & 0x3f,
               (ls & 0x0800) ? " training" : "");
    } else {
        printf("PCIe link          unknown\n");
    }
    printf("DMA SG entries     %llu x %llu bytes, first IOVA 0x%08llx\n",
           out[kIkStDmaSegments], out[kIkStDmaSegmentBytes], out[kIkStFirstIova]);
    printf("interrupt          %s%s\n", (fl & 4) ? "ok" : "none", (fl & 8) ? " (MSI)" : "");
    printf("device             %s\n", (fl & 1) ? "GONE" : "present");
    printf("card               %s, number %llu, %llu sectors (%llu MiB)\n",
           (fl & 2) ? "ready" : "not ready", out[kIkStCardNumber], out[kIkStSectorCount],
           (out[kIkStSectorCount] * 512ULL) >> 20);
    printf("stats              %llu DMA reads, %llu interrupts, %llu timeouts\n",
           out[kIkStDmaReads], out[kIkStInterrupts], out[kIkStDmaTimeouts]);
}

int main(int argc, char **argv)
{
    if (argc < 2) usage();
    const char *cmd = argv[1];

    if (!strcmp(cmd, "status") && argc == 2) {
        io_connect_t c = open_driver();
        cmd_status(c);
        IOServiceClose(c);
    } else if (!strcmp(cmd, "reg") && argc == 3) {
        io_connect_t c = open_driver();
        uint64_t in = num(argv[2]), out = 0;
        uint32_t cnt = 1;
        check(IOConnectCallScalarMethod(c, kIkSelReadReg, &in, 1, &out, &cnt), "reg");
        printf("reg 0x%04llx = 0x%08llx\n", in, out);
        IOServiceClose(c);
    } else if (!strcmp(cmd, "eeprom") && argc == 4) {
        uint64_t addr = num(argv[2]), len = num(argv[3]);
        if (len == 0 || len > kIkMaxEepromBytes) {
            fprintf(stderr, "ikctl: len must be 1..0x%x\n", kIkMaxEepromBytes);
            return 2;
        }
        uint8_t *buf = calloc(1, len);
        io_connect_t c = open_driver();
        uint64_t in[4] = { addr, len, (uint64_t)(uintptr_t)buf, len }, out = 0;
        uint32_t cnt = 1;
        check(IOConnectCallScalarMethod(c, kIkSelEeprom, in, 4, &out, &cnt), "eeprom");
        hexdump(buf, out, addr);
        IOServiceClose(c);
        free(buf);
    } else if (!strcmp(cmd, "frame") && argc == 4) {
        uint64_t page = num(argv[2]);
        uint8_t *buf = calloc(1, kIkFrameBytes);
        io_connect_t c = open_driver();
        uint64_t in[3] = { page, (uint64_t)(uintptr_t)buf, kIkFrameBytes }, out = 0;
        uint32_t cnt = 1;
        check(IOConnectCallScalarMethod(c, kIkSelFrame, in, 3, &out, &cnt), "frame");
        write_file(argv[3], buf, out);
        printf("wrote %llu bytes of flash page %llu to %s\n", out, page, argv[3]);
        IOServiceClose(c);
        free(buf);
    } else if (!strcmp(cmd, "sectors") && argc == 5) {
        uint64_t lba = num(argv[2]), count = num(argv[3]);
        if (count == 0 || count > kIkMaxDebugSectors) {
            fprintf(stderr, "ikctl: count must be 1..0x%x\n", kIkMaxDebugSectors);
            return 2;
        }
        size_t bytes = count * 512;
        uint8_t *buf = calloc(1, bytes);
        io_connect_t c = open_driver();
        uint64_t in[4] = { lba, count, (uint64_t)(uintptr_t)buf, bytes }, out = 0;
        uint32_t cnt = 1;
        check(IOConnectCallScalarMethod(c, kIkSelSectors, in, 4, &out, &cnt), "sectors");
        write_file(argv[4], buf, out);
        printf("wrote %llu bytes (LBA %llu..%llu) to %s\n", out, lba, lba + count - 1, argv[4]);
        IOServiceClose(c);
        free(buf);
    } else {
        usage();
    }
    return 0;
}
