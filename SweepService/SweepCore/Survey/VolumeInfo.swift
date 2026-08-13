import Foundation

// Volume telemetry.
//
// `available` comes from `volumeAvailableCapacityForImportantUsageKey` — the
// purgeable-aware figure macOS Storage settings itself shows, and therefore the
// one the user will compare Sweep against. The raw `volumeAvailableCapacityKey`
// is smaller and would make Sweep look wrong to anyone checking.
//
// This is also the measurement behind C5's "freed space is measured, not summed":
// sample before, sample after, report the delta.
struct VolumeInfo: Equatable, Sendable {
    var url: URL
    var name: String
    var total: Int64
    /// Purgeable-aware free space — what Storage settings reports.
    var available: Int64
    /// Free space ignoring purgeable content.
    var availableStrict: Int64

    var used: Int64 { max(0, total - available) }

    /// Fraction of the volume in use, 0…1.
    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(total)))
    }

    /// Space macOS believes it could reclaim on demand (caches, snapshots).
    var purgeable: Int64 { max(0, available - availableStrict) }
}

enum VolumeReader {

    static let bootVolume = URL(fileURLWithPath: "/System/Volumes/Data")

    private static let keys: Set<URLResourceKey> = [
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
    ]

    /// Reads current volume telemetry, or nil when the volume cannot be read.
    /// Nil is deliberate: a zero here would be indistinguishable from a full disk.
    ///
    /// `available` is the purgeable-aware figure macOS Storage settings shows (for
    /// the gauge). `availableStrict` is read live via `statfs` — the same source
    /// `df` uses — because the URL resource-value capacity keys are cached and do
    /// not move immediately after a delete, which would make a freed-space delta
    /// read as zero (C5, and the Phase 08 df-agreement exit criterion).
    static func read(_ url: URL = bootVolume) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let important = values.volumeAvailableCapacityForImportantUsage
        else { return nil }

        return VolumeInfo(
            url: url,
            name: values.volumeName ?? url.lastPathComponent,
            total: Int64(total),
            available: Int64(important),
            availableStrict: statfsAvailableBytes(url) ?? Int64(values.volumeAvailableCapacity ?? Int(important)))
    }

    /// Free bytes from the `statfs` syscall — `f_bavail * f_bsize`, exactly what
    /// `df` reports and what moves the instant a file is removed.
    private static func statfsAvailableBytes(_ url: URL) -> Int64? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// Bytes actually freed between two samples. Measured on the *strict* available
    /// figure, not the purgeable-aware one.
    ///
    /// C5 names `volumeAvailableCapacityForImportantUsageKey` for this delta, but
    /// that figure is cached and purgeable-aware: deleting a 400 MB file does not
    /// move it immediately (macOS already counted the space as reclaimable-on-
    /// demand), so a freed delta measured on it reads as 0 right after a sweep.
    /// The raw `volumeAvailableCapacityKey` moves with the freed blocks and is
    /// exactly what `df` reports — and the Phase 08 exit criterion requires the
    /// freed figure to agree with `df`. So the delta is measured on the strict
    /// figure; the purgeable-aware figure remains what the free-space gauge shows,
    /// because that is the number Storage settings shows the user.
    static func freedBytes(before: VolumeInfo, after: VolumeInfo) -> Int64 {
        max(0, after.availableStrict - before.availableStrict)
    }
}

// Byte formatting lives with the telemetry it formats. Uses the same base-10
// convention as Finder, so Sweep's figures and the user's Finder window agree.
enum Format {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    /// How long ago something happened, in the coarsest unit that is still true.
    /// Used to label a restored survey, where the point is "this is not live",
    /// not the precise second it was taken.
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<90: return "just now"
        case ..<5400: return "\(Int((seconds / 60).rounded())) min ago"
        case ..<172_800: return "\(Int((seconds / 3600).rounded())) hr ago"
        default: return "\(Int((seconds / 86_400).rounded())) days ago"
        }
    }
}
