import Foundation

/// How long this Mac took, so the Gateway's share of a step is what is left.
///
/// A teaching step crosses three places — the sender's ssh, the Gateway turn,
/// and this host — and only the middle one is slow. Saying so needs a number
/// from each end rather than an argument, so both ends write one: the sender
/// stamps its own round trip, and every operation that reaches here is stamped
/// on the way out.
///
/// Metadata only, by the same rule that governs everything else the host
/// records: the operation name, how many milliseconds it took, and whether it
/// succeeded. No payload, no region, no capture bytes, no window title, no
/// document name. The file is safe to read out loud.
enum StepTiming {
    private static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Calla/step-timing.log")
    /// Rotated rather than grown: this is a diagnostic, and an unbounded log on
    /// the hot path is a slow leak nobody notices.
    private static let maxBytes = 512 * 1024

    /// Record what one host operation cost, given the uptime stamp it began at.
    static func record(_ operation: String, started: UInt64, outcome: String) {
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        append(String(format: "%@ host %@ %.1fms %@\n",
                      ISO8601DateFormatter().string(from: Date()), operation, milliseconds, outcome))
    }

    /// Where a target was resolved to, and by which branch.
    ///
    /// Local only, and it has to be: this is the one diagnostic that carries a
    /// rectangle, which is precisely what must never cross the wire. It is here
    /// because "the cursor is slightly off" is otherwise unfalsifiable — the
    /// receipt says which evidence answered but not where it put the pointer, so
    /// there was no way to tell a bridge rectangle landing exactly right from a
    /// model's guess landing near enough to look right.
    ///
    /// The semantic id, the branch, the confidence and the rectangle. Still no
    /// capture bytes, no window title, no document name.
    static func placement(_ semanticID: String, frame: CGRect, confidence: Double, evidence: [String]) {
        append(String(format: "%@ place %@ conf=%.2f rect=%.0f,%.0f,%.0fx%.0f via=%@\n",
                      ISO8601DateFormatter().string(from: Date()), semanticID, confidence,
                      frame.minX, frame.minY, frame.width, frame.height,
                      evidence.joined(separator: "+")))
    }

    /// How well an icon template matched, whether or not it was believed.
    ///
    /// A correlation score and how far it beat the runner-up. Two numbers, no
    /// pixels: enough to tell a template that no longer matches this theme from
    /// one that was never looked for in the right place.
    static func iconMatch(_ icon: String, score: Double, margin: Double,
                          at y: Int, rival rivalY: Int, accepted: Bool) {
        append(String(format: "%@ icon %@ score=%.3f margin=%.3f y=%d rival_y=%d %@\n",
                      ISO8601DateFormatter().string(from: Date()), icon, score, margin,
                      y, rivalY, accepted ? "accepted" : "rejected"))
    }

    /// How many Properties tabs one calibration pass managed to place.
    static func tabCalibration(objectType: String, learned: Int, of total: Int) {
        append(String(format: "%@ tabs %@ learned=%d of=%d\n",
                      ISO8601DateFormatter().string(from: Date()), objectType, learned, total))
    }

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: logURL.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: logURL.path)[.size]) as? Int, size > maxBytes {
            try? manager.removeItem(at: logURL)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            try? data.write(to: logURL)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
