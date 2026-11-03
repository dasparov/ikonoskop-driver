#!/usr/bin/env python3
"""Prepare Phase 5 step 7 for every colour-profile candidate.

Plain-language summary: for each candidate profile (the factory matrices and the two
sensor-data profiles) this writes everything later steps need, into profiles/<id>/:
  profile.json   the matrices, for the Swift pipeline to write into clean DNGs;
  <id>.dcp       the profile for Adobe Camera Raw / Lightroom;
  IDT.*.ctl      ACES input transforms (camera colours -> ACES), one per white balance;
  idt.json       the same ACES matrices as plain numbers, with how they were derived;
  config.ocio    an OpenColorIO v2 configuration (camera -> ACES -> screen).
Nothing here touches footage; choosing a candidate only means using its folder.

Candidates:
  factory         ColorMatrix1/2 from core/ik_dng_templates.h, read as D55 (EXIF 20) and
                  ISO studio tungsten 3200 K (EXIF 24); no ForwardMatrix.
  kai02150-ir650  profiles/kai02150-ir650/kai02150-ir650.dcp (build_profile.py --ir-cutoff 650)
  kai02150-ir665  profiles/kai02150-ir665/kai02150-ir665.dcp (build_profile.py --ir-cutoff 665)

IDT method (DNG spec + ACES): for the chosen white (xy), find its correlated colour
temperature, blend matrix 1 and 2 linearly in 1/temperature (clamped), then
  with ForwardMatrix:    balanced camera -> XYZ(D50) = ForwardMatrix, rows rescaled so that
                         (1,1,1) -> D50 exactly (as the DNG SDK does);
  without ForwardMatrix: camera -> XYZ = inverse ColorMatrix, Bradford from the white to D50;
then XYZ(D50) -> Bradford -> ACES white (x 0.32168, y 0.33767) -> AP0 (SMPTE ST 2065-1).
White-balanced camera (1,1,1) therefore becomes ACES (1,1,1).

Usage: export_candidates.py [--profiles DIR]
"""
import argparse
import json
import os
import re

import numpy as np

import build_profile as bp
import dng_colour as dc

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
TEMPLATES = os.path.join(REPO, "core", "ik_dng_templates.h")
DENOMINATOR = 10000

EXIF_NAMES = {17: "Standard light A (tungsten, 2856 K)", 20: "D55 (daylight, 5500 K)",
              21: "D65 (daylight, 6500 K)", 24: "ISO studio tungsten (3200 K)"}


def factory_matrices():
    """The factory ColorMatrix1/2 exactly as the driver writes them into every DNG header."""
    text = open(TEMPLATES).read()
    out = []
    for n in (1, 2):
        m = re.search(rf"kColorMatrix{n}Values\[\]\s*=\s*\{{([^}}]*)\}}", text)
        values = [int(v) for v in m.group(1).split(",")]
        assert len(values) == 9
        out.append([v / DENOMINATOR for v in values])
    return out


def white(label):
    """XYZ (Y = 1) of a named white: DNG SDK chromaticities, or a black body for '3200K'."""
    if label == "3200K":
        return dc.planck().white_xyz(3200.0)
    return dc.xy_to_xyz(dc.XY[label])


def candidates(profiles_dir):
    cm1, cm2 = factory_matrices()
    yield {"id": "factory", "name": "A-Cam dII factory matrices (D55 / 3200 K)",
           "calibrationIlluminant1": 20, "calibrationIlluminant2": 24,
           "colorMatrix1": cm1, "colorMatrix2": cm2, "forwardMatrix1": None, "forwardMatrix2": None,
           "whites": ["D55", "3200K"], "dcp": None}
    for pid in ("kai02150-ir650", "kai02150-ir665"):
        dcp = os.path.join(profiles_dir, pid, pid + ".dcp")
        t = bp.read_dcp(dcp)
        yield {"id": pid, "name": t[0xC6F8],
               "calibrationIlluminant1": t[0xC65A][0], "calibrationIlluminant2": t[0xC65B][0],
               "colorMatrix1": t[0xC621], "colorMatrix2": t[0xC622],
               "forwardMatrix1": t[0xC714], "forwardMatrix2": t[0xC715],
               "whites": ["A", "D65", "D55"], "dcp": dcp}


def r4(values):
    return None if values is None else [round(float(v), 4) for v in values]


def fmt_row(row):
    return ", ".join(f"{v:.10f}" for v in row)


WB_LABEL = {"D55": "D55", "3200K": "3200 K", "A": "A", "D65": "D65"}


def colourspace_name(pid, wb):
    return f"A-Cam dII linear ({pid}, {WB_LABEL[wb]} white balance)"


def write_ctl(path, pid, wb, name, entry):
    m = entry["matrixToACES2065_1"]
    lines = [
        f"// <ACEStransformID>urn:ampas:aces:transformId:v1.5:IDT.Ikonoskop.ACamdII.{pid}.{wb}.a1.v1</ACEStransformID>",
        f"// <ACESuserName>ACES 1.0 Input - Ikonoskop A-Cam dII ({pid}, {WB_LABEL[wb]} white balance)</ACESuserName>",
        "//",
        "// Input Device Transform for the Ikonoskop A-Cam dII (Kodak KAI-02150 CCD, 12-bit CinemaDNG).",
        "//",
        "// Input:  demosaiced linear camera RGB, black level subtracted, normalised so that",
        "//         1.0 = white level (4095), white balanced for " + WB_LABEL[wb] + ", i.e. each camera",
        "//         channel divided by the camera neutral " + json.dumps([round(v, 6) for v in entry["cameraNeutral"]]) + ".",
        "// Output: ACES2065-1 (AP0 primaries, linear). Balanced white (1,1,1) -> ACES (1,1,1);",
        "//         no exposure scaling, no clipping.",
        f"// Profile: {name}",
        f"// White: {wb}, xy {entry['whiteXy'][0]:.5f} {entry['whiteXy'][1]:.5f}, CCT {entry['cct']:.0f} K,",
        f"//        DNG blend weight of matrix 1 = {entry['weightMatrix1']:.4f}",
        "// Method: " + entry["method"],
        "// Generated by pipeline/colour/export_candidates.py from profile.json; do not edit by hand.",
        "",
        "const float B[3][3] = {",
        "    { " + fmt_row(m[0]) + " },",
        "    { " + fmt_row(m[1]) + " },",
        "    { " + fmt_row(m[2]) + " }",
        "};",
        "",
        "void main",
        "(",
        "    input varying float rIn,",
        "    input varying float gIn,",
        "    input varying float bIn,",
        "    input varying float aIn,",
        "    output varying float rOut,",
        "    output varying float gOut,",
        "    output varying float bOut,",
        "    output varying float aOut",
        ")",
        "{",
        "    rOut = B[0][0] * rIn + B[0][1] * gIn + B[0][2] * bIn;",
        "    gOut = B[1][0] * rIn + B[1][1] * gIn + B[1][2] * bIn;",
        "    bOut = B[2][0] * rIn + B[2][1] * gIn + B[2][2] * bIn;",
        "    aOut = aIn;",
        "}",
        "",
    ]
    with open(path, "w") as f:
        f.write("\n".join(lines))


def ocio_matrix(m):
    m44 = np.eye(4)
    m44[:3, :3] = m
    return "[" + ", ".join(f"{v:.10f}" for v in m44.ravel()) + "]"


def write_ocio(path, cand, entries):
    pid = cand["id"]
    camera_spaces = []
    for e in entries:
        wb = e["white"]
        camera_spaces.append(f"""
  - !<ColorSpace>
    name: "{colourspace_name(pid, wb)}"
    family: Input/Ikonoskop
    encoding: scene-linear
    description: |
      Ikonoskop A-Cam dII demosaiced linear camera RGB: black subtracted, 1.0 = white level
      (4095), white balanced for {WB_LABEL[wb]} (camera RGB divided by camera neutral
      {[round(v, 6) for v in e['cameraNeutral']]}). Matrix from profile {pid}
      ({cand['name']}); same matrix as IDT.Ikonoskop.ACamdII.{pid}.{wb}.ctl.
    isdata: false
    to_scene_reference: !<MatrixTransform> {{matrix: {ocio_matrix(e['matrixToACES2065_1'])}}}
""")
    text = f"""ocio_profile_version: 2.1

environment:
  {{}}
search_path: ""
strictparsing: true
luma: [0.2126, 0.7152, 0.0722]
name: ikonoskop-acam-dii-{pid}
description: |
  Ikonoskop A-Cam dII, colour profile candidate "{pid}" ({cand['name']}).
  Scene reference: ACES2065-1. Display reference: CIE XYZ D65.
  Generated by pipeline/colour/export_candidates.py; do not edit by hand.

roles:
  aces_interchange: ACES2065-1
  cie_xyz_d65_interchange: CIE-XYZ-D65
  color_timing: ACEScct
  compositing_log: ACEScct
  data: Raw
  default: ACES2065-1
  scene_linear: ACEScg

file_rules:
  - !<Rule> {{name: Default, colorspace: ACES2065-1}}

displays:
  sRGB - Display:
    - !<View> {{name: ACES 1.0 - SDR Video, view_transform: ACES 1.0 - SDR Video, display_colorspace: sRGB - Display}}
    - !<View> {{name: Un-tone-mapped, view_transform: Un-tone-mapped, display_colorspace: sRGB - Display}}
    - !<View> {{name: Raw, colorspace: Raw}}
  Rec.1886 Rec.709 - Display:
    - !<View> {{name: ACES 1.0 - SDR Video, view_transform: ACES 1.0 - SDR Video, display_colorspace: Rec.1886 Rec.709 - Display}}
    - !<View> {{name: Un-tone-mapped, view_transform: Un-tone-mapped, display_colorspace: Rec.1886 Rec.709 - Display}}
    - !<View> {{name: Raw, colorspace: Raw}}

active_displays: [sRGB - Display, Rec.1886 Rec.709 - Display]
active_views: [ACES 1.0 - SDR Video, Un-tone-mapped, Raw]

default_view_transform: Un-tone-mapped

view_transforms:
  - !<ViewTransform>
    name: ACES 1.0 - SDR Video
    description: ACES 1.0 Output Transform (RRT + SDR video ODT, 100 nits).
    from_scene_reference: !<BuiltinTransform> {{style: ACES-OUTPUT - ACES2065-1_to_CIE-XYZ-D65 - SDR-VIDEO_1.0}}

  - !<ViewTransform>
    name: Un-tone-mapped
    description: Colorimetric conversion only (Bradford ACES white to D65), no tone mapping.
    from_scene_reference: !<BuiltinTransform> {{style: UTILITY - ACES-AP0_to_CIE-XYZ-D65_BFD}}

display_colorspaces:
  - !<ColorSpace>
    name: CIE-XYZ-D65
    family: ""
    encoding: display-linear
    description: The CIE XYZ (D65) display connection colour space.
    isdata: false

  - !<ColorSpace>
    name: sRGB - Display
    family: Display
    encoding: sdr-video
    description: sRGB monitor (piecewise sRGB transfer function, Rec.709 primaries, D65).
    isdata: false
    from_display_reference: !<BuiltinTransform> {{style: DISPLAY - CIE-XYZ-D65_to_sRGB}}

  - !<ColorSpace>
    name: Rec.1886 Rec.709 - Display
    family: Display
    encoding: sdr-video
    description: Rec.709 video display (Rec.1886 gamma 2.4, Rec.709 primaries, D65).
    isdata: false
    from_display_reference: !<BuiltinTransform> {{style: DISPLAY - CIE-XYZ-D65_to_REC.1886-REC.709}}

colorspaces:
  - !<ColorSpace>
    name: ACES2065-1
    family: ACES
    encoding: scene-linear
    description: ACES2065-1, AP0 primaries, linear (the reference and interchange space).
    isdata: false

  - !<ColorSpace>
    name: ACEScg
    family: ACES
    encoding: scene-linear
    description: ACEScg, AP1 primaries, linear.
    isdata: false
    to_scene_reference: !<BuiltinTransform> {{style: ACEScg_to_ACES2065-1}}

  - !<ColorSpace>
    name: ACEScct
    family: ACES
    encoding: log
    description: ACEScct, AP1 primaries, log encoding for grading.
    isdata: false
    to_scene_reference: !<BuiltinTransform> {{style: ACEScct_to_ACES2065-1}}

  - !<ColorSpace>
    name: Raw
    family: Utility
    encoding: data
    description: Data, no colour conversion.
    isdata: true
{''.join(camera_spaces)}"""
    with open(path, "w") as f:
        f.write(text)


def export(cand, profiles_dir):
    pid = cand["id"]
    out = os.path.join(profiles_dir, pid)
    os.makedirs(out, exist_ok=True)

    profile_json = {k: cand[k] for k in ("id", "name", "calibrationIlluminant1", "calibrationIlluminant2")}
    for k in ("colorMatrix1", "colorMatrix2", "forwardMatrix1", "forwardMatrix2"):
        profile_json[k] = r4(cand[k])
    profile_json["rationalDenominator"] = DENOMINATOR
    with open(os.path.join(out, "profile.json"), "w") as f:
        json.dump(profile_json, f, indent=2)
        f.write("\n")

    dcp = os.path.join(out, pid + ".dcp")
    if cand["dcp"] is None:
        bp.write_dcp(dcp, cand["name"], np.reshape(profile_json["colorMatrix1"], (3, 3)),
                     np.reshape(profile_json["colorMatrix2"], (3, 3)),
                     cand["calibrationIlluminant1"], cand["calibrationIlluminant2"])
    t = bp.read_dcp(dcp)  # the DCP and profile.json must carry the same numbers
    for tag, key in ((0xC621, "colorMatrix1"), (0xC622, "colorMatrix2"),
                     (0xC714, "forwardMatrix1"), (0xC715, "forwardMatrix2")):
        expected = profile_json[key]
        assert (tag in t) == (expected is not None), f"{dcp}: tag {tag:#x} presence"
        if expected is not None:
            assert np.allclose(t[tag], expected, atol=1e-9), f"{dcp}: tag {tag:#x} differs from profile.json"

    profile = dc.Profile(cand["name"], profile_json["colorMatrix1"], profile_json["colorMatrix2"],
                         profile_json["calibrationIlluminant1"], profile_json["calibrationIlluminant2"],
                         profile_json["forwardMatrix1"], profile_json["forwardMatrix2"])
    method = ("ForwardMatrix (DNG-normalised to D50) -> Bradford D50 to ACES white -> XYZ to AP0"
              if profile.fm is not None else
              "inverse ColorMatrix -> Bradford white to D50 -> Bradford D50 to ACES white -> XYZ to AP0")
    entries = []
    for wb in cand["whites"]:
        w = white(wb)
        to_aces, neutral, temperature, g = dc.balanced_to_aces(profile, w)
        to_d50 = profile.balanced_to_xyz_d50(w)[0]
        entries.append({
            "white": wb, "whiteXy": [w[0] / w.sum(), 1 / w.sum()], "cct": temperature,
            "weightMatrix1": g, "cameraNeutral": neutral.tolist(), "method": method,
            "balancedCameraToXYZD50": to_d50.tolist(), "matrixToACES2065_1": to_aces.tolist(),
            "ctl": f"IDT.Ikonoskop.ACamdII.{pid}.{wb}.ctl", "ocioColorSpace": colourspace_name(pid, wb),
        })
        write_ctl(os.path.join(out, entries[-1]["ctl"]), pid, wb, cand["name"], entries[-1])
    idt = {
        "profile": pid, "name": cand["name"],
        "input": "demosaiced linear camera RGB, black subtracted, 1.0 = white level, divided by cameraNeutral",
        "output": "ACES2065-1 (AP0, linear); balanced (1,1,1) -> (1,1,1)",
        "D50": dc.D50_DNG.tolist(), "acesWhite": dc.ACES_WHITE.tolist(),
        "bradfordD50ToAcesWhite": bp.bradford(dc.D50_DNG, dc.ACES_WHITE).tolist(),
        "xyzToAP0": dc.XYZ_TO_AP0.tolist(),
        "transforms": entries,
    }
    with open(os.path.join(out, "idt.json"), "w") as f:
        json.dump(idt, f, indent=1)
        f.write("\n")
    write_ocio(os.path.join(out, "config.ocio"), cand, entries)
    return entries


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--profiles", default=os.path.join(HERE, "profiles"))
    args = ap.parse_args()
    for cand in candidates(args.profiles):
        entries = export(cand, args.profiles)
        print(f"{cand['id']}: {cand['name']}")
        for e in entries:
            m = np.array(e["matrixToACES2065_1"])
            print(f"  {e['white']:5s} CCT {e['cct']:6.0f} K  weight(M1) {e['weightMatrix1']:.4f}  neutral "
                  f"{np.round(e['cameraNeutral'], 4).tolist()}  row sums {np.round(m.sum(1), 6).tolist()}")
            print("        to AP0 " + " | ".join(" ".join(f"{v:+.4f}" for v in row) for row in m))


if __name__ == "__main__":
    main()
