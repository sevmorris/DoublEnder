import SwiftUI

// Warm amber palette — matches ContentView / CloudContentView so the help
// window reads as part of the same product, not a generic system document.
/// Near-black warm background (#0D0800) — same as the chassis screen.
private let helpSurface   = Color(red: 0x0D/255, green: 0x08/255, blue: 0x00/255)
/// Warm off-white body text (#F0E0C0) — readable on the dark warm surface.
private let helpText      = Color(red: 0xF0/255, green: 0xE0/255, blue: 0xC0/255)
/// Warm amber (#FFD580) — section headings, matches clock-digit colour.
private let helpAccent    = Color(red: 0xFF/255, green: 0xD5/255, blue: 0x80/255)
/// Muted amber-tinted off-white for subtitle / definition detail.
private let helpSecondary = Color(red: 0xE8/255, green: 0xD8/255, blue: 0xC0/255).opacity(0.55)

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                section("Overview") {
                    #if GCS_ENABLED
                    text("""
                    DoublEnder Cloud is a minimal audio recorder for macOS. Pick your \
                    microphone, hit record, and your file is saved to your Desktop and \
                    uploaded to your producer's cloud bucket automatically.
                    """)
                    text("""
                    Designed for podcast guests who shouldn't need to know anything about \
                    audio — or how the file gets to their producer. No accounts, no \
                    file-sharing services, no manual upload step.
                    """)
                    #else
                    text("""
                    DoublEnder is a minimal audio recorder for macOS. Pick your microphone, \
                    hit record, and get an AAC file on your Desktop. That's the whole app.
                    """)
                    text("""
                    Designed for podcast guests who shouldn't need to know anything about \
                    audio. No setup, no account, no cloud. Record your side of the \
                    conversation and send the file back to your host.
                    """)
                    #endif
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
                    #if GCS_ENABLED
                    steps([
                        "Click the mic icon (left) to pick your input device. Watch the 40-segment level meter — aim for green, avoid red.",
                        "Click the RECORD button to start. The timer counts up, the button fills deep orange-red, and the red LED above the timer lights up.",
                        "Click the button again to stop. Your file saves to the Desktop and uploads automatically. The blue LED above the timer indicates when the cloud connection is ready.",
                        "A confirmation dialog appears when the upload finishes. The local file stays on your Desktop as a backup."
                    ])
                    #else
                    steps([
                        "Click the mic icon (left) to pick your input device. Watch the 40-segment level meter — aim for green, avoid red.",
                        "Click the RECORD button to start. The timer counts up, the button fills deep orange-red, and the red LED above the timer lights up.",
                        "Click the button again to stop. Your file is saved to the Desktop.",
                        "A macOS notification appears with a Reveal in Finder action — use it to jump straight to the file, then send it to your host."
                    ])
                    #endif
                }

                dividerRow

                section("Audio Processing") {
                    text("""
                    DoublEnder does no audio processing. What the mic captures is what \
                    hits the file — no compressor, no limiter, no noise gate, no EQ. \
                    Audio flows from the capture device straight into the writer with \
                    only the unavoidable AAC encode (when recording m4a) in between.
                    """)
                    text("""
                    The level meter shows the raw input signal, so what you see is \
                    what gets recorded. Aim for the green range and watch for any \
                    excursions into red.
                    """)
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
                    definition("Format", "Choose AAC / M4A (256 kbps, smaller) or WAV (24-bit PCM, uncompressed). Defaults to AAC.")
                }

                dividerRow

                section("Output File") {
                    text("""
                    Recordings are saved to your Desktop as \
                    DoublEnder_<date>.m4a — AAC audio, 256 kbps, mono. If you \
                    pick WAV in settings, the file is saved as .wav (24-bit \
                    PCM, uncompressed) instead. The prefix follows whatever \
                    you set under Filename.
                    """)
                    text("""
                    When a recording finishes, a confirmation dialog appears with \
                    the saved filename. If notifications are enabled, a system \
                    banner also appears with a Reveal in Finder action.
                    """)
                    text("""
                    The file is ready to send as-is. It will play in QuickTime, \
                    VoiceNotes, and any podcast editing app.
                    """)
                }

                #if GCS_ENABLED
                dividerRow

                section("Cloud Upload") {
                    text("""
                    Every recording uploads automatically to your producer's bucket \
                    after saving. A progress indicator runs during the upload and a \
                    confirmation dialog appears when it finishes.
                    """)
                    definition("Connection status", "The blue LED above the timer indicates cloud readiness: solid blue when the network is reachable and the embedded credential is present, off otherwise. You can still record offline — uploads will be retried with the same file when the connection returns.")
                    definition("Local backup", "Your file is saved to the Desktop first, then uploaded. The local copy is never deleted automatically — keep or remove it as you prefer.")
                    definition("Pending uploads", "If an upload fails or is interrupted (network drop, app quit, retries exhausted), the next launch offers to retry it. The original file always stays on your Desktop until the upload succeeds.")
                }
                #endif

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
            #if GCS_ENABLED
            Text("DoublEnder Cloud Help")
                .font(.largeTitle.bold())
                .foregroundColor(helpText)
            Text("Cloud-Connected Audio Recorder for macOS")
                .font(.title3)
                .foregroundColor(helpSecondary)
            #else
            Text("DoublEnder Help")
                .font(.largeTitle.bold())
                .foregroundColor(helpText)
            Text("Simple Audio Recorder for macOS")
                .font(.title3)
                .foregroundColor(helpSecondary)
            #endif
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
