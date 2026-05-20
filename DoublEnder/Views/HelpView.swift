import SwiftUI

// Palette kept in sync with ContentView / RecoveryView so the help window
// reads as part of the same product rather than a generic system document.
private let helpSurface  = Color(red: 0x1A/255, green: 0x1A/255, blue: 0x1A/255)
private let helpText     = Color(red: 0xE8/255, green: 0xE8/255, blue: 0xE8/255)
private let helpAccent   = Color(red: 0x39/255, green: 0xFF/255, blue: 0x14/255)
private let helpSecondary = Color(red: 0xA0/255, green: 0xA0/255, blue: 0xA0/255)

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                section("Overview") {
                    text("""
                    DoublEnder is a minimal audio recorder for macOS. Pick your microphone, \
                    hit record, and get an AAC file on your Desktop. That's the whole app.
                    """)
                    text("""
                    Designed for podcast guests who shouldn't need to know anything about \
                    audio. No setup, no account, no cloud. Record your side of the \
                    conversation and send the file back to your host.
                    """)
                }

                dividerRow

                section("Microphone Permission") {
                    text("""
                    The first time you record, macOS will ask for microphone access. \
                    Click Allow. If you accidentally denied it, go to System Settings → \
                    Privacy & Security → Microphone and enable DoublEnder there.
                    """)
                }

                dividerRow

                section("Quick Start") {
                    steps([
                        "Click the mic icon (left) to pick your input device.",
                        "Hit the big red button to start recording. The timer counts up.",
                        "Hit the button again to stop. Your file is saved to the Desktop.",
                        "A macOS notification appears with a Reveal in Finder action — use it to jump straight to the file, then send it to your host."
                    ])
                }

                dividerRow

                section("Settings") {
                    text("""
                    Tap the gear icon (right of the record button) to open settings. \
                    The gear is disabled while recording — you can't change settings \
                    mid-session.
                    """)
                    definition("Filename", "Override the prefix on saved files. A timestamp suffix is always appended automatically.")
                    definition("Notes", "Optional text written into the recording as description metadata. View it in Finder → Get Info → More Info.")
                    definition("Format", "Choose AAC / M4A (256 kbps, smaller) or WAV (32-bit float, uncompressed). Defaults to AAC.")
                }

                dividerRow

                section("Output File") {
                    text("""
                    Recordings are saved to your Desktop as \
                    DoublEnder_<date>.m4a — AAC audio, 256 kbps, mono. If you \
                    pick WAV in settings, the file is saved as .wav (32-bit \
                    float, uncompressed) instead. The prefix follows whatever \
                    you set under Filename.
                    """)
                    text("""
                    The file is ready to send as-is. It will play in QuickTime, \
                    VoiceNotes, and any podcast editing app.
                    """)
                }

                dividerRow

                section("Recovery & Quit Protection") {
                    text("""
                    DoublEnder won't let you lose a recording by mistake.
                    """)
                    definition("Quitting mid-record", "Pressing ⌘Q while recording shows a confirmation. Choose Stop & Save to finalize the file, Quit Without Saving to discard it, or Cancel to keep going.")
                    definition("Crash recovery", "If the app exits unexpectedly while a recording is in progress, the next launch offers to keep the orphaned file (revealed in Finder) or delete it.")
                }

                dividerRow

                section("Updates") {
                    text("""
                    Choose DoublEnder → Check for Updates… from the app menu to \
                    look for a new version. DoublEnder also performs a quiet \
                    check at launch.
                    """)
                }

                Spacer()
            }
            .padding(30)
        }
        .frame(width: 520, height: 640)
        .background(helpSurface)
        .preferredColorScheme(.dark)  // M11: match the rest of the app's dark palette
    }

    // MARK: - Components

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DoublEnder Help")
                .font(.largeTitle.bold())
                .foregroundColor(helpText)
            Text("Simple Audio Recorder for macOS")
                .font(.title3)
                .foregroundColor(helpSecondary)
        }
    }

    private var dividerRow: some View {
        Divider()
            .padding(.vertical, 4)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.bold())
                .foregroundColor(helpAccent)
            content()
        }
    }

    private func text(_ string: String) -> some View {
        Text(string)
            .foregroundColor(helpText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func steps(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.body.bold())
                        .foregroundColor(helpAccent)
                        .frame(width: 20, alignment: .trailing)
                    Text(item)
                        .foregroundColor(helpText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func definition(_ term: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(term)
                .font(.body.bold())
                .foregroundColor(helpText)
            Text(detail)
                .foregroundColor(helpSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

#Preview {
    HelpView()
}
