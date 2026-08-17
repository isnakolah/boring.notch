import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// What sits beside the notch, and in which order.
///
/// Every control the header can draw used to own a toggle in whichever pane its
/// feature lived in — the settings gear in Appearance, the battery in Battery,
/// the mirror in Camera — so nothing could tell the reader how many things they
/// had already put up there. Here the count is the interface: three slots a
/// side, and asking for a fourth says so instead of clipping.
struct NotchLayoutPane: View {
    @Default(.notchHeaderLeading) private var leading
    @Default(.notchHeaderTrailing) private var trailing
    @State private var notice: String?

    private var slotsPerSide: Int { NotchHeaderItem.slotsPerSide }

    var body: some View {
        SettingsPane(eyebrow: "Notch", title: "Layout",
                     detail: "Three slots on each side of the notch. Drag to arrange, or place an item from the list below.") {
            arrangementCard
            itemsCard
        }
    }

    // MARK: - Arrangement

    private var arrangementCard: some View {
        SettingCard("Arrangement",
                    detail: "Drag a slot onto another to swap them, or drop it on the bin to clear it.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    sideStrip(.leading)
                    notchGap
                    sideStrip(.trailing)
                    Spacer(minLength: 0)
                    binTarget
                }

                if let notice {
                    Label(notice, systemImage: "exclamationmark.circle.fill")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(NotchTint.attention)
                }

                HStack {
                    Text("\(filled(.leading)) of \(slotsPerSide) left · \(filled(.trailing)) of \(slotsPerSide) right")
                        .font(NotchType.figure)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to defaults") {
                        withAnimation { NotchHeaderLayout.resetToDefaults() }
                        notice = nil
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func sideStrip(_ side: NotchHeaderSide) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(side.title.uppercased())
                .font(NotchType.eyebrow)
                .foregroundStyle(.tertiary)
                .kerning(0.5)
            HStack(spacing: 6) {
                ForEach(0..<slotsPerSide, id: \.self) { index in
                    slotView(side: side, index: index)
                }
            }
            .padding(8)
            .background(NotchSurface.sunken,
                        in: RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
        }
    }

    /// The slab itself, so the two strips read as the two sides of one thing.
    private var notchGap: some View {
        VStack(spacing: 6) {
            Text(" ").font(NotchType.eyebrow)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(NotchSurface.sunken)
                .frame(width: 34, height: 44)
        }
    }

    private func slotView(side: NotchHeaderSide, index: Int) -> some View {
        let item = slots(side)[index]
        return ZStack {
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .fill(item == .none ? Color.clear : Color.white.opacity(0.10))
                .frame(width: 42, height: 42)

            if item == .none {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.white.opacity(0.25))
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(item.isEnabled ? Color.white : Color.white.opacity(0.35))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
        .help(item == .none ? "Empty slot" : item.label)
        .onDrag {
            NSItemProvider(object: NSString(string: "slot:\(side.rawValue):\(index)"))
        }
        .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
            handleDrop(providers) { payload in
                drop(payload, on: side, at: index)
            }
        }
    }

    private var binTarget: some View {
        VStack(spacing: 6) {
            Text(" ").font(NotchType.eyebrow)
            ZStack {
                RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                    .fill(NotchSurface.raised)
                    .frame(width: 44, height: 44)
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .contentShape(RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
            .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                handleDrop(providers) { payload in
                    if case let .slot(side, index) = payload {
                        withAnimation { NotchHeaderLayout.remove(on: side, at: index) }
                        notice = nil
                    }
                }
            }
        }
    }

    // MARK: - Items

    private var itemsCard: some View {
        SettingCard("Items",
                    detail: "Off, left or right. An item whose feature is switched off keeps its slot but stays hidden.") {
            VStack(spacing: 12) {
                ForEach(NotchHeaderItem.placeable) { item in
                    itemRow(item)
                    if item != NotchHeaderItem.placeable.last {
                        Divider().opacity(0.35)
                    }
                }
            }
        }
    }

    private func itemRow(_ item: NotchHeaderItem) -> some View {
        let placement = NotchHeaderLayout.side(of: item)
        return HStack(spacing: 12) {
            SettingGlyph(symbol: item.icon,
                         tint: placement == nil ? NotchTint.paused : NotchTint.active,
                         size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label).font(NotchType.rowTitle)
                    if let pane = item.featurePane, !item.isEnabled {
                        SettingBadge("Off in \(pane)", tint: NotchTint.attention)
                    }
                }
                if let detail = detail(for: item) {
                    Text(detail).font(NotchType.rowDetail).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)

            if let key = item.featureKey {
                Toggle("", isOn: Binding(get: { Defaults[key] },
                                         set: { Defaults[key] = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Turn \(item.label) on or off")
            }

            Picker("", selection: placementBinding(item)) {
                Text("Off").tag(NotchHeaderSide?.none)
                Text("Left").tag(NotchHeaderSide?.some(.leading))
                Text("Right").tag(NotchHeaderSide?.some(.trailing))
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 170)
        }
    }

    private func detail(for item: NotchHeaderItem) -> String? {
        guard let side = NotchHeaderLayout.side(of: item),
              let index = slots(side).firstIndex(of: item) else { return nil }
        return "\(side.title) · slot \(index + 1)"
    }

    private func placementBinding(_ item: NotchHeaderItem) -> Binding<NotchHeaderSide?> {
        Binding(
            get: { NotchHeaderLayout.side(of: item) },
            set: { newValue in
                guard let side = newValue else {
                    withAnimation { NotchHeaderLayout.remove(item) }
                    notice = nil
                    return
                }
                guard NotchHeaderLayout.side(of: item) != side else { return }
                withAnimation {
                    if !NotchHeaderLayout.append(item, to: side) {
                        notice = "\(side.title) side is full. Clear a slot first, then place \(item.label)."
                    } else {
                        notice = nil
                    }
                }
            }
        )
    }

    // MARK: - Drag payloads

    private enum DropPayload {
        case slot(NotchHeaderSide, Int)
    }

    private func drop(_ payload: DropPayload, on side: NotchHeaderSide, at index: Int) {
        if case let .slot(fromSide, fromIndex) = payload {
            withAnimation {
                NotchHeaderLayout.move(from: (fromSide, fromIndex), to: (side, index))
            }
            notice = nil
        }
    }

    private func handleDrop(_ providers: [NSItemProvider],
                            _ apply: @escaping (DropPayload) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) })
        else { return false }
        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let raw = (item as? NSString) as String? ?? item as? String,
                  let payload = parse(raw) else { return }
            DispatchQueue.main.async { apply(payload) }
        }
        return true
    }

    private func parse(_ raw: String) -> DropPayload? {
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == "slot",
              let side = NotchHeaderSide(rawValue: parts[1]),
              let index = Int(parts[2]),
              (0..<NotchHeaderItem.slotsPerSide).contains(index) else { return nil }
        return .slot(side, index)
    }

    // MARK: - Reads

    private func slots(_ side: NotchHeaderSide) -> [NotchHeaderItem] {
        NotchHeaderLayout.padded(side == .leading ? leading : trailing)
    }

    private func filled(_ side: NotchHeaderSide) -> Int {
        slots(side).filter { $0 != .none }.count
    }
}
