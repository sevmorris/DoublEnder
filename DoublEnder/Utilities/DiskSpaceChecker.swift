import Foundation

enum DiskSpaceChecker {

    /// Minimum free space required before starting a recording (50 MB).
    private static let minimumFreeBytes: Int64 = 50 * 1024 * 1024

    /// Returns nil when the volume has enough space, or a user-facing message.
    static func recordingBlockedReason(for directory: URL) -> String? {
        guard let free = availableBytes(at: directory) else { return nil }
        guard free < minimumFreeBytes else { return nil }
        let mb = max(1, free / (1024 * 1024))
        return "Not enough disk space on Desktop (\(mb) MB free). Free at least 50 MB before recording."
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
