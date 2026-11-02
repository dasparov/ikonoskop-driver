#!/usr/bin/env python3
"""Differential test: original IkonoskopCardReader v1.2 x86_64 code vs core/ (ik::VirtualCard).

The original kext's x86_64 slice is loaded at its link address into a Unicorn CPU emulator.
Its imports (memset, memcpy, strncpy, snprintf, IOMalloc, IOLog, ...) are served by Python
stubs and the hardware accessors kacamfpga_read_reg / kacamfpga_write_reg are hooked: reads
return the mock card's FPGA registers, and the frame-DMA trigger (reg 0x110) fills the
original's DMA buffer (this+0x100) with the mock frame of the programmed page (reg 0x04).
The mock EEPROM image is placed at _ee_prom (read_buffer + 3).

The emulated original then runs its own init_fat32 -> update_fat32 -> eeprom_* path and its
fetch_sectors -> fetch_fat_sector / fetch_directory_sector / fpga_read_dma ->
create_dng_header / abs_timecode_to_smpte / get_timecode_smpte path, and every sector it
returns is compared with libiktest.dylib (core/ + the same mock) for the same LBA.

usage: diff_x86.py <IkonoskopCardReader12.x86_64> <libiktest.dylib>
"""
import ctypes
import struct
import sys
import time

from unicorn import Uc, UcError, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE, UC_PROT_ALL
from unicorn.x86_const import (UC_X86_REG_RAX, UC_X86_REG_RCX, UC_X86_REG_RDI, UC_X86_REG_RDX,
                               UC_X86_REG_RIP, UC_X86_REG_RSI, UC_X86_REG_RSP, UC_X86_REG_R8,
                               UC_X86_REG_R9)

SECTOR = 512
FRAME_DMA_BYTES = 0x335000
FILE_LBA = 0x2c840
FILE_SPAN = 0x2000
DATA_LBA = 0xc8c0
FAT_SECTORS = 0xc880
EE_PROM = 0xe9c3                  # _ee_prom = &read_buffer[3]
IMAGE_SIZE = 0x50000              # __TEXT + __DATA incl. __common/__bss
HEAP, HEAP_SIZE = 0x10000000, 0x10000000
STACK, STACK_SIZE = 0x30000000, 0x100000
STUBS = 0x40000000
SENTINEL = 0x40100000
GUARD = 0x40100100

ARG_REGS = [UC_X86_REG_RDI, UC_X86_REG_RSI, UC_X86_REG_RDX, UC_X86_REG_RCX, UC_X86_REG_R8, UC_X86_REG_R9]


class MachO:
    def __init__(self, path):
        self.data = open(path, 'rb').read()
        d = self.data
        magic, _, _, _, ncmds, _, _, _ = struct.unpack_from('<IiiIIIII', d, 0)
        assert magic == 0xfeedfacf, 'not a 64-bit Mach-O'
        off = 32
        self.segments = []
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', d, off)
            if cmd == 0x19:   # LC_SEGMENT_64
                name = d[off + 8:off + 24].rstrip(b'\0').decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', d, off + 24)
                self.segments.append((name, vmaddr, vmsize, fileoff, filesize))
            elif cmd == 0x2:  # LC_SYMTAB
                self.symoff, self.nsyms, self.stroff, _ = struct.unpack_from('<IIII', d, off + 8)
            elif cmd == 0xb:  # LC_DYSYMTAB
                f = struct.unpack_from('<18I', d, off + 8)
                self.extreloff, self.nextrel = f[14], f[15]
            off += size
        self.symbols = []
        for i in range(self.nsyms):
            strx, ntype, sect, desc, value = struct.unpack_from('<IBBHQ', d, self.symoff + 16 * i)
            s = d[self.stroff + strx:d.index(b'\0', self.stroff + strx)].decode()
            self.symbols.append((s, ntype, sect, value))
        self.defined = {s: v for s, t, sect, v in self.symbols if sect != 0 and (t & 0xe) == 0xe}

    def ext_relocs(self):
        for i in range(self.nextrel):
            addr, info = struct.unpack_from('<iI', self.data, self.extreloff + 8 * i)
            yield addr, info & 0xffffff, (info >> 24) & 1, (info >> 25) & 3, (info >> 27) & 1, info >> 28


class Original:
    """The v1.2 kext running in Unicorn against one mock scenario."""

    def __init__(self, macho, lib, scenario):
        self.m, self.lib, self.sc = macho, lib, scenario
        uc = self.uc = Uc(UC_ARCH_X86, UC_MODE_64)
        uc.mem_map(0, IMAGE_SIZE, UC_PROT_ALL)
        for name, vmaddr, vmsize, fileoff, filesize in macho.segments:
            if filesize and name != '__LINKEDIT':
                uc.mem_write(vmaddr, macho.data[fileoff:fileoff + filesize])
        uc.mem_map(HEAP, HEAP_SIZE, UC_PROT_ALL)
        uc.mem_map(STACK, STACK_SIZE, UC_PROT_ALL)
        uc.mem_map(STUBS, 0x200000, UC_PROT_ALL)
        uc.mem_write(SENTINEL, b'\xf4')            # hlt
        uc.mem_write(GUARD, struct.pack('<Q', 0x5a5a5a5aa5a5a5a5))
        self.heap = HEAP
        self.log = []

        # Resolve imports: one `ret` stub per imported function.
        self.stub_names = {}
        stub_of = {}
        for addr, symnum, pcrel, length, ext, rtype in macho.ext_relocs():
            name = macho.symbols[symnum][0]
            if name == '___stack_chk_guard':
                target = GUARD
            elif name in macho.defined:
                target = macho.defined[name]
            else:
                if name not in stub_of:
                    stub = STUBS + 16 * len(stub_of)
                    stub_of[name] = stub
                    self.stub_names[stub] = name
                    uc.mem_write(stub, b'\xc3')
                target = stub_of[name]
            if rtype == 2 and pcrel and length == 2:        # X86_64_RELOC_BRANCH
                addend = struct.unpack('<i', uc.mem_read(addr, 4))[0]
                uc.mem_write(addr, struct.pack('<i', target + addend - (addr + 4)))
            elif rtype == 0 and length == 3:                 # X86_64_RELOC_UNSIGNED, 8 bytes
                addend = struct.unpack('<Q', uc.mem_read(addr, 8))[0]
                uc.mem_write(addr, struct.pack('<Q', (target + addend) & (2 ** 64 - 1)))
            else:
                raise RuntimeError('unhandled relocation type %d at 0x%x' % (rtype, addr))
        uc.hook_add(UC_HOOK_CODE, self._stub_hook, begin=STUBS, end=STUBS + 0x10000)

        fn = lambda n: macho.defined['__ZN31com_Ikonoskop_driver_CardReader' + n]
        self.fn_init_fat32 = fn('10init_fat32Ev')
        self.fn_fetch_sectors = fn('13fetch_sectorsEPvjj')
        self.hooks = {fn('18kacamfpga_read_regEj'): self._read_reg,
                      fn('19kacamfpga_write_regEjj'): self._write_reg}
        for a in self.hooks:
            uc.hook_add(UC_HOOK_CODE, self._fn_hook, begin=a, end=a)

        # The CardReader object, initialised as start() does before init_fat32().
        self.this = self.alloc(0x400)
        self.dma = self.alloc(FRAME_DMA_BYTES)
        self.w32(self.this + 0x16c, 0xffffffff)
        self.w32(self.this + 0x170, 0xffffffff)
        self.w32(self.this + 0x174, 0xffffffff)
        self.w32(self.this + 0x180, 1)
        self.w64(self.this + 0x100, self.dma)      # XPCIe_getBuffer()
        # this+0xc0 (DMA wait lock) and this+0xc8 (FPGA lock) stay NULL: no sleeping.
        ee = ctypes.create_string_buffer(0x2000)
        lib.ikt_eeprom(scenario, ee)
        uc.mem_write(EE_PROM, ee.raw)
        self.page = None
        self.dma_count = 0
        self.call(self.fn_init_fat32, self.this)

    # -- memory helpers
    def alloc(self, n):
        a = self.heap
        self.heap = (self.heap + n + 15) & ~15
        assert self.heap < HEAP + HEAP_SIZE, 'emulated heap exhausted'
        return a

    def w32(self, a, v):
        self.uc.mem_write(a, struct.pack('<I', v))

    def w64(self, a, v):
        self.uc.mem_write(a, struct.pack('<Q', v))

    def cstr(self, a):
        out = bytearray()
        while True:
            b = self.uc.mem_read(a, 64)
            i = b.find(b'\0')
            if i >= 0:
                return bytes(out + b[:i])
            out += b
            a += 64

    def arg(self, i):
        if i < 6:
            return self.uc.reg_read(ARG_REGS[i])
        rsp = self.uc.reg_read(UC_X86_REG_RSP)
        return struct.unpack('<Q', self.uc.mem_read(rsp + 8 * (i - 5), 8))[0]

    # -- calls
    def call(self, fn, *args):
        uc = self.uc
        rsp = STACK + STACK_SIZE - 0x1000
        rsp -= 8
        uc.mem_write(rsp, struct.pack('<Q', SENTINEL))
        uc.reg_write(UC_X86_REG_RSP, rsp)
        for r, v in zip(ARG_REGS, args):
            uc.reg_write(r, v)
        try:
            uc.emu_start(fn, SENTINEL)
        except UcError as e:
            raise RuntimeError('emulation fault at rip=0x%x: %s' % (uc.reg_read(UC_X86_REG_RIP), e))
        return uc.reg_read(UC_X86_REG_RAX)

    def fetch(self, lba, count, fill=0):
        buf = self.alloc(count * SECTOR) if count * SECTOR > 0x400000 else self._scratch(count)
        self.uc.mem_write(buf, bytes([fill]) * (count * SECTOR))
        self.call(self.fn_fetch_sectors, self.this, buf, lba, count)
        return bytes(self.uc.mem_read(buf, count * SECTOR))

    def _scratch(self, count):
        if not hasattr(self, 'scratch'):
            self.scratch = self.alloc(0x400000)
        return self.scratch

    # -- hooks
    def _return(self, value):
        uc = self.uc
        rsp = uc.reg_read(UC_X86_REG_RSP)
        ret = struct.unpack('<Q', uc.mem_read(rsp, 8))[0]
        uc.reg_write(UC_X86_REG_RAX, value & (2 ** 64 - 1))
        uc.reg_write(UC_X86_REG_RSP, rsp + 8)
        uc.reg_write(UC_X86_REG_RIP, ret)

    def _fn_hook(self, uc, address, size, _):
        self._return(self.hooks[address]())

    def _read_reg(self):
        return self.lib.ikt_reg(self.sc, self.arg(1) & 0xffffffff)

    def _write_reg(self):
        reg, val = self.arg(1) & 0xffffffff, self.arg(2) & 0xffffffff
        if reg == 0x04:
            self.page = val
        elif reg == 0x110:
            assert val == FRAME_DMA_BYTES
            frame = ctypes.create_string_buffer(FRAME_DMA_BYTES)
            self.lib.ikt_frame(self.sc, self.page, frame)
            self.uc.mem_write(self.dma, frame.raw)
            self.dma_count += 1
        return 0

    def _stub_hook(self, uc, address, size, _):
        name = self.stub_names.get(address)
        a = self.arg
        if name == '_memset':
            uc.mem_write(a(0), bytes([a(1) & 0xff]) * a(2))
            r = a(0)
        elif name == '_memcpy':
            if a(2):
                uc.mem_write(a(0), bytes(uc.mem_read(a(1), a(2))))
            r = a(0)
        elif name == '_strncpy':
            src = self.cstr(a(1))[:a(2)]
            uc.mem_write(a(0), src + b'\0' * (a(2) - len(src)))
            r = a(0)
        elif name == '_snprintf':
            s = self.format(self.cstr(a(2)), 3)
            n = a(1)
            if n:
                out = s[:n - 1] + b'\0'
                uc.mem_write(a(0), out)
            r = len(s)
        elif name == '_IOMalloc':
            r = self.alloc(a(0))
        elif name in ('_IOLog', '_printf'):
            self.log.append(self.format(self.cstr(a(0)), 1).decode(errors='replace'))
            r = 0
        elif name in ('_IOFree', '_mach_absolute_time'):
            r = 0
        elif name in ('_absolutetime_to_nanoseconds', '_nanoseconds_to_absolutetime'):
            if HEAP <= a(1) < HEAP + HEAP_SIZE or STACK <= a(1) < STACK + STACK_SIZE:
                self.w64(a(1), 0)
            r = 0
        else:
            raise RuntimeError('unexpected call to import %s' % name)
        self._return(r)

    def format(self, fmt, first):
        out, i, argi = bytearray(), 0, first
        while i < len(fmt):
            c = fmt[i]
            if c != 0x25:
                out.append(c)
                i += 1
                continue
            j = i + 1
            while fmt[j:j + 1] in (b'0', b'-', b' ', b'+', b'#'):
                j += 1
            k = j
            while fmt[k:k + 1].isdigit():
                k += 1
            width = int(fmt[j:k]) if k > j else 0
            zero = b'0' in fmt[i + 1:j]
            while fmt[k:k + 1] in (b'l', b'h', b'q', b'z'):
                k += 1
            conv = chr(fmt[k])
            i = k + 1
            if conv == '%':
                out += b'%'
                continue
            v = self.arg(argi)
            argi += 1
            if conv in 'di':
                v &= 0xffffffff
                s = str(v - (1 << 32) if v >> 31 else v)
            elif conv == 'u':
                s = str(v & 0xffffffff) if 'l' not in fmt[j:k].decode() else str(v)
            elif conv in 'xX':
                s = '%x' % v
            elif conv == 'p':
                s = '0x%x' % v
            elif conv == 's':
                s = self.cstr(v).decode(errors='replace')
            elif conv == 'c':
                s = chr(v & 0xff)
            else:
                raise RuntimeError('unsupported format %%%s' % conv)
            out += s.rjust(width, '0' if zero and conv not in 's' else ' ').encode()
        return bytes(out)


class Port:
    def __init__(self, lib, scenario):
        self.lib = lib
        self.h = lib.ikt_open(scenario)
        assert self.h, 'ikt_open failed'

    def fetch(self, lba, count):
        buf = ctypes.create_string_buffer(count * SECTOR)
        assert self.lib.ikt_read(self.h, lba, count, buf) == 0, 'ik::VirtualCard::readSectors failed'
        return buf.raw


failures = 0


def compare(what, orig, port, allowed=None):
    """allowed: optional callable(orig_bytes) -> expected port bytes (documented deviation)."""
    global failures
    expect = allowed(orig) if allowed else orig
    if expect == port:
        return True
    failures += 1
    i = next(k for k in range(len(port)) if expect[k] != port[k])
    print('  MISMATCH %s at byte 0x%x (sector +%d): original %s, port %s' % (
        what, i, i // SECTOR, expect[i:i + 16].hex(), port[i:i + 16].hex()))
    return False


def u32s(b):
    return struct.unpack('<%dI' % (len(b) // 4), b)


def main():
    macho = MachO(sys.argv[1])
    lib = ctypes.CDLL(sys.argv[2])
    lib.ikt_open.restype = ctypes.c_void_p
    lib.ikt_open.argtypes = [ctypes.c_int]
    lib.ikt_read.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_uint, ctypes.c_char_p]
    lib.ikt_sector_count.restype = ctypes.c_ulonglong
    lib.ikt_sector_count.argtypes = [ctypes.c_void_p]
    lib.ikt_reg.restype = ctypes.c_uint
    lib.ikt_frame_count.restype = ctypes.c_uint

    # ---------------- scenario 0: the main mock card --------------------------------------
    t0 = time.time()
    orig, port = Original(macho, lib, 0), Port(lib, 0)
    frames = lib.ikt_frame_count(0)
    print('scenario 0: original init_fat32 done (%d log lines, e.g. %r)' % (
        len(orig.log), [l.strip() for l in orig.log if 'frames' in l or 'ERROR' in l][:3]))

    # Boot area: boot sector at 0/6, FSInfo at 1/7, zeros. FSInfo free count (0x1e8) is a
    # documented deviation: the original stores 0, the port the real free cluster count.
    o, p = orig.fetch(0, 0x40), port.fetch(0, 0x40)

    def fsinfo_free(b):
        b = bytearray(b)
        for s in (1, 7):
            b[s * SECTOR + 0x1e8:s * SECTOR + 0x1ec] = p[s * SECTOR + 0x1e8:s * SECTOR + 0x1ec]
        return bytes(b)
    ok = compare('boot area LBA 0..0x3f', o, p, fsinfo_free)
    free = struct.unpack_from('<I', p, SECTOR + 0x1e8)[0]
    print('boot area (BPB, FSInfo, backups): %s; FSInfo free count original %d, port %d' % (
        'identical' if ok else 'DIFFERENT', struct.unpack_from('<I', o, SECTOR + 0x1e8)[0], free))

    # FAT: the 16 sectors of directory chains must be identical; the per-file chains are the
    # documented deviation (original: 128-cluster chain in every FAT sector; port: 103-cluster
    # chain for listed files only, everything else free).
    o, p = orig.fetch(0x40, FAT_SECTORS), port.fetch(0x40, FAT_SECTORS)
    ok = compare('FAT sectors 0..15', o[:16 * SECTOR], p[:16 * SECTOR])
    bad_orig = bad_port = 0
    for fs in range(16, FAT_SECTORS):
        oe, pe = u32s(o[fs * SECTOR:(fs + 1) * SECTOR]), u32s(p[fs * SECTOR:(fs + 1) * SECTOR])
        if oe != tuple(fs * 128 + i + 1 for i in range(127)) + (0x0ffffff8,):
            bad_orig += 1
        f = fs - 16
        want = (tuple(fs * 128 + i + 1 for i in range(102)) + (0x0ffffff8,) + (0,) * 25) if f < frames \
            else (0,) * 128
        if pe != want or (f < frames and oe[:102] != pe[:102]):
            bad_port += 1
    global failures
    failures += bad_orig + bad_port
    print('FAT: directory-chain sectors %s; file-chain sectors: original pattern mismatches %d, '
          'port model mismatches %d (first 102 links equal to the original for all %d files)' % (
              'identical' if ok else 'DIFFERENT', bad_orig, bad_port, frames))

    # Directory clusters 2..0x7ff (root, CLIP..PROXY, IMAGE, take directories, unused).
    o, p = orig.fetch(DATA_LBA, FILE_LBA - DATA_LBA), port.fetch(DATA_LBA, FILE_LBA - DATA_LBA)
    ok = compare('directory region', o, p)
    print('directory region (0x%x sectors, clusters 2..0x7ff): %s' % (
        FILE_LBA - DATA_LBA, 'identical' if ok else 'DIFFERENT'))

    # DNG headers of every frame (create_dng_header + timecodes), 8-sector reads.
    bad = 0
    for f in range(frames):
        lba = FILE_LBA + f * FILE_SPAN
        if not compare('header of frame %d' % f, orig.fetch(lba, 8), port.fetch(lba, 8)):
            bad += 1
    # nsect < 8 path, sif = 0, n = 1. The original copies straight from its static template,
    # so for the 0x182-byte monochrome template the rest of the sector is whatever follows it
    # in __DATA (0x1e zero bytes, then the tungsten template); the port returns the zero-padded
    # header, i.e. the same bytes an 8-sector read returns.
    bw_tail = bytes(orig.uc.mem_read(0xe040 + 0x182, SECTOR - 0x182))
    mono_reads = 0
    for f in range(frames):
        lba = FILE_LBA + f * FILE_SPAN
        o, p = orig.fetch(lba, 1), port.fetch(lba, 1)
        mono = o[:4] == b'II*\x00' and o[0x182:] == bw_tail
        mono_reads += mono
        pad = (lambda b: b[:0x182] + bytes(SECTOR - 0x182)) if mono else None
        if not compare('1-sector header read frame %d' % f, o, p, pad):
            bad += 1
    print('DNG headers: %d frames x (8-sector + 1-sector reads): %s; %d monochrome 1-sector reads where '
          'the original returns adjacent __DATA after byte 0x182 (port: zero padding)' % (
              frames, 'identical' if not bad else '%d DIFFERENT' % bad, mono_reads))

    # Raw payload: whole-file reads, raw-only reads, mid-file reads and msdosfs-style
    # cluster-by-cluster reads (exercises the frame cache, this+0x16c) for a frame of every
    # take, including the corrupt take (page 0) and the last frame.
    picks = sorted({0, 2, 3, 500, 1032, 1033, 1034, frames - 1})
    bad = 0
    for f in picks:
        lba = FILE_LBA + f * FILE_SPAN
        cases = [(lba, FILE_SPAN), (lba + 8, 0x19a8), (lba + 100, 64), (lba + 0x19a8, 8),
                 (lba + 0x19a0, 0x660)]
        for l, n in cases:
            if not compare('frame %d lba+%d n=%d' % (f, l - lba, n), orig.fetch(l, n), port.fetch(l, n)):
                bad += 1
        o = b''.join(orig.fetch(lba + c, 64) for c in range(0, FILE_SPAN, 64))
        p = b''.join(port.fetch(lba + c, 64) for c in range(0, FILE_SPAN, 64))
        if not compare('frame %d cluster-wise' % f, o, p):
            bad += 1
    print('raw payload: frames %s, 6 request shapes each: %s (original issued %d frame DMAs)' % (
        picks, 'identical' if not bad else '%d DIFFERENT' % bad, orig.dma_count))

    # Documented deviation: the original's 0x19a8 clamp zeroes from dst + n_valid *bytes*
    # instead of sectors, leaving part of the tail of the caller's buffer untouched.
    lba = FILE_LBA + 8 + 0x1900
    o = orig.fetch(lba, 0x200, fill=0xaa)
    p = port.fetch(lba, 0x200)
    stale = sum(1 for k in range(0xa8 * SECTOR, len(o)) if o[k] == 0xaa)
    print('clamp-path deviation (buffer pre-filled 0xaa): original leaves %d stale bytes past the '
          'raw data, port zero-fills (raw bytes equal: %s)' % (stale, o[:0xa8 * SECTOR] == p[:0xa8 * SECTOR]))
    print('scenario 0 done in %.1fs' % (time.time() - t0))

    # ---------------- scenario 1: monochrome 25 fps take, then tungsten take --------------
    orig, port = Original(macho, lib, 1), Port(lib, 1)
    bw = FILE_LBA
    tungsten = FILE_LBA + 2 * FILE_SPAN
    o_bw, p_bw = orig.fetch(bw, 8), port.fetch(bw, 8)
    ok_bw = compare('monochrome 25 fps header', o_bw, p_bw)
    o_t, p_t = orig.fetch(tungsten, 8), port.fetch(tungsten, 8)
    diff = [k for k in range(len(o_t)) if o_t[k] != p_t[k]]
    ok_t = (bool(diff) and all(0xbe <= k < 0xc2 for k in diff) and o_t[0xbe:0xc2] == b'\x01\x00\x00\x00'
            and p_t[0xbe:0xc2] == b'\x12\xc6\x01\x00')
    if not (ok_bw and ok_t):
        failures += 1
    print('scenario 1: monochrome header identical: %s; tungsten header after it differs only at '
          '0x%x..0x%x where the original has %s (its stray FrameRate denominator write over the '
          'DNGVersion IFD entry; port keeps %s): %s' % (
              ok_bw, 0xbe, 0xc1, o_t[0xbe:0xc2].hex(), p_t[0xbe:0xc2].hex(), 'as expected' if ok_t else
              'UNEXPECTED diff at %s' % [hex(k) for k in diff[:8]]))

    print('differential test: %s' % ('PASS' if failures == 0 else 'FAIL (%d)' % failures))
    return 0 if failures == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
