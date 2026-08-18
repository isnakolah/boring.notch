import Defaults
import SwiftUI

/// The notch, at the top of the sidebar, showing the pane you are editing.
///
/// Every pane in this window configures one physical surface. General and
/// Advanced change its geometry, Media, Battery, HUDs and Calendar change what
/// it displays, and the rest hang features off it. So the surface itself is the
/// thing worth putting where it can be seen while it is being changed, rather
/// than a decorative header that repeats the pane name already below it.
///
/// `MusicSlotConfigurationView` already proved the idea at row scale with its
/// "Layout Preview"; this is the same move at window scale.
///
/// Bound to a plain snapshot rather than to `BoringViewCoordinator`, so opening
/// Settings never drags a media player, a capture, or an XPC poll in with it.
struct NotchPreviewWell: View {
    let content: NotchPreviewContent

    @Default(.cornerRadiusScaling) private var cornerRadiusScaling

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                NotchShape(
                    topCornerRadius: cornerRadiusScaling ? 8 : 6,
                    bottomCornerRadius: cornerRadiusScaling ? 18 : 14
                )
                .fill(NotchSurface.sunken)
                .frame(height: 46)
                .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
                .animation(NotchMotion.drill, value: content.caption)

                content.view
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .frame(height: 46)
            }
            .frame(maxWidth: .infinity)

            Text(content.caption)
                .font(NotchType.rowDetail)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

/// What the well is showing. One case per pane group that has something true to
/// draw; panes that only change geometry fall to `.shape`, which is still live
/// because geometry is exactly what they change.
enum NotchPreviewContent {
    case shape
    case media(title: String, artist: String)
    case battery(percent: Int, charging: Bool)
    case hud(symbol: String, fraction: Double)
    case activity(symbol: String, text: String, tint: Color, caption: String)
    /// The header items as they are actually arranged right now.
    ///
    /// Header layout is the one pane where the well is load-bearing rather than
    /// decorative — it is the answer to what the pane is asking. The pane had
    /// been drawing its own smaller version of this.
    case slots(leading: [NotchHeaderItem], trailing: [NotchHeaderItem])
    /// A figure that is part of a whole: reclaimable space, processor load.
    case meter(label: String, fraction: Double, tint: Color, caption: String)

    var caption: String {
        switch self {
        case .shape: return "Your notch, at its current size"
        case .media: return "Media live activity"
        case .battery: return "Charge indicator"
        case .hud: return "System HUD replacement"
        case let .activity(_, _, _, caption): return caption
        case .slots: return "What sits either side of your notch"
        case let .meter(_, _, _, caption): return caption
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .shape:
            EmptyView()
        case let .media(title, artist):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(NotchTint.active.opacity(0.8))
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                    Text(artist).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 4)
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTint.active)
            }
            .lineLimit(1)
        case let .battery(percent, charging):
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text("\(percent)%")
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Image(systemName: charging ? "battery.100.bolt" : "battery.75")
                    .font(.system(size: 12))
                    .foregroundStyle(charging ? NotchTint.healthy : .white)
            }
        case let .hud(symbol, fraction):
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.white)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(NotchTint.active)
                            .frame(width: max(0, geometry.size.width * fraction))
                    }
                }
                .frame(height: 4)
            }
        case let .activity(symbol, text, tint, _):
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint)
                Text(text).font(.system(size: 10)).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
            }
            .lineLimit(1)
        case let .slots(leading, trailing):
            HStack(spacing: 0) {
                slotStrip(leading, alignment: .leading)
                Spacer(minLength: 8)
                slotStrip(trailing, alignment: .trailing)
            }
        case let .meter(label, fraction, tint, _):
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(tint)
                            .frame(width: max(0, geometry.size.width * min(max(fraction, 0), 1)))
                    }
                }
                .frame(height: 4)
            }
        }
    }

    @ViewBuilder
    private func slotStrip(_ items: [NotchHeaderItem], alignment: HorizontalAlignment) -> some View {
        HStack(spacing: 5) {
            if items.isEmpty {
                Text("Empty")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
            } else {
                ForEach(items) { item in
                    Image(systemName: item.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(item.isEnabled ? .white.opacity(0.85) : .white.opacity(0.25))
                }
            }
        }
    }
}
