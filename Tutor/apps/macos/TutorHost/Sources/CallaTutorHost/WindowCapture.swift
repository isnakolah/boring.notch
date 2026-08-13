import AppKit
import CoreImage
import Foundation
import ScreenCaptureKit
import TutorProtocol

/// Captures a single allowlisted window so a vision model can suggest where a
/// target is.
///
/// Deliberately never captures a display. SECURITY.md requires screenshots to be
/// "in-memory and allowlisted by default", and a full-screen grab would sweep in
/// every other window on the desktop. Nothing here writes to disk.
enum WindowCapture {
    /// Long edge of the encoded image when the user has expressed no
    /// preference.
    ///
    /// The capture is the most expensive thing in a teaching step — roughly
    /// 27,000 input tokens at 1600 — and 1024 was chosen to hold that down. It
    /// costs accuracy, and in some applications it costs all of it: a guide snaps
    /// to the Accessibility control under the model's region, so a poor estimate
    /// is usually corrected, but an application that exposes no controls (Blender
    /// is one whole AXWindow below its menu bar) has nothing to snap to and the
    /// pointer lands exactly where the model guessed. Pixels are the only thing
    /// carrying the guess there.
    static let defaultLongEdge: CGFloat = 1600
    /// JPEG quality.
    ///
    /// Raised from 0.7, which was quietly the bigger of the two problems.
    /// Interface text is thin, high-contrast and high-frequency, which is
    /// precisely what JPEG spends its error budget on: at 0.7 the ringing lands
    /// on the small labels a model most needs to read, so the bytes saved come
    /// out of exactly the detail the picture is taken for. Quality is far cheaper
    /// than resolution — the encoded image stays well inside `maxEncodedBytes`,
    /// which has three megabytes of headroom against a capture of a few hundred
    /// kilobytes.
    static let jpegQuality = 0.85
    /// Encoded bytes, before base64. Kept under the 64 KiB socket frame limit's
    /// intent by bounding the image itself rather than truncating a frame.
    static let maxEncodedBytes = 3 * 1024 * 1024

    struct Capture {
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
        /// Window bounds in Accessibility coordinates, so a normalised hint can
        /// be mapped back onto the screen.
        let windowFrame: CGRect

        var base64: String { data.base64EncodedString() }
    }

    enum Failure: Error {
        case notPermitted
        case noMatchingWindow
        case encodingFailed
    }

    /// True when Screen Recording has been granted. This is a *second* TCC
    /// permission, separate from Accessibility, and is checked without
    /// triggering capture.
    static func isPermitted() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    /// The window the observation named, as ScreenCaptureKit sees it.
    ///
    /// `windowID` is what makes the image and the geometry agree. Both this and
    /// the observation's own window lookup used to say "the largest window this
    /// process owns", and the two lists are built differently — an application
    /// with a full-screen background window behind its document window could
    /// have the model reading one window while every region was mapped onto
    /// another, which puts the cursor nowhere near the control. Matching on the
    /// window server's id removes the guess; the size rule is only a fallback
    /// for a window that has since been replaced.
    /// The last window we resolved, and when.
    ///
    /// Enumerating every shareable window costs 10–20 ms, and the change poll
    /// asks for the same window many times a second for the length of a step.
    /// The answer does not change over that span — a window that is replaced
    /// fails the id match on the next miss, and the whole cache is dropped when
    /// the lesson ends — so resolving it once per lesson is both faster and
    /// quieter on the battery.
    private struct ResolvedWindow {
        let window: SCWindow
        let filter: SCContentFilter
        let processID: pid_t
        let windowID: CGWindowID
        let resolvedAt: Date
    }

    // Every caller is on the main actor — the teaching engine, the change poll,
    // the permission check — so the cache lives there too rather than needing a
    // lock of its own.
    @MainActor private static var cached: ResolvedWindow?
    /// Short enough that a window closed behind our back is noticed promptly,
    /// long enough to cover a whole poll interval many times over.
    private static let cacheLifetime: TimeInterval = 2

    /// Forget the cached window. Called when a lesson ends, so nothing carries
    /// into the next one.
    @MainActor static func forgetCachedWindow() { cached = nil }

    @MainActor
    private static func window(bundleID: String, processID: pid_t, windowID: CGWindowID?) async throws -> SCWindow {
        if let cached, cached.processID == processID, cached.windowID == windowID ?? cached.windowID,
           Date().timeIntervalSince(cached.resolvedAt) < cacheLifetime {
            return cached.window
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Failure.notPermitted
        }

        // Match on the owning process, not the title: titles are user data and
        // change constantly.
        let candidates = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == bundleID
                && window.owningApplication?.processID == processID
                && window.isOnScreen
                && window.frame.width > 1
                && window.frame.height > 1
        }
        let resolved: SCWindow
        if let windowID, let exact = candidates.first(where: { $0.windowID == windowID }) {
            resolved = exact
        } else if let largest = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            resolved = largest
        } else {
            cached = nil
            throw Failure.noMatchingWindow
        }
        cached = ResolvedWindow(window: resolved,
                                filter: SCContentFilter(desktopIndependentWindow: resolved),
                                processID: processID,
                                windowID: resolved.windowID,
                                resolvedAt: Date())
        return resolved
    }

    /// The filter for a window we just resolved, built once alongside it.
    @MainActor
    private static func filter(for window: SCWindow) -> SCContentFilter {
        if let cached, cached.window.windowID == window.windowID { return cached.filter }
        return SCContentFilter(desktopIndependentWindow: window)
    }

    /// - Parameter crop: an optional part of the window to keep, each side a
    ///   fraction of it. Cropping sends less of the screen and buys detail where
    ///   it is wanted: the long edge budget then covers one panel instead of the
    ///   whole window. The returned `windowFrame` is the cropped rectangle, so a
    ///   region read off the image still maps back onto the screen correctly.
    @MainActor
    static func capture(bundleID: String, processID: pid_t, windowID: CGWindowID? = nil,
                        longEdge: CGFloat = defaultLongEdge,
                        crop: NormalizedRegion? = nil) async throws -> Capture {
        let window = try await self.window(bundleID: bundleID, processID: processID, windowID: windowID)

        let full: CGRect = window.frame
        var region: CGRect = full
        if let crop {
            let originX: CGFloat = full.minX + full.width * CGFloat(crop.left)
            let originY: CGFloat = full.minY + full.height * CGFloat(crop.top)
            let width: CGFloat = max(full.width * CGFloat(crop.width), 1)
            let height: CGFloat = max(full.height * CGFloat(crop.height), 1)
            region = CGRect(x: originX, y: originY, width: width, height: height)
        }

        let scale: CGFloat = min(1, longEdge / max(region.width, region.height))
        let configuration = SCStreamConfiguration()
        configuration.width = Int((region.width * scale).rounded())
        configuration.height = Int((region.height * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        if crop != nil {
            // Relative to the window's own top-left, which is what sourceRect
            // is measured in for a window filter.
            configuration.sourceRect = CGRect(x: region.minX - full.minX, y: region.minY - full.minY,
                                              width: region.width, height: region.height)
        }

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter(for: window),
                                                               configuration: configuration)

        guard let data = encodeJPEG(image), data.count <= maxEncodedBytes else {
            throw Failure.encodingFailed
        }
        return Capture(data: data,
                       pixelWidth: image.width,
                       pixelHeight: image.height,
                       windowFrame: region)
    }

    /// One part of the window, as pixels, for reading on this Mac.
    ///
    /// Separate from `capture` because the purpose is different in the one way
    /// that matters: nothing this returns is encoded, sent, or stored. It exists
    /// so text recognition can run against a rectangle the host already resolved,
    /// and it is captured at twice the point size rather than shrunk to a token
    /// budget, because the reader here is Vision and detail is free.
    ///
    /// - Parameter rect: screen points, top-left origin, the window server's
    ///   space. Clipped to the window: a rectangle that has drifted off the
    ///   window since it was resolved yields nothing rather than a slice of some
    ///   other application.
    @MainActor
    static func image(bundleID: String, processID: pid_t, windowID: CGWindowID?,
                      rect: CGRect) async throws -> (image: CGImage, frame: CGRect) {
        let window = try await self.window(bundleID: bundleID, processID: processID, windowID: windowID)
        let region = rect.intersection(window.frame)
        guard region.width >= 4, region.height >= 4 else { throw Failure.noMatchingWindow }

        let configuration = SCStreamConfiguration()
        // Twice the point size is the Retina backing store. Capped so a whole
        // editor asked for by mistake cannot allocate an enormous surface.
        let pixelScale = min(2, 4_096 / max(region.width, region.height))
        configuration.width = Int((region.width * pixelScale).rounded())
        configuration.height = Int((region.height * pixelScale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.sourceRect = CGRect(x: region.minX - window.frame.minX, y: region.minY - window.frame.minY,
                                          width: region.width, height: region.height)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter(for: window),
                                                               configuration: configuration)
        return (image, region)
    }

    /// Side of the greyscale fingerprint used to notice that the learner acted.
    ///
    /// The capture was always taken at 96 and then thrown away by redrawing it
    /// into 32, which cost a factor of nine in spatial detail for nothing. It
    /// mattered: on a 1710x1073 window each 32-pixel cell averages some 1,800
    /// real pixels, so a plainly visible change — toggling Blender's sidebar —
    /// measured 0.002 against a 0.012 threshold and read as "nothing moved".
    /// Keeping the resolution already paid for puts a real action above the
    /// threshold while leaving the fingerprint far too coarse to read: 96x96
    /// greyscale of a whole window recovers no text, and only the verdict "this
    /// changed" ever leaves the Mac.
    static let thumbprintSide = 96

    /// A tiny greyscale fingerprint of the window, for noticing that the
    /// learner did something.
    @MainActor
    static func thumbprint(bundleID: String, processID: pid_t, windowID: CGWindowID? = nil) async throws -> [UInt8] {
        let window = try await self.window(bundleID: bundleID, processID: processID, windowID: windowID)
        let side = thumbprintSide
        let configuration = SCStreamConfiguration()
        configuration.width = side
        configuration.height = side
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter(for: window),
                                                               configuration: configuration)

        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw Failure.encodingFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    /// How much the strongest local part of the window changed, 0...1.
    ///
    /// The strongest *local* part, not the average, because averaging over the
    /// whole window is what made this signal useless. Almost everything a
    /// learner does is confined to a corner of a large window: toggling
    /// Blender's sidebar on a 1710-pixel-wide window measured 0.007 as a mean
    /// while an idle window measured up to 0.004, which is not a separation
    /// anything can be decided on. Measured per tile, the same toggle saturates
    /// the tiles it covers and leaves the rest alone.
    ///
    /// Still only ever answers "did something change here". No tile, and no
    /// pixel, leaves this Mac.
    static func difference(_ left: [UInt8], _ right: [UInt8]) -> Double {
        guard left.count == right.count, !left.isEmpty else { return 1 }
        let side = thumbprintSide
        // Fall back to a plain mean if these are not the fingerprints we make,
        // so the function stays total rather than trusting its callers.
        guard left.count == side * side else {
            let total = zip(left, right).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            return Double(total) / Double(left.count * 255)
        }
        // Eight is a twelfth of the fingerprint: small enough that a control or
        // a panel edge fills several tiles, large enough that one noisy pixel
        // cannot carry a tile on its own.
        let tile = 8
        var strongest = 0.0
        for tileRow in stride(from: 0, to: side, by: tile) {
            for tileColumn in stride(from: 0, to: side, by: tile) {
                var total = 0
                for row in tileRow..<min(tileRow + tile, side) {
                    for column in tileColumn..<min(tileColumn + tile, side) {
                        let index = row * side + column
                        total += abs(Int(left[index]) - Int(right[index]))
                    }
                }
                strongest = max(strongest, Double(total) / Double(tile * tile * 255))
            }
        }
        return strongest
    }

    /// In-memory only: no file is written at any point.
    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }
}
