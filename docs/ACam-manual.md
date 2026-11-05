# ACam user manual

ACam copies the footage off **Ikonoskop A-Cam dII** memory cards on an Apple silicon Mac, checks that every frame was
copied correctly, and prepares the footage for editing: sound as a WAV file, corrected DNGs with better colour, and
ProRes movies if you want them. You can look at every take, with its sound, before you copy it.

## Why it exists

Ikonoskop no longer exists, and its last card reader driver runs only on Intel Macs. The driver in this repository makes
the MK-3 ExpressCard reader work on Apple silicon Macs; the card then appears as a read-only volume named `ACAM` plus the
card number (for example `ACAM 102`). ACam is the app on top of it. It does what a careful assistant would do with every
card, and a few things nobody could do before:

- **Copies are checked, not trusted.** Every frame is read twice from the card and once from each copy, and the reads
  must agree. A-Cam cards return slightly different data now and then (on one test card, about 1 frame in 6 on a second
  read). ACam reads such a frame again until two reads match exactly. A Finder copy reads every frame once and can carry
  these errors.
- **Two drives in one go.** ACam can write a second copy to another drive at the same time, from the same reads of the
  card.
- **Proof that the copy is complete,** today and later: a report (`REPORT.md`) and standard checksum files (ASC MHL) for
  every take, which **Verify a copy** checks again whenever you like.
- **The camera's sound.** The A-Cam dII stores its sound inside every frame, which no driver ever exposed. ACam turns it
  into a WAV file with the take's timecode, and plays it in the take preview.
- **Corrected DNGs.** The camera's DNG files have tag errors: no make or model, invalid light-source codes, and a black
  level that makes shadows green. ACam's clean DNGs fix them, use a colour profile built from the sensor's published data,
  and are about half the size, without changing a single pixel value.

## What you need

- An Apple silicon Mac with macOS 13 or later, with the card reader driver installed and approved (see the
  [README](../README.md#install)).
- The MK-3 ExpressCard reader in a Thunderbolt-to-ExpressCard adapter, and an A-Cam dII card.
- The app: see [Installing ACam](#installing-acam).
- Free disk space where the copies go: see [How much space you need](#how-much-space-you-need).

## Installing ACam

**The ready-made app (no developer tools needed).** Download `ACam-<version>.zip` from the repository's
[Releases](https://github.com/dasparov/ikonoskop-driver/releases) page and open it. Drag `ACam.app` into **Applications**.

ACam is free and not registered with Apple, so the first time macOS refuses to open it ("Apple could not verify…").
Do this once:

1. Open **Terminal** (in Applications › Utilities), paste this line and press Return:

   ```sh
   xattr -dr com.apple.quarantine /Applications/ACam.app
   ```

   This removes the "downloaded from the internet" mark from ACam and from the small tool inside it that reads the
   card's take table.
2. Open ACam as usual.

Without Terminal: double-click ACam, click **Done** (or **Cancel**), open **System Settings › Privacy & Security**,
scroll down, click **Open Anyway** next to the message about ACam, and confirm. If the take table check later fails with
a message about `ikctl`, use the Terminal line above.

**Building it yourself.** In Terminal, in the repository folder, run `make app` (it needs Apple's Command Line Tools);
the app appears as `pipeline/build/ACam.app`. The [command-line tool](#for-advanced-users-the-command-line) is built
with `make pipeline`.

## First start

1. Connect the reader, insert the card, and open ACam. The card appears in the **Card** menu after a few seconds.
2. macOS asks **"ACam would like to access files on a removable volume"**. Click **OK**. Until you do, ACam waits at
   "Reading ACAM …". macOS asks this again whenever the app is rebuilt or updated.
3. When the first run finishes, macOS asks whether ACam may send notifications. Click **Allow** to get a message when a
   long copy is done (see [When a run ends](#when-a-run-ends)).
4. When you copy a card with **Check the card's take table** ticked, macOS asks for your password: ACam reads the card's
   own list of takes from the reader with an administrator command (`ikctl eeprom`).

ACam remembers the destination, the second copy drive, the outputs and the colour profile between launches.

## The window

ACam's lettering is Helvetica, the typeface of Ikonoskop's website and camera manual.

**Card row.** The **Card** menu lists the cards that are in the reader. **Refresh** looks again (also at the
destination drives); **Eject** ejects the card so you can take it out. **List** / **Grid** switches how the takes are
shown.

**Card line.** Under the card menu: the number of takes, how long they run, how much footage there is, and how full the
card is, with the recording time left. Example: *9 takes · 10 min 10 s · 49.29 GB of footage — card 61% full (49.41 GB of
80.51 GB), about 6 min 25 s of recording left at 24 fps*. An 80 GB card holds about 16½ minutes at 24 fps. (Finder shows
the card as 100.4 GB: the driver's volume is bigger than the card. ACam works out the real size.)

**Takes.** One row (List) or picture (Grid) per take: the take's first frame, its name (`AC` + card number + take
number), when it was recorded, number of frames, length, size, frame rate, the camera's colour temperature setting and
the start timecode. The pictures are developed in the colour profile chosen under Outputs and change when you change the
profile. Click a picture to open the take's [preview](#previewing-a-take). Tick a take's box to include it in **Process
selected takes**.

**Destination.** Click **Choose…** and pick a folder, usually on an external drive. ACam makes a folder named after the
card inside it (for example `ACAM 102`). The free space on that drive is shown next to the path, or **not connected**
when the drive is not plugged in. If the folder is already there from an earlier run, ACam adds what it lacks: see
[Adding to an earlier copy](#adding-to-an-earlier-copy).

**Second copy.** Optional. Click **Choose…** and pick a folder on a *different* drive; ACam writes the same files there.
**None** goes back to one copy. When the second drive is not connected, the line says so in orange and runs make one
copy, at the destination; the report then says that no second copy was made. See [A second copy](#a-second-copy).

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

**Buttons.** **Process card** copies and checks every take on the card. **Process selected takes…** copies only the
ticked takes; see [Copying only some takes](#copying-only-some-takes). **Verify a copy…** checks a finished copy again;
see [Checking a copy later](#checking-a-copy-later). **Make outputs from a copy…** makes the ticked outputs for a copy
made earlier, without the card; see [The first and the second run](#the-first-and-the-second-run). While a run is going,
these become **Stop**; see [Stopping a run](#stopping-a-run).

**Help.** The **?** button next to List / Grid (or **Help › ACam Help** in the menu bar) opens a short guide: how ACam
works, how to copy fast, and the first and the second run.

Under the buttons, ACam says what a run will do before it starts: how much footage it copies, about how much it writes
with the chosen outputs (and to the second drive), and what an earlier run already left at the destination. An orange
line says why a run cannot start, for example **Not enough space**; the button is then greyed out.

**Result.** When a run ends, the window shows its result in large letters and the report below it:

- **ALL VERIFIED** (green): every take on the card is copied and every check passed.
- **PARTIAL** (orange): only the selected takes were copied, and they all passed. The others are still only on the card.
- **STOPPED** (orange): you stopped the run; see [Stopping a run](#stopping-a-run).
- **PROBLEMS FOUND** (red): something did not pass. The report says what.
- **NOT STARTED** (red): the run could not start, for example because the destination is full. Nothing was copied.

**Show in Finder** opens the card's folder with `REPORT.md` selected.

## Previewing a take

Click a take's picture to open its preview window, which plays the take straight from the card, with its sound, before
it is copied.

- **Space bar**: play and pause. **Left / right arrow**: one frame back or on. Drag the **slider** to jump anywhere.
- **M** or the speaker button: sound off and on. ACam remembers the choice.
- The timecode and frame number are shown next to the slider.
- The window opens at half the screen's width; drag its corner to resize it, or use the green button for full screen.
- The sound sets the pace, so you can find the clap: the picture follows the sound. While playing, frames are developed
  at half resolution; when you pause or step, the frame is shown at full resolution, without sound. If the Mac falls
  behind developing pictures, pictures are skipped, never sound. If the card itself is read too slowly, the sound waits.
- **While a card is being copied, previews are off.** Clicking a take then shows a message, and starting a copy closes an
  open preview. The copy gets the card to itself.

## Copying a card

1. Insert the card and wait until the takes appear.
2. Look through the takes if you like.
3. Check the destination (and the second copy, if you want one). ACam remembers them from last time.
4. Choose the outputs and the colour profile.
5. Read the line under the buttons: it says what the run will copy and write. Click **Process card**. If the take table
   check is on, type your password.
6. Wait. The progress bar and the line under it show what ACam is doing. Copying a full 49 GB card to an external hard
   disk took about 50 minutes in testing; a fast SSD is several times quicker.
   - ACam keeps the Mac awake until the run is over (the screen may still turn off). Closing a laptop's lid still puts
     it to sleep, so leave it open, and keep it plugged in.
   - Leave the card and the destination drives connected.
   - The card menu, the outputs and the previews are locked until the copy has finished.
7. When it says **ALL VERIFIED**, click **Eject** and take the card out.

### When a run ends

ACam plays a sound, shows a notification (if you allowed notifications) and, if you are working in another app, bounces
its Dock icon until you look. Verify a copy does the same.

### Stopping a run

Click **Stop** (or press **⌘.**), and confirm. What happens depends on how far the run is:

- **While copying** (before every copy has been verified): ACam removes what this run copied. Nothing half-checked is
  left behind; the card still has every take. The result says **STOPPED**.
- **While making the outputs** (WAV, clean DNGs, ProRes, the second copy): the copied takes are verified and stay. The
  output being made is removed, and the report lists what was not made. Make them later, with or without the card: see
  [The first and the second run](#the-first-and-the-second-run).

Quitting ACam or a crash during a run leaves an unfinished folder behind. The next run into the same destination moves
it to the Trash (from where you can still get it back) and copies the take again.

## Ways of copying

The card reader delivers about 165 MB/s, so any copy of a full 80 GB card takes at least about 8 minutes. What else it
takes depends on where the copy goes and what ACam makes:

| Way | Full 80 GB card | Checked? |
|---|---|---|
| Finder: drag the take folders to an SSD | about 8 min | No |
| ACam, checked copies only (outputs unticked), to an SSD | about 18–20 min | Yes, every frame |
| ACam with WAV and clean DNGs, to a USB hard disk | about 1½ hours | Yes |

- **ACam takes a little over twice as long as a plain copy,** because it reads every frame twice from the card and reads
  each copy back to compare. That is the point: the card sometimes returns a frame slightly differently (on the test card
  about 1 frame in 6 on a second read). A Finder copy keeps whatever it read the first time, without telling you, and it
  has no checksum files, so it cannot be checked later.
- **A USB hard disk is the slow part.** It reads and writes about 50 MB/s, a third of what the card delivers. Copy to the
  Mac's own disk or to a USB-C or Thunderbolt SSD.
- **The fastest safe way:** copy to an SSD with the outputs unticked, then make the outputs in a second run (next
  section).
- **A second copy** to another fast drive costs almost no extra time: each frame is written to both as it is read.

The hard disk figure comes from the 49 GB test card (copying and checking took 43 minutes, 50 with the WAVs); the SSD
figures are worked out from the card's speed.

## The first and the second run

**First run, on set (fast):** untick **Audio as WAV**, **Clean DNGs** and both **ProRes** options, and click **Process
card**. You get the card's folder with the checked copies, their checksum files and the report (ALL VERIFIED). This is
the part that needs the card.

**Second run, later,** makes the outputs. Tick the ones you want. There are two ways:

| | With the card: **Process card** again | Without the card: **Make outputs from a copy…** |
|---|---|---|
| What you do | Put the same card in the reader and click **Process card**, into the same destination | Click **Make outputs from a copy…** and choose the card's folder (on any drive) |
| What it checks first | Compares each take's first frame with the card, and checks the card's take table again | Checks the copies against their checksum files: every frame present at its size, the first frame's checksum; the clean DNGs check every frame |
| What it can add | The outputs the copied takes lack, and takes not copied yet | The outputs the copied takes lack |
| The report | A new REPORT.md for the whole card; the earlier one becomes REPORT-1.md | A section added to the end of REPORT.md |
| The second copy | Updated too | Run it on that folder as well |
| Needs | The same card, not recorded over since | Only the copy |

Both make the outputs from the copies on the drive, not from the card, and never change what is already there. The time
depends on the drive and the Mac: on the Mac's own SSD, the WAV and clean DNGs of a 420-frame take took under 3 seconds.
If everything is already there, ACam says *nothing to add* or **NOTHING TO MAKE**.

## A second copy

Choose a **Second copy** folder on another drive. Then every run writes the same files to both drives:

- Each frame is read from the card once and written to both drives at the same time, and both copies are read back and
  compared with the card's two reads. A second copy therefore costs little extra time.
- The WAV files, clean DNGs, ProRes movies and colour files are made on the first drive and then copied to the second,
  each file read back and compared.
- Both card folders get the same `REPORT.md`, and each take folder on the second drive gets its own checksum history,
  so each drive can be checked on its own with **Verify a copy**.
- Both drives must have room for the run, or it does not start.
- If something goes wrong only on the second drive, the first copy is still verified; the result is PROBLEMS FOUND and
  the report says what. Process the card again into the same folders to repair the second copy: ACam copies what is
  missing there from the first drive.

When the second drive is not connected, ACam makes one copy and says so: in the window before you start, and in the
report.

## Copying only some takes

Tick the takes you want and click **Process selected takes…**. ACam asks first, and says how many takes will stay only on
the card. The result is **PARTIAL**, never ALL VERIFIED, and the report lists the takes that were not copied, so it is
always clear that the card still holds footage that exists nowhere else.

Do this when you need a few takes quickly. Copy the rest before the card is used again: anything that is not copied is
lost when you record over it. You can add the rest to the same folder later.

## Adding to an earlier copy

When the destination already holds a folder for this card (from a PARTIAL run, a stopped run, or a run with fewer
outputs), **Process card** adds what it lacks: the takes not yet copied, and the chosen outputs the copied takes don't
have yet. The line under the buttons says what will be added, for example *ACAM 102 is already at the destination with
2 of 9 takes. Process card adds 7 takes; what is there stays as it is.*

- Takes that are already there are never copied again or changed. ACam checks that they really are this card's takes:
  it compares their first frame with the card. A folder with a different recording under the same names (for example
  from an earlier shoot on the same card) is refused; choose another destination.
- The new report covers the whole card. The earlier report and take table are kept as `REPORT-1.md` and `EEPROM-1.txt`
  (then `-2`, and so on).
- When every take is there with every chosen output, the line says *nothing to add* and the button is greyed out.

## Checking a copy later

**Verify a copy…** reads a copy that ACam made again, file by file, and compares every file with the checksums in its
`ascmhl/` folders. Use it after moving a copy to another drive, before you delete a card, or now and then for archived
footage. Choose the card's folder (or one take folder in it).

- **ALL MATCH** (green): every file is still exactly as it was written.
- **MISMATCH FOUND** (red): the list shows each changed or missing file. Copy those takes again from another copy or
  from the card.
- Files that are not in the checksum history are listed as warnings only.

It reads everything, so it takes about as long as reading the files from that drive: the 49 GB test card took 16
minutes from a USB hard disk. It can be stopped like a run. The free `ascmhl` tool checks the same files:
`ascmhl-debug verify <take folder>`.

## What you get on disk

```
ACAM 102/                      the card's folder, inside the destination you chose
  REPORT.md                    the report: result, every take, problems and warnings
  REPORT-1.md                  the report of an earlier run into this folder, if any
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

The second copy, if chosen, holds the same files.

## Reading the report

`REPORT.md` opens in any text editor. It starts with the result and a table: the card, where it was copied to (and the
second copy), when, how many takes and frames, and the result of each check. Then one line per take: frames, length,
frame rate, first and last timecode, checksums (with the number of frames read again), sound and clean DNGs. Takes and
outputs from an earlier run into the same folder say *earlier run*.

**Problems** are reasons the result is not ALL VERIFIED, for example a frame where no two reads ever matched, or a take
that the card's take table lists but the card does not show. Process the card again; if a take keeps failing, copy the
card to a new folder.

**Warnings** are worth knowing but do not make the copy incomplete. The common ones:

- *The card returned different data the second time N frames were read*: the card's normal read errors; each of these
  frames was read again until two reads matched.
- *The take table also keeps N entries from earlier recordings*: older recordings that were deleted from the card's list.
  The driver does not show them, so they were not copied.
- *Only the chosen takes were copied*: a partial copy; the listed takes are still only on the card.
- *Stopped before everything was made*: the outputs listed were not made; process the card again to make them.
- *No second copy was made*: the second drive was not connected.

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

The card records, per take: the **date and time** it was recorded (the files' dates), the **frame rate**, the
**colour temperature** setting (the camera's COL. TEMP menu: DAYLIGHT or TUNGSTEN, shown as DL or TS in the viewfinder),
**colour or black-and-white**, two **timecodes** (one counting the recording, one the time of day) and the reel name.
ACam shows the recording date, frame rate, colour temperature (or *Monochrome*) and start timecode.

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
the estimate for the card in front of you before you start, for both drives, and does not start a run that will not fit
with the chosen outputs. The outputs' sizes are estimates, so leave a little room to spare.

## Ejecting the card

Click **Eject**, wait for **"… is ejected: you can take the card out of the reader"**, then take the card out. Eject is
refused while the card is being copied. Ejecting in Finder works too.

## Safety, in short

- Every frame is read twice from the card and once from each copy; all reads must match.
- Nothing that is already copied is overwritten. Unfinished leftovers of an interrupted run go to the Trash, not away.
- A copy of some takes is never called ALL VERIFIED.
- A run that will not fit does not start.
- No previews, card changes or eject during a copy.
- The card itself is never written to: the driver is read-only.

## Troubleshooting

| What you see | What to do |
|---|---|
| "No A-Cam card mounted" | Check that the reader is connected and the card is in. Click **Refresh**. If Finder doesn't show the card either, see the driver's [README](../README.md#troubleshooting) |
| The window stays at "Reading ACAM …" | Answer macOS's question about access to removable volumes (it may be behind other windows) |
| macOS says ACam cannot be opened | See [Installing ACam](#installing-acam) |
| "Not enough space…" | Free up space, untick outputs you don't need now, or choose another drive. Outputs can be added later |
| "… holds another recording" or "… is not on this card" | The destination already has a folder with this card's name from a different recording. Choose another destination folder |
| "the second copy must go to another drive" | Choose a second copy folder on a different drive, or click **None** |
| "nothing to add" | The destination already holds every take with these outputs |
| NOTHING TO MAKE | The folder already has the ticked outputs for every take. Tick the ones you want, then try again |
| PROBLEMS FOUND | Read the Problems section of the report, then process the card again |
| MISMATCH FOUND after Verify a copy | The listed files have changed on that drive. Copy those takes again from your other copy or from the card |
| The preview says it could not read a frame | The card was probably taken out. Insert it again and reopen the preview |

## For advanced users: the command line

The app runs the same code as the `acam` command (build it with `make pipeline`; it is in `pipeline/build/`):

```sh
sudo tools/ikctl eeprom 0 0x2000 > eeprom.txt     # the card's take table
pipeline/build/acam offload --source "/Volumes/ACAM 102" --dest /Volumes/Backup --eeprom eeprom.txt --prores both
pipeline/build/acam offload ... --second-dest /Volumes/Backup2   # a second copy on another drive
pipeline/build/acam offload ... --takes AC102003,AC102007        # only these takes (PARTIAL)
pipeline/build/acam offload ... --add                            # add what an earlier run's folder lacks
pipeline/build/acam offload ... --profile factory                # Ikonoskop's colour instead of the sensor-data profile
pipeline/build/acam verify "/Volumes/Backup/ACAM 102"            # check a copy against its checksums
pipeline/build/acam outputs "/Volumes/Backup/ACAM 102"           # make the outputs a copy lacks, without the card
pipeline/build/acam --help                                       # everything else
```

Ctrl-C stops a run the way the Stop button does; pressing it twice quits at once. Without `--add`, `acam offload`
refuses a destination that already has the card's folder.

## Known limits

- Closing a laptop's lid puts the Mac to sleep even during a run.
- The sizes of the outputs are estimates; a drive that is nearly full can still run out during the ProRes movies.
- Verify a copy checks the take folders. `REPORT.md`, the ProRes movies and the colour files have no checksums.
- ACam is not registered with Apple: the first start needs the steps in [Installing ACam](#installing-acam).
- Make outputs from a copy works on one folder at a time: for a second copy, run it on that folder too (or process the
  card again, which updates both).

ACam is made by Kapil Das. It is free and open source (MIT licence).
