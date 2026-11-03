"""DNG colour maths shared by the renderer and the step-7 exporter (numpy only).

Plain-language summary: a DNG camera profile stores two colour matrices, each measured under
one light (for example tungsten and daylight). For any other light a raw converter blends the
two, depending on the colour temperature of the scene's white. This module does that blend the
way Adobe's DNG specification describes it, and turns the result into the matrix that converts
white-balanced camera colours to standard XYZ colour (D50 white), and from there to ACES.
"""
import numpy as np

import build_profile as bp

# Chromaticities used by the DNG SDK (dng_xy constants) and by ACES.
XY = {
    "A": (0.4476, 0.4074),
    "D50": (0.3457, 0.3585),
    "D55": (0.3324, 0.3474),
    "D65": (0.3127, 0.3290),
    "ACES": (0.32168, 0.33767),  # ACES white, "D60"
}


def xy_to_xyz(xy):
    x, y = xy
    return np.array([x / y, 1.0, (1 - x - y) / y])


D50_DNG = xy_to_xyz(XY["D50"])  # DNG profile connection space white
ACES_WHITE = xy_to_xyz(XY["ACES"])
# ACES2065-1 (AP0) primaries, SMPTE ST 2065-1
AP0_PRIMARIES = {"r": (0.7347, 0.2653), "g": (0.0, 1.0), "b": (0.0001, -0.0770)}


def rgb_to_xyz_matrix(primaries, white_xy):
    p = np.column_stack([xy_to_xyz(primaries[c]) for c in "rgb"])
    return p * np.linalg.solve(p, xy_to_xyz(white_xy))


AP0_TO_XYZ = rgb_to_xyz_matrix(AP0_PRIMARIES, XY["ACES"])
XYZ_TO_AP0 = np.linalg.inv(AP0_TO_XYZ)


class Planck:
    """CIE 1960 uv of the Planckian locus, for converting XYZ to correlated colour temperature."""

    def __init__(self):
        self.cmf = bp.load_csv("cie1931_2deg_cmf.csv")[1]
        self.mireds = np.arange(20.0, 700.0, 0.5)  # 50,000 K .. 1,430 K
        self.uv = np.array([self.xyz_to_uv(self.spectrum(1e6 / m) @ self.cmf) for m in self.mireds])

    @staticmethod
    def spectrum(temperature):
        lam = bp.WL * 1e-9
        return 1.0 / (lam ** 5 * (np.exp(1.4388e-2 / (lam * temperature)) - 1.0))

    def white_xyz(self, temperature):
        """XYZ (Y = 1) of a black body at `temperature` K."""
        xyz = self.spectrum(temperature) @ self.cmf
        return xyz / xyz[1]

    @staticmethod
    def xyz_to_uv(xyz):
        d = xyz[0] + 15 * xyz[1] + 3 * xyz[2]
        return np.array([4 * xyz[0] / d, 6 * xyz[1] / d])

    def cct(self, xyz):
        """Temperature of the closest Planckian point in uv (the definition of CCT)."""
        d = np.sum((self.uv - self.xyz_to_uv(xyz)) ** 2, axis=1)
        i = int(np.clip(np.argmin(d), 1, len(d) - 2))
        # parabola through the three nearest samples (0.5 mired apart)
        y0, y1, y2 = d[i - 1], d[i], d[i + 1]
        denom = y0 - 2 * y1 + y2
        offset = 0.5 * (y0 - y2) / denom if denom > 0 else 0.0
        return 1e6 / (self.mireds[i] + offset * 0.5)


_PLANCK = None


def planck():
    global _PLANCK
    _PLANCK = _PLANCK or Planck()
    return _PLANCK


def interpolation_weight(temperature, t1, t2):
    """DNG: weight of matrix 1, linear in inverse temperature, clamped outside [t1, t2]."""
    g = (1.0 / temperature - 1.0 / t2) / (1.0 / t1 - 1.0 / t2)
    return float(np.clip(g, 0.0, 1.0))


class Profile:
    """Two ColorMatrices (XYZ -> camera) and optional ForwardMatrices, with EXIF illuminant codes."""

    def __init__(self, label, cm1, cm2, illum1, illum2, fm1=None, fm2=None):
        self.label = label
        self.cm = (np.asarray(cm1, float).reshape(3, 3), np.asarray(cm2, float).reshape(3, 3))
        self.fm = None if fm1 is None else (np.asarray(fm1, float).reshape(3, 3),
                                            np.asarray(fm2, float).reshape(3, 3))
        self.illuminants = (illum1, illum2)
        self.temps = (bp.EXIF_TEMPERATURE[illum1], bp.EXIF_TEMPERATURE[illum2])

    @classmethod
    def from_dcp(cls, path, label):
        t = bp.read_dcp(path)
        fm = (t[0xC714], t[0xC715]) if 0xC714 in t and 0xC715 in t else (None, None)
        return cls(label, t[0xC621], t[0xC622], t[0xC65A][0], t[0xC65B][0], *fm)

    def blend(self, white_xyz):
        """(temperature, weight of matrix 1, ColorMatrix, ForwardMatrix or None) for a white."""
        temperature = planck().cct(white_xyz)
        g = interpolation_weight(temperature, *self.temps)
        cm = g * self.cm[0] + (1 - g) * self.cm[1]
        fm = None if self.fm is None else g * self.fm[0] + (1 - g) * self.fm[1]
        return temperature, g, cm, fm

    def balanced_to_xyz_d50(self, white_xyz):
        """Matrix from white-balanced camera RGB (camera / neutral) to XYZ with D50 white.

        Returns (matrix, camera neutral, temperature, weight). Balanced (1, 1, 1) maps exactly to
        the D50 white, as in the DNG SDK: ForwardMatrix rows are rescaled so FM x (1,1,1) = D50;
        without ForwardMatrix, camera -> XYZ is the inverse ColorMatrix followed by Bradford
        adaptation from the scene white to D50."""
        white_xyz = np.asarray(white_xyz, float) / white_xyz[1]
        temperature, g, cm, fm = self.blend(white_xyz)
        neutral = cm @ white_xyz
        neutral = neutral / neutral.max()
        if fm is not None:
            m = np.diag(D50_DNG / (fm @ np.ones(3))) @ fm
        else:
            cam_to_xyz = np.linalg.inv(cm)
            m = bp.bradford(white_xyz, D50_DNG) @ cam_to_xyz @ np.diag(neutral)
            m = m / (m @ np.ones(3))[1]
        return m, neutral, temperature, g

    def camera_to_xyz_d50(self, neutral):
        """DNG camera (not balanced) -> XYZ(D50) matrix for a given camera neutral, finding the
        white by the DNG SDK's iteration neutral -> xy -> temperature. Returns (matrix, CCT, weight)."""
        xyz = D50_DNG.copy()
        for _ in range(50):
            _, _, cm, _ = self.blend(xyz)
            new = np.linalg.solve(cm, neutral)
            new = new / new[1]
            done = np.max(np.abs(new - xyz)) < 1e-9
            xyz = new
            if done:
                break
        m, _, temperature, g = self.balanced_to_xyz_d50(xyz)
        return m @ np.diag(1.0 / neutral), temperature, g


def balanced_to_aces(profile, white_xyz):
    """White-balanced camera RGB -> ACES2065-1 (AP0): XYZ D50 -> Bradford -> ACES white -> AP0."""
    m, neutral, temperature, g = profile.balanced_to_xyz_d50(white_xyz)
    return XYZ_TO_AP0 @ bp.bradford(D50_DNG, ACES_WHITE) @ m, neutral, temperature, g
