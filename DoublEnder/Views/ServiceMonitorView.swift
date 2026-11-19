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
final class ServiceMonitorPanel {
    static let shared = ServiceMonitorPanel()
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            relayClick()
            DiagnosticLogger.shared.log("SERVICE MODE // OFF", level: .system)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        relayClick()
        DiagnosticLogger.shared.log("SERVICE MODE // ON — type 'help'", level: .system)
        if let about = NSApp.keyWindow {
            let f = about.frame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY - 12))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
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
        return panel
    }

    /// A soft system click, like a relay closing. Non-blocking; silent if the
    /// sound is missing.
    private func relayClick() {
        guard let sound = NSSound(named: "Tink")?.copy() as? NSSound else { return }
        sound.volume = 0.35
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
    @FocusState private var focused: Bool

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
            .onChange(of: log.lines.last?.id) { _, last in
                guard let last else { return }
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
                input += text.filter { !$0.isNewline }
                return .handled
            }
            return .ignored
        }
        let typed = press.characters.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        guard !typed.isEmpty else { return .ignored }
        if input.count < 120 { input += typed }
        return .handled
    }

    private func submit() {
        let command = input.trimmingCharacters(in: .whitespaces)
        input = ""
        historyIndex = nil
        guard !command.isEmpty else { return }
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
        NSSound(named: "Bottle")?.play()
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
                "paths     working / output directories   (paths open → reveal in Finder)",
                "dump      copy the pinned lines and the log buffer to the clipboard",
                "clear     clear the console buffer (the pinned lines stay)",
                "degauss   demagnetize the tube",
            ].forEach { log.log($0) }
        case "status":
            RecorderViewModel.shared.serviceStatusLines().forEach { log.log($0) }
        case "paths":
            let output = RecorderViewModel.recordingsDirectory
            log.log("OUTPUT ......... \(output.path)")
            log.log("WORKING DIR .... \(FileManager.default.currentDirectoryPath)")
            log.log("APP BUNDLE ..... \(Bundle.main.bundlePath)")
            log.log("TEMP ........... \(FileManager.default.temporaryDirectory.path)")
            if parts.dropFirst().first == "open" {
                if let file = RecorderViewModel.shared.recordedFileURL,
                   FileManager.default.fileExists(atPath: file.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } else {
                    NSWorkspace.shared.open(output)
                }
                log.log("OUTPUT FOLDER REVEALED IN FINDER", level: .system)
            }
        case "dump":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(log.exportText(), forType: .string)
            log.log("\(log.lines.count) LINES COPIED TO PASTEBOARD", level: .system)
        case "clear", "cls":
            log.clear()
        case "degauss":
            degauss()
            log.log("DEGAUSS CYCLE COMPLETE", level: .system)
        default:
            log.log("?SYNTAX ERROR — '\(parts.first ?? raw)' unknown. Type 'help'.", level: .warn)
        }
    }
}
