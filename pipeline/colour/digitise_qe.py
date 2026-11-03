#!/usr/bin/env python3
"""Extract the KAI-02150 colour (Bayer) quantum-efficiency curves from the datasheet PDFs.

Plain-language summary: the sensor datasheets draw their QE graphs as vector graphics, so the
data points are stored in the PDF as exact coordinates. This script reads those coordinates
(no tracing of pixels), converts them to wavelength and QE using the graph's own gridlines and
tick labels, cross-checks two independent datasheets, and writes data/kai02150_qe.csv.

Sources (PDFs live in datasheet/, which git ignores; see data/SOURCES.md):
  * Kodak KAI-02150 Device Performance Specification, Rev 1.0, MTD/PS-1066, 27 Oct 2008,
    page 14, Figure 5 "Color (Bayer RGB) with Microlens" (AR-coated cover glass).
    Data points every 10 nm from 390 to 1100 nm. Primary source for 390-780 nm.
  * Truesense Imaging KAI-02150 Device Performance Specification, Rev 2.0, PS-0007,
    16 Nov 2012, page 17, Figure 8 (same Gen1 colour filters; MAR and clear glass).
    Data every 10 nm from 350 nm. Used for 380 nm (the Kodak graph starts at 390 nm) and as a
    cross-check of every other point.

Usage: digitise_qe.py [--datasheets DIR] [--out CSV] [--check-png PNG]
Needs: python3 with numpy (matplotlib + Pillow only for --check-png), swiftc (Command Line Tools).
"""
import argparse
import os
import subprocess
import sys
from collections import defaultdict

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
KODAK_PDF = "KAI-02150_kodak_MTD-PS-1066_rev1.pdf"
KODAK_PAGE = 14
TRUESENSE_PDF = "KAI-02150_truesense_PS-0007_rev2.pdf"
TRUESENSE_PAGE = 17
TRUESENSE_FORM = "Meta242"  # the upper graph on page 17 (Figure 8)

KODAK_SERIES = {(1.0, 0.0, 0.0): "r", (0.0, 0.502, 0.0): "g", (0.0, 0.0, 1.0): "b"}
KODAK_MARKERS = {(1.0, 0.0, 0.0): "r", (0.0, 1.0, 0.0): "g", (0.0, 1.0, 1.0): "b"}
TRUESENSE_SERIES = {(0.502, 0.0, 0.0): "r_mar", (0.0, 0.502, 0.0): "g_mar", (0.0, 0.0, 1.0): "b_mar",
                    (1.0, 0.0, 0.0): "r_clear", (0.0, 1.0, 0.0): "g_clear", (0.2, 0.6, 1.0): "b_clear"}

OUT_WAVELENGTHS = list(range(380, 781, 10))


def tool_path():
    """Compile tools/pdf_vector_ops.swift into pipeline/build/colour (git-ignored) if needed."""
    src = os.path.join(HERE, "tools", "pdf_vector_ops.swift")
    out_dir = os.path.join(REPO, "pipeline", "build", "colour")
    exe = os.path.join(out_dir, "pdf_vector_ops")
    if not os.path.exists(exe) or os.path.getmtime(exe) < os.path.getmtime(src):
        os.makedirs(out_dir, exist_ok=True)
        subprocess.run(["swiftc", "-O", "-o", exe, src], check=True)
    return exe


def page_ops(pdf, page, form=None):
    """Operator lines of a page, or of one form XObject on it."""
    text = subprocess.run([tool_path(), "ops", pdf, str(page)], check=True, capture_output=True,
                          text=True).stdout.splitlines()
    if form is None:
        end = next((i for i, l in enumerate(text) if l.startswith("XOBJECT")), len(text))
        return text[:end]
    start = text.index(f"XOBJECT {form} Form") + 1
    return text[start:text.index("ENDXOBJECT", start)]


def parse(lines):
    """Turn operator lines into stroked paths, filled+stroked shapes and text fragments.

    Returns (strokes, shapes, texts): strokes = [(stroke_rgb, [(x, y), ...])],
    shapes = [(fill_rgb, stroke_rgb, op, [(x, y), ...])], texts = [(x, y, font_size, string)]."""
    stroke, fill = (0.0, 0.0, 0.0), (0.0, 0.0, 0.0)
    stack, path = [], []
    strokes, shapes, texts = [], [], []
    last_tm, font_size = None, 1.0
    for line in lines:
        op, _, rest = line.partition(" ")
        if op == "Tj":
            if last_tm:
                texts.append((last_tm[4], last_tm[5], font_size * abs(last_tm[0] or last_tm[1]), rest))
            continue
        vals = [float(v) for v in rest.split()] if rest and op not in ("Do", "XOBJECT") else []
        if op == "Tf":
            font_size = vals[0] if vals else 1.0
        elif op == "RG":
            stroke = tuple(round(v, 3) for v in vals)
        elif op == "rg":
            fill = tuple(round(v, 3) for v in vals)
        elif op == "q":
            stack.append((stroke, fill))
        elif op == "Q":
            stroke, fill = stack.pop()
        elif op == "Tm":
            last_tm = vals
        elif op == "m":
            path.append([(vals[0], vals[1])])
        elif op == "l":
            path[-1].append((vals[0], vals[1]))
        elif op == "c":
            path[-1].append((vals[4], vals[5]))
        elif op == "re":
            x, y, w, h = vals
            path.append([(x, y), (x + w, y), (x + w, y + h), (x, y + h)])
        elif op == "S":
            strokes.extend((stroke, sub) for sub in path)
            path = []
        elif op in ("f", "B"):
            pts = [p for sub in path for p in sub]
            if pts:
                shapes.append((fill, stroke, op, pts))
            path = []
        elif op == "n":
            path = []
    return strokes, shapes, texts


DIGIT_WIDTH = 0.556  # Arial/Helvetica digit advance, in units of the font size


def labels(texts):
    """Join text fragments on one baseline into words.

    Returns [(x_centre, y_middle, word)]; widths are estimated from the font size."""
    rows = defaultdict(list)
    for x, y, size, s in texts:
        rows[round(y, 2)].append((x, size, s))
    words = []
    for y, frags in rows.items():
        frags.sort()
        start = end = size0 = None
        word = ""
        for x, size, s in frags:
            if start is not None and x - end > 0.5 * size:
                words.append(((start + end) / 2, y + 0.35 * size0, word.strip()))
                start = None
            if start is None:
                start, word, size0 = x, "", size
            word += s
            end = x + DIGIT_WIDTH * size * len(s)
        words.append(((start + end) / 2, y + 0.35 * size0, word.strip()))
    return words


def numeric_words(words):
    out = []
    for x, y, w in words:
        try:
            out.append((x, y, float(w)))
        except ValueError:
            pass
    return out


def merge_close(values, tol=0.5):
    """Sort coordinates and merge ones closer than `tol` (frame edge vs. last gridline)."""
    out = []
    for v in sorted(values):
        if out and v - out[-1][-1] < tol:
            out[-1].append(v)
        else:
            out.append([v])
    return [float(np.mean(group)) for group in out]


def axis_calibration(strokes, texts, frame_colour):
    """Fit wavelength(x) and QE(y) from the grid and the tick labels.

    The plot frame is the rectangle stroked in `frame_colour`; gridlines/major ticks are the
    straight segments spanning it. Tick labels are the numeric words below (x axis) or left of
    (y axis) the frame. Labels and gridlines are matched in order, then fitted linearly."""
    frame = [pts for col, pts in strokes if col == frame_colour and len(pts) >= 4]
    xs = [p[0] for pts in frame for p in pts]
    ys = [p[1] for pts in frame for p in pts]
    fx0, fx1, fy0, fy1 = min(xs), max(xs), min(ys), max(ys)
    vgrid, hgrid = set(), set()
    for col, pts in strokes:
        if len(pts) != 2:
            continue
        (ax, ay), (bx, by) = pts
        if abs(ax - bx) < 0.01 and abs(abs(ay - by) - (fy1 - fy0)) < 1.0:
            vgrid.add(round(ax, 3))
        if abs(ay - by) < 0.01 and abs(abs(ax - bx) - (fx1 - fx0)) < 1.0:
            hgrid.add(round(ay, 3))
    vgrid |= {round(fx0, 3), round(fx1, 3)}
    hgrid |= {round(fy0, 3), round(fy1, 3)}
    vgrid, hgrid = merge_close(vgrid), merge_close(hgrid)
    nums = numeric_words(labels(texts))
    xlab = sorted((n for n in nums if n[1] < fy0 and fx0 - 15 < n[0] < fx1 + 15 and n[2] >= 100), key=lambda n: n[0])
    ylab = sorted((n for n in nums if n[0] < fx0 and fy0 - 10 < n[1] < fy1 + 10 and n[2] <= 1), key=lambda n: n[1])
    if len(xlab) != len(vgrid) or len(ylab) != len(hgrid):
        sys.exit(f"axis calibration: {len(xlab)} x labels vs {len(vgrid)} gridlines, "
                 f"{len(ylab)} y labels vs {len(hgrid)} gridlines")
    xv = np.array([n[2] for n in xlab])
    yv = np.array([n[2] for n in ylab])
    if np.any(np.diff(xv) <= 0) or np.any(np.diff(yv) <= 0):
        sys.exit("axis calibration: tick labels are not in increasing order")
    # each label must be centred on its gridline (to within the text-width estimate)
    x_offset = max(abs(n[0] - g) for n, g in zip(xlab, vgrid))
    y_offset = max(abs(n[1] - g) for n, g in zip(ylab, hgrid))
    if x_offset > 4 or y_offset > 4:
        sys.exit(f"axis calibration: tick labels are {x_offset:.1f}/{y_offset:.1f} pt from their gridlines")
    px = np.polyfit(vgrid, xv, 1)
    py = np.polyfit(hgrid, yv, 1)
    report = {
        "frame": (fx0, fx1, fy0, fy1),
        "x_labels": xv.tolist(), "y_labels": yv.tolist(), "label_offset_pt": max(x_offset, y_offset),
        "x_fit_residual_nm": float(np.max(np.abs(np.polyval(px, vgrid) - xv))),
        "y_fit_residual_qe": float(np.max(np.abs(np.polyval(py, hgrid) - yv))),
    }
    return (lambda x: np.polyval(px, x)), (lambda y: np.polyval(py, y)), report


def series_from_strokes(strokes, colours, to_wl, to_qe, frame, min_points):
    """Collect polyline vertices per series, snapped to the 10 nm data grid."""
    fx0, fx1, fy0, fy1 = frame
    out = defaultdict(dict)
    for col, pts in strokes:
        name = colours.get(col)
        if name is None:
            continue
        # the main polyline, plus the short clipped segment that ends on the frame's left edge
        clipped_start = (len(pts) == 2 and pts[0][0] < fx0 - 0.5 and abs(pts[1][0] - fx0) < 0.5
                         and all(fy0 - 1 <= y <= fy1 + 1 for _, y in pts))
        if len(pts) < min_points and not clipped_start:
            continue
        for x, y in pts:
            wl = float(to_wl(x))
            grid = round(wl / 10) * 10
            if abs(wl - grid) > 1.5:
                sys.exit(f"{name}: vertex at {wl:.2f} nm is off the 10 nm grid")
            out[name].setdefault(grid, []).append(float(to_qe(y)))
    result = {}
    for name, d in out.items():
        for grid, vals in d.items():
            if np.ptp(vals) > 1e-3:
                sys.exit(f"{name} {grid} nm: inconsistent vertices {vals}")
        result[name] = {g: float(np.mean(v)) for g, v in d.items()}
    return result


def kodak():
    pdf = os.path.join(ARGS.datasheets, KODAK_PDF)
    strokes, shapes, texts = parse(page_ops(pdf, KODAK_PAGE))
    to_wl, to_qe, cal = axis_calibration(strokes, texts, (0.502, 0.502, 0.502))
    lines = series_from_strokes(strokes, KODAK_SERIES, to_wl, to_qe, cal["frame"], 20)
    # markers (one per data point): fill colour identifies the series
    fx0, fx1, fy0, fy1 = cal["frame"]
    markers = defaultdict(dict)
    for fill, stroke, op, pts in shapes:
        name = KODAK_MARKERS.get(fill)
        if name is None or op != "B":
            continue
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
        if not (fx0 - 3 < cx < fx1 + 3 and fy0 - 3 < cy < fy1 + 3):
            continue  # legend
        wl = float(to_wl(cx))
        grid = round(wl / 10) * 10
        if abs(wl - grid) <= 1.5:
            markers[name][grid] = float(to_qe(cy))
    data, notes = {}, []
    for c in "rgb":
        line, mark = lines[c], markers[c]
        common = sorted(set(line) & set(mark))
        bias = float(np.mean([mark[w] - line[w] for w in common]))
        spread = float(np.max(np.abs([mark[w] - bias - line[w] for w in common])))
        filled = sorted(w for w in mark if w not in line)
        merged = dict(line)
        for w in filled:  # vertices Excel dropped on straight runs: use the marker centre
            merged[w] = mark[w] - bias
        data[c] = merged
        notes.append(f"Kodak {c}: {len(line)} line vertices, {len(mark)} markers; marker offset "
                     f"{bias:+.5f}, line-vs-marker max deviation {spread:.5f}; filled from markers: {filled}")
    return data, cal, notes


def truesense():
    pdf = os.path.join(ARGS.datasheets, TRUESENSE_PDF)
    strokes, _, texts = parse(page_ops(pdf, TRUESENSE_PAGE, TRUESENSE_FORM))
    to_wl, to_qe, cal = axis_calibration(strokes, texts, (0.502, 0.502, 0.502))
    return series_from_strokes(strokes, TRUESENSE_SERIES, to_wl, to_qe, cal["frame"], 30), cal


def main():
    global ARGS
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--datasheets", default=os.path.join(HERE, "datasheet"))
    ap.add_argument("--out", default=os.path.join(HERE, "data", "kai02150_qe.csv"))
    ap.add_argument("--check-png", help="write a datasheet-vs-CSV comparison image here")
    ARGS = ap.parse_args()

    kd, kcal, notes = kodak()
    ts, tcal = truesense()
    for name, cal in (("Kodak", kcal), ("Truesense", tcal)):
        print(f"{name} axes: x labels {cal['x_labels'][0]:g}-{cal['x_labels'][-1]:g} nm, "
              f"y labels {cal['y_labels'][0]:g}-{cal['y_labels'][-1]:g}; gridline fit residual "
              f"{cal['x_fit_residual_nm']:.2f} nm / {cal['y_fit_residual_qe']:.4f} QE; labels within "
              f"{cal['label_offset_pt']:.1f} pt of their gridlines")
    for n in notes:
        print(n)
    for c in "rgb":
        missing = [w for w in range(390, 1101, 10) if w not in kd[c]]
        if missing:
            sys.exit(f"Kodak {c}: missing {missing}")
        ws = range(390, 1101, 10)
        d = np.array([ts[c + "_mar"][w] - kd[c][w] for w in ws])
        ratio = np.array([ts[c + "_clear"][w] / ts[c + "_mar"][w] for w in range(400, 701, 10)
                          if ts[c + "_mar"][w] > 0.1])
        print(f"cross-check {c}: Truesense MAR - Kodak over 390-1100 nm: mean {d.mean():+.4f}, "
              f"max |diff| {np.abs(d).max():.4f}; clear/MAR ratio where QE>0.1: "
              f"{ratio.mean():.3f} +/- {ratio.std():.3f}")

    rows = []
    for w in OUT_WAVELENGTHS:
        if w < 390:
            vals = [ts[c + "_mar"][w] for c in "rgb"]
        else:
            vals = [kd[c][w] for c in "rgb"]
        rows.append((w, *vals))
    with open(ARGS.out, "w") as f:
        f.write("wavelength_nm,r,g,b\n")
        for w, r, g, b in rows:
            f.write(f"{w},{r:.4f},{g:.4f},{b:.4f}\n")
    print(f"wrote {ARGS.out} ({len(rows)} rows)")

    if ARGS.check_png:
        check_png(kd, kcal, ARGS.check_png)


def check_png(kd, kcal, out):
    """Datasheet graph (left), the CSV re-plotted (right), and the CSV drawn over the graph (bottom)."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from PIL import Image

    dpi = 400
    scratch = os.path.join(REPO, "pipeline", "build", "colour")
    os.makedirs(scratch, exist_ok=True)
    page_png = os.path.join(scratch, "kodak_p14.png")
    subprocess.run([tool_path(), "render", os.path.join(ARGS.datasheets, KODAK_PDF), str(KODAK_PAGE),
                    str(dpi), page_png], check=True, capture_output=True)
    page = Image.open(page_png).convert("RGB")
    fx0, fx1, fy0, fy1 = kcal["frame"]
    s = dpi / 72.0
    h = page.height
    crop = page.crop((int((fx0 - 40) * s), int(h - (fy1 + 15) * s), int((fx1 + 15) * s), int(h - (fy0 - 50) * s)))

    csv = np.loadtxt(ARGS.out, delimiter=",", skiprows=1)
    fig = plt.figure(figsize=(16, 13))
    ax1 = fig.add_axes([0.02, 0.50, 0.47, 0.45])
    ax1.imshow(crop)
    ax1.set_axis_off()
    ax1.set_title("Datasheet: Kodak KAI-02150 Rev 1.0 (2008), Figure 5, as printed")
    ax2 = fig.add_axes([0.56, 0.55, 0.42, 0.38])
    for i, (c, col) in enumerate((("r", "red"), ("g", "green"), ("b", "blue"))):
        ax2.plot(csv[:, 0], csv[:, i + 1], "o-", color=col, ms=3, lw=1, label=c.upper())
    ax2.set_xlim(400, 1100)
    ax2.set_ylim(0, 0.6)
    ax2.set_xticks(range(400, 1101, 50))
    ax2.grid(True, color="0.85")
    ax2.set_xlabel("Wavelength (nm)")
    ax2.set_ylabel("Absolute quantum efficiency")
    ax2.set_title("Our CSV (380-780 nm), same axes as the datasheet")
    ax2.legend()

    # overlay: datasheet pixels with the CSV points at the positions the calibration predicts
    ax3 = fig.add_axes([0.05, 0.04, 0.9, 0.40])
    big = page.crop((int((fx0 - 5) * s), int(h - (fy1 + 5) * s), int((fx0 + (fx1 - fx0) * 400 / 700 + 5) * s),
                     int(h - (fy0 - 5) * s)))
    wl_px = lambda w: ((fx0 + (w - 400) / 700 * (fx1 - fx0)) - (fx0 - 5)) * s
    qe_px = lambda q: ((fy1 + 5) - (fy0 + q / 0.6 * (fy1 - fy0))) * s
    ax3.imshow(big, aspect="auto")
    m = csv[:, 0] >= 390  # the graph's frame starts at 400 nm; 390 nm sits on its edge
    for i in range(3):
        ax3.plot(wl_px(csv[m, 0]), qe_px(csv[m, i + 1]), "x", color="black", ms=7, mew=1.2)
    ax3.set_axis_off()
    ax3.set_title("Overlay: CSV values (black x) drawn on the datasheet graph, 400-800 nm "
                  "(each x should sit in the middle of a datasheet marker)")
    fig.savefig(out, dpi=110)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
