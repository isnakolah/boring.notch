import Foundation
import Testing
import TutorProtocol
@testable import CallaTutorHost

/// A 1520x900 Blender window as the read-only bridge reports it: the viewport on
/// the left, the Properties editor down the right edge, its context tabs in a
/// NAV_BAR strip. Origin bottom-left, units Blender's own framebuffer pixels.
private func layoutJSON(windowWidth: Double = 1520, windowHeight: Double = 900) -> JSONValue {
    func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ type: String) -> JSONValue {
        .object(["type": .string(type), "x": .number(x), "y": .number(y),
                 "width": .number(width), "height": .number(height)])
    }
    return .object([
        "window": .object(["width": .number(windowWidth), "height": .number(windowHeight)]),
        "ui_scale": .number(1),
        "areas": .array([
            .object(["type": .string("VIEW_3D"), "x": .number(0), "y": .number(0),
                     "width": .number(1200), "height": .number(900),
                     "regions": .array([rect(0, 874, 1200, 26, "HEADER"),
                                        rect(0, 0, 1200, 874, "WINDOW")])]),
            .object(["type": .string("PROPERTIES"), "context": .string("MODIFIER"),
                     "x": .number(1200), "y": .number(0), "width": .number(320), "height": .number(900),
                     "regions": .array([rect(1200, 874, 320, 26, "HEADER"),
                                        rect(1200, 0, 48, 874, "NAV_BAR"),
                                        rect(1248, 0, 272, 874, "WINDOW")])]),
        ]),
    ])
}

private func selector(_ fields: [String: String]) -> BridgeSelector { BridgeSelector(fields: fields) }

@Suite("Blender window pixels to screen points")
struct BlenderLayoutTests {
    /// A non-Retina window: one Blender pixel is one point, and the window has no
    /// chrome above its content.
    private let simple = CGRect(x: 100, y: 50, width: 1520, height: 900)

    @Test("an editor's rectangle lands where the window server says the window is")
    func mapsAreas() throws {
        let layout = try #require(BlenderLayout(layoutJSON()))
        let mapping = try #require(BlenderWindowMapping(layout: layout, windowFrame: simple))
        let properties = try #require(mapping.screenRect(for: selector(["editor_type": "PROPERTIES"])))
        // The editor is the right-hand 320 points of the window, full height.
        #expect(properties == CGRect(x: 100 + 1200, y: 50, width: 320, height: 900))
    }

    @Test("Blender's bottom-left origin becomes the window server's top-left")
    func flipsTheOrigin() throws {
        let layout = try #require(BlenderLayout(layoutJSON()))
        let mapping = try #require(BlenderWindowMapping(layout: layout, windowFrame: simple))
        // The viewport header sits at the *top* of the window. In Blender that is
        // a high y; on screen it is a low one. Getting this backwards points at
        // the bottom of the window and looks like a plausible near miss rather
        // than an inverted axis, which is why it is worth a test of its own.
        let header = try #require(mapping.screenRect(for: selector(["editor_type": "VIEW_3D", "region_type": "HEADER"])))
        #expect(header.minY == 50)
        #expect(header.height == 26)
    }

    @Test("a Retina window halves every pixel without being told the scale")
    func derivesTheScale() throws {
        // Same Blender layout, reported in backing pixels, in a window the window
        // server measures in points at half the size. Nothing here knows about
        // Retina; the scale falls out of the two widths.
        let layout = try #require(BlenderLayout(layoutJSON()))
        let retina = CGRect(x: 0, y: 0, width: 760, height: 450)
        let mapping = try #require(BlenderWindowMapping(layout: layout, windowFrame: retina))
        #expect(mapping.scale == 0.5)
        let navBar = try #require(mapping.screenRect(for: selector(["editor_type": "PROPERTIES", "region_type": "NAV_BAR"])))
        // Half of everything, including the 26-pixel header the strip sits under.
        #expect(navBar == CGRect(x: 600, y: 13, width: 24, height: 437))
    }

    @Test("a title bar is measured, never assumed")
    func accountsForChrome() throws {
        let layout = try #require(BlenderLayout(layoutJSON()))
        // The window server reports 28 points more height than Blender drew.
        let chromed = CGRect(x: 0, y: 0, width: 1520, height: 928)
        let mapping = try #require(BlenderWindowMapping(layout: layout, windowFrame: chromed))
        #expect(mapping.chrome == 28)
        let properties = try #require(mapping.screenRect(for: selector(["editor_type": "PROPERTIES"])))
        #expect(properties.minY == 28)
    }

    @Test("a window mid-resize is refused rather than pointed at confidently")
    func refusesDisagreement() throws {
        let layout = try #require(BlenderLayout(layoutJSON()))
        // Blender has reflowed to a size the window server has not caught up
        // with. Any rectangle derived from these two together is wrong, and a
        // confident wrong rectangle is worse than no rectangle.
        #expect(BlenderWindowMapping(layout: layout, windowFrame: CGRect(x: 0, y: 0, width: 1520, height: 400)) == nil)
    }

    @Test("a context the selector did not ask for is not the one it gets")
    func honoursContext() throws {
        let layout = try #require(BlenderLayout(layoutJSON()))
        let mapping = try #require(BlenderWindowMapping(layout: layout, windowFrame: simple))
        #expect(mapping.screenRect(for: selector(["editor_type": "PROPERTIES", "context": "MODIFIER"])) != nil)
        #expect(mapping.screenRect(for: selector(["editor_type": "PROPERTIES", "context": "MATERIAL"])) == nil)
        #expect(mapping.screenRect(for: selector(["editor_type": "OUTLINER"])) == nil)
        #expect(mapping.screenRect(for: selector(["editor_type": "VIEW_3D", "region_type": "NAV_BAR"])) == nil)
    }

    @Test("two of the same editor is an ambiguity, not a coin toss")
    func refusesAmbiguity() throws {
        var raw = try #require(layoutJSON().objectValue)
        guard case .array(let areas)? = raw["areas"] else { return }
        raw["areas"] = .array(areas + [areas[0]])
        let layout = try #require(BlenderLayout(.object(raw)))
        let mapping = try #require(BlenderWindowMapping(layout: layout, windowFrame: simple))
        #expect(mapping.screenRect(for: selector(["editor_type": "VIEW_3D"])) == nil)
    }

    @Test("bridge regions carry an outline while exact local controls stay arrow-only")
    func classifiesPresentation() {
        let region = TargetPresentation(evidence: ["local_application_bridge_layout", "bridge-selector:PROPERTIES"])
        let ax = TargetPresentation(evidence: ["accessibility-role:AXButton", "descriptor-matcher"])
        let text = TargetPresentation(evidence: ["local_application_bridge_layout", "local_vision_text_match"])
        let icon = TargetPresentation(evidence: ["local_application_bridge_layout", "local_vision_icon_template_match"])
        let tab = TargetPresentation(evidence: ["local_application_bridge_layout", "local_property_tab_highlight"])
        let frame = CGRect(x: 10, y: 20, width: 48, height: 700)

        #expect(region == .broadArea)
        #expect(region.outlineFrame(for: frame) == frame)
        #expect(ax == .exactControl)
        #expect(ax.outlineFrame(for: frame) == nil)
        #expect(text == .exactControl)
        #expect(text.outlineFrame(for: frame) == nil)
        #expect(icon == .exactControl)
        #expect(icon.outlineFrame(for: frame) == nil)
        // One row of the tab strip is a control, and outlining it would undo
        // the work that made it one.
        #expect(tab == .exactControl)
        #expect(tab.outlineFrame(for: frame) == nil)
    }
}

@Suite("Which row of the Properties strip is which")
struct PropertyTabTests {
    /// The strip as Blender's own layout reports it on a Retina display: thirty
    /// points wide, seven hundred and eighty tall, holding twenty-six square
    /// tabs.
    private let strip = CGRect(x: 1407, y: 308, width: 30, height: 780)

    @Test("a band is a row of the strip, not a fraction of the screen")
    func placesABand() {
        // The wrench measured on a real window: a third of the way down.
        let band = PropertyTabs.Band(offset: 0.3292761050608584, height: 0.033311979500320305)
        let rect = band.rect(in: strip)
        #expect(rect.minX == strip.minX)
        #expect(rect.width == strip.width)
        // 308 + 780 * 0.3293 = 565, and the tab is 26 points tall — one row,
        // not the eight-hundred-point column it used to point at.
        #expect(abs(rect.minY - 565) < 1)
        #expect(abs(rect.height - 26) < 1)
        // And it stays inside the strip it came from.
        #expect(strip.contains(CGPoint(x: rect.midX, y: rect.midY)))
    }

    @Test("a band keeps its place when the window is resized")
    func survivesAResize() {
        // Stored as a fraction precisely so this holds: the same tab in a strip
        // of a different height is still the same tab.
        let band = PropertyTabs.Band(offset: 0.25, height: 0.05)
        let tall = band.rect(in: CGRect(x: 0, y: 0, width: 30, height: 800))
        let short = band.rect(in: CGRect(x: 0, y: 0, width: 30, height: 400))
        #expect(tall.minY == 200)
        #expect(short.minY == 100)
        #expect(tall.height == 40)
        #expect(short.height == 20)
    }

    @Test("a degenerate band is still large enough to point at")
    func neverCollapses() {
        let band = PropertyTabs.Band(offset: 0.5, height: 0)
        #expect(band.rect(in: strip).height >= 8)
    }
}

@Suite("Where the arrow's apex goes")
@MainActor
struct AimTests {
    @Test("a small control keeps its own face visible")
    func aimsClearOfSmallTargets() {
        // The Modifier tab as it actually resolves: thirty by twenty-six.
        let tab = CGRect(x: 1407, y: 565, width: 30, height: 26)
        let aim = PointerOverlay.aim(tab)
        // Inside the target, so it unambiguously indicates this control...
        #expect(tab.contains(aim))
        // ...and past the middle, so the arrow's body falls off the icon
        // instead of over it.
        #expect(aim.x > tab.midX)
        #expect(aim.y > tab.midY)
    }

    @Test("a region keeps its centre")
    func aimsAtTheMiddleOfRegions() {
        // Nothing to hide in an editor-sized rectangle, and a corner would read
        // as pointing at the corner.
        let editor = CGRect(x: 1407, y: 282, width: 301, height: 806)
        #expect(PointerOverlay.aim(editor) == CGPoint(x: editor.midX, y: editor.midY))
    }

    @Test("a sliver of a control is still aimed at inside itself")
    func neverAimsOutside() {
        // The Add Modifier label: sixty-seven by ten.
        let label = CGRect(x: 1548, y: 358, width: 67, height: 10)
        let aim = PointerOverlay.aim(label)
        #expect(label.contains(aim))
    }
}
