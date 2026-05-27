import Foundation

/// Shared version-string parsing for UpdateChecker and the on-screen overlay.
enum VersionFormatting {

    /// Strip pre-release suffixes and trailing letter build flavours (`lr`, `cr`, `hot`).
    /// `"1.6.28lr"` → `"1.6.28"`, `"v1.0.0-beta.2"` → `"1.0.0"`.
    static func numericVersion(_ raw: String) -> String {
        let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        if let range = stripped.range(of: #"[^0-9.]"#, options: .regularExpression) {
            return String(stripped[..<range.lowerBound])
        }
        return stripped
    }

    /// Split `"1.6.18lr"` → `("1.6.18", "lr")`.
    static func splitSuffix(_ raw: String) -> (numeric: String, suffix: String) {
        guard let range = raw.range(of: #"[A-Za-z]+$"#, options: .regularExpression) else {
            return (raw, "")
        }
        return (String(raw[..<range.lowerBound]), String(raw[range]))
    }
}
