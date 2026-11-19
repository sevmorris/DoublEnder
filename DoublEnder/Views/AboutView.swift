import SwiftUI
import AppKit

/// The app's About window. Replaces the stock panel so the icon can carry the
/// hidden Service Monitor trigger: triple-click it, or ⌥-click it.
struct AboutView: View {
    @State private var clickTimes: [Date] = []

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "DoublEnder"
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        let (numeric, suffix) = VersionFormatting.splitSuffix(short)
        return "Version \(numeric)\(suffix.uppercased()) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: FaceplateDesign.screenGlowColor.opacity(0.35), radius: 10)
                .contentShape(Rectangle())
                .onTapGesture { iconClicked() }
            Text(appName)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(FaceplateDesign.vpAmber)
            Text(version)
                .font(FaceplateDesign.metadataFont)
                .foregroundColor(FaceplateDesign.secondaryAmber)
            Text("A minimal audio recorder for podcast guests.")
                .font(.system(size: 11))
                .foregroundColor(FaceplateDesign.secondaryText.opacity(0.7))
            Text("© Sev Morris")
                .font(.system(size: 10))
                .foregroundColor(FaceplateDesign.secondaryText.opacity(0.45))
        }
        .padding(28)
        .frame(width: 300)
        .background(FaceplateDesign.vpSurface)
        .preferredColorScheme(.dark)
    }

    /// ⌥-click opens at once; otherwise three clicks within 0.6 s.
    private func iconClicked() {
        if NSEvent.modifierFlags.contains(.option) {
            clickTimes.removeAll()
            ServiceMonitorPanel.shared.toggle()
            return
        }
        let now = Date()
        clickTimes = clickTimes.filter { now.timeIntervalSince($0) < 0.6 } + [now]
        if clickTimes.count >= 3 {
            clickTimes.removeAll()
            ServiceMonitorPanel.shared.toggle()
        }
    }
}
