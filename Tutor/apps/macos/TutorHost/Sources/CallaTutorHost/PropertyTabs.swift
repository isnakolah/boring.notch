import AppKit
import Foundation
import TutorProtocol

/// Which row of Blender's Properties tab strip is which.
///
/// The bridge can name the strip exactly and cannot name a tab inside it, so
/// pointing at "the wrench" meant pointing at the middle of a column eight
/// hundred points tall — technically inside the right region and useless as an
/// instruction.
///
/// Matching the icons was tried and does not work: every tab in that strip is
/// the same size, the same colour and the same position within its own row, so
/// two different glyphs correlate at about 0.92 and a wrench cannot be told from
/// the tab below it. What *is* unmistakable is that Blender draws the **selected**
/// tab on a lighter plate. That is a large, high-contrast, unambiguous signal —
/// one band in a column of identical ones — and the bridge already says which
/// context is selected. So the strip is read for the highlight, the bridge names
/// it, and the pair is remembered.
///
/// After that, every tab the learner has ever selected can be pointed at exactly,
/// and one that has never been selected falls back to the strip rather than to a
/// guess. The lesson that opens the Modifier tab teaches Calla where the Modifier
/// tab is, which is a pleasing way round.
@MainActor
enum PropertyTabs {
    /// A tab's place inside the strip, as a fraction of the strip's height.
    ///
    /// Stored as a fraction rather than in points so a window resized between
    /// two lessons does not invalidate what was learned; the guards in
    /// `remembered(_:for:)` cover the cases a fraction cannot survive.
    struct Band: Codable, Equatable {
        let offset: Double
        let height: Double

        func rect(in strip: CGRect) -> CGRect {
            CGRect(x: strip.minX,
                   y: strip.minY + strip.height * offset,
                   width: strip.width,
                   height: max(strip.height * height, 8))
        }
    }

    /// How much lighter than the rest of the column a selected tab's plate is.
    ///
    /// Measured at 10 on the shipped theme against a median of 26. Eight is
    /// comfortably inside that and comfortably outside the noise of a flat
    /// column, and a theme that does not clear it produces no band at all rather
    /// than a wrong one.
    private static let highlightMargin = 8.0
    /// Below this a "band" is a rendering artefact, not a tab.
    private static let minimumBandPixels = 12

    // MARK: - Reading the strip

    /// The selected tab's band, read from the pixels of the strip itself.
    static func activeBand(in strip: CGRect, of snapshot: Snapshot) async -> Band? {
        guard strip.width >= 4, strip.height >= 40 else { return nil }
        guard let (image, frame) = try? await WindowCapture.image(bundleID: snapshot.appBundleID,
                                                                  processID: snapshot.processID,
                                                                  windowID: snapshot.windowID,
                                                                  rect: snapshot.windowFrame),
              let pixels = grayscale(image) else { return nil }
        let scaleX = CGFloat(image.width) / frame.width
        let scaleY = CGFloat(image.height) / frame.height
        let left = Int(((strip.minX - frame.minX) * scaleX).rounded())
        let right = Int(((strip.maxX - frame.minX) * scaleX).rounded())
        let top = Int(((strip.minY - frame.minY) * scaleY).rounded())
        let bottom = Int(((strip.maxY - frame.minY) * scaleY).rounded())
        guard left >= 0, top >= 0, right <= pixels.width, bottom <= pixels.height,
              right - left >= 6, bottom - top >= 40 else { return nil }

        // The two columns down each edge of the strip. The glyph never reaches
        // them, so what they carry is the plate and nothing else — which is the
        // whole point: this measures the tab's background, not its icon.
        var plate = [Double](repeating: 0, count: bottom - top)
        for row in top..<bottom {
            let start = row * pixels.width
            let samples = [left + 1, left + 2, right - 2, right - 3]
                .filter { $0 >= left && $0 < right }
            guard !samples.isEmpty else { return nil }
            plate[row - top] = samples.reduce(0.0) { $0 + Double(pixels.pixels[start + $1]) } / Double(samples.count)
        }

        let baseline = median(plate)
        var best: (start: Int, end: Int)?
        var start: Int?
        for (index, value) in plate.enumerated() {
            let lit = value > baseline + highlightMargin
            if lit, start == nil { start = index }
            if !lit, let opened = start {
                if index - opened >= minimumBandPixels, best == nil || (index - opened) > (best!.end - best!.start) {
                    best = (opened, index)
                }
                start = nil
            }
        }
        if let opened = start, plate.count - opened >= minimumBandPixels,
           best == nil || (plate.count - opened) > (best!.end - best!.start) {
            best = (opened, plate.count)
        }
        guard let band = best else { return nil }
        // A "band" taller than a third of the column is not one tab, it is a
        // theme this reading does not understand.
        guard Double(band.end - band.start) < Double(plate.count) / 3 else { return nil }
        return Band(offset: Double(band.start) / Double(plate.count),
                    height: Double(band.end - band.start) / Double(plate.count))
    }

    // MARK: - Remembering

    /// What was learned, keyed so a layout it cannot apply to is never used.
    ///
    /// The key carries the object type because Blender shows a different set of
    /// tabs for a mesh and for a light, and a different set means every row below
    /// the difference has moved.
    private struct Key: Hashable, Codable {
        let bundleID: String
        let objectType: String
        let tabCount: Int
    }

    private static var learned: [String: [String: Band]] = load()
    private static let file = CallaRuntime.file("property-tabs.json")

    private static func key(_ snapshot: Snapshot, objectType: String, strip: CGRect) -> String {
        // The strip's aspect is a proxy for how many tabs it holds: they are
        // square, so height over width counts them without needing Blender to.
        let tabs = Int((strip.height / max(strip.width, 1)).rounded())
        return "\(snapshot.appBundleID)|\(objectType)|\(tabs)"
    }

    static func remember(_ context: String, band: Band, for snapshot: Snapshot,
                         objectType: String, strip: CGRect) {
        guard !context.isEmpty else { return }
        let identifier = key(snapshot, objectType: objectType, strip: strip)
        if learned[identifier]?[context] == band { return }
        learned[identifier, default: [:]][context] = band
        save()
    }

    static func remembered(_ context: String, for snapshot: Snapshot,
                           objectType: String, strip: CGRect) -> Band? {
        learned[key(snapshot, objectType: objectType, strip: strip)]?[context]
    }

    private static func load() -> [String: [String: Band]] {
        let url = CallaRuntime.file("property-tabs.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: Band]].self, from: data) else { return [:] }
        return decoded
    }

    private static func save() {
        guard let data = try? JSONEncoder().encode(learned) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: - Learning them all at once

    /// Whether this strip has already been walked, so it is walked once.
    private static var calibrated: Set<String> = []

    /// Show every Properties tab in turn and note where each one's button is.
    ///
    /// The one place Calla asks Blender to change something. It is worth stating
    /// plainly what that costs and why it is the smallest thing that works.
    ///
    /// Blender publishes where it drew the tab strip and not where it drew any
    /// tab inside it, and no read of the running program answers the question —
    /// the enum lists every context that exists, not the ones on screen, and the
    /// only way to find out whether a tab is shown is to ask for it. Matching the
    /// icons was tried and cannot work. So the highlight is watched instead, and
    /// watching the highlight move means moving it.
    ///
    /// What it may change is one enum on one editor: which tab is displayed. No
    /// scene, no object, no file, nothing the learner has made. It runs once per
    /// strip, and it puts back the tab it found.
    @discardableResult
    static func calibrate(strip: CGRect, snapshot: Snapshot, objectType: String,
                          bridge: BlenderBridgeObserver) async -> Int {
        let identifier = key(snapshot, objectType: objectType, strip: strip)
        guard !calibrated.contains(identifier) else { return 0 }
        calibrated.insert(identifier)
        guard let contexts = try? bridge.propertyContexts(), !contexts.isEmpty else {
            // Said out loud. A calibration that quietly declined looked exactly
            // like one that ran and found nothing, and the difference is whether
            // the bridge answered at all.
            StepTiming.tabCalibration(objectType: objectType, learned: 0, of: 0)
            // Not learning anything is not a reason never to try again.
            calibrated.remove(identifier)
            return 0
        }
        // Where the learner was, so they are put back there.
        let original = (try? bridge.observeState())?.objectValue?["properties_contexts"].flatMap { value -> String? in
            guard case .array(let items) = value else { return nil }
            return items.compactMap(\.stringValue).first
        }
        var learnedCount = 0
        for context in contexts.prefix(32) {
            // A tab that does not apply to this object is refused by Blender,
            // which is exactly how the ones on screen are told from the rest.
            guard (try? bridge.setPropertyContext(context)) != nil else { continue }
            // Blender redraws after the timer that set this returns, so the
            // highlight is not on screen yet.
            try? await Task.sleep(for: .milliseconds(90))
            guard let band = await activeBand(in: strip, of: snapshot) else { continue }
            remember(context, band: band, for: snapshot, objectType: objectType, strip: strip)
            learnedCount += 1
        }
        if let original { try? bridge.setPropertyContext(original) }
        StepTiming.tabCalibration(objectType: objectType, learned: learnedCount, of: contexts.count)
        return learnedCount
    }

    // MARK: - Pixels

    private struct Gray {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private static func grayscale(_ image: CGImage) -> Gray? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Gray(width: width, height: height, pixels: pixels)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
