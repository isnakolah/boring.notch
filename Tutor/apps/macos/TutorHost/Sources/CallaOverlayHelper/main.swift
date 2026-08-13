import AppKit
import Carbon.HIToolbox
import CoreImage
import Foundation
import SwiftUI

// Calla's overlay renderer.
//
// This runs as its own plain NSApplication process rather than inside
// TutorHost. The identical AppKit panels never composite from the SwiftUI
// MenuBarExtra host — they report isVisible with a real window number and
// nothing reaches the screen — while they render correctly from a process
// shaped like this one. Keeping the renderer separate also means a hung or
// crashed overlay can never take the socket host down with it.
//
// Protocol: one JSON object per line on stdin.
//   {"cmd":"point","x":123,"y":456,"window":{"x":0,"y":0,"width":1,"height":1},
//    "owner":"com.example.app","step":"Add a torus","text":"...","status":"..."}
//   {"cmd":"narrate","step":"Add a torus","text":"...","status":"...","thinking":true}
//   {"cmd":"narrate","text":"Checking your work…","thinking":true,"holding":true}
//   {"cmd":"preferences","cursor_size":30,"tooltip_opacity":0.92,"show_hud":true}
//   {"cmd":"aside","aside":true}
//   {"cmd":"locate"}
//   {"cmd":"hide"}
//   {"cmd":"quit"}
// Coordinates are screen points with a top-left origin, matching what the host
// resolves; the conversion to Cocoa's bottom-left origin happens here.
//
// `window` and `owner` scope the overlay to the application being taught: the
// tooltip is kept inside that window rather than anywhere on the display, and
// everything hides while the learner has some other application in front.

/// Calla's own log line. stdout belongs to the host's command channel, so
/// anything diagnostic has to go to stderr.
func note(_ message: String) {
    FileHandle.standardError.write("[calla] \(message)\n".data(using: .utf8)!)
}

// MARK: - Wallpaper accent

enum Accent {
    /// Average the wallpaper, then force enough saturation and brightness that
    /// the cursor stays legible over any background.
    static func fromWallpaper() -> Color {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = CIImage(contentsOf: url) else { return Color(red: 1, green: 0.58, blue: 0) }
        let extent = image.extent
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: image,
                                                 kCIInputExtentKey: CIVector(cgRect: extent)]),
              let output = filter.outputImage else { return Color(red: 1, green: 0.58, blue: 0) }
        var bitmap = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()])
            .render(output, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let base = NSColor(red: CGFloat(bitmap[0]) / 255, green: CGFloat(bitmap[1]) / 255,
                           blue: CGFloat(bitmap[2]) / 255, alpha: 1)
        guard let hsb = base.usingColorSpace(.deviceRGB) else { return Color(red: 1, green: 0.58, blue: 0) }
        let saturation = max(hsb.saturationComponent, 0.72)
        let brightness = min(max(hsb.brightnessComponent, 0.85), 1.0)
        return Color(nsColor: NSColor(hue: hsb.hueComponent, saturation: saturation,
                                      brightness: brightness, alpha: 1))
    }
}

// MARK: - Cursor

/// Calla's pointer, drawn from `apps/macos/TutorHost/assets/calla-cursor.svg`.
///
/// Authored in the SVG's 512 view box and scaled into whatever rect it is
/// given, so the geometry has exactly one definition. A bare `Path` inside
/// `.frame()` gets centred, which moves the tip by about half a point in each
/// axis; a Shape receives the exact rect, so the tip stays on `hotspot`.
///
/// The corners are rounded by stroking the outline with a round line join over
/// the fill, which is what keeps the radius uniform on the concave notch too.
struct CallaPointerShape: Shape {
    /// Half the round join width, in view-box units.
    static let cornerRadius: CGFloat = 31
    /// The tip, in view-box units, after the round join pushes it outward.
    static let tip = CGPoint(x: 70, y: 58)
    static let viewBox: CGFloat = 512
    /// The four corners, in view-box units. One definition, shared with the
    /// halo, which has to know where the edges are to run alongside them.
    static let outline: [CGPoint] = [
        CGPoint(x: 100, y: 90),
        CGPoint(x: 418, y: 218),
        CGPoint(x: 300, y: 298),
        CGPoint(x: 240, y: 418),
    ]

    /// The corners in the coordinates of the rect the artwork is drawn in.
    static func corners(in rect: CGRect) -> [CGPoint] {
        let scale = min(rect.width, rect.height) / viewBox
        return outline.map { CGPoint(x: rect.minX + $0.x * scale, y: rect.minY + $0.y * scale) }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for (index, corner) in Self.corners(in: rect).enumerated() {
            if index == 0 { p.move(to: corner) } else { p.addLine(to: corner) }
        }
        p.closeSubpath()
        return p
    }
}

/// The pointer's outline, pushed the same distance outward the whole way round.
///
/// A scaled-up copy of the artwork cannot do this. The arrow is long and thin,
/// so scaling it about any point leaves one end of the border miles away and
/// lays the other end straight over the artwork — which is exactly what made the
/// old waiting indicator vanish for a third of every lap. Offsetting each edge
/// along its own normal, and rounding the corners with an arc, keeps the
/// clearance constant, so a light running along it stays visible all the way.
struct CallaPointerHalo: Shape {
    /// Distance outside the artwork's own path, in points.
    let offset: CGFloat

    func path(in rect: CGRect) -> Path { Self.contour(in: rect, offset: offset).path }

    /// The contour's own perimeter, which is what a dash pattern one lap long
    /// has to measure. Computed rather than approximated: a pattern that is a
    /// few percent off its path leaves the light jumping once a lap.
    ///
    /// Remembered per size, because it is asked for twice on every evaluation of
    /// a view that is inside a `repeatForever` animation — sixty times a second
    /// rebuilding the same offset contour to arrive at the same number, for a
    /// value that changes only when the learner picks a different cursor size.
    @MainActor private static var lengths: [CGFloat: CGFloat] = [:]

    @MainActor
    static func length(in rect: CGRect, offset: CGFloat) -> CGFloat {
        let key = (rect.width * 1000).rounded() + offset
        if let cached = lengths[key] { return cached }
        let measured = contour(in: rect, offset: offset).length
        // Bounded by the handful of cursor sizes a learner can choose; cleared
        // rather than grown if something ever varies the rect continuously.
        if lengths.count > 64 { lengths.removeAll() }
        lengths[key] = measured
        return measured
    }

    private static func contour(in rect: CGRect, offset: CGFloat) -> (path: Path, length: CGFloat) {
        let corners = CallaPointerShape.corners(in: rect)
        let count = corners.count
        // Which way the outline is wound, so a corner can be called convex or
        // not, and so "outward" means outward rather than into the artwork.
        var area: CGFloat = 0
        for index in 0..<count {
            let a = corners[index], b = corners[(index + 1) % count]
            area += a.x * b.y - b.x * a.y
        }
        let winding: CGFloat = area >= 0 ? 1 : -1

        var directions: [CGPoint] = []
        var normals: [CGPoint] = []
        for index in 0..<count {
            let a = corners[index], b = corners[(index + 1) % count]
            let delta = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let length = max(hypot(delta.x, delta.y), 0.0001)
            directions.append(CGPoint(x: delta.x / length, y: delta.y / length))
            normals.append(CGPoint(x: delta.y / length * winding, y: -delta.x / length * winding))
        }

        // Every corner contributes where the offset edge before it ends, where
        // the one after it starts, and — when the corner turns outward — the arc
        // that joins them.
        struct Corner { let entry: CGPoint; let exit: CGPoint; let sweep: CGFloat }
        var joints: [Corner] = []
        for index in 0..<count {
            let previous = (index + count - 1) % count
            let vertex = corners[index]
            let entry = CGPoint(x: vertex.x + normals[previous].x * offset,
                                y: vertex.y + normals[previous].y * offset)
            let exit = CGPoint(x: vertex.x + normals[index].x * offset,
                               y: vertex.y + normals[index].y * offset)
            let turn = directions[previous].x * directions[index].y - directions[previous].y * directions[index].x
            if turn * winding > 0 {
                let from = atan2(entry.y - vertex.y, entry.x - vertex.x)
                let to = atan2(exit.y - vertex.y, exit.x - vertex.x)
                var sweep = to - from
                while sweep > .pi { sweep -= 2 * .pi }
                while sweep < -.pi { sweep += 2 * .pi }
                joints.append(Corner(entry: entry, exit: exit, sweep: sweep))
            } else {
                // Turning inward: the two offset edges cross, and the crossing
                // is the corner. No arc, or the border would loop back on itself.
                let meeting = intersection(entry, directions[previous], exit, directions[index])
                    ?? CGPoint(x: (entry.x + exit.x) / 2, y: (entry.y + exit.y) / 2)
                joints.append(Corner(entry: meeting, exit: meeting, sweep: 0))
            }
        }

        var path = Path()
        var length: CGFloat = 0
        path.move(to: joints[0].exit)
        var cursor = joints[0].exit
        for step in 1...count {
            let joint = joints[step % count]
            path.addLine(to: joint.entry)
            length += hypot(joint.entry.x - cursor.x, joint.entry.y - cursor.y)
            if joint.sweep != 0 {
                let vertex = corners[step % count]
                let from = atan2(joint.entry.y - vertex.y, joint.entry.x - vertex.x)
                path.addArc(center: vertex, radius: offset,
                            startAngle: .radians(Double(from)),
                            endAngle: .radians(Double(from + joint.sweep)),
                            clockwise: joint.sweep < 0)
                length += offset * abs(joint.sweep)
            }
            cursor = joint.exit
        }
        path.closeSubpath()
        return (path, length)
    }

    /// Where two offset edges cross, or nil when they are parallel.
    private static func intersection(_ a: CGPoint, _ da: CGPoint, _ b: CGPoint, _ db: CGPoint) -> CGPoint? {
        let denominator = da.x * db.y - da.y * db.x
        guard abs(denominator) > 0.0001 else { return nil }
        let t = ((b.x - a.x) * db.y - (b.y - a.y) * db.x) / denominator
        return CGPoint(x: a.x + da.x * t, y: a.y + da.y * t)
    }
}

/// Width of the lesson card.
///
/// One constant because it was five: the panel's frame, the view's frame, and
/// three placement helpers each carried their own `300`, so widening the card
/// meant finding all five or watching the text clip against a panel that had not
/// moved with it.
let defaultTooltipWidth: CGFloat = 340

/// Everything the three panels draw, in one place they can observe.
///
/// The panels used to be redrawn by throwing away their `NSHostingView` and
/// building another, which happens three times for a single step — once for
/// "not thinking", once for "moving", once for the status that follows. Every
/// rebuild discards the SwiftUI state inside, so the pointer's travelling light
/// and the waiting bar restarted from nothing on each one, and the panels had to
/// be ordered front again afterwards because a rebuilt content view drops off the
/// window server's visible list. Observing one object instead lets SwiftUI change
/// the two labels that actually changed.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var step = ""
    @Published var text = ""
    @Published var thinking = false
    /// What Calla is doing, when it is doing something.
    @Published var working: String?
    @Published var askOnly = false
    @Published var askingRequested = 0
    @Published var aside = false
    @Published var status = "Calla"
    @Published var cursorSize: CGFloat = CallaCursor.defaultSize
    @Published var tooltipWidth: CGFloat = defaultTooltipWidth
    /// Bumped when Calla arrives somewhere, to fire the destination beacon.
    @Published private(set) var pulseGeneration = 0

    /// False whenever the panels are not actually on screen.
    ///
    /// A `repeatForever` animation keeps running behind `alphaValue` 0 — SwiftUI
    /// has no idea the panel is invisible — so the pointer's light and the
    /// waiting bar kept the compositor awake all day for a lesson nobody was
    /// having. Nothing animates unless it can be seen.
    @Published var animating = false

    /// Whether the "Calla is working" motion should be drawn at all.
    var showsActivity: Bool { thinking && animating }

    func pulse() { pulseGeneration &+= 1 }
}

struct CallaCursor: View {
    /// Kept off the wallpaper accent on purpose: the pointer is Calla's mark,
    /// and it has to stay recognisable on every desktop.
    static let gradient = LinearGradient(
        colors: [Color(red: 0.13, green: 0.83, blue: 1.0), Color(red: 0.0, green: 0.50, blue: 0.94)],
        startPoint: UnitPoint(x: 0.08, y: 0.06), endPoint: UnitPoint(x: 0.86, y: 0.82))
    /// The panel is always built at the largest size a user can pick, because a
    /// rebuilt panel would never composite. Changing the size re-renders the
    /// artwork inside that panel instead.
    static let maxSize: CGFloat = 38
    static let defaultSize: CGFloat = 30
    /// The working ring. Large enough to catch the eye from across a window.
    static let ringSize: CGFloat = 46
    /// Blank space kept around the artwork inside the panel.
    ///
    /// The arrival flash is drawn on the pointer's *tip*, and the tip sits four
    /// points from the panel's own top-left corner — so without room to grow
    /// into, half of every flash was clipped off the edge of its own panel. The
    /// panel cannot be resized later (it would stop compositing), so the space
    /// is built in and the hotspot moves with it.
    static let margin: CGFloat = 30

    @ObservedObject var model: OverlayModel
    @State private var march: CGFloat = 0
    @State private var beaconScale: CGFloat = 0.42
    @State private var beaconOpacity: CGFloat = 0
    @State private var beaconRepeat = 0

    private var size: CGFloat { model.cursorSize }

    private var join: CGFloat {
        CallaPointerShape.cornerRadius * 2 * size / CallaPointerShape.viewBox
    }

    /// Where the pointer's tip is, inside the panel.
    private var tip: CGPoint {
        CGPoint(x: Self.margin + CallaPointerShape.tip.x / CallaPointerShape.viewBox * size,
                y: Self.margin + CallaPointerShape.tip.y / CallaPointerShape.viewBox * size)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if model.showsActivity { halo }
                pointer
            }
            .offset(x: Self.margin, y: Self.margin)
            // Drawn last and positioned on the tip, because the tip is the part
            // that means anything: the flash says "this exact spot", not "the
            // pointer is somewhere around here".
            tipFlash
        }
        .frame(width: Self.panelEdge, height: Self.panelEdge, alignment: .topLeading)
        .onChange(of: model.pulseGeneration) { _, _ in pulseAtDestination() }
    }

    static var panelEdge: CGFloat { maxSize + ringSize + margin * 2 }

    private var pointer: some View {
        ZStack {
            // A white halo under the fill, so the pointer separates from dark
            // and light interfaces alike without an outline that reads as chrome.
            CallaPointerShape()
                .stroke(.white.opacity(0.88),
                        style: StrokeStyle(lineWidth: join + 1.8, lineCap: .round, lineJoin: .round))
            CallaPointerShape()
                .stroke(Self.gradient, style: StrokeStyle(lineWidth: join, lineCap: .round, lineJoin: .round))
            CallaPointerShape().fill(Self.gradient)
        }
        .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
        .frame(width: size, height: size, alignment: .topLeading)
        .frame(width: Self.maxSize, height: Self.maxSize, alignment: .topLeading)
    }

    /// The arrival flash, on the tip and nowhere else.
    ///
    /// Small on purpose. A wave around the whole pointer says "look in this
    /// area"; a flash on the tip says "look at this pixel", which is the only
    /// thing a lesson ever means. A bright dot on the point itself, one ring
    /// leaving it, twice — enough to catch the eye, over before it is noise.
    private var tipFlash: some View {
        ZStack {
            Circle()
                .fill(Self.beaconColour.opacity(beaconOpacity * 0.9))
                .frame(width: 7, height: 7)
                .shadow(color: Self.beaconColour.opacity(beaconOpacity), radius: 5)
            Circle()
                .stroke(Self.beaconColour.opacity(beaconOpacity), lineWidth: 2.2)
                .frame(width: 13, height: 13)
                .scaleEffect(beaconScale)
        }
        .position(tip)
        .frame(width: Self.panelEdge, height: Self.panelEdge, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    static let beaconColour = Color(red: 0.13, green: 0.83, blue: 1.0)

    private func pulseAtDestination() {
        beaconRepeat = 0
        emitBeacon()
    }

    /// Twice, a third of a second apart. One pulse is a blink and is missed;
    /// two read as something insisting.
    private func emitBeacon() {
        beaconScale = 0.5
        beaconOpacity = 1
        withAnimation(.easeOut(duration: 0.55)) {
            beaconScale = 2.6
            beaconOpacity = 0
        }
        guard beaconRepeat < 1 else { return }
        beaconRepeat += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            MainActor.assumeIsolated { emitBeacon() }
        }
    }

    /// Waiting is one light travelling around the pointer's own border.
    ///
    /// A ring floating near the tip was both easy to miss and half-covered by
    /// the tooltip. Marching dashes replaced it and read as a selection marquee
    /// — a thing you are supposed to act on — rather than as progress. One
    /// segment running the loop reads as loading at a glance, needs no room of
    /// its own, and belongs unmistakably to the pointer rather than sitting
    /// beside it. The faint full outline under it is the track the light runs
    /// on, so the border is legible even at the moment the light is elsewhere.
    private var halo: some View {
        ZStack(alignment: .topLeading) {
            // A faint track, so the border still reads as a border at the moment
            // the light is on the far side of it. Kept well under the light's
            // weight: drawn any stronger it stops being a track and starts being
            // a second arrow standing behind the cursor.
            CallaPointerHalo(offset: haloOffset)
                .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 2.0, lineJoin: .round))
            // The light. White underneath for the same reason the pointer has
            // it: this has to read on a dark viewport and a light toolbar alike,
            // and a lesson points at both.
            travellingArc(lineWidth: 3.6, colour: AnyShapeStyle(Color.white.opacity(0.95)))
            travellingArc(lineWidth: 2.2, colour: AnyShapeStyle(Self.gradient))
                // The glow is what makes it read as motion rather than as a
                // gap in a dashed line.
                .shadow(color: Color(red: 0.13, green: 0.83, blue: 1.0).opacity(0.9), radius: 4)
        }
        // The same rect the artwork is drawn in: the border is an offset of the
        // pointer's own outline, not a larger copy of it, so it needs no frame
        // of its own and the tip cannot appear to move.
        .frame(width: size, height: size, alignment: .topLeading)
        .frame(width: Self.maxSize + Self.ringSize, height: Self.maxSize + Self.ringSize,
               alignment: .topLeading)
        // One lap per cycle, measured in laps rather than in points, so changing
        // the cursor size cannot leave the loop with a seam in it. Started when
        // the halo appears, which now only happens while it can be seen.
        .onAppear {
            march = 0
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                march = -1
            }
        }
        .onDisappear { march = 0 }
    }

    /// How far outside the artwork the border runs: clear of the pointer's own
    /// white outline — which is `join` wide plus 1.8 — with a little daylight
    /// left, so the light is never drawn underneath the thing it belongs to.
    private var haloOffset: CGFloat { join / 2 + 3.1 }
    /// How much of the border the light occupies. A quarter is long enough to
    /// see travelling and short enough to leave a clear leading edge.
    private static let arcFraction: CGFloat = 0.26

    /// Perimeter of the border, in points.
    private var lap: CGFloat {
        CallaPointerHalo.length(in: CGRect(x: 0, y: 0, width: size, height: size), offset: haloOffset)
    }

    /// One dash as long as the light and one gap as long as the rest of the
    /// border: a single segment, running the loop, with no seam because the
    /// pattern's period is exactly one lap.
    private func travellingArc(lineWidth: CGFloat, colour: AnyShapeStyle) -> some View {
        CallaPointerHalo(offset: haloOffset)
            .stroke(colour, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                               lineJoin: .round,
                                               dash: [lap * Self.arcFraction, lap * (1 - Self.arcFraction)],
                                               dashPhase: march * lap))
    }
}

// MARK: - Tooltip

/// The lesson's controls live on the lesson.
///
/// Everything a learner needs mid-step — I did that, a question, stop — is here
/// rather than in a menu or another application. Going somewhere else to say "I
/// finished" means leaving the window being taught, which is the thing this
/// whole design is trying to avoid.
struct CallaTooltip: View {
    let accent: Color
    @ObservedObject var model: OverlayModel
    var onEvent: ((String, String) -> Void)?

    @State private var asking = false
    @State private var question = ""
    @FocusState private var questionFocused: Bool

    private var askOnly: Bool { model.askOnly }
    private var aside: Bool { model.aside }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(model.step)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if model.thinking {
                    Text(model.working ?? "working")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(model.text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            // The route is not listed here. It was, and the tooltip grew tall
            // enough to become the thing in the way — which is the problem this
            // whole overlay is trying not to be. "Step 2 of 5" in the header
            // carries the same shape in four words.
            if model.showsActivity { WaitingBar(accent: accent) }
            if onEvent != nil { controls }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: model.tooltipWidth, alignment: .leading)
        .animation(.easeOut(duration: 0.14), value: asking)
        // The card is built once and observed now, so opening the question field
        // cannot ride on the view being reconstructed.
        .onAppear { if model.askingRequested > 0 { asking = true } }
        .onChange(of: model.askingRequested) { _, requested in if requested > 0 { asking = true } }
        .onExitCommand {
            guard asking else { return }
            question = ""
            asking = false
            onEvent?("ask_closed", "")
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accent.opacity(0.45), lineWidth: 1))
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
        )
    }

    @ViewBuilder private var controls: some View {
        if asking {
            HStack(spacing: 6) {
                TextField("Ask Calla…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($questionFocused)
                    .onSubmit(send)
                Button("Send", action: send)
                    .controlSize(.small)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .onAppear { questionFocused = true }
        } else if askOnly {
            EmptyView()
        } else {
            // Stopping lives in the menu bar. It sat here beside "Did it" and
            // "Ask", which are the two things a learner reaches for constantly
            // mid-step — an ending does not belong one slip away from them.
            HStack(spacing: 8) {
                if aside {
                    // Returning and reporting completion are different choices.
                    // Returning redraws the held instruction. "Did it" clears
                    // the aside and verifies that same held step first; it must
                    // never redraw the lesson merely because a question ended.
                    pill("Back to lesson", "⌥⌘L") { onEvent?("resume", "") }
                    pill("Did it", "⌥⌘↩") { onEvent?("next", "") }
                    pill("Ask", "⌥⌘/") { asking = true }
                } else {
                    pill("Did it", "⌥⌘↩") { onEvent?("next", "") }
                    pill("Ask", "⌥⌘/") { asking = true }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 1)
        }
    }

    private func send() {
        let trimmed = question.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onEvent?("ask", trimmed)
        question = ""
        asking = false
    }

    /// The shortcut rides on the button, because a shortcut nobody can see is a
    /// shortcut nobody uses — and the tooltip hides while the pointer is over
    /// it, so the keyboard is the only way to answer it without looking away.
    private func pill(_ title: String, _ shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 11, weight: .medium, design: .rounded))
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(accent.opacity(0.18)))
            .overlay(Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// A bar that travels, because waiting should look like it is getting somewhere.
///
/// Dots that fade in turn say "busy" and nothing else. A band sweeping the width
/// of the tooltip is the shape people already read as progress, and it costs one
/// line of the layout rather than a row of its own.
struct WaitingBar: View {
    let accent: Color
    @State private var travelling = false

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(accent)
                .frame(width: geometry.size.width * 0.34)
                .offset(x: travelling ? geometry.size.width * 0.66 : 0)
                .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true),
                           value: travelling)
        }
        .frame(height: 2)
        .background(Capsule().fill(accent.opacity(0.18)).frame(height: 2))
        .onAppear { travelling = true }
    }
}

/// The outline drawn around a control the learner has now missed twice.
struct HighlightRing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color(red: 0.13, green: 0.83, blue: 1.0), lineWidth: 2.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.7), lineWidth: 4)
                    .blur(radius: 2))
            .padding(2)
    }
}

// MARK: - Status HUD

struct StatusHUD: View {
    let accent: Color
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(accent).frame(width: 8, height: 8)
            Text(model.status)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Divider().frame(height: 12)
            Text("Pause")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
        }
        // Take the width the words actually need. Without this the capsule was
        // pinned to its panel's width and SwiftUI compressed both labels to fit,
        // so a longer status read "Call… | Pau…" — the two things on it, both
        // unreadable. The panel is wider than any status and transparent, so the
        // capsule hugging its text is what is seen.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// A panel that will accept the keyboard.
///
/// Borderless windows refuse key status, so the question field could be shown
/// but never typed into. Non-activating plus this override is the combination
/// that lets the tooltip take keystrokes without yanking the learner out of the
/// application they are being taught.
final class CallaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay

@MainActor
final class CallaOverlay {
    static let shared = CallaOverlay()

    private var cursor: CallaPanel?
    private var tooltip: CallaPanel?
    private var hud: CallaPanel?
    /// Persistent outline for a broad application area resolved by the host.
    private var targetOutline: CallaPanel?
    private var hasTargetOutline = false
    /// Brief escalation/locate outline. Separate from target outline so a
    /// temporary cue can never fade a current broad-area boundary.
    fileprivate var highlightOutline: CallaPanel?
    /// Bumped by each highlight, so an older one expiring cannot take a newer
    /// one off the screen.
    fileprivate var highlightGeneration = 0
    private let accent = Accent.fromWallpaper()
    /// The one thing the three panels observe. Changing a field here re-renders
    /// what changed; nothing is ever rebuilt.
    let model = OverlayModel()
    private var tooltipOpacity: CGFloat = 0.92

    /// The application being taught, and its window in Cocoa coordinates.
    private var owner: String?
    private var window: CGRect?
    /// Whether a step has asked to be on screen, and whether the learner is
    /// currently looking at the taught application. Both must hold to draw.
    private var narrating = false
    var isNarrating: Bool { narrating }
    private var ownerIsFrontmost = true

    /// Where the current step put the cursor. Every decision about the tooltip
    /// is made against this anchor rather than against the panel's live frame,
    /// which is the rule that keeps the behaviour from chasing itself.
    private var lastPoint: CGPoint?
    /// True while the learner's own pointer is over where the tooltip sits.
    private var pointerIsOver = false
    /// True while the learner's own pointer is over Calla's.
    private var pointerOverCursor = false
    /// Bumped by every notice, so a stale one expiring cannot close a live lesson.
    fileprivate var noticeGeneration = 0
    /// Two lines and the control row. Fixed: a tooltip that changes height is a
    /// tooltip that moves, and moving is what makes it lose its arrow.
    private let tooltipHeight: CGFloat = 148
    /// How wide the lesson card is. The owner's choice: a card wide enough to
    /// hold a step in two lines on one screen wraps to four on another.
    private var tooltipWidth: CGFloat = defaultTooltipWidth

    /// The learner pressed something in the tooltip. The host is listening on
    /// this process's stdout, because it owns the connection to Calla.
    static func emit(_ event: String, _ text: String) {
        if event == "ask" {
            // Close the field and keep it closed. The flag that opens it is
            // read by every rebuild of the tooltip, so leaving it set meant the
            // question box came straight back after every send.
            CallaOverlay.shared.askOpen = false
            CallaOverlay.shared.model.askingRequested = 0
            CallaOverlay.shared.setWorking("Asking Calla…", status: "Calla — asking")
        }
        if event == "ask_closed" {
            CallaOverlay.shared.askOpen = false
            CallaOverlay.shared.model.askingRequested = 0
            if CallaOverlay.shared.askOnly {
                CallaOverlay.shared.hide()
            } else {
                CallaOverlay.shared.redraw()
            }
        }
        let payload: [String: Any] = ["event": event, "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }
    private var pointerWatch: Timer?
    private var mouseMonitor: Any?
    private var hideOnHover = true
    private var followFocus = true
    /// True while the question field is open. Asking necessarily brings Calla
    /// forward so the field can take keystrokes, and the scoping rule would
    /// then read that as the learner leaving and hide the lesson mid-question.
    /// Rather than trying to out-guess which process macOS calls frontmost,
    /// scoping is simply suspended for as long as the field is up.
    private var askOpen = false
    private var askOnly = false
    /// True while the lesson is held and the learner is asking something else.
    private var aside = false
    private var shortcutsHeld = false
    private var hudEnabled = true

    /// The size the artwork is currently drawn at, inside a panel that is
    /// always `CallaCursor.maxSize` square.
    private var cursorPointSize = CallaCursor.defaultSize

    /// Local coordinates of the pointer's tip, measured from the panel's
    /// top-left, for the size the artwork is drawn at.
    private var hotspot: CGPoint {
        CGPoint(x: CallaCursor.margin + CallaPointerShape.tip.x / CallaPointerShape.viewBox * cursorPointSize,
                y: CallaCursor.margin + CallaPointerShape.tip.y / CallaPointerShape.viewBox * cursorPointSize)
    }
    /// Room for the pointer plus the thinking pulse around its tip.
    private static let cursorSize = CGSize(width: CallaCursor.panelEdge, height: CallaCursor.panelEdge)

    /// Panel origin that places the pointer's tip exactly on `point`.
    private func cursorOrigin(for point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - hotspot.x, y: point.y - (Self.cursorSize.height - hotspot.y))
    }

    /// Keep the pointer's tip inside the window being taught.
    ///
    /// A region near an edge, or a window that moved between the observation
    /// and the draw, would otherwise put Calla's cursor on the desktop or on a
    /// neighbouring application — annotating something it is not teaching.
    private func clamped(_ point: CGPoint) -> CGPoint {
        guard let window, window.width > 1, window.height > 1 else { return point }
        return CGPoint(x: min(max(point.x, window.minX + 1), window.maxX - 1),
                       y: min(max(point.y, window.minY + 1), window.maxY - 1))
    }

    /// `.nonactivatingPanel` is load-bearing, not cosmetic. A borderless
    /// `NSPanel` without it belongs to an application that is never frontmost
    /// here, so the window server assigns it a window number, reports
    /// `isVisible`, and still composites nothing. With it the panel renders over
    /// whichever application the learner is actually using.
    private func panel(_ frame: CGRect, interactive: Bool = false) -> CallaPanel {
        let p = CallaPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Only the tooltip takes clicks, and only because it carries the
        // lesson's controls. A non-activating panel can take them without
        // pulling focus off the application being taught, which is the whole
        // reason the controls can live here at all.
        p.ignoresMouseEvents = !interactive
        // Always true, including for the interactive tooltip. Clearing it makes
        // the panel want key status, and a borderless non-activating panel that
        // wants to be key stops compositing while its own application is
        // inactive — which is always, since Calla never takes focus. The
        // tooltip's buttons still take clicks without it; only the text field
        // needs key status, and it asks for that itself when it appears.
        p.becomesKeyOnlyIfNeeded = true
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }

    /// Build every panel up front, on-screen but fully transparent.
    ///
    /// Two constraints meet here. Panels created after `NSApplication.run()`
    /// begins get a window number and report `isVisible` while never reaching
    /// the screen, so nothing may be constructed lazily later. And a panel first
    /// ordered front while its frame lies outside every display is never added
    /// to the window server's on-screen list — moving it back later does not
    /// re-evaluate that. So they are parked at the centre of the main screen at
    /// `alphaValue` 0 instead of off to one side.
    func prepare() {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let park = CGPoint(x: screen.midX, y: screen.midY)

        // The pointer is parked transparent like everything else. It used to come
        // up visible, on the reasoning that the helper only ran while Calla was
        // teaching — but the helper now starts with the host, so that left a
        // pointer sitting in the middle of the screen from login until the first
        // lesson. `applyVisibility` raises it when a step actually narrates.
        let c = panel(CGRect(origin: park, size: Self.cursorSize))
        c.contentView = NSHostingView(rootView: CallaCursor(model: model))
        c.alphaValue = 0
        c.orderFrontRegardless(); cursor = c

        let t = panel(CGRect(x: park.x, y: park.y, width: tooltipWidth, height: tooltipHeight), interactive: true)
        t.contentView = NSHostingView(rootView: CallaTooltip(accent: accent, model: model, onEvent: Self.emit))
        t.alphaValue = 0
        // Parked invisible, so it must also be parked click-through: an
        // alpha-0 panel still takes every mouse event over it.
        t.ignoresMouseEvents = true
        t.orderFrontRegardless(); tooltip = t

        // Wider than the longest status Calla can report, so the capsule inside is
        // never the thing that has to shrink. The panel itself draws nothing.
        let hudWidth: CGFloat = 620
        let h = panel(CGRect(x: screen.midX - hudWidth / 2, y: screen.minY + 46,
                             width: hudWidth, height: 44))
        h.contentView = NSHostingView(rootView: StatusHUD(accent: accent, model: model))
        h.alphaValue = 0
        h.orderFrontRegardless(); hud = h

        let target = panel(CGRect(origin: park, size: CGSize(width: 120, height: 40)))
        target.contentView = NSHostingView(rootView: HighlightRing())
        target.alphaValue = 0
        target.ignoresMouseEvents = true
        target.orderFrontRegardless(); targetOutline = target

        let highlight = panel(CGRect(origin: park, size: CGSize(width: 120, height: 40)))
        highlight.contentView = NSHostingView(rootView: HighlightRing())
        highlight.alphaValue = 0
        highlight.ignoresMouseEvents = true
        highlight.orderFrontRegardless(); highlightOutline = highlight

        startPointerWatch()
    }

    func begin(at rawPoint: CGPoint, step: String, text: String, status: String) {
        let point = clamped(rawPoint)
        lastPoint = point
        cursor?.setFrameOrigin(cursorOrigin(for: point))
        // Lesson card belongs to app window, not current target. Cursor alone
        // moves through route; controls never chase it.
        tooltip?.setFrame(askFrame(), display: true)
        setThinking(false, step: step, text: text)
        self.status(status)
        let arriving = tooltip?.alphaValue ?? 0 < 0.5
        narrating = true
        askOnly = false
        askOpen = false
        pointerIsOver = false
        Shortcuts.shared.claim()
        show()
        if arriving {
            tooltip?.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                tooltip?.animator().alphaValue = tooltipOpacity
            }
        }
    }

    /// Scope the overlay to one application, and start following its focus.
    ///
    /// Without this the cursor and tooltip float over the whole desktop,
    /// including whatever the learner switches to next, which reads as Calla
    /// annotating the wrong program.
    func adopt(owner bundleID: String?, window rect: CGRect?) {
        window = rect
        guard owner != bundleID else { return }
        clearTargetOutline()
        owner = bundleID
        ownerIsFrontmost = bundleID == nil
            || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
        applyVisibility()
    }

    func frontmostApplicationChanged(to bundleID: String?) {
        // Calla coming forward is not the learner leaving.
        //
        // Asking a question activates this process so the field can take
        // keystrokes, which made the frontmost application Calla — and the
        // scoping rule then hid the whole lesson the instant the shortcut was
        // pressed. Its own windows never count as somewhere else.
        let isOwner = owner == nil || bundleID == owner
        guard isOwner != ownerIsFrontmost else { return }
        ownerIsFrontmost = isOwner
        if !isOwner && !askOpen { clearTargetOutline() }
        applyVisibility()
    }

    /// Panels are ordered front during launch while parked off-screen and fully
    /// transparent, which is the only arrangement that composites at all — but
    /// the window server never adds them to its visible list in that state, and
    /// a later move or alpha change does not re-evaluate it. Ordering front
    /// again once they are positioned and opaque is what actually puts them on
    /// the screen.
    private func show() {
        applyVisibility()
    }

    /// The overlay belongs to the application being taught.
    ///
    /// It is not drawn over anything else — a pointer floating above an unrelated
    /// window is annotating something Calla knows nothing about. What made this
    /// feel broken before was not the scoping but a missed activation
    /// notification: the overlay would hide and never come back. Frontmost is
    /// polled on the pointer timer now, so that cannot happen.
    private func applyVisibility() {
        // Claim on the way into a lesson, release on the way out — on the
        // transition only. applyVisibility runs on every step, every hover and
        // every focus poll, and driving claim/release from it churned the
        // registrations dozens of times a lesson. Carbon does not complain
        // about that, it just leaves duplicates behind, so one press of ⌥⌘.
        // arrived as many stops and killed the lesson the learner had just
        // started.
        if narrating != shortcutsHeld {
            shortcutsHeld = narrating
            if narrating { Shortcuts.shared.claim() } else { Shortcuts.shared.release() }
        }
        // The overlay belongs to the application being taught and to nothing
        // else. This used to be a preference defaulting to off, because scoping
        // it made lessons appear to vanish — but that was the symptom of a
        // missed activation notification, which the pointer watch has since
        // fixed, and the cure was worse than the disease: Calla's cursor and
        // words sitting over an unrelated window are annotating something Calla
        // knows nothing about. `askOpen` is the one exception, and only because
        // asking a question necessarily brings Calla's own process forward.
        let onScreen = ownerIsFrontmost || askOpen
        cursor?.alphaValue = onScreen && narrating && !askOnly && !pointerOverCursor ? 1 : 0
        // The tooltip is the only thing that gets out of the way, and it does it
        // by disappearing rather than moving: moving detached the words from
        // the arrow they belong to. Its resting opacity is owner-controlled.
        setTooltipAlpha(onScreen && narrating && !(hideOnHover && pointerIsOver) ? tooltipOpacity : 0)
        placeHUD()
        hud?.alphaValue = onScreen && narrating && hudEnabled ? 1 : 0
        targetOutline?.alphaValue = onScreen && narrating && hasTargetOutline ? 1 : 0
        // Nothing animates while nothing can be seen. A `repeatForever` behind
        // alpha 0 keeps the compositor awake for a lesson that is not on screen,
        // which is most of the day.
        model.animating = onScreen && narrating
        guard onScreen else { return }
        // Cursor last, so it is on top. The tooltip sits ten points from the
        // tip and the working ring is wider than that, so ordering the pointer
        // first buried the very thing that says Calla is busy. The pointer
        // should never be behind its own words in any case.
        for panel in [targetOutline, tooltip, hud, cursor] { panel?.orderFrontRegardless() }
    }

    /// Set the card's opacity, and let clicks through whenever it is invisible.
    ///
    /// The card takes mouse events because it carries the lesson's controls, and
    /// hiding it only ever faded the alpha — so an invisible card went on
    /// swallowing every click in the top-right of the window being taught. The
    /// learner sees nothing there and cannot press what is underneath, which is
    /// the worst of both. Transparency and click-through move together now.
    private func setTooltipAlpha(_ alpha: CGFloat) {
        tooltip?.alphaValue = alpha
        // Immediately rather than at the end of the fade: the reason the card is
        // going is that the learner is reaching for what is behind it.
        tooltip?.ignoresMouseEvents = alpha <= 0.01
    }

    /// Keep the status capsule on the display the lesson is on.
    ///
    /// It was positioned once at launch against whichever screen was main then,
    /// and never moved. On a second display that put it on the wrong monitor for
    /// the whole session.
    private func placeHUD() {
        guard let hud, let bounds = screen(containing: window)?.frame else { return }
        let frame = CGRect(x: bounds.midX - hud.frame.width / 2, y: bounds.minY + 46,
                           width: hud.frame.width, height: hud.frame.height)
        if !hud.frame.equalTo(frame) { hud.setFrame(frame, display: false) }
    }

    /// Mark a broad area until this step no longer owns it.
    ///
    /// Exact controls keep arrow-only guidance. A bridge region carries this
    /// boundary because its midpoint is direction, not a claim about a tab's
    /// exact icon position.
    func setTargetOutline(_ rect: CGRect?) {
        guard let rect, rect.width > 1, rect.height > 1, let targetOutline else {
            clearTargetOutline()
            return
        }
        hasTargetOutline = true
        targetOutline.setFrame(rect.insetBy(dx: -5, dy: -5), display: false)
        targetOutline.alphaValue = (ownerIsFrontmost || askOpen) && narrating ? 1 : 0
        targetOutline.orderFrontRegardless()
    }

    private func clearTargetOutline() {
        hasTargetOutline = false
        targetOutline?.alphaValue = 0
    }

    /// Outline a control for a moment.
    ///
    /// The rung above pointing on a lesson's escalation ladder: a learner who has
    /// missed the same step twice is not helped by the same sentence a third
    /// time, and an outline says "this thing, here" in a way an arrow beside it
    /// does not. Built with the others in `prepare` — a panel constructed later
    /// never composites — and click-through always, because it is annotation and
    /// the learner has to be able to press what it is drawn around.
    func highlight(_ rect: CGRect) {
        guard let highlightOutline, rect.width > 1, rect.height > 1 else { return }
        highlightOutline.setFrame(rect.insetBy(dx: -5, dy: -5), display: false)
        highlightOutline.orderFrontRegardless()
        highlightOutline.alphaValue = 0
        highlightGeneration &+= 1
        let generation = highlightGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            highlightOutline.animator().alphaValue = 1
        } completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                MainActor.assumeIsolated {
                    guard CallaOverlay.shared.highlightGeneration == generation else { return }
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.35
                        CallaOverlay.shared.highlightOutline?.animator().alphaValue = 0
                    }
                }
            }
        }
    }

    /// Notice where the learner's pointer is, and who is in front.
    ///
    /// This ran as a 20 Hz timer from launch to quit — lesson or no lesson —
    /// and each tick asked the window server for the frontmost application and
    /// read the mouse. Twenty wake-ups a second, forever, to answer a question
    /// nobody was asking: a Mac with Calla installed and no lesson running was
    /// paying for this all day.
    ///
    /// Now the mouse drives it, which is both exact and free when the mouse is
    /// still. The slow timer stays because a mouse monitor cannot see the
    /// frontmost application change — a lesson is normally asked for from
    /// somewhere else, so the first step lands while the taught application is
    /// behind, and something has to notice when it comes forward. Two a second
    /// is enough for that and three per cent of what it cost.
    private func startPointerWatch() {
        stopPointerWatch()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            MainActor.assumeIsolated { CallaOverlay.shared.updateProximity() }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { CallaOverlay.shared.updateProximity() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerWatch = timer
    }

    private func stopPointerWatch() {
        pointerWatch?.invalidate()
        pointerWatch = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    /// Apply the owner's overlay preferences. The panels themselves are never
    /// rebuilt — only what is drawn inside them, and whether the HUD shows.
    func apply(cursorSize: CGFloat?, tooltipOpacity: Double?, showHUD: Bool?, tooltipWidth width: CGFloat? = nil) {
        if let width {
            let bounded = min(max(width, 260), 620)
            if bounded != tooltipWidth {
                tooltipWidth = bounded
                model.tooltipWidth = bounded
                // The panel and the view it hosts have to agree, or the words
                // clip against a frame that did not move with them.
                tooltip?.setFrame(askFrame(), display: true)
            }
        }
        if let cursorSize {
            let bounded = min(max(cursorSize, 16), CallaCursor.maxSize)
            if bounded != cursorPointSize {
                cursorPointSize = bounded
                model.cursorSize = bounded
                // The tip's offset inside the panel is derived from the size, so a
                // resize that leaves the panel where it was puts the pointer's tip
                // somewhere other than the thing it is pointing at. Re-place it.
                if let anchor = lastPoint { cursor?.setFrameOrigin(cursorOrigin(for: anchor)) }
            }
        }
        if let tooltipOpacity {
            let bounded = CGFloat(min(max(tooltipOpacity, 0.5), 1.0))
            if bounded != self.tooltipOpacity {
                self.tooltipOpacity = bounded
                applyVisibility()
            }
        }
        if let showHUD, showHUD != hudEnabled {
            hudEnabled = showHUD
            applyVisibility()
        }
    }

    /// Say where the lesson is, when the learner has lost it.
    ///
    /// A pointer thirty points wide on a large display is easy to miss, and the
    /// tooltip hides itself whenever the learner's own pointer is over it. This
    /// pulses both, in place, without moving the step or disturbing anything.
    func locate() {
        guard lastPoint != nil else { return }
        pointerIsOver = false
        applyVisibility()
        for panel in [cursor, tooltip] { panel?.orderFrontRegardless() }
        // The tip's own pulse, and nothing else.
        //
        // This used to dip the whole overlay's opacity twice and draw a box
        // around the pointer as well. Three cues for one question, and the two
        // loud ones both answered it worse: blinking the overlay says "something
        // here changed" without saying where, and a box drawn around the arrow
        // marks the arrow rather than the thing the arrow is indicating. The
        // pulse is already on the tip, which is the only place the answer is.
        pulseCursor()
        status("Calla — here")
    }

    /// A destination cue, including the first point. The overlay panel moves;
    /// the user's physical mouse is never read or moved by this method.
    func pulseCursor() {
        guard narrating, !askOnly else { return }
        model.pulse()
    }

    /// Say one thing, briefly, with no lesson behind it.
    ///
    /// For the cases where the learner asked for something and the answer is "not
    /// yet, because…". Those used to be written to a status string nothing
    /// rendered, so the shortcut and the menu button both appeared to be broken.
    /// Carries no lesson controls — there is no lesson — and takes itself away.
    func showNotice(_ text: String) {
        askOnly = true
        model.askOnly = true
        model.step = "Calla"
        model.text = text
        model.thinking = false
        model.working = nil
        pointerIsOver = false
        narrating = true
        tooltip?.setFrame(askFrame(), display: true)
        status("Calla — not started")
        applyVisibility()
        noticeGeneration += 1
        let generation = noticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated {
                // Only if nothing has happened since; a lesson that started in the
                // meantime must not be torn down by an old notice expiring.
                guard CallaOverlay.shared.noticeGeneration == generation else { return }
                CallaOverlay.shared.hide()
            }
        }
    }

    /// Open the tooltip's question field from a shortcut.
    func beginAsking() {
        FileHandle.standardError.write("[calla] ask requested, narrating=\(narrating)\n".data(using: .utf8)!)
        // Asking holds or begins a different interaction. Do not leave a prior
        // area's boundary behind it.
        clearTargetOutline()
        if !narrating {
            askOnly = true
            model.askOnly = true
            model.step = "Teach me…"
            model.text = "What would you like to learn?"
            model.thinking = false
            model.working = nil
            pointerIsOver = false
            narrating = true
            tooltip?.setFrame(askFrame(), display: true)
            status("Calla — ready")
        }
        askOpen = true
        applyVisibility()
        model.askingRequested += 1
        // Key without activating the app in the Dock sense, so the learner
        // keeps their place; but the process does have to come forward for
        // keystrokes to arrive at all.
        NSApp.activate(ignoringOtherApps: true)
        tooltip?.makeKeyAndOrderFront(nil)
    }

    /// Say plainly that this is not the lesson, and offer the way back.
    func setAside(_ value: Bool) {
        guard aside != value else { return }
        aside = value
        redraw()
    }

    func setFollowFocus(_ value: Bool) {
        guard followFocus != value else { return }
        followFocus = value
        applyVisibility()
    }

    func setHideOnHover(_ value: Bool) {
        guard hideOnHover != value else { return }
        hideOnHover = value
        // Switching it off must reveal the tooltip immediately, not at the next
        // time the pointer happens to move.
        if !value { pointerIsOver = false }
        applyVisibility()
    }

    func updateProximity() {
        // Re-check who is in front here rather than trusting the activation
        // notification alone. A lesson is normally asked for from somewhere
        // else — Raycast, a chat window — so the first guide lands while the
        // taught application is behind. If that one notification is missed the
        // overlay would never come back. Polling a timer that already runs
        // costs nothing and cannot miss.
        // Calla coming forward is not the learner leaving. Asking a question
        // activates this process so the field can take keystrokes, and the
        // scoping rule would otherwise hide the whole lesson the instant the
        // shortcut was pressed. Compared by process, not bundle id, because the
        // renderer is a nested helper and its identifier is easy to get wrong.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != NSRunningApplication.current.processIdentifier {
            frontmostApplicationChanged(to: front.bundleIdentifier)
        }

        // How close the learner's own pointer is to Calla's.
        //
        // The comment on this method promised this and the code never did it,
        // so somebody hunting for a small arrow on a large screen got no signal
        // at all — not warmer, not colder, nothing when they were on top of it.
        // Measured against the anchor the step was drawn at rather than the
        // panel's live frame, for the same reason everything else here is: a
        // frame mid-animation makes the answer depend on its own effect.
        // Calla's pointer gets out of the way of the learner's own.
        //
        // Two arrows on the same spot is one arrow too many: the learner cannot
        // tell which is theirs, and Calla's is sitting on the very control it is
        // asking them to click. So Calla's leaves while theirs is there, and
        // comes back when it goes — the same bargain the lesson card makes.
        //
        // Hysteresis, because a single threshold at the exact distance the mouse
        // is resting at makes the pointer flicker in and out with the hand's own
        // tremor.
        if narrating, let anchor = lastPoint {
            let mouse = NSEvent.mouseLocation
            let distance = hypot(mouse.x - anchor.x, mouse.y - anchor.y)
            let over = pointerOverCursor ? distance < 46 : distance < 30
            if over != pointerOverCursor {
                pointerOverCursor = over
                // Faded rather than switched: a pointer that blinks out reads as
                // a glitch, and one that fades reads as making room.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = over ? 0.12 : 0.18
                    context.timingFunction = CAMediaTimingFunction(name: over ? .easeIn : .easeOut)
                    cursor?.animator().alphaValue = over ? 0 : 1
                }
            }
        } else if pointerOverCursor {
            pointerOverCursor = false
            applyVisibility()
        }

        // Hide the tooltip while the learner's pointer is over it.
        //
        // The card is fixed at top-right now. Testing against the old
        // cursor-attached placement made hover work only at where the card
        // *used* to be, not where it visibly is. Its frame stays fixed while
        // hidden, so this still cannot feed back into its own hit test.
        guard hideOnHover, narrating, let card = tooltip else { return }
        let over = card.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
        guard over != pointerIsOver else { return }
        pointerIsOver = over
        // Set before the fade, not after it: the learner is reaching for what is
        // behind the card, and a click during a 160ms fade must still land there.
        tooltip?.ignoresMouseEvents = over
        NSAnimationContext.runAnimationGroup { context in
            // Long enough to read as the tooltip getting out of the way rather
            // than blinking out, short enough not to be in the way while it does.
            context.duration = over ? 0.16 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: over ? .easeIn : .easeOut)
            tooltip?.animator().alphaValue = over ? 0 : tooltipOpacity
        }
    }

    /// Place the tooltip beside the cursor, inside the taught window, on
    /// whichever side of it has more room.
    ///
    /// Bounding it by the window rather than the display keeps the narration on
    /// the program being taught instead of spilling onto the desktop. Choosing
    /// the side by where the cursor sits is what stops it from parking on top of
    /// the thing it is describing: pointing at something near the top of the
    /// window pushes the words down, pointing near the bottom pushes them up,
    /// and the same for left and right. A window too small to hold it leaves
    /// nowhere legal to sit, so fall back to the display.
    /// Every place the words could legally sit, best first.
    ///
    /// Legacy placement helper retained for binary compatibility with older
    /// helper commands. New lesson card is fixed at top-right via askFrame().
    private func tooltipSlots(for point: CGPoint) -> [CGRect] {
        let size = CGSize(width: tooltipWidth, height: tooltipHeight)
        let display = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
        var bounds = display
        if let window, window.width >= size.width + 20, window.height >= size.height + 20 {
            bounds = window
        }
        // Close enough to read as one object with the pointer. Far enough not
        // to cover what the pointer is indicating.
        let gap: CGFloat = 10
        // Cocoa's y grows upward, so a cursor high on screen has a large y and
        // wants its words below it, at a smaller y.
        // Down and to the right of the tip first, every time. A tooltip that
        // picks a different corner each step stops looking attached to the
        // arrow, which is the only thing telling the learner the words and the
        // pointer are one object. Cocoa's y grows upward, so "below" is the
        // smaller y. The other three corners are fallbacks for when it does not
        // fit, and targets for stepping aside.
        let xs = [point.x + gap, point.x - gap - size.width]
        let ys = [point.y - gap - size.height, point.y + gap]

        var slots: [CGRect] = []
        for y in ys {
            for x in xs {
                let clampedX = min(max(x, bounds.minX + 10), bounds.maxX - size.width - 10)
                let clampedY = min(max(y, bounds.minY + 10), bounds.maxY - size.height - 10)
                slots.append(CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: size))
            }
        }
        return slots
    }

    private func tooltipFrame(for point: CGPoint) -> CGRect {
        tooltipSlots(for: point)[0]
    }

    /// The inset used everywhere the overlay sits against an edge.
    private static let edgeInset: CGFloat = 10

    /// The display something is actually on.
    ///
    /// `NSScreen.main` is the display holding the *key* window, and `screens[0]`
    /// is the one the global coordinate origin sits in. Those are the same
    /// display on a laptop and different displays the moment a second monitor is
    /// plugged in, and this file used both for placement — so a lesson taught on
    /// the second display was measured against the first, and the panels sat off
    /// the window they belonged to. The flip in `cocoa()` still uses `screens[0]`,
    /// because that is what that origin means; everything about placement uses
    /// the screen the thing being placed is on.
    private func screen(containing rect: CGRect?) -> NSScreen? {
        guard let rect else { return NSScreen.main ?? NSScreen.screens.first }
        let overlapping = NSScreen.screens.max { left, right -> Bool in
            let a = left.frame.intersection(rect), b = right.frame.intersection(rect)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
        return overlapping ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The window a lesson is starting in, when it is big enough to hold the
    /// panel; otherwise the display.
    ///
    /// Ask never inherits a former lesson's target, so neither its placement nor
    /// its cursor can leak into an unrelated application.
    private func startingBounds(for size: CGSize) -> CGRect {
        // The card belongs to the application being taught, exactly as the
        // pointer does. It used to fall back to the whole display whenever the
        // window was too small to hold it comfortably, which put Calla's words
        // over whatever else happened to be on that part of the screen — a
        // lesson annotating something it knows nothing about. A window that is
        // genuinely too small gets a card pinned to its corner instead.
        guard let window, window.width > 1, window.height > 1 else {
            return screen(containing: nil)?.frame ?? .zero
        }
        guard window.width >= size.width + 20, window.height >= size.height + 20 else {
            return CGRect(x: window.maxX - size.width - Self.edgeInset * 2,
                          y: window.maxY - size.height - Self.edgeInset * 2,
                          width: size.width + Self.edgeInset * 2,
                          height: size.height + Self.edgeInset * 2)
        }
        return window
    }

    /// Ask opens in the top-right of the window being taught.
    ///
    /// It used to open dead centre, which put it over the middle of the very
    /// interface the learner is about to be taught — the one place guaranteed to
    /// be in the way. Cocoa's y grows upward, so the top edge is `maxY`.
    private func askFrame() -> CGRect {
        let size = CGSize(width: tooltipWidth, height: tooltipHeight)
        let bounds = startingBounds(for: size)
        return CGRect(x: bounds.maxX - size.width - Self.edgeInset,
                      y: bounds.maxY - size.height - Self.edgeInset,
                      width: size.width, height: size.height)
    }


    /// Slide the pointer and its words to the next step together.
    func glide(from: CGPoint, to rawPoint: CGPoint, duration: TimeInterval,
               onArrival: (@MainActor () -> Void)? = nil) {
        let point = clamped(rawPoint)
        lastPoint = point
        // Clearing the flag is not enough on its own: the alpha is where the
        // last hide left it, so a step that began while the learner's pointer
        // happened to be over the old position would arrive invisible.
        pointerIsOver = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if narrating { tooltip?.animator().alphaValue = tooltipOpacity }
            // setFrame, not setFrameOrigin: the animator proxy ignores
            // setFrameOrigin on a window, so animating that way moved the
            // tooltip and left the pointer standing where it was.
            if let cursor {
                cursor.animator().setFrame(
                    CGRect(origin: cursorOrigin(for: point), size: cursor.frame.size),
                    display: true)
            }
            // Fixed card follows only window geometry. Never move it per target.
            tooltip?.animator().setFrame(askFrame(), display: true)
        } completionHandler: {
            MainActor.assumeIsolated { onArrival?() }
        }
    }

    func move(to rawPoint: CGPoint) {
        let point = clamped(rawPoint)
        lastPoint = point
        cursor?.setFrameOrigin(cursorOrigin(for: point))
        tooltip?.setFrameOrigin(askFrame().origin)
    }

    // The route is deliberately not mirrored here.
    //
    // The tooltip used to hold the model's whole plan so it could say "Step 2 of
    // 5", which meant a second copy of state the engine already owns and a set
    // of rules for merging a re-plan against it. The header says what this step
    // is instead. The plan itself still exists where it earns its keep — in the
    // host's engine, carrying each step's region and words, which is what lets
    // the Mac advance a step in about a tenth of a second instead of waiting on
    // a Gateway turn.

    /// A new beat of the lesson: new words, and no longer waiting on anything.
    func setThinking(_ value: Bool, step: String, text: String) {
        model.thinking = value
        model.working = nil
        model.step = step
        model.text = text
    }

    /// Say that Calla is busy without disturbing the step.
    ///
    /// `nil` means done working. The step, its words and the pointer's position
    /// are all left alone — this only lights the working line and the pointer's
    /// marching outline, which is what "loading" should have meant all along.
    func setWorking(_ text: String?, status: String? = nil) {
        model.working = text
        model.thinking = text != nil
        if let status { self.status(status) }
    }

    /// Where to wait when no step has said where to point yet: the top-right of
    /// the window being taught, matching where Ask opens.
    ///
    /// The centre was the obvious choice and the wrong one — before Calla has
    /// been told where to point, the one thing it should not cover is the middle
    /// of the interface. Waiting in the same corner Ask uses also means a lesson
    /// does not appear to jump across the window between being asked and getting
    /// its first instruction.
    var restingPoint: CGPoint {
        let size = CGSize(width: tooltipWidth, height: tooltipHeight)
        let bounds = startingBounds(for: size)
        return CGPoint(x: bounds.maxX - Self.edgeInset - size.width / 2,
                       y: bounds.maxY - Self.edgeInset)
    }

    /// Kept as the one place that says "something about the lesson changed".
    ///
    /// It used to replace both panels' hosting views; now the model has already
    /// published the change and SwiftUI has already drawn it, so all that is left
    /// is making sure the panels are where the window server can see them.
    private func redraw() {
        for panel in [tooltip, cursor] { panel?.orderFrontRegardless() }
    }

    /// Puts the narration away and leaves the pointer on screen. Calla is still
    /// active — the helper is still running — so the pointer still belongs
    /// there. `quit` is what ends the session.
    /// End the lesson gently.
    ///
    /// Cutting the alpha to zero in one frame reads as the overlay being
    /// yanked, which makes a finished lesson feel like a crash. A short fade,
    /// and the pointer leaving last, gives it an ending.
    func hide() {
        narrating = false
        askOpen = false
        askOnly = false
        model.askingRequested = 0
        pointerIsOver = false
        Shortcuts.shared.release()
        model.animating = false
        pointerOverCursor = false
        tooltip?.ignoresMouseEvents = true
        highlightGeneration &+= 1
        clearTargetOutline()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            cursor?.animator().alphaValue = 0
            tooltip?.animator().alphaValue = 0
            hud?.animator().alphaValue = 0
            highlightOutline?.animator().alphaValue = 0
        }
    }

    func status(_ text: String) { model.status = text }
}


// MARK: - Shortcuts

/// Answering Calla without touching the tooltip.
///
/// The tooltip moves out from under the learner's pointer, which makes it a
/// poor thing to have to click, and reaching for it means leaving whatever they
/// were doing anyway. These are system-wide hot keys.
///
/// Carbon's RegisterEventHotKey rather than an NSEvent global monitor on
/// purpose: a global keyboard monitor needs Accessibility, and the whole point
/// of this path is that it needs nothing but Screen Recording.
@MainActor
final class Shortcuts {
    static let shared = Shortcuts()

    /// ⌥⌘⏎ did it · ⌥⌘/ ask · ⌥⌘L back to lesson
    ///
    /// Stop is deliberately absent. Its label rode on a tooltip pill that has
    /// moved to the menu bar, and a shortcut nobody can see is one nobody can
    /// use on purpose — only by accident, ending a lesson mid-step.
    ///
    /// `global` is held for as long as Calla is running; the rest only while a
    /// lesson is on screen. Ask is global because it is how a lesson *starts*: a
    /// shortcut that works only once a lesson exists cannot begin one, which is
    /// why starting used to mean going to the menu bar and finding the right
    /// application already in front.
    private static let bindings: [(id: UInt32, key: Int, event: String, label: String, global: Bool)] = [
        (1, kVK_Return, "next", "⌥⌘↩", false),
        (2, kVK_ANSI_Slash, "ask", "⌥⌘/", true),
        (3, kVK_ANSI_L, "resume", "⌥⌘L", false),
    ]

    private var installed = false
    /// Split by scope so releasing a lesson's keys never drops the global one.
    private var registered: [EventHotKeyRef] = []
    private var globalRegistered: [EventHotKeyRef] = []
    /// Combos another application already owns. Reported rather than silently
    /// swallowed, because a shortcut that does nothing is worse than none.
    private(set) var unavailable: [String] = []

    func install(onEvent: @escaping (String) -> Void) {
        guard !installed else { return }
        installed = true
        self.onEvent = onEvent

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let id = pressed.id
            DispatchQueue.main.async { MainActor.assumeIsolated { Shortcuts.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)

    }

    /// Register one scope's worth of keys.
    private func register(global: Bool) -> [EventHotKeyRef] {
        let modifiers = UInt32(optionKey | cmdKey)
        var references: [EventHotKeyRef] = []
        var missing: [String] = []
        for binding in Self.bindings where binding.global == global {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.key), modifiers,
                EventHotKeyID(signature: OSType(0x43414C41), id: binding.id),
                GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                references.append(reference)
            } else {
                missing.append(binding.label)
            }
        }
        for label in missing where !unavailable.contains(label) { unavailable.append(label) }
        note("claimed \(references.count) \(global ? "global" : "lesson") shortcut(s)"
             + (missing.isEmpty ? "" : "; unavailable: \(missing.joined(separator: " "))"))
        if !missing.isEmpty {
            CallaOverlay.emit("shortcuts_unavailable", missing.joined(separator: " "))
        }
        return references
    }

    /// Hold Ask for as long as Calla runs.
    ///
    /// A system-wide hot key outranks the application underneath it, so holding
    /// all three permanently would quietly take three combinations away from
    /// every program on the Mac. One is the price of being able to start a lesson
    /// from wherever the learner already is, which is the whole point.
    func claimGlobal() {
        guard installed, globalRegistered.isEmpty else { return }
        globalRegistered = register(global: true)
    }

    /// Hold the lesson's own keys only while a lesson is on screen, so a
    /// collision with the program being taught lasts as long as the lesson and no
    /// longer.
    func claim() {
        guard installed else { return }
        // Registering over the top of a live set is what produced duplicates.
        guard registered.isEmpty else { return }
        registered = register(global: false)
    }

    func release() {
        for reference in registered { UnregisterEventHotKey(reference) }
        registered = []
    }

    private var onEvent: ((String) -> Void)?

    fileprivate func fire(_ id: UInt32) {
        guard let binding = Self.bindings.first(where: { $0.id == id }) else { return }
        // Logged because whether a hot key arrives cannot be observed from
        // outside the process: macOS lets several applications register the
        // same combination, so a successful registration proves nothing.
        note("hotkey \(binding.label) -> \(binding.event)")
        // A resume with no lesson running is a stray — a duplicate registration
        // from an earlier build, or a combination the learner meant for the
        // application underneath. The same guard used to protect stop, which
        // acting on tore down lessons that had only just started.
        if binding.event == "resume", !CallaOverlay.shared.isNarrating {
            note("ignored resume: no lesson running")
            return
        }
        if binding.event == "ask" {
            if CallaOverlay.shared.isNarrating {
                // A lesson is up, so the window is already adopted and the field
                // can open right here.
                CallaOverlay.shared.beginAsking()
            } else {
                // No lesson yet, so this process does not know which window to
                // open over. Only the host can resolve the subject — it holds the
                // allowlist and what the learner was last working in — so let it
                // decide and send the ask back with a window attached.
                onEvent?("ask_open")
            }
        } else {
            onEvent?(binding.event)
        }
    }
}

// MARK: - Command loop

struct WindowRect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct Command: Decodable {
    let cmd: String
    let x: Double?
    let y: Double?
    let window: WindowRect?
    /// The control to outline, for `highlight`.
    let rect: WindowRect?
    /// Broad target area to keep outlined for this step.
    let target_rect: WindowRect?
    let owner: String?
    let hide_on_hover: Bool?
    let follow_focus: Bool?
    let tooltip_width: Int?
    let cursor_size: Int?
    let tooltip_opacity: Double?
    let show_hud: Bool?
    let step: String?
    let text: String?
    let status: String?
    let thinking: Bool?
    /// A working status rather than a new beat of the lesson: keep the step.
    let holding: Bool?
    /// The lesson is held while the learner asks something else.
    let aside: Bool?
}

func cocoa(_ p: CGPoint) -> CGPoint {
    guard let primary = NSScreen.screens.first else { return p }
    return CGPoint(x: p.x, y: primary.frame.height - p.y)
}

/// Top-left-origin screen rect to Cocoa's bottom-left origin.
func cocoa(_ rect: WindowRect) -> CGRect {
    guard let primary = NSScreen.screens.first else {
        return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
    return CGRect(x: rect.x, y: primary.frame.height - rect.y - rect.height,
                  width: rect.width, height: rect.height)
}

/// Quadratic arc so the cursor sweeps to its target instead of sliding along a
/// ruler, which is far easier for the eye to follow.
func arc(_ from: CGPoint, _ to: CGPoint, _ t: CGFloat) -> CGPoint {
    let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
    let dx = to.x - from.x, dy = to.y - from.y
    let length = max(sqrt(dx * dx + dy * dy), 1)
    let bow = min(length * 0.22, 120)
    let control = CGPoint(x: mid.x - dy / length * bow, y: mid.y + dx / length * bow)
    let inv = 1 - t
    return CGPoint(x: inv * inv * from.x + 2 * inv * t * control.x + t * t * to.x,
                   y: inv * inv * from.y + 2 * inv * t * control.y + t * t * to.y)
}

@MainActor
final class Runner {
    static let shared = Runner()
    private var last: CGPoint?
    private var step = "Calla"
    private var text = ""

    /// Change what the tooltip says without moving the cursor. This is how a
    /// lesson narrates several beats about one control, and how it shows that
    /// the model is still deciding.
    ///
    /// `holding` means "Calla is working on this step", not "here is the next
    /// thing to do". Those had been the same call, so pressing "Did it" replaced
    /// the instruction the learner was halfway through with the word
    /// "Thinking…" — throwing away the one thing they still needed to read while
    /// they waited. A held narration keeps the step and its words exactly where
    /// they are and says what Calla is doing on the working line instead.
    func narrate(step: String?, text: String?, status: String?, thinking: Bool, holding: Bool = false) {
        // Only when there is a step to hold on to. Asked from Raycast, this is
        // the first thing on screen and the very message worth showing, so it
        // falls through and opens the tooltip like any other beat.
        if holding, CallaOverlay.shared.isNarrating {
            CallaOverlay.shared.setWorking(thinking ? (text ?? "Working…") : nil,
                                           status: status)
            return
        }
        self.step = step ?? self.step
        self.text = text ?? self.text
        // Before the first `point` there is no anchor to narrate at, and this
        // used to return without drawing anything — which is why "Starting a
        // lesson…" never appeared and the first turn of every lesson looked like
        // nothing was happening. The centre of the taught window is a truthful
        // enough place to wait: Calla has not been told where to point yet.
        let anchor = last ?? CallaOverlay.shared.restingPoint
        last = anchor
        CallaOverlay.shared.begin(at: anchor, step: self.step, text: self.text,
                                  status: status ?? "Calla")
        CallaOverlay.shared.setThinking(thinking, step: self.step, text: self.text)
        CallaOverlay.shared.pulseCursor()
    }

    func point(_ target: CGPoint, step: String, text: String, status: String) {
        self.step = step
        self.text = text
        guard let from = last else {
            CallaOverlay.shared.begin(at: target, step: step, text: text, status: status)
            CallaOverlay.shared.setThinking(false, step: step, text: text)
            CallaOverlay.shared.pulseCursor()
            last = target
            return
        }
        // One Core Animation run rather than sixty dispatched frames. The old
        // arc was drawn by scheduling a setFrameOrigin per frame, and anything
        // else happening on the main thread showed up as a stutter; handing the
        // whole move to the animator keeps it smooth and costs one call.
        //
        // The move used to be announced as a working state — "moving" — which
        // lit the waiting bar and the pointer's marching outline for the two
        // hundred milliseconds of the glide, on every single step. A step that
        // resolves locally is over before that flicker finishes, so it read as
        // Calla hesitating on work it had already done. The glide says the same
        // thing without claiming to be busy.
        CallaOverlay.shared.setThinking(false, step: step, text: text)
        CallaOverlay.shared.status(status)
        // Arrival is announced by Core Animation rather than by a timer set to
        // the same duration, so the beacon lands with the pointer instead of
        // near it.
        CallaOverlay.shared.glide(from: from, to: target, duration: 0.22) {
            CallaOverlay.shared.pulseCursor()
        }
        last = target
    }
}

/// Panels must be built inside applicationDidFinishLaunching. Built before
/// `run()` they composite only intermittently, and built later they never
/// composite at all — they get a window number and report isVisible while
/// nothing reaches the screen.
final class OverlayDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        note("helper launched pid \(getpid())")
        MainActor.assumeIsolated {
            CallaOverlay.shared.prepare()
            Shortcuts.shared.install { event in CallaOverlay.emit(event, "") }
            // Ask has to work before there is a lesson to ask within — that is
            // how one begins — so it is claimed here rather than when a lesson
            // starts. The lesson's own two keys are still claimed with the lesson.
            Shortcuts.shared.claimGlobal()
        }
        // Follow the learner's attention. NSWorkspace reports this without any
        // Accessibility grant, so scoping the overlay to one application costs
        // no extra permission.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = application?.bundleIdentifier
            MainActor.assumeIsolated { CallaOverlay.shared.frontmostApplicationChanged(to: bundleID) }
        }
    }
}

let app = NSApplication.shared
let delegate = OverlayDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Read commands off the main thread; apply them on it.
Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8),
              let command = try? JSONDecoder().decode(Command.self, from: data) else { continue }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch command.cmd {
                case "highlight":
                    guard let rect = command.rect else { return }
                    CallaOverlay.shared.highlight(cocoa(rect))
                case "point":
                    guard let x = command.x, let y = command.y else { return }
                    CallaOverlay.shared.setHideOnHover(command.hide_on_hover ?? true)
                    CallaOverlay.shared.apply(cursorSize: command.cursor_size.map(CGFloat.init),
                                              tooltipOpacity: command.tooltip_opacity,
                                              showHUD: command.show_hud,
                                              tooltipWidth: command.tooltip_width.map(CGFloat.init))
                    CallaOverlay.shared.adopt(owner: command.owner, window: command.window.map(cocoa))
                    Runner.shared.point(cocoa(CGPoint(x: x, y: y)),
                                        step: command.step ?? "Calla",
                                        text: command.text ?? "",
                                        status: command.status ?? "Calla")
                    CallaOverlay.shared.setTargetOutline(command.target_rect.map(cocoa))
                case "preferences":
                    CallaOverlay.shared.apply(cursorSize: command.cursor_size.map(CGFloat.init),
                                              tooltipOpacity: command.tooltip_opacity,
                                              showHUD: command.show_hud,
                                              tooltipWidth: command.tooltip_width.map(CGFloat.init))
                case "notice":
                    CallaOverlay.shared.showNotice(command.text ?? "")
                case "locate":
                    CallaOverlay.shared.locate()
                case "ask":
                    CallaOverlay.shared.adopt(owner: command.owner, window: command.window.map(cocoa))
                    CallaOverlay.shared.beginAsking()
                case "narrate":
                    Runner.shared.narrate(step: command.step, text: command.text,
                                          status: command.status, thinking: command.thinking ?? false,
                                          holding: command.holding ?? false)
                case "aside":
                    CallaOverlay.shared.setAside(command.aside ?? false)
                case "hide":
                    CallaOverlay.shared.hide()
                case "quit":
                    NSApplication.shared.terminate(nil)
                default:
                    break
                }
            }
        }
    }
    // stdin closed: the host is gone, so the overlay should not linger.
    note("stdin closed -> terminating")
    DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
}

app.run()
