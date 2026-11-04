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
| Padding | 8,192 bytes of 0xFF after each frame's image data *(wrong: the block is the audio; see Phase 2)* |
| Per-frame metadata | SMPTE timecode, frame rate (24/1), ReelName |
| Take table | Read via `ikctl eeprom` |
| Current card | 20 takes, 9,359 frames *(card ACAM 000; the card in the reader on 2026-11-03 is ACAM 102: 9 takes, 14,640 frames)* |
| DNG tag problems | No Make or Model; WhiteLevel listed twice; CalibrationIlluminant values 38268 and 36168 are invalid; no BaselineExposure *(the two illuminant values encode 5500 K and 3400 K; see Phase 0 findings. Also, the greens' BlackLevel is 10 too low: green shadows; see Phase 5, black level)* |
| Audio | Not exposed by the old or new driver. The AUDIO folder is created empty. Location unknown. *(found: inside every frame; see Phase 2)* |
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

**Gate:** tests with fixture files, including a deliberately corrupted copy that must be caught; a real run on the current card shows ALL VERIFIED; first frames of every take on the test card are distinct. *(Was "all 20 takes": the card in the reader now is ACAM 102 with 9 takes.)*

#### Phase 1 results (2026-11-03)

- [x] Steps 1–7 are built: `acam offload` (`pipeline/Sources/ACamKit/`: `Offload.swift`, `CardJob.swift`, `ASCMHL.swift`, `Report.swift`).
- Verification: each file is hashed with xxHash64 (the official xxHash 0.8.3) while it is copied, read a second time from the card after all takes are copied, and read back from the destination. These reads bypass the macOS file cache. All three must agree.
- ASC MHL: written in the standard ASC MHL v2 layout, `<take>/ascmhl/0001_<take>_<time>Z.mhl` plus `ascmhl_chain.xml`, instead of one `<take>.mhl` (that name belongs to the older MHL v1 format). The WAV and the clean DNGs are added as generations 2 and 3. The reference `ascmhl` tool (1.2) verifies these folders and catches a changed byte.
- Take table: reading the EEPROM needs `sudo` (the driver lets only root do it): `--eeprom <file>` or `--read-eeprom`; the app asks for the password with the standard macOS dialog. Without it, the report says PROBLEMS FOUND, because the check was not done.
- **Take table history (ACAM 102's EEPROM, read 2026-11-04):** the 9 listed takes match the card's volume exactly (14,640 frames). After them comes an empty entry, then 69 more valid entries from earlier recordings on this card (8 Oct 2015 to 27 Nov 2019), each earlier list ending in its own empty entry. So it looks like when the card is cleared, the camera starts the list again at entry 0 and at the start of the flash, and leaves the rest of the old list in place. The driver shows only the entries before the first empty one, which is right. The offload reports older entries like these as a warning, and a newer entry after the gap (a take the driver would hide) as a problem.
- **Older recordings may still be on the card (not checked):** no newer recording has reached the flash of 4 takes from 27 Nov 2019 (entries 13–16, 4,437 frames) and 7 takes from 5 Oct 2019 (entries 63–69, 3,490 frames), about 5.5 minutes at 24 fps, plus the ends of 2 more. If the camera doesn't wipe the flash when it clears the card, they can still be read with `ikctl frame` (needs the password). The next take recorded on this card starts at flash block 1,178 (of 2,394) and records over the 27 Nov 2019 takes first.
- Kernel log: read with `log show` after the copy (no root needed). Errors of the driver session that served the card mark the affected take, or the card, FAILED. A driver restart during the copy (reader reconnected) is a problem too.
- Tests (`make pipeline-check`): fixture cards built from the camera's real header templates. A corrupted copy, an unstable second read, duplicate first frames, take-table differences, driver-log errors and an existing destination are all caught.
- **Real card, read errors:** on ACAM 102 (take AC102008, 420 frames) the card returns slightly different data for about one frame in six when it is read twice. That's about 2 random bytes per frame, flipping both ways, never at the same place twice: random read errors of the flash or the reader, not data stored on the card. So verification now reads such a frame again until two reads match exactly, and keeps that version; a copy made from a bad read is replaced. Every re-read comes from the flash, not from the driver's 8-frame cache. Result: 420 of 420 frames verified, 72 read again, 163 MB/s. A frame fails only if 8 reads never match twice. [INFERENCE] Copies made by simply dragging in Finder read each frame once, so they can carry these errors; the Desktop copies from 2026-11-01 probably contain some. Whether the errors come from the card's flash, the reader or the Thunderbolt adapter is unknown; a test with another adapter would tell.
- [ ] Full run on the test card (all 9 takes, to `/Volumes/IDFC/acam-pipeline-test`, with the EEPROM dump). It doesn't need the clap take, which is a separate test of the sound (Phase 2). First attempt, 2026-11-04 06:25: all 9 takes were copied and verified by 07:08; then the Mac ran out of memory while making take 3's WAV and was forced off at 07:24. To be run again with the fix below.
- **Memory (fixed 2026-11-04):** `acam audio` and `acam clean` kept every frame they read in memory until the program ended, about 3.4 MB per frame (Foundation's `Data(contentsOf:)` is autoreleased, and these loops never emptied a pool), so a full card (49 GB of frames) needed far more than the Mac's 16 GB. The audio step now reads only each frame's 8 KiB sound block into one buffer, and clean empties a pool after every frame. Peak memory on a 420-frame take: audio 1.43 GB → 13 MB, clean 1.93 GB → 175 MB, the whole offload with audio and clean 177 MB. The audio test fails if memory grows with the take.

### Phase 2 — Find the audio

The camera is documented as recording two channels of 48 kHz uncompressed audio, but no driver has ever exposed it. This phase is investigation, not building.

1. I will record a new short take with a clear clap or tone going into the camera's audio input. Tell me when you need it.
2. Using the debug tools that already exist (`ikctl sectors`, `ikctl frame`, the EEPROM take table), map which flash areas belong to frames, and look for data **outside** the frame map that changes with the new take.
3. Look for audio-like patterns: 16- or 24-bit PCM, about 2,000 samples per channel per frame at 24 fps.
4. Check `DNGPrivateData` in the headers for any pointer to audio.
5. Report what you found: where the audio is and its format, or evidence that it was never recorded.

Reading flash areas the driver doesn't normally read may need a new **read-only** debug selector in the driver. If so, stop and ask me first, and explain exactly what it reads.

**Gate:** a written finding in `SPEC.md` with evidence. If audio exists, a raw dump of the clap take's audio that plays the clap.

#### Phase 2 finding (2026-11-03): the audio is inside every frame

- **Where:** the 8 KiB block after each frame's image (file offset 0x334000, which the header labels `DNGPrivateData`). No new driver code was needed.
- **Format:** 16-bit signed little-endian PCM, 48 kHz, two channels interleaved (channel 1, channel 2). At 24 fps each frame holds 2,000 sample pairs, and about one frame in 100 holds 2,001 (the audio clock runs about 5 ppm fast against the frame clock). The first `FF FF FF FF` pair ends a frame's samples; it can never be data, because channel 2's lowest bit is always 0. Joined in frame order, the sound is continuous (gap test: +0.02 samples).
- **Evidence:** `work/phase2/findings.md` (byte statistics over 848 frames, continuity tests, spectra), WAVs in `work/phase2/wav/`.
- **Content so far:** none of the existing takes has sound from the scene, only the camera's own hum at about −76 dBFS. The audio input was probably not connected.
- **Also found:** (1) the card's flash data has rare 1→0 bit flips, about 3.8 per million bits, heard as clicks in the audio. The Phase 1 real run shows whether they are stored on the card or happen when reading. (2) Of the two timecodes in each frame, the first counts at 25 fps even on 24 fps takes; the second counts at 24.
- [ ] Still open, needs the clap take: the sync offset between picture and sound, which channel is left, loud sound, and other frame rates. The gate's "dump that plays the clap" waits for that take.

### Phase 3 — Audio export (only if Phase 2 found audio)

`acam audio`, also part of `acam offload`

- Extract each take's audio to `<take>_Audio.wav`: 48 kHz, original bit depth, stereo.
- Embed the starting timecode (BWF `bext` chunk) so editing software lines it up automatically.

**Gate:** the clap lines up with the clap frame within one frame; over a full take, drift stays under one frame at the end.

#### Phase 3 results (2026-11-03)

- [x] `acam audio` (and the offload) writes `<take>_Audio.wav`: 48 kHz, 16-bit, stereo, channel 1 first as stored, samples unchanged, no resampling. A BWF `bext` chunk holds the take's first timecode as TimeReference (the first DNG TimeCodes entry, the one editors read), counted at the take's frame rate. Each WAV is added to the take's ASC MHL history.
- Take AC000001 (623 frames): 25.958 s; drift against the picture +0.15 ms (7 extra sample pairs); byte-identical to the separate Phase 2 extraction; bext start 01:25:16:23.
- Drift in general: about 18 ms per hour, under one frame for takes up to about 2 hours.
- [ ] The clap part of the gate needs the clap take.

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

#### Phase 4 results (2026-11-03)

- [x] `acam clean` (and the offload) writes `<take>/clean/`: Make "Ikonoskop", Model "A-Cam dII", one WhiteLevel (4095), BaselineExposure 0, tiled lossless JPEG (Compression 7, 256×224 tiles, as Adobe's DNG SDK picks). Timecodes, frame rate, reel name and every other tag are unchanged, except colour frames' BlackLevel: 90 in every channel since 2026-11-04 (see Phase 5, black level).
- **Illuminants (changed from the plan):** 38268 and 36168 are 0x8000 + 5500 and 0x8000 + 3400, so ColorMatrix1 was calibrated at 5500 K and ColorMatrix2 at 3400 K. The clean DNGs use 20 (D55) and 24 (ISO studio tungsten, 3200 K), the closest standard codes, in that order. 17 and 21 would have put each matrix at the wrong colour temperature.
- **The 8 KiB block is the audio, not padding.** The clean DNGs leave it out, so they end at the image data, but only after the WAV is written. The verified originals keep it.
- Evidence: every clean frame is read back from disk, decoded and compared with the original pixels. LibRaw, an independent decoder, reads them to identical raw values, and Apple's RAW engine opens them. Take AC000001: 52% of the original size (card 102 samples: 46%).
- Side finding: columns 0–27 and 2020–2047 are black in every frame (unexposed margin). Not changed. Marking them with the DNG ActiveArea / DefaultCrop tags would remove the black side bars (picture 1992×1092).
- [ ] The Resolve check is yours.

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

#### Phase 5 results (2026-11-03): steps 1–6 done, waiting for your pick

- **Datasheets** downloaded (Kodak 2008 Rev 1.0 and Truesense 2012 Rev 2.0), kept out of git in `pipeline/colour/datasheet/`. The colour curves are vector drawings inside the PDFs, so they were read out exactly; the 2008 and 2012 sheets agree to within 0.002. Numbers: `pipeline/colour/data/kai02150_qe.csv` (380–780 nm, 10 nm steps). Check image: `work/phase5/qe_check.png`.
- **Tool:** our own open-source profile builder, `pipeline/colour/build_profile.py` (numpy only), instead of dcamprof (not installed); no new dependency.
- **Profiles:** B-650 (IR-cut at 650 nm) and B-665. Tuned once to 665 nm, because B-650 made skin and reds pinker in every frame, and 665 nm is also what the camera's own white-balance presets point to. Files: `pipeline/colour/profiles/`.
- **Comparison sheets:** `work/phase5/compare_sheet.png` (A vs B-650) and `work/phase5/compare_sheet_v2_ir665.png` (A vs B-665), seven frames with skin, foliage, overcast sky and neutrals. There is no blue sky or colour chart in the footage. Greys render exactly neutral with A and with both Bs. These first sheets used the camera's wrong black level (below): every option had green shadows. Corrected sheets: `work/phase5/compare_sheet_v3_b650.png` and `compare_sheet_v3_b665.png`.
- **Assumptions** (full table with reasons: `work/phase5/assumptions.md`):
  - Sensor: KAI-02150 colour version with the first-generation colour filters (part KAI-02150-CBA) and AR-coated cover glass. The datasheet curves are taken as typical for every sensor. The response to light power is QE × wavelength.
  - IR-cut filter: smooth edge, 95% transmission below it, practically zero 50 nm above it. Cut-off 650 nm by default, the middle of typical values (Basler 650, MidOpt SP645, FLIR 680 nm), tuned to 665 nm.
  - Optical low-pass filter, lens and cover glass: spectrally neutral. The model sees 10–20% more blue than the factory presets imply, possibly blue absorption in the lens or glass; not modelled.
  - Fit: 123 reference colours (ColorChecker 24 plus the 99 CIE 224:2017 samples), CIE 1931 2° observer, illuminants A and D65 (D50 for the ForwardMatrix), white held exact, ΔE2000 minimised. Typical error on chart colours: 2.3–3 ΔE2000.
- **Black level (2026-11-04, after your feedback "everything has a green bias, the shadows a lot"):** the camera's header says black is 80 for the two green channels and 90 for red and blue (the tungsten template says 80 for red too). The pixels disagree:
  - In 30 frames from both cards, the darkest values of all four channels are the same: the 0.001 / 0.01 / 0.1 / 1% percentiles are 86–87 / 88–89 / 91 / 93–95 in every channel.
  - At equal raw values, all four channels have the same temporal noise (measured from consecutive frames). A 10-step difference in black would add about 1.5 DN² to green at every brightness; there is none.

  So all four channels share one black level of about 90. The greens' 80 left about 10 extra steps of green in every shadow, multiplied by the sheets' exposure lift (up to 16×). Clean DNGs now say 90 for every channel (monochrome frames keep their 60, not measured); `acam prores` on camera DNGs uses the same value; the comparison renders too. The shared value is 90 ± about 2 (from the dark floor); a few seconds recorded with the lens cap on would pin it down. Scripts: `work/phase5/black_level_check.py`, `work/phase5/black_level_ptc.py`.
- [ ] Step 7 waits for your pick from the corrected sheets: A, B-650 or B-665.

### Phase 6 — ProRes export and Mac app

- `acam prores`: render clean DNGs to ProRes 4444 XQ using Apple's AVFoundation, with the WAV audio muxed in and timecode set. Offer two looks: log (ACEScct) for grading, and a simple Rec.709 preview.
- A small SwiftUI Mac app over the same code: shows the mounted card and its takes, lets me choose a destination and outputs, has one **Process card** button, a progress bar, and shows the report at the end.

**Gate:** one card goes to verified copies, clean DNGs, WAVs and ProRes in one click; the ProRes opens in Resolve and Final Cut with sound in sync.

#### Phase 6 results (2026-11-03)

- [x] `acam prores` (also an option of `acam offload` and the app): ProRes 4444 XQ through AVFoundation, 2048×1092. Pictures come from the clean DNGs through Apple's RAW engine (Core Image) with the DNG's own matrices. ACEScct: a scene-linear ACEScg render plus the ACEScct curve. Rec.709: Core Image's standard tone curve, tagged BT.709. The WAV goes in unchanged, and a timecode track starts at the take's first timecode.
- Evidence on take AC000001 (623 frames): both movies are ProRes 4444 XQ, 24 fps, 623 frames; the sound is byte-identical to the WAV; picture and sound lengths differ by 0.15 ms; the timecode is 01:25:16:23. Speed on the M1 Pro: 53–80 frames/s (ACEScct), 99–129 frames/s (Rec.709), 2–5 times real time. Notes: `work/prores/notes.md`.
- [x] The ACam app (`make app`, then open `pipeline/build/ACam.app`): it shows the mounted card and its takes, lets you choose the destination, outputs and colour profile, and has one **Process card** button, a progress bar and the report at the end. It reads the card in the background, and asks for your password for the take table with the normal macOS dialog. The first time, macOS asks whether ACam may access files on a removable volume: allow it. Screenshot: `work/phase6/app_card.png`.
- [ ] Gate: a one-click run on a card and the Resolve / Final Cut check (yours).

### Phase 7 — Future-proofing (later, separate decision)

- Test the driver on a newer macOS when I have a spare Mac or partition, using the checklist in `HANDOVER.md`.
- Evaluate porting the driver to PCIDriverKit (a dext). That would remove the need for Reduced Security and kext approval. Write up the effort and the entitlement Apple requires, then stop and let me decide.

#### Phase 7 results (2026-11-03)

- [x] Driver-port evaluation: `docs/dext-evaluation.md`. In short: the hardware side maps onto Apple's PCIDriverKit, but a DriverKit driver cannot present the synthesized card volume, so the practical design is a dext that hands frames straight to `acam` (no mounted volume). It would take about 5.5–11 person-weeks, a paid Apple developer account, and Apple's approval of a PCI entitlement for Xilinx's vendor ID, which may be refused or slow. Recommendation: keep the kext for now; if Full Security matters, first spend a day on a test dext.
- [ ] The newer-macOS test needs a spare Mac or partition.

---

## 7. Out of scope

- Neural denoising, AI highlight repair, AI upscaling
- Windows and Linux
- DNxHR export
- Anything that writes to the card

## 8. Start now

Begin with Phase 0. Before changing anything, read `AUDIT-2026-11-03.md`, `HANDOVER.md` and the README. Then tell me in a few plain sentences what you will do in Phase 0, and wait for my OK.
