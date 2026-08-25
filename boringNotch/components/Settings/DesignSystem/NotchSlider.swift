//
//  NotchSlider.swift
//  boringNotch
//

import SwiftUI

/// The slider this window leans on and had never designed.
///
/// Eight panes were drawing `Slider(value:in:)` with the number parked in a
/// fixed-width column beside it. That control loses on three counts: the value
/// sits far enough from the thumb that reading it means looking away from what
/// you are moving, the ends of the range are never stated so a position means
/// nothing in absolute terms, and the thumb is the same size whether you are
/// hovering it, dragging it, or looking at a disabled control.
///
/// So: a recessed rail, an accent fill that reads as a quantity rather than a
/// highlight, a thumb that grows under the pointer and lifts while it is being
/// dragged, the value riding the thumb during a drag and settling into the label
/// line at rest, and the ends of the range named where they are.
///
/// `accessibilityRepresentation` hands VoiceOver a real `Slider`, so none of the
/// above costs the increment/decrement rotor the stock control gives for free.
struct NotchSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Snap increment. `nil` is continuous — pass one only when the underlying
    /// value is genuinely quantised, never to draw tick marks.
    var step: Double?
    var label: String?
    /// How the number reads. Byte counts, durations, points and percentages are
    /// formatted differently and none of that belongs in a slider.
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    /// What the two ends of the range mean, in words. `nil` where the unit in
    /// the value already says it.
    var ends: (String, String)?
    /// `.glass` draws the rail as a checkerboard under a translucent fill, so a
    /// transparency control shows the transparency it is setting.
    var style: Style = .amount

    enum Style { case amount, glass }

    @State private var hovering = false
    @State private var dragging = false
    @Environment(\.isEnabled) private var isEnabled

    private static let thumb: CGFloat = 18
    private static let thumbActive: CGFloat = 20
    private static let rail: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: NotchSpace.tight) {
            if label != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let label { Text(label).font(NotchType.rowTitle) }
                    Spacer(minLength: 8)
                    // At rest the value lives here. While dragging it rides the
                    // thumb instead, so it is never in two places at once.
                    Text(format(value))
                        .font(NotchType.figure)
                        .foregroundStyle(.secondary)
                        .opacity(dragging ? 0 : 1)
                }
            }
            track
            if let ends {
                HStack {
                    Text(ends.0)
                    Spacer(minLength: 8)
                    Text(ends.1)
                }
                .font(NotchType.figure)
                .foregroundStyle(.tertiary)
            }
        }
        // A real `Slider` for VoiceOver, so none of the above costs the
        // increment/decrement rotor the stock control gives for free. Branched
        // on `step` rather than passing a tiny one: `step:` quantises the whole
        // range, and 0.0001 over a 460…900 range is four million positions for
        // the rotor to walk.
        .accessibilityRepresentation {
            if let step, step > 0 {
                Slider(value: $value, in: range, step: step) { Text(label ?? "") }
            } else {
                Slider(value: $value, in: range) { Text(label ?? "") }
            }
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - Self.thumb)
            let x = Self.thumb / 2 + travel * fraction

            ZStack(alignment: .leading) {
                railView
                fillView(width: x)
                thumbView
                    .position(x: x, y: geometry.size.height / 2)
                if dragging {
                    // Clear of the label line above, which is where the value
                    // lives at rest — the two must never be legible at once.
                    valueBubble
                        .position(x: x, y: -18)
                }
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        set(fraction: (drag.location.x - Self.thumb / 2) / travel)
                    }
                    .onEnded { _ in dragging = false }
            )
            .onHover { hovering = $0 }
        }
        .frame(height: Self.thumbActive)
    }

    @ViewBuilder private var railView: some View {
        switch style {
        case .amount:
            Capsule()
                .fill(Color.primary.opacity(0.10))
                .frame(height: Self.rail)
                // A well, not a line. Without the inner shadow the fill reads as
                // a highlight on a rule rather than as a level in a channel.
                .overlay(
                    Capsule()
                        .strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
                        .blur(radius: 0.5)
                        .mask(Capsule())
                )
        case .glass:
            Checkerboard(square: 4)
                .fill(Color.primary.opacity(0.14))
                .background(Color.primary.opacity(0.05))
                .frame(height: Self.rail)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder private func fillView(width: CGFloat) -> some View {
        switch style {
        case .amount:
            Capsule()
                .fill(isEnabled ? NotchTint.active : Color.secondary)
                .frame(width: max(Self.rail, width), height: Self.rail)
        case .glass:
            Capsule()
                .fill(LinearGradient(
                    colors: [Color.primary.opacity(0), Color.primary.opacity(0.55)],
                    startPoint: .leading, endPoint: .trailing))
                .frame(width: max(Self.rail, width), height: Self.rail)
        }
    }

    private var thumbView: some View {
        let active = (hovering || dragging) && isEnabled
        let size = active ? Self.thumbActive : Self.thumb
        return Circle()
            .fill(isEnabled ? Color.white : Color.white.opacity(0.45))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(dragging ? 0.55 : 0.45),
                    radius: dragging ? 4 : 2, y: dragging ? 2 : 1)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5))
            .background(
                Circle()
                    .fill(NotchTint.active.opacity(dragging ? 0.24 : active ? 0.18 : 0))
                    .frame(width: size + (dragging ? 18 : 12),
                           height: size + (dragging ? 18 : 12))
            )
            .animation(NotchMotion.settle, value: active)
            .animation(NotchMotion.settle, value: dragging)
    }

    private var valueBubble: some View {
        Text(format(value))
            .font(NotchType.figure)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.05, blue: 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
            .fixedSize()
            .transition(.opacity)
    }

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((value - range.lowerBound) / span)
    }

    private func set(fraction raw: CGFloat) {
        let clamped = min(max(Double(raw), 0), 1)
        var next = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
        if let step, step > 0 {
            next = (next / step).rounded() * step
        }
        value = min(max(next, range.lowerBound), range.upperBound)
    }
}

// MARK: - Named stops

/// A slider whose positions have names.
///
/// This is what replaces a segmented picker whose options are a *scale* rather
/// than a set. Capture detail was `1024 | 1600 | 2048`, tooltip opacity was
/// `85% | 92% | 100%`, and the gateway fallback was `Never | On failure | Keep
/// warm` — in every case the options are ordered, the ends mean less-and-more,
/// and a segmented control says none of that. It also has room under each stop
/// for what the stop costs, which a segment does not.
///
/// A genuine set of alternatives — Base and Small, This Mac and Gateway — stays
/// a segmented picker. Ordering is the test.
struct NotchStopSlider<Value: Hashable>: View {
    struct Stop: Identifiable {
        let value: Value
        let title: String
        /// What this stop costs or means. One short phrase.
        var caption: String?
        var id: Int { title.hashValue }
    }

    @Binding var selection: Value
    let stops: [Stop]
    var label: String?
    /// A sentence under the whole control describing the chosen stop. Where the
    /// consequence of the choice is worth a sentence, this is where it goes.
    var detail: String?

    @State private var hovering = false
    @State private var dragging = false
    @Environment(\.isEnabled) private var isEnabled

    private static var thumb: CGFloat { 18 }
    private static var thumbActive: CGFloat { 20 }

    private var index: Int { stops.firstIndex { $0.value == selection } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchSpace.tight) {
            if label != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let label { Text(label).font(NotchType.rowTitle) }
                    Spacer(minLength: 8)
                    Text(stops[index].title)
                        .font(NotchType.figure)
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                let travel = max(1, geometry.size.width - Self.thumb)
                let xs = (0..<stops.count).map { i in
                    Self.thumb / 2 + travel * (stops.count > 1
                        ? CGFloat(i) / CGFloat(stops.count - 1) : 0)
                }
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 6)
                    Capsule()
                        .fill(isEnabled ? NotchTint.active : Color.secondary)
                        .frame(width: max(6, xs[index]), height: 6)
                    ForEach(Array(xs.enumerated()), id: \.offset) { i, x in
                        Circle()
                            .fill(Color.primary.opacity(i <= index ? 0.0 : 0.28))
                            .frame(width: 3, height: 3)
                            .position(x: x, y: geometry.size.height / 2)
                    }
                    thumbView
                        .position(x: xs[index], y: geometry.size.height / 2)
                }
                .frame(height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            dragging = true
                            snap(to: drag.location.x, travel: travel)
                        }
                        .onEnded { _ in dragging = false }
                )
                .onHover { hovering = $0 }
            }
            .frame(height: Self.thumbActive)

            stopLabels
            if let detail {
                Text(detail)
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "")
        .accessibilityValue(stops[index].title)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index + 1 < stops.count { selection = stops[index + 1].value }
            case .decrement: if index > 0 { selection = stops[index - 1].value }
            @unknown default: break
            }
        }
    }

    private var thumbView: some View {
        let active = (hovering || dragging) && isEnabled
        let size = active ? Self.thumbActive : Self.thumb
        return Circle()
            .fill(isEnabled ? Color.white : Color.white.opacity(0.45))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(dragging ? 0.55 : 0.45),
                    radius: dragging ? 4 : 2, y: dragging ? 2 : 1)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5))
            .background(
                Circle()
                    .fill(NotchTint.active.opacity(dragging ? 0.24 : active ? 0.18 : 0))
                    .frame(width: size + (dragging ? 18 : 12),
                           height: size + (dragging ? 18 : 12))
            )
            .animation(NotchMotion.settle, value: active)
    }

    /// Laid out by alignment guide rather than by equal-width slots: a stop is
    /// at `i/(n-1)` of the travel, which is not the centre of an nth of the
    /// width, and labels that drift off their ticks are worse than no labels.
    private var stopLabels: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - Self.thumb)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                    let x = Self.thumb / 2 + travel * (stops.count > 1
                        ? CGFloat(i) / CGFloat(stops.count - 1) : 0)
                    VStack(spacing: 1) {
                        Text(stop.title)
                            .font(NotchType.figure)
                            .foregroundStyle(i == index ? AnyShapeStyle(.primary)
                                                        : AnyShapeStyle(.tertiary))
                            .fontWeight(i == index ? .semibold : .regular)
                        if let caption = stop.caption {
                            Text(caption)
                                .font(.system(size: 9, design: .rounded).monospacedDigit())
                                .foregroundStyle(i == index ? AnyShapeStyle(.secondary)
                                                            : AnyShapeStyle(.quaternary))
                        }
                    }
                    .fixedSize()
                    .alignmentGuide(.leading) { d in
                        // The end labels hang inside the track rather than off it.
                        let anchor: CGFloat = i == 0 ? 0
                            : i == stops.count - 1 ? d.width : d.width / 2
                        return anchor - x
                    }
                    .alignmentGuide(.top) { _ in 0 }
                }
            }
        }
        .frame(height: stops.contains { $0.caption != nil } ? 26 : 15)
        .animation(NotchMotion.settle, value: index)
    }

    private func snap(to x: CGFloat, travel: CGFloat) {
        guard stops.count > 1 else { return }
        let f = min(max((x - Self.thumb / 2) / travel, 0), 1)
        let i = Int((f * CGFloat(stops.count - 1)).rounded())
        let next = stops[min(max(i, 0), stops.count - 1)].value
        if next != selection { selection = next }
    }
}

// MARK: - Pieces

/// The transparency rail's ground. Drawn rather than imaged so it stays crisp
/// at any width and follows the appearance.
private struct Checkerboard: Shape {
    let square: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var y: CGFloat = 0
        var row = 0
        while y < rect.height {
            var x: CGFloat = row.isMultiple(of: 2) ? 0 : square
            while x < rect.width {
                path.addRect(CGRect(x: x, y: y,
                                    width: min(square, rect.width - x),
                                    height: min(square, rect.height - y)))
                x += square * 2
            }
            y += square
            row += 1
        }
        return path
    }
}
