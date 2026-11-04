# ACam user manual

ACam copies the footage off **Ikonoskop A-Cam dII** memory cards on an Apple silicon Mac, checks that every frame was
copied correctly, and prepares the footage for editing: sound as a WAV file, corrected DNGs with better colour, and
ProRes movies if you want them. You can look at every take before you copy it.

## Why it exists

Ikonoskop no longer exists, and its last card reader driver runs only on Intel Macs. The driver in this repository makes
the MK-3 ExpressCard reader work on Apple silicon Macs; the card then appears as a read-only volume named `ACAM` plus the
card number (for example `ACAM 102`). ACam is the app on top of it. It does what a careful assistant would do with every
card, and a few things nobody could do before:

- **Copies are checked, not trusted.** Every frame is read twice from the card and once from the copy, and the three
  reads must agree. A-Cam cards return slightly different data now and then (on one test card, about 1 frame in 6 on a
  second read). ACam reads such a frame again until two reads match exactly. A Finder copy reads every frame once and can
  carry these errors.
- **Proof that the copy is complete.** A report (`REPORT.md`) and standard checksum files (ASC MHL) for every take.
- **The camera's sound.** The A-Cam dII stores its sound inside every frame, which no driver ever exposed. ACam turns it
  into a WAV file with the take's timecode.
- **Corrected DNGs.** The camera's DNG files have tag errors: no make or model, invalid light-source codes, and a black
  level that makes shadows green. ACam's clean DNGs fix them, use a colour profile built from the sensor's published data,
  and are about half the size, without changing a single pixel value.

## What you need

- An Apple silicon Mac with macOS 13 or later, with the driver installed and approved (see the
  [README](../README.md#install)).
- The MK-3 ExpressCard reader in a Thunderbolt-to-ExpressCard adapter, and an A-Cam dII card.
- The app itself. Build it once in Terminal with `make app` in the repository folder (it needs Apple's Command Line
  Tools); it appears as `pipeline/build/ACam.app`. Drag it to Applications if you like.
- Free disk space where the copies go: see [How much space you need](#how-much-space-you-need).

## First start

1. Connect the reader, insert the card, and open ACam. The card appears in the **Card** menu after a few seconds.
2. macOS asks **"ACam would like to access files on a removable volume"**. Click **OK**. Until you do, ACam waits at
   "Reading ACAM …". macOS asks this again whenever the app is rebuilt.
3. When you copy a card with **Check the card's take table** ticked, macOS asks for your password: ACam reads the card's
   own list of takes from the reader with an administrator command (`ikctl eeprom`).

## The window

**Card row.** The **Card** menu lists the cards that are in the reader. **Refresh** looks again; **Eject** ejects the
card so you can take it out. **List** / **Grid** switches how the takes are shown (ACam remembers your choice).

**Card line.** Under the card menu: the number of takes, how long they run, how much footage there is, and how full the
card is, with the recording time left. Example: *9 takes · 10 min 10 s · 49.29 GB of footage — card 61% full (49.41 GB of
80.51 GB), about 6 min 25 s of recording left at 24 fps*. An 80 GB card holds about 16½ minutes at 24 fps. (Finder shows
the card as 100.4 GB: the driver's volume is bigger than the card. ACam works out the real size.)

**Takes.** One row (List) or picture (Grid) per take: the take's first frame, its name (`AC` + card number + take
number), number of frames, length, size, frame rate and start timecode. The pictures are developed in the colour profile
chosen under Outputs and change when you change the profile. Click a picture to open the take's
[preview](#previewing-a-take). Tick a take's box to include it in **Process selected takes**.

**Destination.** Click **Choose…** and pick a folder, usually on an external drive. ACam makes a new folder named after
the card inside it (for example `ACAM 102`). That folder must not exist yet: ACam never writes into an existing copy. The
free space on that drive is shown next to the path.

**Outputs.**

| Output | What you get |
|---|---|
| Verified copies, checksums and a report | Always. Exact copies of the card's DNG files, the ASC MHL checksum files and `REPORT.md` |
| Audio as WAV | The camera's sound for each take: 48 kHz, 16-bit, stereo, with the take's start timecode |
| Clean DNGs | Corrected, losslessly compressed DNGs, about half the size; pixel for pixel the same picture |
| ProRes 4444 XQ, ACEScct log | Movies for grading (in DaVinci Resolve, set the input colour space to ACEScct) |
| ProRes 4444 XQ, Rec.709 preview | Movies that look right straight away, for viewing and quick edits |
| Check the card's take table | Compares the takes on the card with the card's own list in the reader's memory. Asks for your password |
| Colour profile | The colour the clean DNGs and ProRes movies carry; see [Colour](#colour) |

**Process card** copies and checks every take on the card. **Process selected takes…** copies only the ticked takes;
see [Copying only some takes](#copying-only-some-takes). Under the buttons, ACam says how much footage the run copies and
about how much it writes with the chosen outputs, and warns in orange when the destination is too small.

**Result.** When a run ends, the window shows its result in large letters and the report below it:

- **ALL VERIFIED** (green): every take was copied and every check passed.
- **PARTIAL** (orange): only the selected takes were copied, and they all passed. The others are still only on the card.
- **PROBLEMS FOUND** (red): something did not pass. The report says what.

**Show in Finder** opens the card's folder with `REPORT.md` selected.

## Previewing a take

Click a take's picture to open its preview window, which plays the take straight from the card before it is copied.

- **Space bar**: play and pause. **Left / right arrow**: one frame back or on. Drag the **slider** to jump anywhere.
- The timecode and frame number are shown next to the slider.
- The window opens at half the screen's width; drag its corner to resize it, or use the green button for full screen.
- While playing, frames are developed at half resolution so the take plays in real time; when you pause or step, the
  frame is shown at full resolution. If the Mac falls behind, frames are skipped; the take never plays slower.
- The preview has no sound.
- **While a card is being copied, previews are off.** Clicking a take then shows a message, and starting a copy closes an
  open preview. The copy gets the card to itself.

## Copying a card

1. Insert the card and wait until the takes appear.
2. Look through the takes if you like.
3. Click **Choose…** and pick where the copy goes. Check that the free space is enough (ACam warns in orange if not).
4. Choose the outputs and the colour profile.
5. Click **Process card**. If the take table check is on, type your password.
6. Wait. The progress bar and the line under it show what ACam is doing. Copying a full 49 GB card to an external hard
   disk took about 50 minutes in testing; a fast SSD is several times quicker.
   - Keep the Mac awake and plugged in, and leave the card and the destination drive connected. ACam does not stop the Mac
     from going to sleep by itself.
   - The card menu, the colour profile and the previews are locked until the copy has finished.
7. When it says **ALL VERIFIED**, click **Eject** and take the card out.

Copy every card to two drives before you record over it: run ACam a second time with another destination.

## Copying only some takes

Tick the takes you want and click **Process selected takes…**. ACam asks first, and says how many takes will stay only on
the card. The result is **PARTIAL**, never ALL VERIFIED, and the report lists the takes that were not copied, so it is
always clear that the card still holds footage that exists nowhere else.

Do this when you need a few takes quickly. Copy the whole card as well before the card is used again: anything that is not
copied is lost when you record over it. A second run needs a new destination folder.

## What you get on disk

```
ACAM 102/                      the card's folder, inside the destination you chose
  REPORT.md                    the report: result, every take, problems and warnings
  EEPROM.txt                   the card's take table, when it was checked
  colour/<profile>/            the colour profile: Lightroom/Camera Raw DCP, ACES input transforms, OpenColorIO config
  prores/                      ProRes movies, one per take and look, if chosen
  AC102001/
    frames/                    exact copies of the camera's DNG files (10200001.DNG, ...)
    AC102001_Audio.wav         the take's sound
    clean/                     corrected, compressed DNGs, if chosen
    ascmhl/                    ASC MHL checksum history of everything in the take folder
  AC102002/
  ...
```

The ASC MHL files let anyone check the copies later, also on another computer, with the free `ascmhl` tool:
`ascmhl-debug verify <take folder>`.

## Reading the report

`REPORT.md` opens in any text editor. It starts with the result and a table: the card, where it was copied to, when, how
many takes and frames, and the result of each check. Then one line per take: frames, length, frame rate, first and last
timecode, checksums (with the number of frames read again), sound and clean DNGs.

**Problems** are reasons the result is not ALL VERIFIED, for example a frame where no two reads ever matched, or a take
that the card's take table lists but the card does not show. Copy the card again to a new folder.

**Warnings** are worth knowing but do not make the copy incomplete. The common ones:

- *The card returned different data the second time N frames were read*: the card's normal read errors; each of these
  frames was read again until two reads matched.
- *The take table also keeps N entries from earlier recordings*: older recordings that were deleted from the card's list.
  The driver does not show them, so they were not copied.
- *Only the chosen takes were copied*: a partial copy; the listed takes are still only on the card.

## Colour

The colour profile decides how the camera's raw colours turn into real colours. ACam offers three:

| Profile | What it is |
|---|---|
| **A-Cam dII KAI-02150 sensor data (IR cut 665 nm)** | The default. Built from the published spectral data of the camera's Kodak KAI-02150 sensor |
| A-Cam dII factory matrices (D55 / 3200 K) | Ikonoskop's own colour, as stored in every frame |
| A-Cam dII KAI-02150 sensor data (IR cut 650 nm) | An earlier version of the sensor-data profile |

- The profile goes into the clean DNGs. **DaVinci Resolve** reads the colour from the DNGs, so pick the profile before you
  process the card. To get the other colour later, make the clean DNGs again with the other profile.
- In **Lightroom or Adobe Camera Raw**, you can switch at any time: the card's `colour/` folder holds the profile as a
  `.dcp` file. Copy it into `~/Library/Application Support/Adobe/CameraRaw/CameraProfiles/`, then pick it in the Profile
  browser. The factory profile's `.dcp` is in the repository under `pipeline/colour/profiles/factory/`.
- The clean DNGs also correct the black level. The camera's files say the greens are black at 80, but the sensor's black is
  about 90 in all four colour channels; the old values left a green tint in every shadow.
- The ProRes movies are made from the clean DNGs, so they have the same colour.

## Sound

The camera writes its sound into every frame: 48 kHz, 16-bit, stereo. ACam joins it into one WAV file per take, sample for
sample, with the take's start timecode stored in the file (Broadcast WAV), so editing programs can line it up with the
pictures. The camera's sound clock runs about 5 parts per million fast against its picture clock: under a millisecond over
a 3-minute take. If nothing was connected to the camera's audio input, the file contains only the camera's faint hum.

## Camera settings in the files

The card records, per take: the **date and time** it was recorded (the files' dates in Finder), the **frame rate**, the
**white balance preset** (daylight or tungsten), **colour or black-and-white**, two **timecodes** (one counting the
recording, one the time of day) and the reel name. ACam shows the frame rate and the start timecode.

The card does **not** record ISO or gain, shutter speed or angle, the aperture or anything about the lens. These settings
are not in the camera's take table or in the frames, so no software can read them. Note them on set.

## How much space you need

| What | Per minute of footage at 24 fps |
|---|---|
| Copies of the camera's files | 4.8 GB (3.37 MB a frame) |
| Clean DNGs | about 2.6 GB |
| ProRes 4444 XQ, ACEScct log | about 3.0 GB |
| ProRes 4444 XQ, Rec.709 | about 3.3 GB |
| Sound | 11.5 MB |

A full 80 GB card (about 16½ minutes) needs about 80 GB for the copies alone, or about 125 GB with clean DNGs. ACam shows
the estimate for the card in front of you before you start, and refuses to start when there is not even room for the
copies.

## Ejecting the card

Click **Eject**, wait for **"… is ejected: you can take the card out of the reader"**, then take the card out. Eject is
refused while the card is being copied. Ejecting in Finder works too.

## Safety, in short

- Every frame is read twice from the card and once from the copy; all three must match.
- An existing copy is never overwritten.
- A copy of some takes is never called ALL VERIFIED.
- No previews, card changes or eject during a copy.
- The card itself is never written to: the driver is read-only.

## Troubleshooting

| What you see | What to do |
|---|---|
| "No A-Cam card mounted" | Check that the reader is connected and the card is in. Click **Refresh**. If Finder doesn't show the card either, see the driver's [README](../README.md#troubleshooting) |
| The window stays at "Reading ACAM …" | Answer macOS's question about access to removable volumes (it may be behind other windows) |
| "… already exists; choose a new destination folder" | The destination already has a folder with the card's name. Choose another folder, or make a new one in the Choose… window |
| "… has N MB free, the card needs N MB" | Free up space or choose another drive |
| PROBLEMS FOUND | Read the Problems section of the report, then copy the card again to a new folder |
| The preview says it could not read a frame | The card was probably taken out. Insert it again and reopen the preview |

## For advanced users: the command line

The app runs the same code as the `acam` command (build it with `make pipeline`; it is in `pipeline/build/`):

```sh
sudo tools/ikctl eeprom 0 0x2000 > eeprom.txt     # the card's take table
pipeline/build/acam offload --source "/Volumes/ACAM 102" --dest /Volumes/Backup --eeprom eeprom.txt --prores both
pipeline/build/acam offload --source "/Volumes/ACAM 102" --dest /Volumes/Backup --takes AC102003,AC102007
pipeline/build/acam offload ... --profile factory   # Ikonoskop's colour instead of the sensor-data profile
pipeline/build/acam --help                          # everything else: audio, clean and prores on copied takes
```

## Known limits

- Previews have no sound.
- A run cannot be stopped once it has started.
- ACam does not keep the Mac awake during a copy.
- One destination per run; for a second copy, run it again.
- A partial copy cannot be completed later into the same folder: copy the whole card to a new folder.
