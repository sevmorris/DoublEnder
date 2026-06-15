import SwiftUI

extension View {
    /// Availability-guarded `focusEffectDisabled()`.
    ///
    /// `focusEffectDisabled()` is macOS 14.0+. The deployment target is 13.0
    /// (Ventura), so on 13.x this resolves to a no-op. The affected controls
    /// all use `.buttonStyle(.plain)` or custom styles where the system focus
    /// effect is already absent or visually harmless, so suppressing it on 14+
    /// while leaving it untouched on 13 produces no meaningful difference.
    @ViewBuilder
    func focusEffectDisabledIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }
}
