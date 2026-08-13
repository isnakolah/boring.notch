import AppKit
import Foundation
import TutorProtocol

/// Blender's own account of where it drew each editor, turned into screen points.
///
/// This is the answer to the oldest problem in this host. Blender renders its
/// entire interface itself, so below the menu bar macOS Accessibility sees one
/// opaque `AXWindow`: there is no button to hit-test, nothing to snap to, and a
/// pointer aimed at "the Properties editor" lands wherever a model happened to
/// guess while reading a JPEG. Blender knows exactly where it put the Properties
/// editor. Asking it is the difference between pointing at a control and pointing
/// near one.
///
/// Nothing here is a coordinate that crossed the wire. The model names a pack
/// entity; the entity names an editor and a region by Blender's own vocabulary;
/// this file turns that into a rectangle using two facts both observed on this
/// Mac — Blender's layout and the window server's frame.
struct BlenderLayout {
    /// A rectangle as Blender reports it: window pixels, origin bottom-left.
    struct Rect {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        init?(_ value: [String: JSONValue]) {
            guard let x = value["x"]?.numberValue, let y = value["y"]?.numberValue,
                  let width = value["width"]?.numberValue, let height = value["height"]?.numberValue,
                  width > 0, height > 0, x.isFinite, y.isFinite else { return nil }
            self.x = CGFloat(x); self.y = CGFloat(y)
            self.width = CGFloat(width); self.height = CGFloat(height)
        }
    }

    struct Region {
        let type: String
        let rect: Rect
    }

    struct Area {
        let type: String
        let uiType: String?
        let context: String?
        let rect: Rect
        let regions: [Region]

        func region(_ type: String) -> Region? {
            regions.first { $0.type.caseInsensitiveCompare(type) == .orderedSame }
        }
    }

    /// The window in the same unit the area rectangles use: framebuffer pixels.
    ///
    /// Not the same as Blender's own `window.width`, which is in points. On a
    /// Retina display the two differ by exactly the factor that would put every
    /// rectangle twice as far from the window's origin as it belongs.
    let windowSize: CGSize
    let uiScale: CGFloat
    let areas: [Area]

    init?(_ value: JSONValue) {
        guard let object = value.objectValue else { return nil }
        // Prefer the framebuffer size the bridge states outright. An add-on that
        // predates it is fed through the same arithmetic rather than refused:
        // window size times pixel size is what `framebuffer` is.
        let pixelSize = object["pixel_size"]?.numberValue ?? 1
        let frame = object["framebuffer"]?.objectValue ?? object["window"]?.objectValue
        let legacyScale = object["framebuffer"] == nil ? pixelSize : 1
        guard let frame, let width = frame["width"]?.numberValue, let height = frame["height"]?.numberValue,
              width > 0, height > 0, legacyScale > 0 else { return nil }
        windowSize = CGSize(width: width * legacyScale, height: height * legacyScale)
        uiScale = CGFloat(object["ui_scale"]?.numberValue ?? 1)
        guard case .array(let rawAreas)? = object["areas"] else { return nil }
        areas = rawAreas.compactMap { rawArea in
            guard let area = rawArea.objectValue, let type = area["type"]?.stringValue,
                  let rect = Rect(area) else { return nil }
            var regions: [Region] = []
            if case .array(let rawRegions)? = area["regions"] {
                regions = rawRegions.compactMap { rawRegion in
                    guard let region = rawRegion.objectValue, let type = region["type"]?.stringValue,
                          let rect = Rect(region) else { return nil }
                    return Region(type: type, rect: rect)
                }
            }
            return Area(type: type, uiType: area["ui_type"]?.stringValue,
                        context: area["context"]?.stringValue, rect: rect, regions: regions)
        }
    }

    /// Every area matching a selector's editor type, and its context if one was
    /// authored. Left as a list on purpose: two Properties editors open at once
    /// is an ambiguity the caller must refuse rather than pick a winner from.
    func areas(matching selector: BridgeSelector) -> [Area] {
        guard let editorType = selector.editorType else { return [] }
        return areas.filter { area in
            guard area.type.caseInsensitiveCompare(editorType) == .orderedSame else { return false }
            if let uiType = selector.uiType, area.uiType?.caseInsensitiveCompare(uiType) != .orderedSame { return false }
            guard let context = selector.context else { return true }
            return area.context?.caseInsensitiveCompare(context) == .orderedSame
        }
    }
}

/// Converts one Blender layout into screen rectangles for one live window.
///
/// The conversion is derived from the two rectangles and never hardcoded, which
/// is the whole reason it survives contact with reality: a Retina display makes
/// Blender's pixels half a point each, an external display makes them one, and a
/// window that has been dragged changes the origin but not the scale. Deriving
/// `scale` from the two widths gets all three right without knowing which is
/// which.
struct BlenderWindowMapping {
    let layout: BlenderLayout
    /// Points per Blender pixel.
    let scale: CGFloat
    /// Window chrome above Blender's own content, in points.
    let chrome: CGFloat
    /// The live window, in the window server's top-left-origin screen space.
    let windowFrame: CGRect

    /// Fails rather than guesses when Blender and the window server disagree.
    ///
    /// They disagree while a window is being resized: Blender has reflowed and
    /// the frame has not caught up, or the reverse. Pointing confidently at a
    /// rectangle derived from two inconsistent facts is worse than not pointing,
    /// because it looks exactly like pointing correctly.
    init?(layout: BlenderLayout, windowFrame: CGRect) {
        guard layout.windowSize.width > 0, layout.windowSize.height > 0,
              windowFrame.width > 1, windowFrame.height > 1 else { return nil }
        let scale = windowFrame.width / layout.windowSize.width
        guard scale > 0.05, scale < 8 else { return nil }
        let contentHeight = layout.windowSize.height * scale
        let chrome = windowFrame.height - contentHeight
        // Blender's content cannot be taller than its window, and a title bar is
        // a few tens of points at most. Anything else means the two views of the
        // window are not of the same moment.
        guard chrome >= -2, chrome <= 120 else { return nil }
        self.layout = layout
        self.scale = scale
        self.chrome = max(chrome, 0)
        self.windowFrame = windowFrame
    }

    /// Blender's bottom-left-origin window pixels to the window server's
    /// top-left-origin screen points.
    func screenRect(_ rect: BlenderLayout.Rect) -> CGRect {
        CGRect(x: windowFrame.minX + rect.x * scale,
               y: windowFrame.minY + chrome + (layout.windowSize.height - rect.y - rect.height) * scale,
               width: rect.width * scale,
               height: rect.height * scale)
    }

    /// A rectangle only counts if there is something there to point at.
    ///
    /// Blender reports a collapsed region as 1x1 rather than omitting it — a
    /// closed viewport sidebar is a truthful 1x1 at the window's edge. Pointing
    /// at it would be pointing at nothing while looking exactly like success.
    private func bounded(_ rect: CGRect) -> CGRect? {
        rect.width >= 4 && rect.height >= 4 ? rect : nil
    }

    /// The rectangle a pack entity's bridge selector names, or nil when Blender's
    /// layout does not contain exactly one of it.
    func screenRect(for selector: BridgeSelector) -> CGRect? {
        let matches = layout.areas(matching: selector)
        guard matches.count == 1 else { return nil }
        let area = matches[0]
        guard let regionType = selector.regionType else { return bounded(screenRect(area.rect)) }
        guard let region = area.region(regionType) else { return nil }
        return bounded(screenRect(region.rect))
    }
}

/// Reads the layout, briefly remembers it, and hands out screen rectangles.
///
/// Cached against the window frame rather than a clock alone: a lesson asks for
/// several rectangles in a row and Blender's layout cannot have changed between
/// them, but a window that has moved invalidates every one of them at once.
@MainActor
final class BlenderLayoutResolver {
    static let bundleID = "org.blenderfoundation.blender"
    /// Long enough to cover the several lookups one step makes, short enough that
    /// dragging a Blender editor divider is noticed on the next step rather than
    /// the next lesson.
    private static let lifetime: TimeInterval = 1.0

    private let observer: BlenderBridgeObserver
    private var cached: (mapping: BlenderWindowMapping, processID: pid_t, at: Date)?

    init(observer: BlenderBridgeObserver) { self.observer = observer }

    func forget() { cached = nil }

    /// True when this snapshot is an application whose layout the bridge can
    /// answer for at all. Everything else keeps today's Accessibility path.
    func canAnswer(for snapshot: Snapshot) -> Bool { snapshot.appBundleID == Self.bundleID }

    func mapping(for snapshot: Snapshot) -> BlenderWindowMapping? {
        guard canAnswer(for: snapshot) else { return nil }
        if let cached, cached.processID == snapshot.processID,
           cached.mapping.windowFrame.equalTo(snapshot.windowFrame),
           Date().timeIntervalSince(cached.at) < Self.lifetime {
            return cached.mapping
        }
        guard let raw = try? observer.observeLayout(), let layout = BlenderLayout(raw),
              let mapping = BlenderWindowMapping(layout: layout, windowFrame: snapshot.windowFrame) else {
            cached = nil
            return nil
        }
        cached = (mapping, snapshot.processID, Date())
        return mapping
    }
}
