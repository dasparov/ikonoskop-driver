#!/usr/bin/env python3
"""Check the step-7 files of every candidate in profiles/ with OpenColorIO.

Plain-language summary: loads each config.ocio with the official OpenColorIO library, runs its
built-in validity check, and pushes test colours through it: a neutral camera grey must come
out neutral in ACES, ACEScct and on screen, and arbitrary colours must match the IDT matrices
in idt.json and in the .ctl files exactly.

Needs PyOpenColorIO 2.x and numpy, e.g. a venv:
  python3 -m venv work/venv-ocio && work/venv-ocio/bin/pip install opencolorio numpy
Usage: work/venv-ocio/bin/python pipeline/colour/tools/check_ocio.py [--profiles DIR]
"""
import argparse
import glob
import json
import os
import re
import sys

import numpy as np
import PyOpenColorIO as ocio

HERE = os.path.dirname(os.path.abspath(__file__))
GREY = 0.18
ACESCCT_018 = (np.log2(0.18) + 9.72) / 17.52  # ACEScct encoding of 0.18 (S-2016-001)


def ctl_matrix(path):
    text = open(path).read()
    body = re.search(r"const float B\[3\]\[3\] = \{(.*?)\};", text, re.S).group(1)
    return np.array([float(v) for v in re.findall(r"[-+]?\d+\.\d+(?:[eE][-+]?\d+)?", body)]).reshape(3, 3)


def apply(processor, rgb):
    return np.array(processor.getDefaultCPUProcessor().applyRGB([float(v) for v in rgb]))


def check(folder, rng):
    failures = []

    def expect(cond, msg):
        if not cond:
            failures.append(msg)

    config = ocio.Config.CreateFromFile(os.path.join(folder, "config.ocio"))
    config.validate()  # raises on error
    idt = json.load(open(os.path.join(folder, "idt.json")))
    print(f"\n== {os.path.basename(folder)}: {idt['name']}  (OCIO {ocio.__version__}, profile version "
          f"{config.getMajorVersion()}.{config.getMinorVersion()}, validate() OK)")
    for t in idt["transforms"]:
        m = np.array(t["matrixToACES2065_1"])
        ctl = ctl_matrix(os.path.join(folder, t["ctl"]))
        expect(np.max(np.abs(ctl - m)) < 1e-9, f"{t['ctl']}: matrix differs from idt.json")
        src = t["ocioColorSpace"]
        expect(config.getColorSpace(src) is not None, f"missing colour space {src}")

        aces = apply(config.getProcessor(src, "ACES2065-1"), [GREY] * 3)
        cct = apply(config.getProcessor(src, "ACEScct"), [GREY] * 3)
        cg = apply(config.getProcessor(src, "ACEScg"), [GREY] * 3)
        print(f"  [{t['white']}] '{src}'")
        print(f"    grey {GREY} -> ACES2065-1 {np.round(aces, 6).tolist()}  ACEScg {np.round(cg, 6).tolist()}  "
              f"ACEScct {np.round(cct, 6).tolist()} (expected {ACESCCT_018:.6f})")
        expect(np.max(np.abs(aces - GREY)) < 1e-5, f"{src}: grey not neutral in ACES2065-1")
        expect(np.max(np.abs(cct - ACESCCT_018)) < 1e-5, f"{src}: grey ACEScct value")
        for display in config.getDisplays():
            for view in ("ACES 1.0 - SDR Video", "Un-tone-mapped"):
                out = apply(config.getProcessor(src, display, view, ocio.TRANSFORM_DIR_FORWARD), [GREY] * 3)
                print(f"    grey -> {display} / {view}: {np.round(out, 6).tolist()}")
                expect(np.ptp(out) < 1e-4, f"{src} -> {display}/{view}: grey not neutral ({out})")
        worst = 0.0
        to_aces = config.getProcessor(src, "ACES2065-1")
        for rgb in rng.uniform(0.0, 1.0, size=(20, 3)):
            worst = max(worst, float(np.max(np.abs(apply(to_aces, rgb) - m @ rgb))))
        print(f"    20 random colours: OCIO vs IDT matrix max difference {worst:.2e}")
        expect(worst < 1e-5, f"{src}: OCIO matrix differs from IDT")
    return failures


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--profiles", default=os.path.join(os.path.dirname(HERE), "profiles"))
    args = ap.parse_args()
    rng = np.random.default_rng(1)
    failures = []
    for folder in sorted(glob.glob(os.path.join(args.profiles, "*", "config.ocio"))):
        failures += check(os.path.dirname(folder), rng)
    print("\nRESULT: " + ("all checks passed" if not failures else "FAILED:\n  " + "\n  ".join(failures)))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
