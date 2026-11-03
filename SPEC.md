# A-Cam dII Pipeline — Full Project Spec

Paste this whole file into Claude Code inside the `ikonoskop-driver` repo. Then save it in the repo as `SPEC.md` and use it as the plan for the whole project.

---

## 1. What we are building

The Ikonoskop A-Cam dII is a discontinued Super 16 digital cinema camera with a CCD sensor. It records 12-bit raw CinemaDNG to proprietary Ikonoskop memory cards.

This repo already has a **working, read-only kernel driver**. It mounts the card as a read-only FAT32 volume on Apple Silicon Macs, proven on macOS 13.3.1. See `AUDIT-2026-11-03.md` for the full audit.

We now build everything **after** the card is mounted: a Mac tool that turns a card into verified, clean, Resolve-ready clips with sound and correct colour.

**Final result:** put in a card, press one button, and get:
- verified copies of every take, with checksums and a report
- audio as WAV files, in sync with the picture (if the camera recorded it)
- corrected, losslessly compressed DNG files that open correctly in DaVinci Resolve
- correct colour from a proper camera profile
- optional ProRes 4444 XQ files with sound, ready to edit

## 2. How to work with me

- I am not a programmer. Explain decisions and results in plain language.
- Work **one phase at a time**, in the order below.
- At the end of each phase, **stop**. Show me the test results and what changed, and wait for my OK before the next phase.
- If something in this spec turns out to be wrong, tell me and propose a fix. Don't silently work around it.
- Keep `SPEC.md` up to date: tick off finished items and record discoveries (for example, where the audio is).
- Commit after each working step, with clear commit messages. Never push without asking me.

## 3. Rules (non-negotiable)

1. **Never write to the card or the reader hardware.** The driver is read-only by design; keep it that way.
2. **Do not change the kernel driver** (`kext/`, `core/`) unless a phase explicitly says so, and then only after asking me.
3. **All new features are userspace code** in a new `pipeline/` folder. No new kernel code for features.
4. **Ask me before any `sudo` command**, or anything that loads, unloads or reinstalls the driver.
5. **Never overwrite or delete existing files on my disks.** Always write output to a new folder I choose.
6. **Never commit or publish Ikonoskop material.** `reference/`, the decompile, the original binaries, `AUDIT-*.md` and `HANDOVER.md` stay private.
7. The footage on the current card is **not important**. Use it freely as test data, read-only.

## 4. Known facts (from the audit)

| Fact | Value |
|---|---|
| Frame size | 2048 × 1092, 12-bit, CFA pattern GRBG |
| Format | Uncompressed DNG 1.2, about 3.35 MB of image data per frame |
| Header | 4 KiB generated header + raw flash data copied byte for byte |
| Padding | 8,192 bytes of 0xFF after each frame's image data *(wrong: the block holds data, probably the audio; see Phase 0 findings)* |
| Per-frame metadata | SMPTE timecode, frame rate (24/1), ReelName |
| Take table | Read via `ikctl eeprom` |
| Current card | 20 takes, 9,359 frames *(card ACAM 000; the card in the reader on 2026-11-03 is ACAM 102: 9 takes, 14,640 frames)* |
| DNG tag problems | No Make or Model; WhiteLevel listed twice; CalibrationIlluminant values 38268 and 36168 are invalid; no BaselineExposure *(the two illuminant values encode 5500 K and 3400 K; see Phase 0 findings)* |
| Audio | Not exposed by the old or new driver. The AUDIO folder is created empty. Location unknown. *(probable location found; see Phase 0 findings)* |
| Corruption behaviour | A corrupt EEPROM entry makes the driver serve flash page 0 as that frame, with only a kernel log line (`core/ik_core.cpp:313-331`) |

## 5. Architecture

```
Card ──► kernel driver (done) ──► mounted read-only volume
                                        │
                                        ▼
                           pipeline/ (userspace, new)
             ┌────────────┬────────────┼─────────────┬──────────────┐
             ▼            ▼            ▼             ▼              ▼
       verified copy    report      audio WAV    clean DNGs    ProRes (v2)
       + MHL                                     (+ colour)
```

- **Language:** Swift for the pipeline and the later app. Use proven open-source libraries where they fit (for example dnglab for lossless DNG, OpenColorIO for colour), and tell me before adding any dependency.
- **Shape:** a command-line tool first (`acam`), with subcommands per feature. The Mac app in Phase 6 is a thin layer over the same code.
- **Output folder layout** (per card):

```
<destination>/<card name>/
   REPORT.md
   <take>/
      frames/        (verified original DNGs)
      clean/         (corrected, compressed DNGs)
      <take>_Audio.wav
      <take>.mhl
   prores/           (optional)
```

---

## 6. Phases

Each phase ends with a **gate**: tests that must pass before moving on.

### Phase 0 — Housekeeping

- [x] Add `AUDIT-*.md` and `HANDOVER.md` to `.gitignore`.
- [x] Move `reference/` and any private history bundle **outside** the repo folder, and update anything that points to them (for example the optional Unicorn test). Ask me where to move them.
- [x] Pin `unicorn==2.1.4` and record the SDK/Command Line Tools version used for builds.
- [x] Licensing: replace the 2,358 bytes in `core/ik_dng_templates.inc` (copied from the original Ikonoskop binary) with code that generates the same three DNG headers at build time. The existing diff tests must prove they are byte-identical. Correct the README sentence "It contains no Ikonoskop software" to be accurate. *(This is the one allowed change near `core/`. Ask me before starting it.)*
- [x] Create the `pipeline/` folder and the `acam` command-line skeleton.

**Gate:** `make check` passes; `git ls-files` shows no Ikonoskop material; `acam --help` runs.

#### Phase 0 results (2026-11-03): gate passed, waiting for approval

- Private material is in `~/Documents/ikonoskop-private/` (`reference/` and `ikonoskop-driver-private-history.bundle`). `test/Makefile` looks for the original driver there.
- Toolchain, recorded in the README: Command Line Tools 14.3 (Apple clang 14.0.3, macOS SDK 13.3, Swift 5.8). `unicorn==2.1.4` is pinned in `test/Makefile`.
- The three DNG headers are now built by `core/ik_dng_templates.h` from a readable table of their tags, instead of copied bytes. They are byte-identical to the original driver's: `test/harness.cpp` checks their SHA-256 fingerprints on every run, and the differential test compares every header the driver serves (PASS).
- `acam` is built with the Swift compiler directly (`make pipeline` → `pipeline/build/acam`). Swift's package manager (`swift build`) fails on this Mac because only the Command Line Tools are installed (known bug: swiftlang/swift-package-manager#7480). Installing Xcode would fix it; decision pending.
- Gate evidence: `make check` exit 0 (log: `work/phase0/make-check.log`); `git ls-files` lists no Ikonoskop material; `acam --help` runs (exit 0).

**Findings that affect later phases**

1. **The 8 KiB after each frame's image is not padding; it is probably the audio.** The original driver's header already labels it `DNGPrivateData` (file offset 0x334000, 8,192 bytes). In all 623 frames of take AC000001 (card 000), the block holds small signed 16-bit values centred on zero, then 0xFF fill: 8,000 bytes of data in 613 frames, 8,003–8,004 in 6 and 8,040–8,169 in 4. 8,000 bytes is exactly one frame of 48 kHz, 2-channel, 16-bit audio at 24 fps (2,000 samples per channel). To be confirmed in Phase 2 with the clap take. Consequences: Phase 2 probably needs no new driver code, and Phase 4 must not crop this block, at least not before the audio is extracted and verified.
2. **The "invalid" illuminant values encode colour temperatures.** 38268 = 0x8000 + 5500 and 36168 = 0x8000 + 3400, so ColorMatrix1 belongs to 5500 K (daylight-like) and ColorMatrix2 to 3400 K (tungsten-like). That is the reverse of Adobe's usual order (1 = Standard A, 2 = D65), so Phase 4 must tag 1 as daylight and 2 as tungsten. The closest standard codes are 20 (D55, 5500 K) and 24 (ISO studio tungsten, 3200 K); 21 (D65) and 17 (Standard A, 2856 K) are further off. To decide in Phase 4.
3. **The card now in the reader is ACAM 102** (9 takes, 14,640 frames), not the audited ACAM 000 (20 takes, 9,359 frames). Phase 1's gate mentions "all 20 takes"; it should say every take of the test card.

### Phase 1 — Verified offload

`acam offload --source /Volumes/<card> --dest <folder>`

1. Copy every take into `<take>/frames/`.
2. Read each source file a second time and compare xxHash64 of source and copy. A mismatch fails that take loudly. Never fail silently.
3. Write an ASC MHL manifest per take.
4. Compare takes and frame counts with the take table from `ikctl eeprom`. Report anything missing or extra.
5. Watch the kernel log during the copy for the driver's `corrupted data` message. Mark any affected take FAILED.
6. Write `REPORT.md`: card summary, then per take: frame count, duration, first and last timecode, checksum status, warnings. End with **ALL VERIFIED** or **PROBLEMS FOUND**.
7. Check that the first frame of every take is different from every other take. A copy made on 2026-11-01 had take 1's frames in every take, so this check guards against that bug returning.

**Gate:** tests with fixture files, including a deliberately corrupted copy that must be caught; a real run on the current card shows ALL VERIFIED; first frames of all 20 takes are distinct.

### Phase 2 — Find the audio

The camera is documented as recording two channels of 48 kHz uncompressed audio, but no driver has ever exposed it. This phase is investigation, not building.

1. I will record a new short take with a clear clap or tone going into the camera's audio input. Tell me when you need it.
2. Using the debug tools that already exist (`ikctl sectors`, `ikctl frame`, the EEPROM take table), map which flash areas belong to frames, and look for data **outside** the frame map that changes with the new take.
3. Look for audio-like patterns: 16- or 24-bit PCM, about 2,000 samples per channel per frame at 24 fps.
4. Check `DNGPrivateData` in the headers for any pointer to audio.
5. Report what you found: where the audio is and its format, or evidence that it was never recorded.

Reading flash areas the driver doesn't normally read may need a new **read-only** debug selector in the driver. If so, stop and ask me first, and explain exactly what it reads.

**Gate:** a written finding in `SPEC.md` with evidence. If audio exists, a raw dump of the clap take's audio that plays the clap.

### Phase 3 — Audio export (only if Phase 2 found audio)

`acam audio`, also part of `acam offload`

- Extract each take's audio to `<take>_Audio.wav`: 48 kHz, original bit depth, stereo.
- Embed the starting timecode (BWF `bext` chunk) so editing software lines it up automatically.

**Gate:** the clap lines up with the clap frame within one frame; over a full take, drift stays under one frame at the end.

### Phase 4 — Clean DNGs

`acam clean`, also part of `acam offload`

Write corrected copies into `<take>/clean/`. Never modify the verified originals.

- Add `Make` = "Ikonoskop" and `Model` = "A-Cam dII".
- Remove the duplicate `WhiteLevel`, keeping 4095.
- Replace the invalid `CalibrationIlluminant` values with valid ones. Explain your choice to me; for now use 17 (Standard A, tungsten) and 21 (D65, daylight) if the matrices fit that pattern.
- Add `BaselineExposure` = 0.0.
- Keep timecode, frame rate and ReelName.
- Crop the 8 KiB 0xFF padding so the file ends at the image data.
- Compress losslessly (lossless JPEG, as Adobe DNG Converter does).

**Gate:** every clean frame decodes to exactly the same pixel values as its original (automated check over a full take); files are smaller (report the saving); a clean take opens in DaVinci Resolve as a clip, with the camera named correctly. I will check Resolve myself.

### Phase 5 — Colour from sensor data (no chart)

*(Revised 2026-11-03: there are no colour chart shots, so the profile is built from the published spectral response curves of the Kodak KAI-02150 sensor, colour/Bayer version.)*

**Goal:** a camera profile built from the sensor's published spectral curves, compared side by side with Ikonoskop's factory matrices. I pick the one that looks more accurate.

#### Steps

1. **Get the sensor data.** Find the Kodak / ON Semiconductor KAI-02150 datasheet (colour version). If you can't download it, tell me and I will download the PDF and put it in the repo. Keep the PDF out of git (add it to `.gitignore`).
2. **Extract the curves.** Turn the red, green and blue quantum-efficiency curves into numbers, 380–780 nm in 5 or 10 nm steps. If the datasheet only has a graph, digitise it carefully. Save the result as a CSV, plot it, and show me the plot next to the datasheet graph so I can check they match.
3. **Model what we don't know.** The camera has an IR-cut filter and an optical low-pass filter in front of the sensor. Their exact data is unknown.
   - Model the IR-cut filter as a typical camera IR-cut filter. Make its cut-off wavelength a single adjustable setting, and write down the value and the reason.
   - Treat the low-pass filter as spectrally neutral.
   - Record every assumption in `SPEC.md`.
4. **Build the profile.** Use dcamprof (or equivalent open-source tool; tell me before adding it) to build a dual-illuminant camera profile (DCP) from the curves: Standard A (tungsten) and D65 (daylight), using a standard set of reference colour spectra.
5. **Compare.** Render the same frames from my existing footage two ways, with identical settings:
   - **A:** Ikonoskop's factory matrices (with the illuminant tags fixed in Phase 4)
   - **B:** the new sensor-data profile

   Choose 6–8 frames that include skin, foliage, sky and neutral greys or whites. Make a side-by-side comparison sheet (A on the left, B on the right, labelled), and show me.
6. **Tune once if needed.** If B looks off in a consistent way (for example too green or too warm), adjust the IR-cut setting once, rebuild, and show me the comparison again. Don't keep tweaking without asking.
7. **Apply my choice.** When I pick A or B:
   - write the chosen matrices into the clean DNGs
   - build the ACES input transform (IDT) and OpenColorIO config from the same profile
   - save the DCP file in the output so I can also load it in Adobe Camera Raw or Lightroom

#### Gate

- I have approved one profile from the comparison sheet.
- Neutral greys and whites in the test frames render neutral when white-balanced.
- Clean DNGs with the chosen profile open in Resolve with the improved colour.

#### Later upgrade (not now)

If I get a colour chart later, add a chart-based profile as option C in the same comparison. Nothing else needs to change.

### Phase 6 — ProRes export and Mac app

- `acam prores`: render clean DNGs to ProRes 4444 XQ using Apple's AVFoundation, with the WAV audio muxed in and timecode set. Offer two looks: log (ACEScct) for grading, and a simple Rec.709 preview.
- A small SwiftUI Mac app over the same code: shows the mounted card and its takes, lets me choose a destination and outputs, has one **Process card** button, a progress bar, and shows the report at the end.

**Gate:** one card goes to verified copies, clean DNGs, WAVs and ProRes in one click; the ProRes opens in Resolve and Final Cut with sound in sync.

### Phase 7 — Future-proofing (later, separate decision)

- Test the driver on a newer macOS when I have a spare Mac or partition, using the checklist in `HANDOVER.md`.
- Evaluate porting the driver to PCIDriverKit (a dext). That would remove the need for Reduced Security and kext approval. Write up the effort and the entitlement Apple requires, then stop and let me decide.

---

## 7. Out of scope

- Neural denoising, AI highlight repair, AI upscaling
- Windows and Linux
- DNxHR export
- Anything that writes to the card

## 8. Start now

Begin with Phase 0. Before changing anything, read `AUDIT-2026-11-03.md`, `HANDOVER.md` and the README. Then tell me in a few plain sentences what you will do in Phase 0, and wait for my OK.
