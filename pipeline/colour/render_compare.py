#!/usr/bin/env python3
"""Render A-Cam dII frames with two colour profiles side by side.

Plain-language summary: every frame is developed twice with exactly the same settings (black
and white levels, the camera's white balance, demosaic, exposure, tone curve, sRGB output). The
only difference is the colour profile: A (left) is Ikonoskop's factory matrices from the DNG
header, B (right) is the profile built from the sensor's published data. Neutral greys come out
neutral in both by construction; differences show up in coloured objects (skin, foliage, sky).

A: ColorMatrix1/2 from the frame header, with CalibrationIlluminant1 = 20 (D55, 5500 K) and
   CalibrationIlluminant2 = 24 (ISO studio tungsten, 3200 K), interpolated per the DNG spec; no
   ForwardMatrix, so camera -> XYZ is the inverse ColorMatrix plus Bradford adaptation to D50.
B: ColorMatrix1/2 and ForwardMatrix1/2 from a DCP (build_profile.py), interpolated the same way.

Development (identical for A and B):
  * black level per CFA position from BlackLevel, white level from WhiteLevel;
  * half-resolution demosaic: each 2x2 GRBG cell becomes one RGB pixel (greens averaged);
  * white balance from AsShotNeutral; channels clipped at the white level after balance;
  * exposure: one gain per frame, computed from the white-balanced camera green channel only
    (median brought to 18 %, gain limited to 1x-16x), so it cannot differ between A and B;
  * XYZ (D50) -> linear sRGB (Bradford D50->D65), negative values clipped;
  * tone curve per channel: extended Reinhard x(1 + x/16)/(1 + x) (scene 4.0 -> display white),
    then the sRGB transfer function.

Usage: render_compare.py --profile-b DCP [--frames DNG ...] [--out-dir DIR] [--sheet PNG]
                         [--label-b TEXT]
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import acam_dng  # noqa: E402
import build_profile as bp  # noqa: E402
import dng_colour  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
DEFAULT_FRAMES = [
    os.path.expanduser("~/Desktop/AC000001/00000001.DNG"),
    os.path.expanduser("~/Desktop/AC000001/00000451.DNG"),
    os.path.join(REPO, "work/samples/ACAM102/AC102001/10201382.DNG"),
    os.path.join(REPO, "work/samples/ACAM102/AC102004/10207113.DNG"),
    os.path.join(REPO, "work/samples/ACAM102/AC102005/10207863.DNG"),
    os.path.join(REPO, "work/samples/ACAM102/AC102006/10208720.DNG"),
    os.path.join(REPO, "work/samples/ACAM102/AC102008/10213858.DNG"),
]
FACTORY_ILLUMINANTS = (20, 24)  # D55 and ISO studio tungsten, as Phase 4 will write them
XYZ_D65_TO_SRGB = np.array([[3.2404542, -1.5371385, -0.4985314],
                            [-0.9692660, 1.8760108, 0.0415560],
                            [0.0556434, -0.2040259, 1.0572252]])
D65_WHITE = np.array([0.95047, 1.0, 1.08883])


# ----------------------------------------------------------------------------- profiles

def factory_profile(frame):
    return dng_colour.Profile("A: factory matrices", frame.matrix(acam_dng.TAG_COLOR_MATRIX1),
                              frame.matrix(acam_dng.TAG_COLOR_MATRIX2), *FACTORY_ILLUMINANTS)


# ----------------------------------------------------------------------------- development

def srgb_encode(x):
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(np.maximum(x, 0.0031308), 1 / 2.4) - 0.055)


def tone(x, white=4.0):
    return x * (1 + x / (white * white)) / (1 + x)


def develop(camera_rgb, neutral, profile, gain):
    """Camera RGB (black-subtracted, 1.0 = white level) -> 8-bit sRGB; plus diagnostics."""
    m, temperature, g = profile.camera_to_xyz_d50(neutral)
    # white balance + highlight clip (shared), then the profile's matrix on balanced values
    balanced = np.minimum(camera_rgb / neutral, 1.0) * gain
    to_srgb = XYZ_D65_TO_SRGB @ bp.bradford(dng_colour.D50_DNG, D65_WHITE) @ m @ np.diag(neutral)
    lin = np.maximum(balanced @ to_srgb.T, 0.0)
    out = srgb_encode(np.clip(tone(lin), 0, 1))
    return (out * 255 + 0.5).astype(np.uint8), temperature, g, to_srgb


def exposure_gain(camera_rgb, neutral):
    green = np.minimum(camera_rgb[..., 1] / neutral[1], 1.0)
    return float(np.clip(0.18 / max(np.median(green), 1e-6), 1.0, 16.0))


# ----------------------------------------------------------------------------- layout

def font(size):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def labelled(img, text, size=22):
    d = ImageDraw.Draw(img)
    f = font(size)
    box = d.textbbox((0, 0), text, font=f)
    d.rectangle((0, 0, box[2] + 16, box[3] + 12), fill=(0, 0, 0))
    d.text((8, 5), text, fill=(255, 255, 255), font=f)
    return img


def pair_image(a, b, label_a, label_b, caption):
    w, h = a.width, a.height
    gap, top = 8, 34
    out = Image.new("RGB", (2 * w + gap, h + top), (255, 255, 255))
    d = ImageDraw.Draw(out)
    d.text((6, 6), caption, fill=(0, 0, 0), font=font(20))
    out.paste(labelled(a, label_a), (0, top))
    out.paste(labelled(b, label_b), (w + gap, top))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--profile-b", default=os.path.join(HERE, "profiles", "kai02150-ir650", "kai02150-ir650.dcp"))
    ap.add_argument("--label-b", default=None)
    ap.add_argument("--frames", nargs="+", default=DEFAULT_FRAMES)
    ap.add_argument("--out-dir", default=os.path.join(REPO, "work", "phase5", "frames"))
    ap.add_argument("--sheet", default=os.path.join(REPO, "work", "phase5", "compare_sheet.png"))
    ap.add_argument("--sheet-width", type=int, default=1600, help="width of the sheet in pixels")
    args = ap.parse_args()

    tags = bp.read_dcp(args.profile_b)
    label_b = args.label_b or f"B: {tags.get(0xC6F8, os.path.basename(args.profile_b))}"
    profile_b = dng_colour.Profile.from_dcp(args.profile_b, label_b)
    os.makedirs(args.out_dir, exist_ok=True)
    rows = []
    for path in args.frames:
        frame = acam_dng.Frame(path)
        cam = frame.camera_rgb_half()
        neutral = frame.as_shot_neutral
        gain = exposure_gain(cam, neutral)
        profile_a = factory_profile(frame)
        img_a, t_a, g_a, m_a = develop(cam, neutral, profile_a, gain)
        img_b, t_b, g_b, m_b = develop(cam, neutral, profile_b, gain)
        name = f"{os.path.basename(os.path.dirname(path))}_{os.path.splitext(os.path.basename(path))[0]}"
        caption = (f"{name}   exposure x{gain:.2f}   AsShotNeutral {np.round(neutral, 4).tolist()}   "
                   f"white read as: A {t_a:.0f} K, B {t_b:.0f} K")
        pair = pair_image(Image.fromarray(img_a), Image.fromarray(img_b), profile_a.label, profile_b.label, caption)
        pair.save(os.path.join(args.out_dir, name + ".png"))
        rows.append(pair)
        print(f"{name}: gain {gain:.2f}; A white {t_a:.0f} K (weight CM1 {g_a:.2f}); "
              f"B white {t_b:.0f} K (weight A-matrix {g_b:.2f})")
        print("  A cam->sRGB (balanced) " + np.array2string(m_a, precision=3).replace("\n", ""))
        print("  B cam->sRGB (balanced) " + np.array2string(m_b, precision=3).replace("\n", ""))

    scale = args.sheet_width / rows[0].width
    rows = [r.resize((args.sheet_width, int(r.height * scale)), Image.LANCZOS) for r in rows]
    title_h = 50
    sheet = Image.new("RGB", (args.sheet_width, title_h + sum(r.height for r in rows)), (255, 255, 255))
    d = ImageDraw.Draw(sheet)
    d.text((10, 12), f"LEFT = A: factory matrices (D55 / 3200 K)    RIGHT = {label_b}",
           fill=(0, 0, 0), font=font(24))
    y = title_h
    for r in rows:
        sheet.paste(r, (0, y))
        y += r.height
    sheet.save(args.sheet)
    print(f"wrote {args.sheet} and {len(rows)} frames in {args.out_dir}")


if __name__ == "__main__":
    main()
