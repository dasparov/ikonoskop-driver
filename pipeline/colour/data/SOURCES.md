# Colour data: sources and licences

**In short:** these CSV files are the inputs of `build_profile.py`. One file comes from the camera
sensor's datasheet (how strongly the sensor responds to each colour of light). The rest are
standard international colour tables: how the human eye responds to colour, what standard lights
look like, and the colours of real objects. Each one is listed below with its origin and licence.
All files: first column `wavelength_nm`, one column per curve or colour sample, comma-separated.

| File | What it is | Source | Licence |
|---|---|---|---|
| `kai02150_qe.csv` | KAI-02150 colour (Bayer) sensor quantum efficiency, R G B, 380–780 nm in 10 nm steps, absolute (0.43 = 43 %) | 390–780 nm: Kodak *KAI-02150 Device Performance Specification* Rev 1.0, MTD/PS-1066, 27 Oct 2008, p. 14, Figure 5 "Color (Bayer RGB) with Microlens", measured with AR-coated (MAR) cover glass. 380 nm: Truesense Imaging *KAI-02150 Device Performance Specification* Rev 2.0, PS-0007, 16 Nov 2012, p. 17, Figure 8, "MAR" series (the Kodak graph starts at 390 nm). Extracted by `digitise_qe.py` from the vector data in the PDFs. | Facts read from the manufacturer's public datasheet. The PDFs are not redistributed (git ignores `datasheet/`). |
| `cie1931_2deg_cmf.csv` | CIE 1931 2° standard observer colour-matching functions x̄ ȳ z̄, 380–780 nm in 5 nm steps (every 5th row of the 1 nm table, unchanged) | CIE, *CIE 1931 colour-matching functions, 2 degree observer* (data set `CIE_xyz_1931_2deg.csv`, DOI 10.25039/CIE.DS.xvudnb9b), https://files.cie.co.at/Publications-datasets/CIE_xyz_1931_2deg.csv | CC BY-SA 4.0 (CIE). This subset is shared under the same licence. |
| `cie_illuminants.csv` | Relative spectral power of CIE standard illuminants A (tungsten), D65 (daylight) and D50, 380–780 nm in 5 nm steps | CIE data sets `CIE_std_illum_A_1nm.csv`, `CIE_std_illum_D65.csv` (DOI 10.25039/CIE.DS.hjfjmt59), `CIE_std_illum_D50.csv`, https://files.cie.co.at/Publications-datasets/ (original source ISO/CIE 11664-2:2022) | CC BY-SA 4.0 (CIE). This subset is shared under the same licence. |
| `colorchecker24_iso17321.csv` | Spectral reflectance of the 24 patches of the ColorChecker Classic chart, 380–780 nm in 5 nm steps | N. Ohta (1997), *The basis of color reproduction engineering*; identical to the data in ISO 17321-1:2012 (camera colour characterisation). Taken from colour-science `colour/characterisation/datasets/colour_checkers/sds.py`, `DATA_COLORCHECKER_N_OHTA` (https://github.com/colour-science/colour) | colour-science: BSD-3-Clause (Copyright 2013 Colour Developers). |
| `cie224_2017_ces99.csv` | Spectral reflectance of the 99 colour evaluation samples (CES) of CIE 224:2017 (colour fidelity index): natural and man-made objects including skin, foliage, flowers, fabrics, paints; 380–780 nm in 5 nm steps | CIE 224:2017 *Colour Fidelity Index for accurate scientific use*, supplementary data. Taken from colour-science `colour/quality/datasets/tcs_cfi2017_5_nm.csv.gz` | colour-science: BSD-3-Clause; data from the CIE publication. |
| `pmc30_luo2024.csv` | The 30 "preferred memory colour" samples (four skin tones, sky, grass, fruit, neutrals ...), 400–700 nm in 10 nm steps. Used only to check the profile, not to build it | M. R. Luo (2024), *The new preferred memory color (PMC) chart*, Color Research & Application, doi:10.1002/col.22940. Taken from colour-science `sds.py`, `DATA_PMC` (values / 100) | colour-science: BSD-3-Clause. |

`tools/prepare_reference_data.py` re-downloads everything except the QE data and rewrites these
files; `digitise_qe.py` rewrites `kai02150_qe.csv` from the datasheet PDFs.

## Datasheet PDFs (kept out of git, in `datasheet/`)

| File | Document | Downloaded from | SHA-256 |
|---|---|---|---|
| `KAI-02150_kodak_MTD-PS-1066_rev1.pdf` | Kodak, Rev 1.0, MTD/PS-1066, 27 Oct 2008 (74 pages) | https://www.1stvision.com/cameras/sensor_specs/KAI-02150LongSpec.pdf | `d6d79c7be5351a68bbb6da4fccad9d431076349ea23f35a04404d5bf5058ce97` |
| `KAI-02150_truesense_PS-0007_rev2.pdf` | Truesense Imaging, Rev 2.0, PS-0007, 16 Nov 2012 (43 pages) | https://machinevisionstore.com/content/downloads/onsemi/ccd-02150.pdf | `c239ff9f6a0a8a6b207b77c59b9639d2eb1d1d659ccdaa28b08236dba741950c` |
| `kai-02150-d_onsemi_rev6.pdf` | ON Semiconductor, KAI-02150/D Rev 6, April 2015 (current version; colour graphs are raster images, so not used for numbers) | https://www.sensor360.org/files/uploads/pdf/4937e2699917b3988f441c1b396a3bc4.pdf (onsemi.com refuses scripted downloads) | `df9f48939dbf59c55072b30e76aeae393862519448634055dd6bfc441fbc53cd` |
