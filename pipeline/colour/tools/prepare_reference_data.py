#!/usr/bin/env python3
"""Download the public colour-science reference data and write it as plain CSV in data/.

Plain-language summary: building a camera profile needs standard tables (how the eye sees
colour, what standard lights look like, and the colours of real objects). This script fetches
them from their official/public sources and stores them as simple CSV files, so the profile
build itself never needs the internet. Run once; the CSVs are committed.

Usage: prepare_reference_data.py [--downloads DIR]
"""
import argparse
import ast
import gzip
import os
import urllib.request

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
COLOUR_DIR = os.path.dirname(HERE)
DATA = os.path.join(COLOUR_DIR, "data")
REPO = os.path.dirname(os.path.dirname(COLOUR_DIR))

CIE = "https://files.cie.co.at/Publications-datasets/"
COLOUR_SCIENCE = "https://raw.githubusercontent.com/colour-science/colour/develop/colour/"
SOURCES = {
    "CIE_xyz_1931_2deg.csv": CIE + "CIE_xyz_1931_2deg.csv",
    "CIE_std_illum_A_1nm.csv": CIE + "CIE_std_illum_A_1nm.csv",
    "CIE_std_illum_D65.csv": CIE + "CIE_std_illum_D65.csv",
    "CIE_std_illum_D50.csv": CIE + "CIE_std_illum_D50.csv",
    "colour_checkers_sds.py": COLOUR_SCIENCE + "characterisation/datasets/colour_checkers/sds.py",
    "tcs_cfi2017_5_nm.csv.gz": COLOUR_SCIENCE + "quality/datasets/tcs_cfi2017_5_nm.csv.gz",
}
WAVELENGTHS = np.arange(380, 781, 5)


def fetch(downloads):
    os.makedirs(downloads, exist_ok=True)
    paths = {}
    for name, url in SOURCES.items():
        path = os.path.join(downloads, name)
        if not os.path.exists(path):
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req) as r, open(path, "wb") as f:
                f.write(r.read())
        paths[name] = path
    return paths


def cie_table(path, columns):
    """Rows at 380..780 nm, 5 nm steps, from a CIE 1 nm CSV (exact values, no resampling)."""
    raw = np.genfromtxt(path, delimiter=",")
    rows = {int(round(r[0])): r[1:1 + columns] for r in raw}
    return np.array([rows[int(w)] for w in WAVELENGTHS])


def literal(module_path, name):
    tree = ast.parse(open(module_path).read())
    for node in tree.body:
        targets = node.targets if isinstance(node, ast.Assign) else [node.target] if isinstance(node, ast.AnnAssign) else []
        if any(getattr(t, "id", None) == name for t in targets):
            return ast.literal_eval(node.value)
    raise KeyError(name)


def write_csv(name, header, wavelengths, columns, fmt="{:.6g}"):
    path = os.path.join(DATA, name)
    with open(path, "w") as f:
        f.write(",".join(["wavelength_nm"] + header) + "\n")
        for i, w in enumerate(wavelengths):
            f.write(",".join([str(int(w))] + [fmt.format(c[i]) for c in columns]) + "\n")
    print(f"wrote {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--downloads", default=os.path.join(REPO, "pipeline", "build", "colour", "downloads"))
    args = ap.parse_args()
    p = fetch(args.downloads)

    cmf = cie_table(p["CIE_xyz_1931_2deg.csv"], 3)
    write_csv("cie1931_2deg_cmf.csv", ["x_bar", "y_bar", "z_bar"], WAVELENGTHS, cmf.T)

    ill = np.column_stack([cie_table(p[k], 1)[:, 0] for k in
                           ("CIE_std_illum_A_1nm.csv", "CIE_std_illum_D65.csv", "CIE_std_illum_D50.csv")])
    write_csv("cie_illuminants.csv", ["A", "D65", "D50"], WAVELENGTHS, ill.T)

    cc = literal(p["colour_checkers_sds.py"], "DATA_COLORCHECKER_N_OHTA")
    names = list(cc.keys())
    write_csv("colorchecker24_iso17321.csv", [n.replace(",", " ") for n in names], WAVELENGTHS,
              [[cc[n][int(w)] for w in WAVELENGTHS] for n in names], "{:.3f}")

    with gzip.open(p["tcs_cfi2017_5_nm.csv.gz"], "rt") as f:
        ces = np.genfromtxt(f, delimiter=",")
    ces = ces[np.isin(ces[:, 0], WAVELENGTHS)]
    assert np.array_equal(ces[:, 0], WAVELENGTHS) and ces.shape[1] == 100
    write_csv("cie224_2017_ces99.csv", [f"CES{i:02d}" for i in range(1, 100)], WAVELENGTHS, ces[:, 1:].T, "{:.5f}")

    pmc = literal(p["colour_checkers_sds.py"], "DATA_PMC")
    pmc_w = sorted(next(iter(pmc.values())).keys())
    write_csv("pmc30_luo2024.csv", list(pmc.keys()), pmc_w,
              [[pmc[n][w] / 100 for w in pmc_w] for n in pmc], "{:.4f}")


if __name__ == "__main__":
    main()
