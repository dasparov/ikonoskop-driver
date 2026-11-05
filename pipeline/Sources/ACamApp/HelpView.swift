// ACam Help: how the app works, how to copy fast, and the first and second run. Opened from
// Help › ACam Help and the ? button in the main window.
import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("ACam Help").font(Brand.title)
                section("How ACam works", [
                    "Put the card in the reader. ACam lists its takes; click a picture to watch a take with its sound.",
                    "Choose a **Destination** (and, if you like, a **Second copy** on another drive) and the **Outputs**, then click **Process card**. **Process selected takes…** copies only the ticked takes.",
                    "ACam copies every frame and checks it: each frame is read twice from the card and once from each copy, and the reads must match. The card sometimes returns a frame slightly differently; ACam reads such a frame again until two reads agree. It writes checksum files (ASC MHL) and a report (REPORT.md).",
                    "Then it makes the outputs you ticked from the checked copies: the sound as WAV files, clean DNGs and ProRes movies.",
                    "The result: **ALL VERIFIED** (everything copied and checked), **PARTIAL** (some takes are still only on the card), **STOPPED** or **PROBLEMS FOUND** (the report says what). ACam never writes to the card.",
                ])
                fastCopy
                section("First run and second run", [
                    "**First run, on set:** untick Audio, Clean DNGs and ProRes, and click **Process card**. You get the checked copies, their checksums and the report. This is the part that needs the card, and it is as fast as checked copying gets.",
                    "**Second run, later,** makes the outputs. There are two ways:",
                    "**With the card in the reader:** tick the outputs and click **Process card** again, into the same destination. ACam compares the takes in the folder with the card, adds only what is missing (also takes not copied yet) and writes a new report that covers both runs; the earlier one is kept as REPORT-1.md. Do this before the card is recorded over.",
                    "**Without the card:** tick the outputs, click **Make outputs from a copy…** and choose the card's folder. ACam makes the outputs from the copies on the drive. It first checks the copies against their checksums, so it never works from a copy that has changed. It cannot add takes, and it adds a section to the end of REPORT.md. If you keep a second copy, do the same for that folder.",
                ])
                section("Checking a copy later", [
                    "**Verify a copy…** reads a copy ACam made again, file by file, and compares every file with its checksums: **ALL MATCH** or **MISMATCH FOUND**, with the files that changed. Use it after moving a copy to another drive, or before you reuse a card.",
                ])
                section("Good to know", [
                    "ACam keeps the Mac awake during a run (closing a laptop's lid still puts it to sleep), shows a notification when it is done, and remembers your choices.",
                    "**Stop** (⌘.) ends a run. Stopped while copying, nothing of the run is kept and the card still has every take. Stopped while making outputs, the checked copies stay.",
                    "A run that will not fit on the drive does not start: the line under the buttons says why.",
                ])
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("ACam \(acamVersion) by Kapil Das. Free and open source (MIT licence).")
                        .foregroundColor(.secondary)
                    Link("The full manual", destination: URL(string: "https://github.com/dasparov/ikonoskop-driver/blob/main/docs/ACam-manual.md")!)
                    Link("github.com/dasparov/ikonoskop-driver", destination: URL(string: "https://github.com/dasparov/ikonoskop-driver")!)
                }
                .font(Brand.caption)
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .font(Brand.body)
        .frame(minWidth: 520, minHeight: 480)
    }

    /// How long a full 80 GB card takes, and the fastest safe way.
    private var fastCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Brand.label("Copying fast")
            text("The card reader delivers about 165 MB/s, so any copy of a full 80 GB card takes at least 8 minutes. A USB hard disk writes much more slowly than that, so copy to an SSD (the Mac's own disk, or a USB-C or Thunderbolt SSD).")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Way").font(Brand.heading)
                    Text("80 GB card").font(Brand.heading)
                    Text("Checked?").font(Brand.heading)
                }
                GridRow {
                    Text("Finder copy to an SSD")
                    Text("about 8 min")
                    Text("No")
                }
                GridRow {
                    Text("ACam, copies only, to an SSD")
                    Text("about 18–20 min")
                    Text("Yes, every frame")
                }
                GridRow {
                    Text("ACam with WAV and clean DNGs, to a USB hard disk")
                    Text("about 1½ hours")
                    Text("Yes")
                }
            }
            text("A Finder copy keeps a frame the card read wrongly without telling you, and it has no checksums, so it cannot be checked later. The fastest safe way: copy to an SSD with the outputs unticked, and make the outputs in a second run (below). A second copy to another fast drive costs almost no extra time: each frame is written to both as it is read.")
        }
    }

    private func section(_ title: String, _ paragraphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Brand.label(title)
            ForEach(paragraphs, id: \.self) { text($0) }
        }
    }

    /// A paragraph; **bold** marks names of buttons and results.
    private func text(_ markdown: String) -> some View {
        Text((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Help › ACam Help.
struct HelpCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("ACam Help") { openWindow(id: "help") }
    }
}
