import SwiftUI

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
                        "Click the mic icon (bottom left) to pick your input device.",
                        "Speak normally and watch the level meter — aim for green, avoid red. If the CLIP indicator lights up, you're too loud.",
                        "Hit the big red button to start recording. The timer counts up.",
                        "Hit the button again to stop. Your file is saved to the Desktop.",
                        "A macOS notification appears with a Reveal in Finder action — use it to jump straight to the file, then send it to your host."
                    ])
                }

                dividerRow

                section("Reading the Meter") {
                    text("""
                    The segmented bar lights from left to right with the RMS level \
                    (your average loudness) and holds the recent peak. The color zones are:
                    """)
                    definition("Green (−60 to −12 dBFS)", "Good recording level. Aim to stay here.")
                    definition("Yellow (−12 to −6 dBFS)", "Getting loud. Still fine for brief peaks.")
                    definition("Orange (−6 to −3 dBFS)", "Hot. Pull back unless this is the loudest moment of the take.")
                    definition("Red (−3 to 0 dBFS)", "Too loud. The limiter is working hard here.")
                    definition("CLIP indicator", "Lit red when peaks hit the limiter ceiling. Back off your mic position or gain.")
                }

                dividerRow

                section("Output File") {
                    text("""
                    Recordings are saved to your Desktop as \
                    DoublEnder_<date>.m4a — AAC audio, 256 kbps, mono.
                    """)
                    text("""
                    The file is ready to send as-is. It will play in QuickTime, \
                    VoiceNotes, and any podcast editing app.
                    """)
                }

                Spacer()
            }
            .padding(30)
        }
        .frame(width: 520, height: 640)
    }

    // MARK: - Components

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DoublEnder Help")
                .font(.largeTitle.bold())
            Text("Simple Audio Recorder for macOS")
                .font(.title3)
                .foregroundStyle(.secondary)
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
            content()
        }
    }

    private func text(_ string: String) -> some View {
        Text(string)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func steps(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.body.bold())
                        .frame(width: 20, alignment: .trailing)
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func definition(_ term: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(term)
                .font(.body.bold())
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

#Preview {
    HelpView()
}
