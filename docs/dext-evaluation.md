# Porting the card reader driver to DriverKit (a "dext"): evaluation

*Phase 7, second item. Written 2026-11-03. This is an evaluation only: nothing was built or changed, and the next step is your decision.*

## Summary in plain language

**What a dext is.** Today's driver is a *kernel extension* (kext): it runs inside macOS itself, which is why your Mac needs
Reduced Security, a System Integrity Protection change, approval of every build, and a restart. Apple's replacement is
*DriverKit*: the driver runs as a normal, isolated program (a "driver extension", or dext). A dext is installed by an app,
approved once in System Settings, needs no restart, and runs with your Mac at Full Security. If it crashes, the Mac keeps running.

**The catch: you would lose the `ACAM` disk in Finder.** The current driver pretends to be a disk, and macOS mounts it.
DriverKit does have disk-driver kits, but they only work when the *hardware itself* copies every byte into the Mac's memory.
Our driver builds the folders, file tables and DNG headers in software, and DriverKit's disk kits give it no way to write those
bytes. So a dext can't produce the `ACAM` volume. The practical replacement is: the dext only talks to the reader, and the `acam`
tool (and the Mac app from Phase 6) reads the frames directly and writes the DNG files into your destination folder. You would
"offload" the card instead of browsing it. A Finder-style mount would still be possible later with Apple's FSKit, but only on
macOS 26 or newer, and with more work.

**Apple's permission is the big unknown.** A dext only loads if it is signed with special permissions ("entitlements") that
Apple grants. Two cases:

- **Just for your own Macs:** a paid Apple Developer Program membership (US$99 a year) gives you "development" versions of these
  permissions without asking Apple. A dext signed that way should load on Macs you register in your account, at Full Security.
  Apple's driver engineer describes this on the developer forums, but we haven't tried it yet. Checking it takes about a day.
- **For other A-Cam owners:** you would have to ask Apple for the real permission. Apple grants it per PCI *vendor ID*. The reader
  uses Xilinx's vendor ID (the chip maker), not Ikonoskop's own, and neither you nor this project owns it. Apple may say no, or
  take months: other developers on Apple's forums report requests still pending after weeks or months.

**Cost.** About 6 to 11 weeks of work for an experienced macOS driver developer (details below), US$99 a year, Xcode (Apple's
full developer app, which we don't use today), and probably a macOS upgrade on the development Mac. Testing needs the reader and
a card, and the old driver has to be removed while the new one is tested.

**Recommendation: don't port now.** The current driver works, and Apple's macOS 27 documentation still offers the Reduced
Security setting it needs. If Full Security matters to you, the safe order is:

1. Join the Developer Program and spend about a day on a tiny test dext that only recognises the reader and reads one value
   from it, at Full Security. If that works, the "own Macs" route is proven.
2. Only then build the real thing as option (a) below (dext plus the `acam` tool and app, no mounted volume), and ask Apple for the
   distribution permission at the same time, without depending on the answer.

---

## 1. What the current driver does

| Part (in `kext/`) | What it does |
|---|---|
| PCI setup | Matches PCI ID `10ee:0007` (also through Thunderbolt), turns on memory access and bus mastering, maps BAR0 |
| Register access | 32-bit reads and writes in BAR0, including a small SPI controller used to read the card's metadata EEPROM |
| Frame DMA | One 3.3 MB buffer, mapped through the Mac's IOMMU (the DART) with 32-bit addresses and described to the reader as 821 entries of 4 KiB; the reader copies one frame into it per request |
| Interrupts | MSI (with a legacy fallback); a 500 ms timeout aborts a stuck transfer |
| Worker thread | Runs all card work outside interrupt context and queues block reads |
| Block device | An `IOBlockStorageDevice` that macOS's FAT driver (msdosfs) mounts read-only as `ACAM nnn` |
| User client | Root-only debug interface for `tools/ikctl` (status, EEPROM, raw frame, sectors, register read) |
| `core/` | Hardware-independent logic: take table, FAT32 and directory synthesis, DNG headers, frame cache. No IOKit, no STL, no exceptions, no RTTI, so it already builds in user space (the test harness) |

## 2. How the parts map to PCIDriverKit

PCIDriverKit gives a dext an `IOPCIDevice` provider for MMIO and configuration access, and DriverKit supplies DMA, interrupt,
memory and user-client classes. It runs on Apple silicon and Intel Macs.
([PCIDriverKit](https://developer.apple.com/documentation/pcidriverkit),
[IOPCIDevice](https://developer.apple.com/documentation/pcidriverkit/iopcidevice),
[Creating Custom PCIe Drivers for Thunderbolt Devices](https://developer.apple.com/documentation/pcidriverkit/creating-custom-pcie-drivers-for-thunderbolt-devices))

| Kext today | DriverKit equivalent | Fit |
|---|---|---|
| `IOService` subclass, `start`/`stop` | `IOService` subclass declared in an `.iig` file, `Start`/`Stop`, state in an `ivars` struct ([Creating a Driver Using the DriverKit SDK](https://developer.apple.com/documentation/driverkit/creating-a-driver-using-the-driverkit-sdk)) | Direct |
| `setMemoryEnable` / `setBusLeadEnable` | `IOPCIDevice::Open`, then set Memory Space and Bus Master in the command register with `ConfigurationRead16`/`ConfigurationWrite16`. Apple's note: the endpoint driver must enable both every time it configures the device | Direct |
| `mapDeviceMemoryWithRegister(BAR0)` plus pointer loads/stores | `GetBARInfo` for BAR0's memory index, then `MemoryRead32`/`MemoryWrite32`. A failed read returns -1, which matches the driver's existing "all ones means the device is gone" checks ([MemoryRead32](https://developer.apple.com/documentation/pcidriverkit/iopcidevice/memoryread32-60hg9)) | Direct |
| SPI EEPROM polling with `IODelay` | Same register sequence; DriverKit has `IODelay` and `IOSleep` ([IODelay](https://developer.apple.com/documentation/driverkit/iodelay)) | Direct |
| `IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task, …)` | `IOBufferMemoryDescriptor::Create(options, 0x335000, 16384, …)`, then `CreateMapping` to get a pointer in the dext ([Create](https://developer.apple.com/documentation/driverkit/iobuffermemorydescriptor/create)) | Direct |
| `IODMACommand::withSpecification(…, 32 bits, kMapped, device mapper)` and `gen32IOVMSegments` | `IODMACommand::Create` with an `IODMACommandSpecification` whose `maxAddressBits` is 32, then `PrepareForDMA`, which returns up to 32 address segments. The dext splits the mapped range into 4 KiB entries for the reader's table, as the kext does now ([IODMACommand](https://developer.apple.com/documentation/driverkit/iodmacommand), [PrepareForDMA](https://developer.apple.com/documentation/driverkit/iodmacommand/preparefordma)) | Direct, see risks |
| `IOFilterInterruptEventSource` on a work loop, MSI or legacy | `IOPCIDevice::ConfigureInterrupts` plus `IOInterruptDispatchSource::Create(provider, index, queue, …)`. The handler runs on a normal thread. **DriverKit supports only MSI for PCI devices** ([IOInterruptDispatchSource](https://developer.apple.com/documentation/driverkit/iointerruptdispatchsource)) | Fits if the reader offers MSI (see risks) |
| Kernel worker thread, `IOLockSleepDeadline` with a 500 ms deadline | `IODispatchQueue`s, an `IOTimerDispatchSource` for the timeout, and asynchronous completions (`OSAction`) back to the client ([IODispatchQueue](https://developer.apple.com/documentation/driverkit/iodispatchqueue)) | Needs restructuring: the code waits for the interrupt; a dext reacts to it |
| `requestTerminate`/`willTerminate` (Thunderbolt unplug) | `Stop` (cancel queues, fail pending requests, then call super) ([Stop](https://developer.apple.com/documentation/driverkit/ioservice/stop)) | Direct |
| Root-only `IOUserClient` with `IOExternalMethodDispatch` | DriverKit `IOUserClient`: `ExternalMethod` with `IOUserClientMethodDispatch` argument checks; large data through `CopyClientMemoryForType`, which can map the frame buffer *read-only* into the client with no copy ([IOUserClient](https://developer.apple.com/documentation/driverkit/iouserclient), [CopyClientMemoryForType](https://developer.apple.com/documentation/driverkit/iouserclient/copyclientmemoryfortype), [sample](https://developer.apple.com/documentation/driverkit/communicating-between-a-driverkit-extension-and-a-client-app)) | Direct. Access control changes from "root only" to "clients with an entitlement" (section 4) |
| `IOBlockStorageDevice` nub mounted by msdosfs | No workable equivalent (section 3) | **Gap** |
| `core/` | Builds unchanged in a dext or in the `acam` tool: it only needs `memcpy`/`memset` and `snprintf` and a small hardware interface | Direct |

### Gaps and risks in the mapping

- **32-bit DMA addresses and the DART.** The reader only takes 32-bit addresses. DriverKit's DMA specification accepts
  `maxAddressBits = 32`, and the kext already gives the reader addresses from the device's DART rather than physical addresses,
  which is the only mode a dext has. One developer on Apple's PCIDriverKit forum reports Thunderbolt DMA addresses starting at
  `0x80000000` with a 32-bit specification ([forum, PCIDriverKit tag](https://developer.apple.com/forums/tags/pcidriverkit)). Risk: low.
  `[INFERENCE]` The kext keeps one DMA mapping for its whole lifetime and calls `synchronize` after each frame. DriverKit has
  no documented per-transfer synchronize call. PCIe DMA on Apple silicon should be cache-coherent, so the same design should work,
  but only the real hardware can confirm it.
- **Bridges behind Thunderbolt.** The same forum reports a system crash when a card had a PCIe-to-PCI-X bridge whose ID the DART
  didn't expect. The ExpressCard reader is native PCIe and the kext's DART mapping already works through the Matrox adapter, so
  `[INFERENCE]` the risk is low; the first test dext would show it immediately.
- **MSI only.** Our driver falls back to a legacy interrupt if there's no MSI; DriverKit can't. `[INFERENCE]` The original
  Ikonoskop driver used MSI and failed outright without it, and it worked on Intel Macs, so the reader almost certainly offers MSI.
  `sudo tools/ikctl status` (it prints "(MSI)") would confirm it with today's driver, without any changes.
- **Thunderbolt hot-plug.** The dext's personality needs `IOPCITunnelCompatible` (Apple's Thunderbolt article above). Unplugging
  calls `Stop`; pending client calls must fail cleanly. This is the same work the kext already does, and a mistake now crashes only
  the dext, not the Mac.
- **Power management.** The kext doesn't handle sleep either. A dext gets `SetPowerState` calls
  ([SetPowerState](https://developer.apple.com/documentation/driverkit/ioservice/setpowerstate)). `[INFERENCE]` A Thunderbolt
  device is usually torn down on sleep and found again on wake, so the dext would mostly behave like an unplug and replug. Risk: low.
- **Waiting versus reacting.** The biggest code change: today one thread starts a DMA transfer and sleeps until the interrupt
  arrives. In DriverKit, a request starts the transfer, and the interrupt handler (or the 500 ms timer) finishes it and answers the
  client. This is ordinary DriverKit design, but most of `kext/IkonoskopCardReader.cpp`'s control flow would be rewritten. The register
  sequences themselves stay the same.
- **Toolchain.** A dext needs Xcode and its DriverKit SDK; the Command Line Tools we use today don't include them. Xcode 14.3.1 runs
  on your macOS 13.3, but Apple's driver engineer says Xcode's automatic signing handles dexts properly only from Xcode 16, which
  needs macOS 14.5 or later ([Xcode system requirements](https://developer.apple.com/xcode/system-requirements/),
  [forum: How to sign a DEXT](https://developer.apple.com/forums/thread/809202)).

## 3. Can a dext present a disk that macOS mounts?

DriverKit's storage kits:

| DriverKit family | Since | What it is for |
|---|---|---|
| [BlockStorageDeviceDriverKit](https://developer.apple.com/documentation/blockstoragedevicedriverkit) (`IOUserBlockStorageDevice`) | macOS 12 (DriverKit 21) | Custom storage hardware with its own protocol, used together with PCIDriverKit |
| [SCSIControllerDriverKit](https://developer.apple.com/documentation/scsicontrollerdriverkit) | macOS 11.3 (DriverKit 20.4) | SCSI host adapters on PCI or Thunderbolt |
| [SCSIPeripheralsDriverKit](https://developer.apple.com/documentation/scsiperipheralsdriverkit) | macOS 13 (DriverKit 22) | Drivers for SCSI devices on an existing SCSI transport |

On paper BlockStorageDeviceDriverKit is the match. In practice it doesn't work for this card:

- Its read call, [`DoAsyncReadWrite`](https://developer.apple.com/documentation/blockstoragedevicedriverkit/iouserblockstoragedevice/doasyncreadwrite),
  gives the dext only a **DMA address** for the destination buffer, not memory the dext can write to. Apple's open-source kernel
  side shows why: it maps the buffer into the PCI device's DART and passes a single device address
  ([IOStorageFamily, `IORequest.cpp` and `IOUserBlockStorageDevice_kext.cpp`](https://github.com/apple-oss-distributions/IOStorageFamily)).
  The family is built for hardware that copies data into the Mac's memory by itself.
- SCSIControllerDriverKit works the same way: Apple's driver engineer (Kevin Elliott) says on the forums that its buffer address is a
  device address the dext can't turn into memory it can access (cited in a post under the
  [DriverKit forum tag](https://developer.apple.com/forums/tags/driverkit), thread 776020).
- Our "disk" is mostly made by software: the FAT32 boot sector, FAT tables, folders and every DNG's 4 KiB header are generated by
  `core/`. Only the frame data comes from the reader's DMA engine. `[INFERENCE]` The reader can only copy from the card's flash to the
  Mac, not from Mac memory to Mac memory, so there's no way to get the generated bytes into the buffer.

**Conclusion: no DriverKit family lets this driver present the `ACAM` volume.** The alternatives:

| | (a) dext + user client, `acam` writes the files | (b) dext + FSKit file system | (c) dext + local network share |
|---|---|---|---|
| How it works | The dext only reads registers, the EEPROM and frames. `acam` links `core/` (it already builds in user space), rebuilds the exact same DNG files and writes them to the destination | An FSKit module (a user-space file system extension) shows the takes as a read-only volume; it asks the dext for frames | A small server in the app serves the files to macOS's own NFS client on `localhost` (the way fuse-t works) |
| macOS needed | Any version that runs the dext (macOS 12 or later is plenty) | **macOS 26 or later.** FSKit exists from macOS 15.4, but until macOS 26 it only mounts real disks ([FSBlockDeviceResource](https://developer.apple.com/documentation/fskit/fsblockdeviceresource)); a volume that isn't a disk needs [FSGenericURLResource](https://developer.apple.com/documentation/fskit/fsgenericurlresource) (macOS 26) | Any |
| Finder browsing, other apps reading the card directly | No. Card → offload → folder | Yes, once mounted (`mount -t …` or the app) | Yes, with network-volume quirks |
| Extra permissions | None beyond the dext's | [`com.apple.developer.fskit.fsmodule`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule); the user turns on the extension in System Settings > General > Login Items & Extensions ([FSKit sample](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system)). `[INFERENCE]` The sandboxed extension also needs permission to open the dext's user client; not tested | None |
| Extra work over (a) | n/a | +2 to 4 weeks; speed of a user-space file system at 165 MB/s unknown | +3 to 5 weeks; most fragile |
| Fit with the pipeline | Best: `acam offload` already verifies and hashes every file; the Phase 6 app becomes the dext's host app | Good | Fair |

Option (a) matches how the project is used: SPEC.md's workflow is offload first, then process. It loses the "just browse the card"
convenience. Because `core/` produces byte-identical files, the existing MHL hashes from a kext-based offload can prove that the dext
path produces the same footage.

## 4. Entitlements and process

### Entitlement keys

| Key | Where | Value for this driver | Needs Apple's approval for distribution? |
|---|---|---|---|
| [`com.apple.developer.driverkit`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit) | dext | `true` | Yes |
| [`com.apple.developer.driverkit.transport.pci`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.transport.pci) | dext | Array of match dictionaries, for example `IOPCIPrimaryMatch` = `0x000710EE` (device `0007`, vendor `10EE`). The same keys go in the dext's `IOKitPersonalities` with `IOPCITunnelCompatible` = true | Yes. A forum report says Apple granted a vendor ID only, not vendor plus device ([forum, PCIDriverKit tag](https://developer.apple.com/forums/tags/pcidriverkit)) |
| [`com.apple.developer.driverkit.userclient-access`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.userclient-access) | the app (or tool) that opens the user client | Array with the dext's bundle ID | Yes |
| *or* [`com.apple.developer.driverkit.allow-any-userclient-access`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.allow-any-userclient-access) | dext | `true`: any program may connect. Acceptable for a read-only device, and lets the plain `acam` command-line tool connect without its own provisioning profile | Yes |
| [`com.apple.developer.system-extension.install`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.system-extension.install) | host app | `true` (Xcode's "System Extension" capability) | No, standard capability |
| `com.apple.developer.driverkit.family.*` | dext | **None needed** for options (a) and (c). Only a block-storage dext would need [`family.block-storage-device`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.family.block-storage-device), which section 3 rules out | n/a |
| [`com.apple.developer.fskit.fsmodule`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule) | FSKit extension, option (b) only | `true` | Not stated in Apple's documentation |

A command-line tool can't carry restricted entitlements by itself; it has to live inside an app bundle with a provisioning profile
([Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)).
So with `userclient-access`, `acam` would ship inside the A-Cam app; with `allow-any-userclient-access` on the dext, it can stay a
plain tool.

### Development versus distribution

- **Development entitlements, no approval needed.** Apple now offers "development" versions of all DriverKit entitlements on every
  paid developer account. They work only in development-signed builds and allow matching *any* hardware; the development form of the PCI
  entitlement is `IOPCIPrimaryMatch` = `0xFFFFFFFF&0x00000000` (Kevin Elliott, DTS,
  [How to sign a DEXT](https://developer.apple.com/forums/thread/809202); the same post appears under the
  [USBDriverKit tag](https://developer.apple.com/forums/tags/usbdriverkit)). A development-signed build only runs on Macs registered
  in the developer account. `[INFERENCE]` It loads with SIP and Full Security on: the post presents it as the replacement for the old
  "disable SIP" method, and developers run such builds on iPads, where SIP can't be turned off. This is the first thing the test dext
  should confirm.
- **Distribution entitlements, approval needed.** Request them at [developer.apple.com/system-extensions](https://developer.apple.com/system-extensions/)
  ([Requesting Entitlements for DriverKit Development](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development)).
  The form asks for the transport (PCI), *"your company's hardware vendor ID"* (here 4334 = `0x10EE`, which belongs to Xilinx),
  device descriptions and the app that installs the driver. Apple ties the grant to the developer team, as one group of entitlements.
- **Program membership:** the Apple Developer Program costs US$99 a year, as an individual or an organisation
  ([Apple Developer Program](https://developer.apple.com/programs/)). It's needed for development entitlements, Developer ID
  certificates, notarisation and entitlement requests. Free accounts can't sign dexts.

### Packaging, signing and installing

1. The dext goes in the app's `Contents/Library/SystemExtensions`. The app must be in `/Applications` and asks macOS to activate the
   dext with `OSSystemExtensionRequest.activationRequest` ([Installing System Extensions and Drivers](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers)).
   Updates use the same call with a higher version number; deleting the app removes the dext.
2. Distribution builds are signed with a **Developer ID** certificate and Developer ID provisioning profiles that contain the approved
   entitlements ([Developer ID](https://developer.apple.com/developer-id/)), then **notarised** by Apple
   ([Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)).
3. The user approves the driver once: on macOS 15 and later in System Settings > General > Login Items & Extensions
   ([Apple Support](https://support.apple.com/guide/mac-help/change-login-items-extensions-settings-mtusr003/mac)); on macOS 13 and 14 under
   Privacy & Security. No restart and no trip to Recovery mode.

### What still needs SIP or Reduced Security

| Setup | Security changes needed |
|---|---|
| Distribution build (Developer ID, approved entitlements, notarised) | **None.** Full Security, SIP on |
| Personal build (development-signed, development entitlements, Mac registered in the account) | None `[INFERENCE, to confirm with the test dext]` |
| Unsigned/"Sign to Run Locally" development build | SIP fully off plus `systemextensionsctl developer on` ([Debugging and testing system extensions](https://developer.apple.com/documentation/driverkit/debugging-and-testing-system-extensions)). Worse than today's setup; avoid |
| Reduced Security | Never needed for a dext. Apple's arm64e test mode needs lower security, but a dext built for plain arm64 doesn't need it |

## 5. Effort, risks, gains and losses

### Effort (person-weeks for an experienced macOS driver developer)

| Component | Low | High |
|---|---|---|
| Setup: membership, Xcode, project, signing; test dext that matches the reader and reads one register at Full Security | 0.5 | 1.5 |
| Hardware layer: MMIO, SPI EEPROM, DMA buffer and 32-bit DART mapping, reader DMA table, MSI, 500 ms timeout and abort, unplug, rewritten as event-driven code | 1.5 | 3 |
| User client (status, EEPROM, frame into a shared read-only buffer, register read) and a Swift wrapper | 0.5 | 1 |
| `acam` direct-read source: `core/` driven through the user client, `acam offload` reading from it instead of `/Volumes/ACAM…`, kernel-log checks moved to the dext's log | 1 | 2 |
| Host app: install, activate, update, uninstall, approval guidance (folds into the Phase 6 app) | 0.5 | 1 |
| Hardware testing: byte-for-byte comparison with MHLs from a kext offload, whole-card copies, unplug during copy, sleep, both card sizes if available | 1 | 2 |
| Distribution: Developer ID signing, notarisation, README | 0.5 | 0.5 |
| **Total, option (a)** | **5.5** | **11** |
| Option (b) on top: FSKit read-only volume (macOS 26+) | +2 | +4 |

Waiting for Apple isn't included: the request can sit for weeks or months, and the work can go ahead with development entitlements in
the meantime.

### Risks

| Risk | Likelihood | Effect | Mitigation |
|---|---|---|---|
| Apple refuses or delays the distribution PCI entitlement: vendor ID `0x10EE` is Xilinx's, the device is discontinued, the requester isn't the manufacturer. Recent forum threads ask exactly this for other end-of-life devices without a published answer, and several requests show as pending for weeks ([forum](https://developer.apple.com/forums/tags/usbdriverkit)) | High | Only Macs registered in your account can use the dext; other owners keep the kext | Decide up front that personal use is enough; request anyway and explain that matching is limited to `10ee:0007` |
| Development-signed dext doesn't load at Full Security after all | Low to medium | The personal route collapses to "SIP off", which is worse than today | Test dext first (1 day) before any real work |
| Only one reader, one Mac, no simulator for PCIDriverKit | Certain | Kext and dext both claim the reader, so testing the dext means uninstalling the kext (with restarts); a bug in the dext means no working reader until the kext is reinstalled | Offload important cards before switching; keep the kext release ready to reinstall; `core/` stays covered by the existing mock-hardware tests |
| DMA/DART behaviour differs in a dext (bridge IDs, cache coherency) | Low | Frames garbled or the transfer fails | Shows up in the first frame test; compare against kext MHLs |
| Reader has no MSI | Very low | DriverKit can't take its interrupt; would need a polling design | Check `ikctl status` today |
| Toolchain change: Xcode, newer macOS on the development Mac | Certain | A second build system next to the Makefiles | Keep `core/` and `pipeline/` building as now; only the dext and app need Xcode |
| Membership lapses | Medium over the years | `[INFERENCE]` Development-signed builds stop working when their profile expires (needs a yearly renewal and rebuild); whether Developer ID-signed dexts keep loading after a lapse isn't documented in the pages read | Budget US$99 a year for as long as the reader is in use |

### What you gain and lose

**Gain**
- Full Security and SIP back on; no Recovery-mode setup on a new Mac.
- No restart to install or update, one approval per install instead of one per build.
- A driver bug crashes the dext, not the Mac.
- Off the deprecated path: Apple calls kexts deprecated and points to system extensions
  ([Deprecated Kernel Extensions](https://developer.apple.com/support/kernel-extensions/)), so the day Reduced Security goes away
  won't strand the footage.
- Other A-Cam owners could use it **if** Apple grants the distribution entitlement.

**Lose**
- The `ACAM` volume in Finder (until an FSKit version on macOS 26+). Other apps such as Resolve can't open the card directly; footage
  goes through `acam offload` or the app first.
- Independence: a yearly fee, Apple's approval, and Xcode, where the kext needs only the free Command Line Tools.
- Simplicity: one kext becomes an app, a dext and a user client.
- Months of work to reach what already works today.

## 6. Recommendation

Keep the kext for now. It works, and it isn't blocked on any current macOS.

If you want to move to Full Security, stop after step 1 at first:

1. **Test dext (about 1 day after joining the program):** a development-signed dext that matches `10ee:0007`, maps BAR0 and logs the
   flash-size register, installed by a tiny app from `/Applications`, with Full Security and SIP on. Also run `sudo tools/ikctl status`
   with today's driver to confirm MSI.
2. If step 1 works and losing the Finder volume is acceptable: build option (a), then submit the distribution entitlement request,
   without making the project depend on the answer.
3. Consider option (b) only once your Macs run macOS 26 or later and browsing the card in Finder matters.

## Sources

Apple documentation: [DriverKit](https://developer.apple.com/documentation/driverkit) ·
[PCIDriverKit](https://developer.apple.com/documentation/pcidriverkit) ·
[IOPCIDevice](https://developer.apple.com/documentation/pcidriverkit/iopcidevice) ·
[Creating Custom PCIe Drivers for Thunderbolt Devices](https://developer.apple.com/documentation/pcidriverkit/creating-custom-pcie-drivers-for-thunderbolt-devices) ·
[IODMACommand](https://developer.apple.com/documentation/driverkit/iodmacommand) ·
[IOInterruptDispatchSource](https://developer.apple.com/documentation/driverkit/iointerruptdispatchsource) ·
[IOUserClient](https://developer.apple.com/documentation/driverkit/iouserclient) ·
[BlockStorageDeviceDriverKit](https://developer.apple.com/documentation/blockstoragedevicedriverkit) ·
[IOUserBlockStorageDevice](https://developer.apple.com/documentation/blockstoragedevicedriverkit/iouserblockstoragedevice) ·
[SCSIControllerDriverKit](https://developer.apple.com/documentation/scsicontrollerdriverkit) ·
[FSKit](https://developer.apple.com/documentation/fskit) ·
[Requesting Entitlements for DriverKit Development](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development) ·
[Debugging and testing system extensions](https://developer.apple.com/documentation/driverkit/debugging-and-testing-system-extensions) ·
[Installing System Extensions and Drivers](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers) ·
[System extensions in macOS (Apple Platform Deployment)](https://support.apple.com/guide/deployment/system-extensions-in-macos-depa5fb8376f/web) ·
[Xcode system requirements](https://developer.apple.com/xcode/system-requirements/) ·
[Apple Developer Program](https://developer.apple.com/programs/)

Apple open source: [IOStorageFamily](https://github.com/apple-oss-distributions/IOStorageFamily) (`BlockStorageDeviceDriverKit/IOUserBlockStorageDevice.iig`,
`IOUserBlockStorageDevice_kext.cpp`, `IORequest.cpp`, tag IOStorageFamily-337.100.1).

Apple Developer Forums: [How to sign a DEXT](https://developer.apple.com/forums/thread/809202) (Kevin Elliott, DTS) ·
[PCIDriverKit tag](https://developer.apple.com/forums/tags/pcidriverkit) · [DriverKit tag](https://developer.apple.com/forums/tags/driverkit) ·
[USBDriverKit tag](https://developer.apple.com/forums/tags/usbdriverkit) ·
[DriverKit entitlement eligibility for an EOL third-party device](https://developer.apple.com/forums/thread/842748) ·
[DriverKit PCI entitlement pending](https://developer.apple.com/forums/thread/849407). Forum pages were read on 2026-11-03.
