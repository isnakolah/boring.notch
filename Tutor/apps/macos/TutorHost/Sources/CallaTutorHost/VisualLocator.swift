import AppKit
import Foundation
import ImageIO
import TutorProtocol
import Vision

/// Reads a label off the screen to find the control wearing it.
///
/// This is the branch of last resort for an application that draws its own
/// interface, and it is deliberately hemmed in on three sides.
///
/// It never scans a display, and never scans a whole window: the only rectangle
/// it is ever given is one another branch already resolved — an editor Blender
/// itself reported, or an Accessibility element. So the question is always "where
/// inside *this panel* is the button called Add Modifier", never "find something
/// that looks like a button".
///
/// Nothing it produces may act. Text recognition is evidence about pixels, and
/// pixels are the weakest thing this host knows: a confident reading is still a
/// reading. `confidenceCeiling` keeps every result below the confidence any pack
/// entity requires to click, and `ResolutionAuthority.action` refuses this branch
/// outright rather than trusting the arithmetic. Pixels may point. Pixels may not
/// press.
///
/// And it stays on this Mac. The image is captured, read, and dropped; no bytes
/// are encoded, sent, or written.
@MainActor
enum VisualLocator {
    /// The most any pixel-derived result may claim.
    ///
    /// Below every `minimum_confidence.act` in the shipped packs (0.92–0.94) and
    /// above every `minimum_confidence.point` (0.72–0.75), which is exactly the
    /// authority this branch is meant to have. The action path refuses it
    /// independently, so this number being wrong could not on its own let a
    /// reading press anything.
    static let confidenceCeiling = 0.90
    /// Below this, Vision is guessing at shapes rather than reading text.
    private static let minimumTextConfidence: Float = 0.4

    struct Match {
        let frame: CGRect
        let confidence: Double
        let text: String
    }

    /// Exact Blender icon match, constrained to Blender's own reported strip.
    ///
    /// The bridge can name the navigation strip, but not individual buttons
    /// within it. Its midpoint is direction only. This matcher compares one
    /// shipped Blender 5.2 icon template against pixels *inside that strip*;
    /// it returns no result unless one location is both strong and distinct.
    /// Thus a changed theme, scale, or future Blender version falls back to the
    /// honest outlined strip rather than inventing an exact icon location.
    static func icon(named icon: String, in rect: CGRect, of snapshot: Snapshot) async -> Match? {
        guard icon == "wrench" else { return nil }
        guard let template = iconTemplate(named: icon) else { return nil }
        // ScreenCaptureKit rejects narrow source rects on some displays. Read
        // this one allowlisted window in memory, then constrain match back to
        // Blender's locally reported strip. No pixels leave this Mac.
        let captureRect = snapshot.windowFrame
        guard let capture = try? await WindowCapture.image(bundleID: snapshot.appBundleID,
                                                            processID: snapshot.processID,
                                                            windowID: snapshot.windowID,
                                                            rect: captureRect) else { return nil }
        let (image, frame) = capture
        // Search the strip Blender named, not the window it sits in.
        //
        // Scanning the whole window was both far too slow — a 40x40 template
        // over a 3420x2146 capture is some three billion operations, three and a
        // half seconds on the path that is supposed to take a tenth of one — and
        // wrong: the best match anywhere on screen is usually some unrelated
        // glyph, and the containment check then threw the whole answer away. The
        // bounds are what make this both fast and honest.
        let scaleX = CGFloat(image.width) / frame.width
        let scaleY = CGFloat(image.height) / frame.height
        let search = CGRect(x: (rect.minX - frame.minX) * scaleX,
                            y: (rect.minY - frame.minY) * scaleY,
                            width: rect.width * scaleX,
                            height: rect.height * scaleY)
            // A little slack, so a glyph flush against the strip's edge is not
            // half outside the only place we agreed to look.
            .insetBy(dx: -CGFloat(template.width) / 2, dy: -CGFloat(template.height) / 2)
        guard let candidate = bestTemplateMatch(template: template, in: image, within: search) else { return nil }
        // Template matching is pixel evidence. Keep its confidence below action
        // authority exactly like text recognition.
        // Match only when one candidate clearly outranks every other point in
        // strip. Current Blender themes vary enough that absolute luminance
        // score is not stable; normalised correlation's separation is.
        // Recorded either way. "The icon match did not fire" is otherwise
        // unfalsifiable — a silent nil looks identical whether the template is
        // missing, the theme has moved, or the strip was the wrong rectangle.
        StepTiming.iconMatch(icon, score: candidate.score, margin: candidate.margin,
                             at: candidate.y, rival: candidate.rivalY,
                             accepted: candidate.score >= 0.35 && candidate.margin >= 0.015)
        guard candidate.score >= 0.35, candidate.margin >= 0.015 else { return nil }
        let matchedFrame = CGRect(x: frame.minX + CGFloat(candidate.x) / scaleX,
                                  y: frame.minY + CGFloat(candidate.y) / scaleY,
                                  width: CGFloat(template.width) / scaleX,
                                  height: CGFloat(template.height) / scaleY)
        guard rect.contains(CGPoint(x: matchedFrame.midX, y: matchedFrame.midY)) else { return nil }
        return Match(frame: matchedFrame,
                     confidence: min(confidenceCeiling, 0.65 + candidate.score * 0.25),
                     text: "Blender wrench icon")
    }

    private struct GrayImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    /// A template plus how much each of its pixels is worth.
    ///
    /// The shipped template is a crop of the real interface, so it is mostly
    /// button plate and only a little glyph — and the plate is identical under
    /// every tab in the strip. Correlating raw luminance therefore scored the
    /// wrench, the camera and the printer at 0.51 apiece and separated them by
    /// four thousandths, which is the honest answer to the wrong question.
    ///
    /// The weight is how far a pixel departs from the plate, with the plate
    /// estimated from the template's own border. What is left to compare is the
    /// glyph, which is the thing that actually differs.
    private struct WeightedTemplate {
        let image: GrayImage
        let weights: [Double]
        let total: Double
        var width: Int { image.width }
        var height: Int { image.height }

        init?(_ image: GrayImage) {
            let width = image.width, height = image.height
            guard width > 2, height > 2 else { return nil }
            var border: [UInt8] = []
            for x in 0..<width { border.append(image.pixels[x]); border.append(image.pixels[(height - 1) * width + x]) }
            for y in 0..<height { border.append(image.pixels[y * width]); border.append(image.pixels[y * width + width - 1]) }
            border.sort()
            let plate = Double(border[border.count / 2])
            var weights = [Double](repeating: 0, count: width * height)
            var total = 0.0
            for index in 0..<weights.count {
                // Squared, so a pixel well clear of the plate counts for much
                // more than one a shade off it — anti-aliasing at the glyph's
                // edge should not weigh as much as the glyph.
                let departure = abs(Double(image.pixels[index]) - plate) / 255
                let weight = departure * departure
                weights[index] = weight
                total += weight
            }
            // A template that is all plate carries no information about which
            // tab it is, and saying so is better than correlating noise.
            guard total > 0.5 else { return nil }
            self.image = image
            self.weights = weights
            self.total = total
        }
    }

    private struct TemplateCandidate {
        let x: Int
        let y: Int
        let score: Double
        let margin: Double
        /// Where the best rival glyph was, so a margin that refuses a match can
        /// be told from a margin that never had a rival to measure.
        let rivalY: Int
    }

    private static func iconTemplate(named icon: String) -> WeightedTemplate? {
        let filename = "blender-\(icon)-template-5.2"
        let candidates = [
            // `url(forResource:withExtension:)` treats final `.2` as a file
            // extension. Build the URL directly: Blender's version is part of
            // this asset's literal name.
            Bundle.main.resourceURL?.appendingPathComponent("\(filename).png"),
            // SwiftPM's executable has no resource bundle. This fallback is for
            // local host builds; installed apps always use Bundle.main above.
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("assets/blender/\(icon)-template-5.2.png"),
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let gray = grayscale(image) else { return nil }
        return WeightedTemplate(gray)
    }

    private static func grayscale(_ image: CGImage) -> GrayImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    /// Normalised cross-correlation makes the same glyph match whether Blender
    /// renders it as selected blue or ordinary grey. Only translation is tried:
    /// the capture is fixed at 2× and the template is Blender 5.2 at that same
    /// scale, so accepting arbitrary scale would turn nearby glyphs into false
    /// positives.
    ///
    /// - Parameter search: the only part of the image worth looking at, in the
    ///   image's own pixels. Clipped to the image, so a strip reported at the
    ///   window's edge cannot walk the scan off the end of the buffer.
    private static func bestTemplateMatch(template: WeightedTemplate, in image: CGImage,
                                          within search: CGRect) -> TemplateCandidate? {
        guard let source = grayscale(image), source.width >= template.width,
              source.height >= template.height else { return nil }
        let bounds = search.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !bounds.isNull else { return nil }
        let minX = max(0, Int(bounds.minX.rounded(.down)))
        let minY = max(0, Int(bounds.minY.rounded(.down)))
        let maxX = min(source.width - template.width, Int(bounds.maxX.rounded(.up)) - template.width)
        let maxY = min(source.height - template.height, Int(bounds.maxY.rounded(.up)) - template.height)
        guard maxX >= minX, maxY >= minY else { return nil }
        // Every mean and every energy below is weighted by the glyph mask, so
        // the plate the template shares with every other tab contributes nothing
        // to either the match or the score.
        var meanTemplate = 0.0
        for index in 0..<template.weights.count {
            meanTemplate += template.weights[index] * Double(template.image.pixels[index])
        }
        meanTemplate /= template.total
        var templateEnergy = 0.0
        for index in 0..<template.weights.count {
            let centered = Double(template.image.pixels[index]) - meanTemplate
            templateEnergy += template.weights[index] * centered * centered
        }
        guard templateEnergy > 1e-6 else { return nil }

        var best = (-Double.infinity, 0, 0)
        // Every position scored, so the runner-up can be chosen *after* the
        // winner is known.
        //
        // Taking it as "second best anywhere" was wrong in a way that looked
        // right: the second best position is always one pixel from the first,
        // scoring within a thousandth of it, so a perfectly clear match reported
        // a margin of 0.004 and was thrown away. What the margin is supposed to
        // ask is whether some *other* glyph in the strip is nearly as good, and
        // that means ignoring the winner's own neighbourhood.
        var scored: [(score: Double, x: Int, y: Int)] = []
        scored.reserveCapacity(((maxX - minX) + 1) * ((maxY - minY) / 2 + 1))
        for y in stride(from: minY, through: maxY, by: 2) {
            for x in stride(from: minX, through: maxX, by: 1) {
                var mean = 0.0
                for row in 0..<template.height {
                    let start = (y + row) * source.width + x
                    let templateStart = row * template.width
                    for column in 0..<template.width {
                        mean += template.weights[templateStart + column] * Double(source.pixels[start + column])
                    }
                }
                mean /= template.total
                var dot = 0.0, energy = 0.0
                for row in 0..<template.height {
                    let targetStart = (y + row) * source.width + x
                    let templateStart = row * template.width
                    for column in 0..<template.width {
                        let weight = template.weights[templateStart + column]
                        let a = Double(template.image.pixels[templateStart + column]) - meanTemplate
                        let b = Double(source.pixels[targetStart + column]) - mean
                        dot += weight * a * b
                        energy += weight * b * b
                    }
                }
                let score = energy > 1e-6 ? dot / sqrt(templateEnergy * energy) : -1
                scored.append((score, x, y))
                if score > best.0 { best = (score, x, y) }
            }
        }
        guard best.0 > -Double.infinity else { return nil }
        // The best score belonging to a different glyph: anything at least one
        // template away from the winner in either direction.
        let runnerUp = scored
            .filter { abs($0.x - best.1) >= template.width || abs($0.y - best.2) >= template.height }
            .map(\.score)
            .max() ?? -1
        let rival = scored
            .filter { abs($0.x - best.1) >= template.width || abs($0.y - best.2) >= template.height }
            .max { $0.score < $1.score }
        return TemplateCandidate(x: best.1, y: best.2, score: best.0,
                                 margin: best.0 - runnerUp, rivalY: rival?.y ?? -1)
    }

    /// The smallest recognised line inside `rect` whose text the matcher accepts.
    ///
    /// Smallest, because a matcher for "add modifier" also matches a paragraph
    /// mentioning it, and the button is the tighter of the two. Returns nil when
    /// nothing matches, which is a real answer: the caller falls through to the
    /// next branch rather than pointing at the panel.
    static func text(matching matcher: SafeMatcher, in rect: CGRect,
                     of snapshot: Snapshot) async -> Match? {
        guard let (image, frame) = try? await WindowCapture.image(bundleID: snapshot.appBundleID,
                                                                  processID: snapshot.processID,
                                                                  windowID: snapshot.windowID,
                                                                  rect: rect) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        // Interface labels are not prose. Correction turns "Subsurf" into
        // "Subsurface" and then the matcher misses the control that is right
        // there on the screen.
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return nil }

        var best: Match?
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumTextConfidence,
                  matcher.matches(candidate.string) else { continue }
            // Vision's box is normalized with a bottom-left origin; the window
            // server's space is top-left. The flip is the `1 - maxY`.
            let box = observation.boundingBox
            let match = Match(
                frame: CGRect(x: frame.minX + box.minX * frame.width,
                              y: frame.minY + (1 - box.maxY) * frame.height,
                              width: box.width * frame.width,
                              height: box.height * frame.height),
                confidence: min(confidenceCeiling, 0.6 + 0.3 * Double(candidate.confidence)),
                text: candidate.string)
            guard match.frame.width > 1, match.frame.height > 1 else { continue }
            if best == nil || match.frame.width * match.frame.height < best!.frame.width * best!.frame.height {
                best = match
            }
        }
        return best
    }
}
