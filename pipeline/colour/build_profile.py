#!/usr/bin/env python3
"""Build a dual-illuminant DNG camera profile (DCP) for the Ikonoskop A-Cam dII from sensor data.

Plain-language summary: we know how strongly the camera's sensor (Kodak KAI-02150, colour
version) responds to each wavelength of light, from its datasheet. We simulate photographing
123 standard real-world colours (a ColorChecker chart plus the CIE's 99 colour-evaluation
samples) under tungsten light (Standard A) and daylight (D65), compare what the simulated camera
records with what a human observer sees, and find the 3x3 colour matrices that translate one
into the other with the smallest colour error. The matrices are written as an Adobe DNG Camera
Profile (.dcp) and as JSON. Things we cannot know (the camera's infrared-cut filter) are modelled
with typical values; see --ir-cutoff.

This script is the open-source equivalent of `dcamprof make-dcp` for this one camera. It uses
numpy only.

Writes profiles/<id>/<id>.dcp and profiles/<id>/fit.json (matrices + fit errors);
export_candidates.py turns the DCP into the step-7 files (profile.json, IDTs, OCIO config).

Usage: build_profile.py [--ir-cutoff NM] [--ir-slope NM] [--out-dir DIR] [--id NAME]
"""
import argparse
import json
import os
import struct

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
WL = np.arange(380, 781, 5, dtype=np.float64)

# EXIF LightSource codes and the colour temperatures the DNG SDK assigns to them.
ILLUMINANT_CODES = {"A": 17, "D65": 21}
EXIF_TEMPERATURE = {17: 2850.0, 20: 5500.0, 21: 6500.0, 23: 5000.0, 24: 3200.0}
D50_PCS = np.array([0.9642, 1.0, 0.8249])  # DNG / ICC profile connection space white

BRADFORD = np.array([[0.8951, 0.2664, -0.1614],
                     [-0.7502, 1.7135, 0.0367],
                     [0.0389, -0.0685, 1.0296]])

CAMERA_MODEL = "Ikonoskop A-CAM"


# ----------------------------------------------------------------------------- data

def load_csv(name):
    """Return (wavelengths, matrix[n_wavelengths, n_columns], column names)."""
    path = os.path.join(DATA, name)
    with open(path) as f:
        header = f.readline().strip().split(",")
    raw = np.loadtxt(path, delimiter=",", skiprows=1, ndmin=2)
    return raw[:, 0], raw[:, 1:], header[1:]


def on_grid(wl, values):
    """Linear interpolation onto WL; flat extension outside the measured range."""
    return np.column_stack([np.interp(WL, wl, values[:, i]) for i in range(values.shape[1])])


def reference_data():
    _, cmf, _ = load_csv("cie1931_2deg_cmf.csv")
    _, ill, names = load_csv("cie_illuminants.csv")
    illuminants = {n: ill[:, i] for i, n in enumerate(names)}
    sets = {}
    for key, name in (("CC24", "colorchecker24_iso17321.csv"), ("CES99", "cie224_2017_ces99.csv"),
                      ("PMC30", "pmc30_luo2024.csv")):
        wl, refl, patch_names = load_csv(name)
        sets[key] = (on_grid(wl, refl), patch_names)
    return cmf, illuminants, sets


# ----------------------------------------------------------------------------- camera model

def ir_cut(cutoff, slope, passband=0.95):
    """Typical camera IR-cut filter: flat `passband` transmission, logistic edge with 50 % of the
    pass level at `cutoff` nm; `slope` nm sets the edge width (10 %-90 % width = 4.39 x slope)."""
    return passband / (1.0 + np.exp((WL - cutoff) / slope))


def camera_sensitivity(cutoff, slope):
    """Camera RGB response per unit spectral *power* at each wavelength.

    QE counts electrons per photon; a light of spectral power P(lambda) delivers
    P * lambda / (h c) photons, so the power response is QE x lambda (constant dropped).
    The optical low-pass filter, lens and cover glass are taken as spectrally neutral."""
    wl, qe, _ = load_csv("kai02150_qe.csv")
    s = on_grid(wl, qe) * ir_cut(cutoff, slope)[:, None] * WL[:, None]
    return s / s[:, 1].max()


# ----------------------------------------------------------------------------- colour maths

def tristimulus(refl, illuminant, cmf):
    """XYZ of reflectances (rows = wavelengths, columns = patches) under an illuminant, Y(white)=1."""
    k = 1.0 / np.dot(illuminant, cmf[:, 1])
    return k * (refl * illuminant[:, None]).T @ cmf


def white_xyz(illuminant, cmf):
    return np.dot(illuminant, cmf) / np.dot(illuminant, cmf[:, 1])


def camera_rgb(refl, illuminant, sens):
    return (refl * illuminant[:, None]).T @ sens


def bradford(src_white, dst_white):
    """Linear Bradford chromatic adaptation matrix (as used by the DNG SDK)."""
    s = BRADFORD @ src_white
    d = BRADFORD @ dst_white
    return np.linalg.inv(BRADFORD) @ np.diag(d / s) @ BRADFORD


def xyz_to_lab(xyz, white):
    r = xyz / white
    e = 216 / 24389
    k = 24389 / 27
    f = np.where(r > e, np.cbrt(np.maximum(r, e)), (k * r + 16) / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def delta_e2000(lab1, lab2):
    """CIEDE2000 colour difference (Sharma, Wu & Dalal 2005), vectorised."""
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    c_bar = (np.hypot(a1, b1) + np.hypot(a2, b2)) / 2
    g = 0.5 * (1 - np.sqrt(c_bar ** 7 / (c_bar ** 7 + 25.0 ** 7)))
    a1p, a2p = (1 + g) * a1, (1 + g) * a2
    c1p, c2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360
    dLp = L2 - L1
    dCp = c2p - c1p
    dh = h2p - h1p
    dh = np.where(dh > 180, dh - 360, np.where(dh < -180, dh + 360, dh))
    dh = np.where(c1p * c2p == 0, 0, dh)
    dHp = 2 * np.sqrt(c1p * c2p) * np.sin(np.radians(dh / 2))
    Lp_bar = (L1 + L2) / 2
    Cp_bar = (c1p + c2p) / 2
    hsum = h1p + h2p
    hp_bar = np.where(np.abs(h1p - h2p) <= 180, hsum / 2, np.where(hsum < 360, (hsum + 360) / 2, (hsum - 360) / 2))
    hp_bar = np.where(c1p * c2p == 0, hsum, hp_bar)
    t = (1 - 0.17 * np.cos(np.radians(hp_bar - 30)) + 0.24 * np.cos(np.radians(2 * hp_bar))
         + 0.32 * np.cos(np.radians(3 * hp_bar + 6)) - 0.20 * np.cos(np.radians(4 * hp_bar - 63)))
    d_theta = 30 * np.exp(-(((hp_bar - 275) / 25) ** 2))
    rc = 2 * np.sqrt(Cp_bar ** 7 / (Cp_bar ** 7 + 25.0 ** 7))
    sl = 1 + 0.015 * (Lp_bar - 50) ** 2 / np.sqrt(20 + (Lp_bar - 50) ** 2)
    sc = 1 + 0.045 * Cp_bar
    sh = 1 + 0.015 * Cp_bar * t
    rt = -np.sin(np.radians(2 * d_theta)) * rc
    return np.sqrt((dLp / sl) ** 2 + (dCp / sc) ** 2 + (dHp / sh) ** 2 + rt * (dCp / sc) * (dHp / sh))


# ----------------------------------------------------------------------------- fitting

def constrained_matrix(params, src_white, dst_white):
    """3x3 matrix from 6 free entries; the third column is solved so that M @ src_white == dst_white."""
    m = np.zeros((3, 3))
    m[:, :2] = params.reshape(3, 2)
    m[:, 2] = (dst_white - m[:, :2] @ src_white[:2]) / src_white[2]
    return m


def fit_matrix(src, dst_xyz, src_white, dst_white):
    """Find M (camera -> XYZ) with M @ src_white == dst_white, minimising the sum of squared
    CIEDE2000 errors between M @ src and dst_xyz (Lab relative to dst_white).

    Start: constrained linear least squares in XYZ. Then Levenberg-Marquardt on the six free
    entries with a numerical Jacobian."""
    target_lab = xyz_to_lab(dst_xyz, dst_white)

    def residuals(p):
        return delta_e2000(xyz_to_lab(src @ constrained_matrix(p, src_white, dst_white).T, dst_white), target_lab)

    # linear start: rows independent; substitute the constraint into least squares
    p0 = []
    for r in range(3):
        a = src[:, :2] - np.outer(src[:, 2], src_white[:2] / src_white[2])
        b = dst_xyz[:, r] - src[:, 2] * dst_white[r] / src_white[2]
        p0.extend(np.linalg.lstsq(a, b, rcond=None)[0])
    p = np.array(p0)
    lam = 1e-3
    cost = np.sum(residuals(p) ** 2)
    for _ in range(200):
        r = residuals(p)
        jac = np.empty((r.size, p.size))
        for j in range(p.size):
            dp = np.zeros_like(p)
            dp[j] = 1e-6
            jac[:, j] = (residuals(p + dp) - r) / 1e-6
        jtj = jac.T @ jac
        grad = jac.T @ r
        improved = False
        while lam < 1e10:
            step = np.linalg.solve(jtj + lam * np.diag(np.diag(jtj)), -grad)
            new_cost = np.sum(residuals(p + step) ** 2)
            if new_cost < cost:
                p, lam, improved = p + step, lam / 3, True
                break
            lam *= 4
        if not improved or cost - new_cost < 1e-10 * cost:
            cost = min(cost, new_cost)
            break
        cost = new_cost
    return constrained_matrix(p, src_white, dst_white)


def normalise_color_matrix(cm, white):
    """DNG convention: scale so that the illuminant white (Y = 1) maps to a camera neutral whose
    largest component is 1."""
    return cm / np.max(cm @ white)


def errors(m, src, dst_xyz, white):
    de = delta_e2000(xyz_to_lab(src @ m.T, white), xyz_to_lab(dst_xyz, white))
    return {"mean": float(de.mean()), "median": float(np.median(de)), "p90": float(np.percentile(de, 90)),
            "max": float(de.max()), "per_patch": [round(float(v), 3) for v in de]}


def build(cutoff, slope, fit_sets=("CC24", "CES99")):
    cmf, illuminants, sets = reference_data()
    sens = camera_sensitivity(cutoff, slope)
    result = {"ir_cutoff_nm": cutoff, "ir_slope_nm": slope, "fit_sets": list(fit_sets), "illuminants": {}}
    for name in ("A", "D65"):
        ill = illuminants[name]
        w_xyz = white_xyz(ill, cmf)
        cam_white = ill @ sens
        cam_white = cam_white / cam_white[1]
        to_d50 = bradford(w_xyz, D50_PCS)

        def prepare(key):
            refl = sets[key][0]
            cam = camera_rgb(refl, ill, sens)
            cam = cam / (ill @ sens)[1]
            return cam, tristimulus(refl, ill, cmf)

        fit_cam, fit_xyz = (np.vstack(a) for a in zip(*(prepare(k) for k in fit_sets)))
        # ColorMatrix: camera -> XYZ under the illuminant itself, inverted to XYZ -> camera
        cam_to_xyz = fit_matrix(fit_cam, fit_xyz, cam_white, w_xyz)
        color_matrix = normalise_color_matrix(np.linalg.inv(cam_to_xyz), w_xyz)
        # ForwardMatrix: white-balanced camera -> XYZ adapted to D50
        forward = fit_matrix(fit_cam / cam_white, fit_xyz @ to_d50.T, np.ones(3), D50_PCS)
        entry = {
            "exif_code": ILLUMINANT_CODES[name],
            "white_xyz": w_xyz.tolist(),
            "camera_neutral": (cam_white / cam_white.max()).tolist(),
            "color_matrix": color_matrix.tolist(),
            "forward_matrix": forward.tolist(),
            "errors_forward_matrix_d50": {},
            "errors_color_matrix": {},
        }
        for key in sets:
            cam, xyz = prepare(key)
            entry["errors_forward_matrix_d50"][key] = errors(forward, cam / cam_white, xyz @ to_d50.T, D50_PCS)
            entry["errors_color_matrix"][key] = errors(cam_to_xyz, cam, xyz, w_xyz)
            entry["errors_forward_matrix_d50"][key]["patches"] = sets[key][1]
        result["illuminants"][name] = entry
    return result


# ----------------------------------------------------------------------------- DCP writer

def srational(values, denominator=10000):
    return [(int(round(v * denominator)), denominator) for v in values]


def write_dcp(path, profile_name, cm1, cm2, illum1, illum2, fm1=None, fm2=None, embed_policy=0,
              copyright_text=""):
    """Write an Adobe DNG Camera Profile: a little-endian TIFF-like file with magic 'IIRC'.

    cm1/cm2 (and optional fm1/fm2) are 3x3 matrices for EXIF illuminant codes illum1/illum2."""
    entries = [  # (tag, type, values); types: 2 ASCII, 3 SHORT, 4 LONG, 10 SRATIONAL
        (0xC614, 2, CAMERA_MODEL),                                   # UniqueCameraModel
        (0xC621, 10, srational(np.ravel(cm1))),                      # ColorMatrix1
        (0xC622, 10, srational(np.ravel(cm2))),                      # ColorMatrix2
        (0xC65A, 3, [illum1]),                                       # CalibrationIlluminant1
        (0xC65B, 3, [illum2]),                                       # CalibrationIlluminant2
        (0xC6F8, 2, profile_name),                                   # ProfileName
        (0xC6FD, 4, [embed_policy]),                                 # ProfileEmbedPolicy
        (0xC6FE, 2, copyright_text),                                 # ProfileCopyright
    ]
    if fm1 is not None and fm2 is not None:
        entries += [(0xC714, 10, srational(np.ravel(fm1))),          # ForwardMatrix1
                    (0xC715, 10, srational(np.ravel(fm2)))]          # ForwardMatrix2
    entries = [e for e in entries if not (e[1] == 2 and e[2] == "")]
    entries.sort(key=lambda e: e[0])
    ifd_offset = 8
    data_offset = ifd_offset + 2 + 12 * len(entries) + 4
    ifd, blob = bytearray(), bytearray()
    for tag, typ, values in entries:
        if typ == 2:
            payload, count = values.encode("ascii") + b"\0", len(values) + 1
        elif typ == 3:
            payload, count = struct.pack(f"<{len(values)}H", *values), len(values)
        elif typ == 4:
            payload, count = struct.pack(f"<{len(values)}I", *values), len(values)
        else:
            payload, count = b"".join(struct.pack("<ii", n, dd) for n, dd in values), len(values)
        if len(payload) <= 4:
            ifd += struct.pack("<HHI", tag, typ, count) + payload.ljust(4, b"\0")
        else:
            if len(blob) % 2:
                blob += b"\0"
            ifd += struct.pack("<HHII", tag, typ, count, data_offset + len(blob))
            blob += payload
    with open(path, "wb") as f:
        f.write(b"IIRC" + struct.pack("<I", ifd_offset))
        f.write(struct.pack("<H", len(entries)) + ifd + struct.pack("<I", 0) + blob)


def read_dcp(path):
    """Read back the tags of a DCP (used by render_compare.py and to verify our own output)."""
    import acam_dng  # same directory
    buf = open(path, "rb").read()
    if buf[:4] != b"IIRC":
        raise ValueError(f"{path}: not a DCP (magic {buf[:4]!r})")
    return acam_dng.read_ifd(buf, struct.unpack_from("<I", buf, 4)[0])


# ----------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--ir-cutoff", type=float, default=650.0,
                    help="IR-cut filter 50%% wavelength in nm (default 650; typical 645-680)")
    ap.add_argument("--ir-slope", type=float, default=7.0,
                    help="IR-cut edge softness in nm (default 7: 10-90%% over about 31 nm)")
    ap.add_argument("--out-dir", default=os.path.join(HERE, "profiles"),
                    help="parent folder; the profile goes into <out-dir>/<id>/")
    ap.add_argument("--id", default=None, help="profile id (default kai02150-ir<cutoff>)")
    args = ap.parse_args()

    result = build(args.ir_cutoff, args.ir_slope)
    profile_id = args.id or f"kai02150-ir{args.ir_cutoff:g}"
    out_dir = os.path.join(args.out_dir, profile_id)
    os.makedirs(out_dir, exist_ok=True)
    name = f"A-Cam dII KAI-02150 sensor data (IR cut {args.ir_cutoff:g} nm)"
    dcp = os.path.join(out_dir, profile_id + ".dcp")
    a, d = result["illuminants"]["A"], result["illuminants"]["D65"]
    write_dcp(dcp, name, a["color_matrix"], d["color_matrix"], a["exif_code"], d["exif_code"],
              a["forward_matrix"], d["forward_matrix"],
              copyright_text="Built from published KAI-02150 QE data; free to use")
    tags = read_dcp(dcp)
    for key, illum in ((0xC621, "A"), (0xC622, "D65")):
        stored = np.array(tags[key]).reshape(3, 3)
        assert np.allclose(stored, result["illuminants"][illum]["color_matrix"], atol=6e-5), "DCP readback"
    result["id"] = profile_id
    result["profile_name"] = name
    result["unique_camera_model"] = CAMERA_MODEL
    fit_json = os.path.join(out_dir, "fit.json")
    with open(fit_json, "w") as f:
        json.dump(result, f, indent=1)

    print(f"{name}\n  wrote {dcp}\n  wrote {fit_json}")
    for illum in ("A", "D65"):
        e = result["illuminants"][illum]
        print(f"  {illum}: camera neutral {np.round(e['camera_neutral'], 4).tolist()}")
        print("    ColorMatrix   " + np.array2string(np.array(e["color_matrix"]), precision=4).replace("\n", "\n                  "))
        print("    ForwardMatrix " + np.array2string(np.array(e["forward_matrix"]), precision=4).replace("\n", "\n                  "))
        for key in ("CC24", "CES99", "PMC30"):
            fm = e["errors_forward_matrix_d50"][key]
            cm = e["errors_color_matrix"][key]
            print(f"    dE2000 {key:5s} ForwardMatrix mean {fm['mean']:.2f} max {fm['max']:.2f} | "
                  f"ColorMatrix mean {cm['mean']:.2f} max {cm['max']:.2f}")


if __name__ == "__main__":
    main()
