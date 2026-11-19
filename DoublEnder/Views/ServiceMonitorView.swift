import SwiftUI
import AppKit

// MARK: - Palette

private enum CRT {
    /// Deep CRT charcoal (#12100B).
    static let charcoal = Color(red: 0x12/255, green: 0x10/255, blue: 0x0B/255)
    /// Amber phosphor (#FFB000).
    static let amber = Color(red: 0xFF/255, green: 0xB0/255, blue: 0x00/255)
    /// Dimmed amber (#996600) — timestamps, secondary labels.
    static let dim = Color(red: 0x99/255, green: 0x66/255, blue: 0x00/255)
    /// Warning orange, still phosphor-ish.
    static let warn = Color(red: 0xFF/255, green: 0x7A/255, blue: 0x1A/255)
    static let bezel = Color(red: 0x1C/255, green: 0x19/255, blue: 0x13/255)
    static let font = Font.system(size: 11, weight: .regular, design: .monospaced)
}

// MARK: - Panel

/// The compact utility panel `DE-DIAG // SERVICE MONITOR`. Opened and closed
/// from the About window's hidden trigger.
@MainActor
final class ServiceMonitorPanel: NSObject, NSWindowDelegate {
    static let shared = ServiceMonitorPanel()
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            switchedOff()
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        relayClick()
        DiagnosticLogger.shared.log("SERVICE MODE // ON — type 'help'", level: .system)
        if let about = NSApp.keyWindow, let screen = about.screen ?? NSScreen.main {
            panel.setFrameTopLeftPoint(Self.topLeft(for: panel.frame.size, near: about.frame,
                                                    within: screen.visibleFrame))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// The close button and ⌘W close the panel rather than toggle it; it
    /// is switched off either way.
    func windowWillClose(_ notification: Notification) {
        switchedOff()
    }

    private func switchedOff() {
        relayClick()
        DiagnosticLogger.shared.log("SERVICE MODE // OFF", level: .system)
    }

    /// Where the panel's top-left corner goes: centred under the About
    /// window, or above it when there is no room below, and always inside
    /// the screen's visible frame. Until 2026-11-19 it went under About
    /// whatever the room, so an About window low on the screen put the
    /// panel partly off it.
    nonisolated static func topLeft(for size: NSSize, near about: NSRect, within visible: NSRect) -> NSPoint {
        let gap: CGFloat = 12
        var top = about.minY - gap
        if top - size.height < visible.minY, about.maxY + gap + size.height <= visible.maxY {
            top = about.maxY + gap + size.height
        }
        top = min(max(top, visible.minY + size.height), visible.maxY)
        var x = about.midX - size.width / 2
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))
        return NSPoint(x: x, y: top)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 380),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "DE-DIAG // SERVICE MONITOR"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.minSize = NSSize(width: 460, height: 280)
        panel.backgroundColor = NSColor(red: 0x1C/255, green: 0x19/255, blue: 0x13/255, alpha: 1)
        panel.contentView = NSHostingView(rootView: ServiceMonitorView())
        panel.delegate = self
        return panel
    }

    /// A soft system click, like a relay closing (`ServiceSound`).
    private func relayClick() {
        ServiceSound.play("Tink", volume: 0.35)
    }
}

/// The panel's sounds. They play through the Mac's output, so a guest on
/// speakers would record them into a take, and support may well ask for the
/// panel mid-take: during one they stay silent.
@MainActor
enum ServiceSound {
    static var muted: Bool { RecorderViewModel.shared.isCurrentlyRecording }

    /// Non-blocking; silent if the sound is missing or a take is recording.
    static func play(_ name: String, volume: Float = 1) {
        guard !muted, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}

// MARK: - Console view

struct ServiceMonitorView: View {
    @ObservedObject private var log = DiagnosticLogger.shared
    @State private var input = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @State private var shake: CGFloat = 0
    @State private var flash: Double = 0
    /// Whether the scrollback follows new lines: while it is at the bottom.
    /// Scrolling up holds it, so a take's line every few seconds does not
    /// pull the view away from what is being read; scrolling back down, End,
    /// or a command lets go.
    @State private var following = true
    @FocusState private var focused: Bool

    /// The longest command line the prompt takes, typed or pasted.
    static let inputLimit = 120

    var body: some View {
        screen
            .padding(12)
            .background(bezel)
            .frame(minWidth: 460, minHeight: 280)
    }

    // MARK: Bezel

    /// Inset, beveled dark frame in the faceplate's hardware idiom.
    private var bezel: some View {
        ZStack {
            CRT.bezel
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(LinearGradient(colors: [.black.opacity(0.85), .white.opacity(0.10)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 3)
                .padding(9)
        }
    }

    // MARK: Screen

    private var screen: some View {
        ZStack {
            CRT.charcoal
            VStack(alignment: .leading, spacing: 6) {
                header
                pinnedLines
                scrollback
                prompt
            }
            .padding(10)
            .brightness(flash * 0.35)
            CRTOverlay()
            CRT.amber.opacity(flash)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black, lineWidth: 1.5))
        .modifier(ShakeEffect(animatableData: shake))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { handle($0) }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack {
            Text("DE-DIAG // SERVICE MONITOR")
                .foregroundColor(CRT.amber)
            Spacer()
            if !following {
                Text("HOLD — END TO FOLLOW")
                    .foregroundColor(CRT.warn)
            }
            Text("BUF \(log.lines.count)/\(DiagnosticLogger.capacity)")
                .foregroundColor(CRT.dim)
        }
        .font(CRT.font.weight(.bold))
        .shadow(color: CRT.amber, radius: 3)
    }

    /// The latest handshake, writer and take lines (`DiagnosticLogger.Pin`),
    /// which the ring would lose on a long take. Above the scrollback, under a
    /// rule.
    @ViewBuilder
    private var pinnedLines: some View {
        let pins = log.pinnedLines
        if !pins.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(pins) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("[\(line.stamp)]").foregroundColor(CRT.dim)
                        Text(line.text)
                            .foregroundColor(color(for: line.level))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Rectangle()
                    .fill(CRT.dim.opacity(0.6))
                    .frame(height: 1)
                    .padding(.top, 4)
            }
            .font(CRT.font)
            .shadow(color: CRT.amber.opacity(0.85), radius: 3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scrollback: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(log.lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("[\(line.stamp)]").foregroundColor(CRT.dim)
                            Text(line.text)
                                .foregroundColor(color(for: line.level))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .id(line.id)
                    }
                }
                .font(CRT.font)
                .compositingGroup()
                .shadow(color: CRT.amber.opacity(0.85), radius: 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: ScrollSpot.self, of: ScrollSpot.init) { old, new in
                // New lines grow the content without moving the offset; only
                // a scroll up moves it back.
                if new.atBottom {
                    following = true
                } else if new.offset < old.offset - 0.5 {
                    following = false
                }
            }
            .onChange(of: log.lines.last?.id) { _, last in
                guard following, let last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
            .onChange(of: following) { _, now in
                guard now, let last = log.lines.last?.id else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
            .onAppear {
                if let last = log.lines.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private var prompt: some View {
        HStack(spacing: 0) {
            Text("> ").foregroundColor(CRT.dim)
            Text(input).foregroundColor(CRT.amber)
            TimelineView(.periodic(from: .now, by: 0.53)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
                Rectangle()
                    .fill(CRT.amber)
                    .frame(width: 7, height: 13)
                    .opacity(focused && on ? 1 : (focused ? 0 : 0.35))
            }
            Spacer(minLength: 0)
        }
        .font(CRT.font)
        .shadow(color: CRT.amber, radius: 3)
    }

    private func color(for level: DiagnosticLogger.Level) -> Color {
        switch level {
        case .info: return CRT.amber.opacity(0.92)
        case .event: return CRT.amber
        case .warn: return CRT.warn
        case .input: return CRT.amber
        case .system: return CRT.dim
        }
    }

    // MARK: Keyboard

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .return:
            submit()
            return .handled
        case .delete:
            if !input.isEmpty { input.removeLast() }
            return .handled
        case .escape:
            input = ""
            return .handled
        case .end:
            following = true
            return .handled
        case .upArrow:
            guard !history.isEmpty else { return .handled }
            let i = max(0, (historyIndex ?? history.count) - 1)
            historyIndex = i
            input = history[i]
            return .handled
        case .downArrow:
            guard let i = historyIndex else { return .handled }
            if i + 1 < history.count {
                historyIndex = i + 1
                input = history[i + 1]
            } else {
                historyIndex = nil
                input = ""
            }
            return .handled
        default:
            break
        }
        if press.modifiers.contains(.command) {
            if press.characters == "v", let text = NSPasteboard.general.string(forType: .string) {
                // The same limit as typing: a long paste would be one long line.
                input = String((input + text.filter { !$0.isNewline }).prefix(Self.inputLimit))
                return .handled
            }
            return .ignored
        }
        let typed = press.characters.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        guard !typed.isEmpty else { return .ignored }
        input = String((input + typed).prefix(Self.inputLimit))
        return .handled
    }

    private func submit() {
        let command = input.trimmingCharacters(in: .whitespaces)
        input = ""
        historyIndex = nil
        guard !command.isEmpty else { return }
        // A command's answer is to be seen.
        following = true
        if history.last != command { history.append(command) }
        if history.count > 50 { history.removeFirst() }
        ServiceConsole.run(command, degauss: degauss)
    }

    private func degauss() {
        withAnimation(.linear(duration: 0.5)) { shake += 1 }
        flash = 0.9
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 1.2)) { flash = 0 }
        }
        ServiceSound.play("Bottle")
    }
}

// MARK: - Overlay

/// Scanlines and vignette. Drawn once per size change, takes no input.
private struct CRTOverlay: View {
    var body: some View {
        ZStack {
            Canvas { context, size in
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                                 with: .color(.black.opacity(0.18)))
                    y += 3
                }
            }
            GeometryReader { geo in
                RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center,
                               startRadius: min(geo.size.width, geo.size.height) * 0.35,
                               endRadius: max(geo.size.width, geo.size.height) * 0.75)
            }
        }
        .allowsHitTesting(false)
        .drawingGroup()
    }
}

/// Where the scrollback is, for `ServiceMonitorView.following`.
private struct ScrollSpot: Equatable {
    var offset: CGFloat
    /// Within a few lines of the end, or with everything in view.
    var atBottom: Bool

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        atBottom = geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
    }
}

/// A decaying horizontal jitter for `degauss`.
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let phase = animatableData - floor(animatableData)
        let decay = 1 - phase
        let x = sin(phase * .pi * 10) * 7 * decay
        let y = cos(phase * .pi * 14) * 2 * decay
        return ProjectionTransform(CGAffineTransform(translationX: x, y: y))
    }
}

// MARK: - Commands

@MainActor
enum ServiceConsole {
    static func run(_ raw: String, degauss: () -> Void) {
        let log = DiagnosticLogger.shared
        log.log("> \(raw)", level: .input)
        let parts = raw.lowercased().split(separator: " ").map(String.init)
        switch parts.first ?? "" {
        case "help":
            [
                "help      list service commands",
                "status    audio device, sample rate, engine state, active file",
                "paths     output, app support, bundle and temp folders   (paths open → Finder)",
                "dump      copy the pinned lines, the log buffer and the app's system log",
                "          since launch to the clipboard",
                "clear     clear the console buffer (the pinned lines stay)",
                "degauss   demagnetize the tube",
                "scrolling up holds the scrollback; End or any command follows again",
            ].forEach { log.log($0) }
        case "status":
            RecorderViewModel.shared.serviceStatusLines().forEach { log.log($0) }
        case "paths":
            let output = RecorderViewModel.recordingsDirectory
            // The update state, the version kept for going back, and the
            // like. (The working directory, shown until 2026-11-19, is always
            // "/" for an app opened from Finder.)
            let support = UpdateStateStore.app.url.deletingLastPathComponent()
            log.log("OUTPUT ......... \(output.path)")
            log.log("APP SUPPORT .... \(support.path)")
            log.log("APP BUNDLE ..... \(Bundle.main.bundlePath)")
            log.log("TEMP ........... \(FileManager.default.temporaryDirectory.path)")
            if parts.dropFirst().first == "open" {
                if let file = RecorderViewModel.shared.recordedFileURL,
                   FileManager.default.fileExists(atPath: file.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                    log.log("ACTIVE FILE REVEALED IN FINDER // \(file.lastPathComponent)", level: .system)
                } else if NSWorkspace.shared.open(output) {
                    log.log("OUTPUT FOLDER OPENED IN FINDER", level: .system)
                } else {
                    log.log("COULD NOT OPEN THE OUTPUT FOLDER // \(output.path)", level: .warn)
                }
            }
        case "dump":
            // Reading the system log takes a moment, so off the main thread.
            log.log("COLLECTING THE SYSTEM LOG…", level: .system)
            Task.detached(priority: .userInitiated) {
                let system = DiagnosticLogger.systemLogLines()
                // The app logs only what goes wrong, so a calm session has
                // nothing here; say so rather than leave the section out.
                let shown = system.isEmpty
                    ? ["(nothing since launch: the app writes to the system log only when something goes wrong)"]
                    : system
                await MainActor.run {
                    let log = DiagnosticLogger.shared
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.exportText(systemLog: shown), forType: .string)
                    log.log("COPIED TO PASTEBOARD // \(log.pinnedLines.count) pinned · \(log.lines.count) log · "
                            + "\(system.count) system log lines", level: .system)
                }
            }
        case "clear", "cls":
            log.clear()
        case "degauss":
            degauss()
            log.log("DEGAUSS CYCLE COMPLETE" + (ServiceSound.muted ? " (SILENT: A TAKE IS RECORDING)" : ""), level: .system)
        default:
            log.log("?SYNTAX ERROR — '\(parts.first ?? raw)' unknown. Type 'help'.", level: .warn)
        }
    }
}
