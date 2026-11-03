# Ikonoskop A-Cam dII card reader driver for Apple silicon Macs

*"The camera loves you."* (the A-Cam dII's greeting when you switch it on)

A community driver for the Ikonoskop **MK-3 Express Card Reader** that lets Macs with Apple silicon (M1 and later) read
A-Cam dII memory cards. Ikonoskop's last driver, v1.2, runs only on Intel Macs.

With the reader connected, the card shows up in Finder as a read-only volume named `ACAM 000`, where `000` is the card number.
Each take is a folder of CinemaDNG frames, laid out the same way as with Ikonoskop's driver:

```
ACAM 000/IMAGE/AC000001/00000001.DNG ...   take 1
ACAM 000/IMAGE/AC000002/00000624.DNG ...   take 2
```

Copy the footage with Finder as usual. Copying runs at about 165 MB/s, faster than the 130 MB/s Ikonoskop quoted for the reader.

## Tested on

| | |
|---|---|
| Mac | MacBook Pro 16" (2021), M1 Pro |
| macOS | 13.3.1 Ventura |
| Reader | MK-3 Express Card Reader (PCI ID `10ee:0007`) in a Matrox Thunderbolt-to-ExpressCard adapter (System Information shows `Matrox T/ADP`) |
| Card | 80 GB, 20 takes, 9359 frames |

**Newer macOS:** the driver hasn't run on macOS 14 or later yet. Checked against the macOS 27.2 kernel for the Mac above, every
kernel function it uses is still there, in versions that accept it. Apple's macOS 27 documentation still offers the
Reduced Security setting that lets drivers like this one load.

**Not tested:** 160 GB cards, other Thunderbolt adapters, and other Macs. The driver needs macOS 13 or later.
Reports from other setups are welcome; please open an issue.

## What you need

- A Mac with Apple silicon.
- The MK-3 **ExpressCard** reader. This driver doesn't support the older USB reader.
- A Thunderbolt-to-ExpressCard/34 adapter. If the adapter has the older Thunderbolt 1/2 connector, you also need Apple's
  Thunderbolt 3 (USB-C) to Thunderbolt 2 Adapter.
- An administrator account, for the one-time security change below.

## Before you install: this lowers your Mac's security

Apple silicon Macs only load third-party kernel drivers after you lower the startup security. This driver isn't signed with an
Apple Developer ID; it is "ad-hoc" signed, and that additionally requires turning off System Integrity Protection's
kernel-extension check. Both changes apply to the whole Mac, not just this driver. [Uninstall](#uninstall) explains how to undo them.

A kernel driver runs inside macOS itself, so a bug in it can crash (restart) the Mac. The driver only reads from the card: macOS
can't write to it or erase it through this driver.

## Install

### 1. One-time: allow kernel extensions

1. Shut down the Mac. Press and hold the power button until "Loading startup options" appears, then click **Options** > **Continue**.
2. Choose **Utilities** > **Startup Security Utility**. Select your startup disk, click **Security Policy**, choose
   **Reduced Security**, and tick **Allow user management of kernel extensions from identified developers**. Click **OK**.
   (Apple's instructions: [Change security settings on the startup disk](https://support.apple.com/guide/mac-help/change-security-settings-startup-disk-a-mac-mchl768f7291/mac).)
3. Choose **Utilities** > **Terminal** and run:
   ```sh
   csrutil enable --without kext
   ```
4. Restart.

### 2. Install the driver

**From the release (no developer tools needed):** download `IkonoskopCardReader-<version>.zip` from
[Releases](../../releases), open it, then in Terminal:

```sh
cd ~/Downloads/IkonoskopCardReader-1.2.2
bash install.sh
```

**From source:** install Apple's Command Line Tools (`xcode-select --install`), then:

```sh
git clone https://github.com/dasparov/ikonoskop-driver.git
cd ikonoskop-driver
make install        # builds, runs the tests, then installs
```

`install.sh` asks for your password, copies the driver to `/Library/Extensions`, and tells you what to do next.

### 3. Approve it and restart

Open **System Settings** > **Privacy & Security**. Near the bottom it says that system software requires your attention, or that
it was blocked. Click **Details…** or **Allow**, switch on the Ikonoskop extension, and enter your password. Then restart.

macOS approves this kind of driver by its exact build, so every new version needs this approval again. Restarting without
approving keeps the previous version running.

### 4. Use it

Power the reader, insert a card, and connect it to the Mac. The `ACAM` volume appears in Finder. Eject it before you unplug the reader.

To check that the driver is running (the reader has to be connected):

```sh
kmutil showloaded --bundle-identifier org.ikonoskop.community.CardReader
```

## Uninstall

Run `bash uninstall.sh` from the release folder, or `make uninstall` in the source folder, then restart.

To restore full security afterwards, start up in Recovery again (step 1.1), run `csrutil enable` in Terminal, set
Startup Security Utility back to **Full Security**, and restart.

## Troubleshooting

- **No volume, and `kmutil showloaded` prints nothing:** check that the Mac sees the reader. In System Information, the
  Thunderbolt section should list the adapter, and `ioreg -l | grep pci10ee,7` should print a line. If it does, the
  driver probably isn't approved. Compare the installed build's code hash with the approved list:
  ```sh
  codesign -dvvv /Library/Extensions/IkonoskopCardReader.kext 2>&1 | grep ^CDHash
  plutil -extract UnsignedKernelExtensions xml1 -o - /var/db/SystemPolicyConfiguration/UAKL.plist
  ```
  If the hash isn't listed, approve it (step 3) and restart.
- **Driver log:**
  ```sh
  log show --last 5m --predicate 'senderImagePath CONTAINS "IkonoskopCardReader"'
  ```
- msdosfs logs `device sector count (...) is less than volume sector count (...)` when the card mounts. This is expected: the
  volume reports the same fixed size as Ikonoskop's driver, and every file lies within the card.

## Known limits

- Read-only.
- The driver waits up to 5 seconds after connecting for the reader to report the card's flash size. If it never does, the driver
  assumes an 80 GB card, which would be wrong for a 160 GB card.

## How it works

The camera writes raw sensor frames to the card's flash without a file system. Like Ikonoskop's driver, this one presents the
card as a FAT32 disk that it builds in memory: the directory and file entries come from the take table in the card's EEPROM,
and each `.DNG` file is a CinemaDNG header followed by the frame's raw data, read from flash by DMA when Finder reads the file.

| Folder | Contents |
|---|---|
| `core/` | Hardware-independent part: take table, FAT32 and directory synthesis, DNG headers, an 8-frame read cache |
| `kext/` | macOS driver: PCI setup, scatter-gather DMA, interrupts, the block device, and a debug interface |
| `tools/ikctl` | Debug command line tool (`sudo tools/ikctl status`, `reg`, `eeprom`, `frame`, `sectors`) |
| `test/` | A mock reader and card, file system tests (build the disk image, `fsck_msdos`, mount, compare every file), and a differential test against Ikonoskop's driver |

Changes from Ikonoskop's v1.2 besides the Apple silicon port:

- Reconnecting the reader could garble every take except the first, because the driver read the card's flash size before the
  reader reported it. The driver now waits for it.
- Copying several files at once (as Finder does) was slow, 26 MB/s in testing, because the driver cached only one frame and
  re-read it from flash for every request. It now caches eight.

## Offloading a card: `acam` and the ACam app

`pipeline/` holds a tool that turns a mounted card into verified, ready-to-edit footage. It only reads the card.

| Step | What you get |
|---|---|
| Verified copy | `<card>/<take>/frames/`: every frame, read twice from the card and once from the copy, compared with xxHash64. Frames the card returns differently are read again until two reads match. An ASC MHL checksum history per take (`<take>/ascmhl/`) and `REPORT.md`, ending with ALL VERIFIED or PROBLEMS FOUND |
| Audio | `<take>/<take>_Audio.wav`: the camera's 48 kHz 16-bit stereo sound, which is stored inside each frame, with the start timecode (BWF) |
| Clean DNGs | `<take>/clean/`: Make and Model, valid colour tags, lossless compression (about half the size), pixel-identical to the originals |
| ProRes (optional) | `<card>/prores/`: ProRes 4444 XQ, ACEScct log or Rec.709, with sound and timecode |

On the command line (build it with `make pipeline`):

```sh
sudo tools/ikctl eeprom 0 0x2000 > eeprom.txt     # the card's take table, checked against the copies
pipeline/build/acam offload --source "/Volumes/ACAM 000" --dest /Volumes/Backup --eeprom eeprom.txt --prores both
```

`--profile kai02150-ir665` gives the clean DNGs a colour profile built from the sensor's published data instead of the factory
matrices (`pipeline/colour/`). Or build the Mac app with `make app`, open `pipeline/build/ACam.app`, pick the card and a
destination, and press **Process card**.

## Building and testing

```sh
make                 # driver and tools/ikctl
make check           # tests, then driver checks
make release         # make check, then dist/IkonoskopCardReader-<version>.zip
make pipeline        # the acam tool (pipeline/build/acam)
make pipeline-check  # its tests
make app             # the ACam Mac app (pipeline/build/ACam.app)
```

The file system tests create and mount disk images under `/tmp`. The differential test runs Ikonoskop's original x86_64 driver
code in the [Unicorn](https://www.unicorn-engine.org/) emulator and compares every sector it produces with this driver's. That
needs the x86_64 code from Ikonoskop's v1.2 driver, which isn't included here. If you have that driver, extract it and pass its
path, or save it as `../ikonoskop-private/reference/IkonoskopCardReader12.x86_64` (next to this folder), where `make check`
looks by default:

```sh
lipo -thin x86_64 IkonoskopCardReader.kext/Contents/MacOS/IkonoskopCardReader -output /tmp/ik12.x86_64
make -C test diff ORIGINAL=/tmp/ik12.x86_64
```

Without it, `make check` skips the differential test.

Built and tested with Apple's Command Line Tools 14.3 (Apple clang 14.0.3, macOS SDK 13.3, Swift 5.8) on macOS 13.3.1. The
differential test installs unicorn 2.1.4 into `test/.venv`.

## Legal

This project is not affiliated with or endorsed by Ikonoskop. It is an independent driver written to keep A-Cam dII footage
readable on current Macs, based on analysis (reverse engineering) of how Ikonoskop's v1.2 driver works with the reader. The
source contains no Ikonoskop code or binaries. The CinemaDNG headers are generated by this project's code and match the original
driver's byte for byte, including the camera's factory calibration values (colour matrices, black and white levels), so the
files are the same as those it produced. Ikonoskop and A-Cam are names of their respective owners.

Released under the [MIT License](LICENSE), without warranty.
