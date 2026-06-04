import Foundation

enum DiskSpaceChecker {

    /// Minimum free space before starting an AAC recording (~50 MB).
    private static let minimumFreeBytesAAC: Int64 = 50 * 1024 * 1024
    /// WAV is ~6 MB/min at 48 kHz mono int24 — require more headroom up front.
    private static let minimumFreeBytesWAV: Int64 = 200 * 1024 * 1024

    static func minimumFreeBytes(for format: OutputFormat) -> Int64 {
        switch format {
        case .aac: return minimumFreeBytesAAC
        case .wav: return minimumFreeBytesWAV
        }
    }

    /// Returns nil when the volume has enough space, or a user-facing message.
    static func recordingBlockedReason(for directory: URL, format: OutputFormat = .aac) -> String? {
        let required = minimumFreeBytes(for: format)
        guard let free = availableBytes(at: directory) else {
            return "Could not verify available disk space. Free up space on the Desktop and try again."
        }
        guard free < required else { return nil }
        let mb = max(1, free / (1024 * 1024))
        let requiredMB = max(1, required / (1024 * 1024))
        return "Not enough disk space on Desktop (\(mb) MB free). Free at least \(requiredMB) MB before recording."
    }

    private static func availableBytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ]),
        let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return capacity
    }
}
