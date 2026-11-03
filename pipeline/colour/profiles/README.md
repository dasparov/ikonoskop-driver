# A-Cam dII colour profiles

**In short:** there are three folders, one per colour profile candidate. You choose one, and
that folder holds everything needed to use it:

* in Adobe Camera Raw or Lightroom (the `.dcp` file);
* in the clean DNG files (`profile.json`, read by the `acam` pipeline);
* in ACES and DaVinci Resolve or other OpenColorIO programs (the `.ctl` files and `config.ocio`).

The folders all have the same layout, so applying a choice means using that folder.
The scripts regenerate these files; do not edit them by hand.

| Folder | Candidate | What it is |
|---|---|---|
| `factory/` | **A** | Ikonoskop's own matrices, as stored in every DNG the camera writes. Matrix 1 is for daylight (D55, 5500 K), matrix 2 for studio tungsten (3200 K). |
| `kai02150-ir650/` | **B, version 1** | Built from the published sensor curves, assuming an infrared-cut filter at 650 nm. Matrix 1 is for tungsten (Standard A), matrix 2 for daylight (D65). |
| `kai02150-ir665/` | **B, version 2** | The same, with the filter at 665 nm (tuned once; see `work/phase5/findings.md`). |

## The files in each folder

| File | What it is for |
|---|---|
| `profile.json` | The colour matrices as plain numbers, for the `acam` pipeline to write into the clean DNGs. Each value has 4 decimals; it is stored in the DNG as a fraction over 10000. The two `calibrationIlluminant` numbers are the standard EXIF light codes: 17 = tungsten (Standard A), 20 = D55 daylight, 21 = D65 daylight, 24 = studio tungsten 3200 K. The factory profile has no ForwardMatrix (`null`). |
| `<id>.dcp` | Adobe DNG Camera Profile for Camera Raw and Lightroom. It contains the same numbers as `profile.json`. |
| `IDT.Ikonoskop.ACamdII.<id>.<light>.ctl` | ACES Input Transform (CTL language), one per light the camera was white-balanced for. **Factory:** `D55` and `3200K`. **Sensor-data profiles:** `A` (tungsten), `D65` and `D55` (daylight). The transform converts camera colours to ACES2065-1. |
| `idt.json` | The same ACES matrices as plain numbers, with every intermediate step: camera neutral, colour temperature, blend weight, the matrix to XYZ (D50), and the matrix to ACES. |
| `config.ocio` | OpenColorIO v2 configuration. It contains the camera colour spaces (one per light), ACES2065-1, ACEScg, ACEScct, and two screens: sRGB and Rec.709 (Rec.1886). Each screen has an "ACES 1.0 - SDR Video" view and an "Un-tone-mapped" view. |
| `fit.json` | Sensor-data profiles only: the full fit results, including the colour errors per reference patch. |

### What the camera transforms expect

The camera colour spaces and IDTs take linear camera RGB in this state:

* black level subtracted;
* scaled so that 1.0 is the white level (4095);
* demosaiced;
* white balanced, i.e. each channel divided by the camera neutral. The neutral is listed in the
  file; for footage, use the clip's AsShotNeutral.

Pick the file whose light is closest to the scene's lighting: **D55** for daylight,
**3200K / A** for tungsten. A neutral grey always comes out neutral. Brightness is unchanged:
white-balanced 1.0 becomes ACES 1.0, so set exposure while grading.

**How the matrices are derived (DNG specification + ACES):**

1. Find the colour temperature of the chosen light.
2. Blend matrix 1 and matrix 2 according to that temperature.
3. Convert to XYZ with a D50 white: through the ForwardMatrix if the profile has one,
   otherwise through the inverse ColorMatrix plus a Bradford white adaptation.
4. Bradford-adapt to the ACES white.
5. Convert to the ACES AP0 primaries.

## Loading the DCP in Lightroom or Adobe Camera Raw (Mac)

1. Quit Lightroom and Photoshop.
2. Copy the `.dcp` file into
   `~/Library/Application Support/Adobe/CameraRaw/CameraProfiles/`
   (in Finder: Go → Go to Folder…, paste the path; create the folder if it does not exist).
3. Start Lightroom and open an A-Cam DNG. In the Develop module, open the **Profile** browser.
   The profile appears under its name, for example "A-Cam dII KAI-02150 sensor data (IR cut 665 nm)".
4. The profile is only offered for files whose camera model is **"Ikonoskop A-CAM"**, which is
   what the camera writes into every DNG (the UniqueCameraModel tag).

## Using the OCIO config in DaVinci Resolve

* **Raw DNG clips in a Resolve colour-managed or ACES project:** Resolve reads the matrices
  that `acam clean` writes into the clean DNGs. Pick the candidate there; no extra file is
  needed in Resolve.
* **Footage that is already linear camera RGB** (as described above), and **other OCIO
  programs** such as Nuke, Blender, or the pipeline's own ProRes export: use `config.ocio`.
  * In Resolve, add the effect **Resolve FX → OCIO Color Space** to a node.
  * Set **Config Source** to *File*, **Browse** to this folder's `config.ocio`.
  * Set **Source** to "A-Cam dII linear (…, D55 white balance)" (or the tungsten one), and
    **Output** to *ACEScct* for grading or *ACES2065-1* for interchange.
  * *[Not checked here: the exact menu names depend on the Resolve version, and the OCIO
    effects may require the paid Resolve Studio.]*
  * Other OCIO programs: set the `OCIO` environment variable to the config's path, or choose
    it in the program's colour-management settings.
* **ACES `.ctl` files:** these are for ACES tools that run CTL, such as `ctlrender`. Resolve
  does not load `.ctl` files directly; its custom ACES input transforms use the DCTL format
  instead. The matrices to put into a DCTL are the ones in `idt.json`.

## Regenerating

```
P=/Users/kapil/anaconda3/bin/python3
$P pipeline/colour/build_profile.py                      # kai02150-ir650/<id>.dcp + fit.json
$P pipeline/colour/build_profile.py --ir-cutoff 665      # kai02150-ir665/
$P pipeline/colour/export_candidates.py                  # all three folders: profile.json, factory.dcp, IDTs, idt.json, config.ocio
work/venv-ocio/bin/python pipeline/colour/tools/check_ocio.py   # validation with PyOpenColorIO
```
