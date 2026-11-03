"""Read A-Cam dII DNG frames (numpy only).

The camera writes uncompressed CinemaDNG: a 4 KiB little-endian TIFF header, then one strip
of 12-bit packed CFA data (GRBG, most significant bits first), then an 8 KiB private block.
This module reads the header tags it needs and turns the strip into linear camera RGB.
"""
import struct

import numpy as np

TAG_CFA_PATTERN = 0x828E
TAG_BLACK_LEVEL = 0xC61A
TAG_WHITE_LEVEL = 0xC61D
TAG_COLOR_MATRIX1 = 0xC621
TAG_COLOR_MATRIX2 = 0xC622
TAG_AS_SHOT_NEUTRAL = 0xC628
TAG_CALIBRATION_ILLUMINANT1 = 0xC65A
TAG_CALIBRATION_ILLUMINANT2 = 0xC65B
TAG_STRIP_OFFSETS = 0x0111
TAG_STRIP_BYTE_COUNTS = 0x0117
TAG_IMAGE_WIDTH = 0x0100
TAG_IMAGE_LENGTH = 0x0101
TAG_BITS_PER_SAMPLE = 0x0102
TAG_COMPRESSION = 0x0103

_TYPES = {1: ("B", 1), 2: ("s", 1), 3: ("H", 2), 4: ("I", 4), 5: ("I", 8), 7: ("B", 1),
          8: ("h", 2), 9: ("i", 4), 10: ("i", 8), 11: ("f", 4), 12: ("d", 8)}


def read_ifd(buf, ifd_offset, endian="<"):
    """Return {tag: value} for one IFD. Rationals become floats; ASCII becomes str.

    Values stored outside `buf` are skipped. The first entry wins when a tag repeats (the
    camera writes WhiteLevel twice)."""
    count = struct.unpack_from(endian + "H", buf, ifd_offset)[0]
    tags = {}
    for i in range(count):
        entry = ifd_offset + 2 + 12 * i
        tag, typ, n, value = struct.unpack_from(endian + "HHII", buf, entry)
        if tag == 0 or typ not in _TYPES or tag in tags:
            continue
        fmt, size = _TYPES[typ]
        total = size * n
        start = entry + 8 if total <= 4 else value
        if start + total > len(buf):
            continue
        data = buf[start:start + total]
        if typ == 2:
            tags[tag] = data.split(b"\0")[0].decode("latin-1")
        elif typ in (5, 10):
            raw = struct.unpack(endian + fmt * (2 * n), data)
            tags[tag] = [raw[2 * k] / raw[2 * k + 1] for k in range(n)]
        else:
            tags[tag] = list(struct.unpack(endian + fmt * n, data))
    return tags


def read_header(path):
    with open(path, "rb") as f:
        head = f.read(0x1000)
    if head[:4] != b"II*\x00":
        raise ValueError(f"{path}: not a little-endian TIFF/DNG")
    return read_ifd(head, struct.unpack_from("<I", head, 4)[0])


class Frame:
    """One frame: header tags plus the raw CFA mosaic (uint16, 1092 x 2048)."""

    def __init__(self, path):
        self.path = path
        self.tags = read_header(path)
        t = self.tags
        if t.get(TAG_COMPRESSION, [1])[0] != 1 or t.get(TAG_BITS_PER_SAMPLE, [12])[0] != 12:
            raise ValueError(f"{path}: expected uncompressed 12-bit data")
        self.width = t[TAG_IMAGE_WIDTH][0]
        self.height = t[TAG_IMAGE_LENGTH][0]
        offset = t[TAG_STRIP_OFFSETS][0]
        nbytes = t[TAG_STRIP_BYTE_COUNTS][0]
        with open(path, "rb") as f:
            f.seek(offset)
            packed = np.frombuffer(f.read(nbytes), dtype=np.uint8)
        b = packed.reshape(-1, 3).astype(np.uint16)
        pix = np.empty((b.shape[0], 2), dtype=np.uint16)
        pix[:, 0] = (b[:, 0] << 4) | (b[:, 1] >> 4)        # MSB-first packing
        pix[:, 1] = ((b[:, 1] & 0x0F) << 8) | b[:, 2]
        self.cfa = pix.reshape(self.height, self.width)

    @property
    def black_levels(self):
        return np.array(self.tags[TAG_BLACK_LEVEL], dtype=np.float64).reshape(2, 2)

    @property
    def white_level(self):
        return float(self.tags[TAG_WHITE_LEVEL][0])

    @property
    def cfa_pattern(self):
        """2x2 array of colour indices (0=R, 1=G, 2=B) by (row, column) parity."""
        return np.array(self.tags[TAG_CFA_PATTERN], dtype=int).reshape(2, 2)

    @property
    def as_shot_neutral(self):
        return np.array(self.tags[TAG_AS_SHOT_NEUTRAL], dtype=np.float64)

    def matrix(self, tag):
        return np.array(self.tags[tag], dtype=np.float64).reshape(3, 3)

    def camera_rgb_half(self):
        """Linear camera RGB at half resolution (each 2x2 CFA cell becomes one pixel).

        Black is subtracted per CFA position and the result scaled so that the white level
        maps to 1.0; the two greens are averaged. No white balance is applied."""
        cfa = self.cfa.astype(np.float64)
        h, w = cfa.shape
        out = np.zeros((h // 2, w // 2, 3))
        count = np.zeros(3)
        pattern = self.cfa_pattern
        bl = self.black_levels
        for r in range(2):
            for c in range(2):
                ch = pattern[r, c]
                plane = (cfa[r::2, c::2] - bl[r, c]) / (self.white_level - bl[r, c])
                out[:, :, ch] += plane
                count[ch] += 1
        return out / count
