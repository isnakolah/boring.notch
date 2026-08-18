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
    @Environment(\.settingsRouter) private var router

    @Default(.notchHeaderLeading) private var leading
    @Default(.notchHeaderTrailing) private var trailing
    @State private var notice: String?
    /// Which slot the pointer is over mid-drag, so a slot can say it will
    /// take the thing before it is let go.
    @State private var targeted: String?
    /// Which filled slot the pointer is over, so it can offer to be emptied.
    @State private var hovered: String?

    private var slotsPerSide: Int { NotchHeaderItem.slotsPerSide }

    var body: some View {
        SettingsPane(SettingsPage.headerLayout) {
            arrangementCard
            itemsCard
        }
    }

    // MARK: - Arrangement

    private var arrangementCard: some View {
        SettingCard("Arrangement",
                    detail: "Click an item to put it up or take it down, or drag it where you want it.") {
            VStack(alignment: .leading, spacing: NotchSpace.row) {
                openNotchPreview

                Divider().opacity(0.35)

                palette

                if let notice {
                    Label(notice, systemImage: "exclamationmark.circle.fill")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(NotchTint.attention)
                }

                HStack(spacing: NotchSpace.row) {
                    Text("\(filled(.leading)) of \(slotsPerSide) left · \(filled(.trailing)) of \(slotsPerSide) right")
                        .font(NotchType.figure)
                        .foregroundStyle(.secondary)
                    Spacer()
                    binTarget
                    Button("Reset to defaults") {
                        withAnimation(NotchMotion.settle) { NotchHeaderLayout.resetToDefaults() }
                        notice = nil
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    /// Everything the header can hold, as things you pick up.
    ///
    /// The same shape Media's control slots use — a tile with its name under it,
    /// dragged onto a slot — because they are the same task twice and there is
    /// no reason for the two panes to teach it differently. Tapping is the
    /// shortcut for the common case: put it in the first free slot.
    private var palette: some View {
        VStack(alignment: .leading, spacing: NotchSpace.tight) {
            Text("Click to place or remove. Outlined items are already up there.")
                .font(NotchType.rowDetail)
                .foregroundStyle(.secondary)

            // A grid, not a horizontal scroller. There are nine of these and
            // the scroller put the last two past the edge, where nothing tells
            // you they exist.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72, maximum: 92), spacing: NotchSpace.snug)],
                      alignment: .leading,
                      spacing: NotchSpace.row) {
                ForEach(NotchHeaderItem.placeable) { item in
                    paletteChip(item)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func paletteChip(_ item: NotchHeaderItem) -> some View {
        let placed = NotchHeaderLayout.side(of: item) != nil
        return VStack(spacing: NotchSpace.tight) {
            ZStack {
                RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                    .fill(NotchSurface.raised)
                    .frame(width: 44, height: 44)
                if placed {
                    RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                        .strokeBorder(Color.effectiveAccent.opacity(0.55), lineWidth: 1)
                        .frame(width: 44, height: 44)
                }
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary)
            }
            .opacity(placed ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
            .help(placed ? "Click to take \(item.label) down" : "Click to place \(item.label)")
            .onDrag { NSItemProvider(object: NSString(string: "item:\(item.rawValue)")) }
            .onTapGesture {
                withAnimation(NotchMotion.settle) {
                    if placed {
                        NotchHeaderLayout.remove(item)
                        notice = nil
                    } else {
                        placeInFirstFreeSlot(item)
                    }
                }
            }

            Text(item.label)
                .font(NotchType.figure)
                .foregroundStyle(.secondary)
                .frame(width: 62)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .animation(NotchMotion.settle, value: placed)
    }

    private func placeInFirstFreeSlot(_ item: NotchHeaderItem) {
        if NotchHeaderLayout.append(item, to: .leading) || NotchHeaderLayout.append(item, to: .trailing) {
            notice = nil
        } else {
            notice = "Both sides are full. Take something down first, then place \(item.label)."
        }
    }

    /// The notch as it looks open, with the slots where the items actually land.
    ///
    /// This used to be two abstract strips labelled LEFT and RIGHT beside a grey
    /// rectangle. That told you the order but not the result — you arranged
    /// something here and found out what it looked like by closing Settings.
    /// Dragging onto a picture of the thing being configured is the whole point
    /// of the pane, so the picture is the pane.
    private var openNotchPreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<slotsPerSide, id: \.self) { index in
                        slotView(side: .leading, index: index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // The physical notch, which the header parts around.
                NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
                    .fill(Color.black)
                    .frame(width: 78, height: 26)

                HStack(spacing: 6) {
                    ForEach(0..<slotsPerSide, id: \.self) { index in
                        slotView(side: .trailing, index: index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            // What the rest of the open notch is for, dimmed: it is not being
            // configured here, but without it the header floats in nothing.
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(Color.white.opacity(0.06)).frame(width: 120, height: 8)
                    Capsule().fill(Color.white.opacity(0.04)).frame(width: 76, height: 7)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: 470)
        .background(
            NotchShape(topCornerRadius: 0, bottomCornerRadius: 22)
                .fill(NotchSurface.sunken)
        )
        .overlay(
            NotchShape(topCornerRadius: 0, bottomCornerRadius: 22)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        // Centred, because it is a picture of something that is itself centred
        // on the screen.
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(NotchMotion.settle, value: leading)
        .animation(NotchMotion.settle, value: trailing)
    }

    private func slotView(side: NotchHeaderSide, index: Int) -> some View {
        let item = slots(side)[index]
        let key = "\(side.rawValue):\(index)"
        let isTarget = targeted == key
        return ZStack {
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .fill(isTarget ? Color.effectiveAccent.opacity(0.30)
                               : (item == .none ? Color.clear : Color.white.opacity(0.10)))
                .frame(width: 42, height: 42)
                .overlay {
                    if isTarget {
                        RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                            .strokeBorder(Color.effectiveAccent, lineWidth: 1.5)
                            .frame(width: 42, height: 42)
                    }
                }

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
        .overlay(alignment: .topTrailing) {
            // Removing something used to mean finding a small bin at the far
            // corner of the card and dragging to it. The slot itself is where
            // anyone looks first, so the way out is on the slot.
            if item != .none, hovered == key {
                Button {
                    withAnimation(NotchMotion.settle) { NotchHeaderLayout.remove(on: side, at: index) }
                    notice = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .help("Take \(item.label) down")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .onHover { inside in
            withAnimation(NotchMotion.settle) { hovered = inside ? key : (hovered == key ? nil : hovered) }
        }
        .contentShape(RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
        .help(item == .none ? "Empty slot" : item.label)
        .onDrag {
            NSItemProvider(object: NSString(string: "slot:\(side.rawValue):\(index)"))
        }
        .onDrop(of: [UTType.plainText.identifier],
                isTargeted: Binding(get: { isTarget },
                                    set: { targeted = $0 ? key : (targeted == key ? nil : targeted) })) { providers in
            targeted = nil
            return handleDrop(providers) { payload in
                drop(payload, on: side, at: index)
            }
        }
        .animation(NotchMotion.settle, value: isTarget)
    }

    /// A place to drop things, said out loud.
    ///
    /// It was a bare 44pt bin glyph in the corner with nothing naming it, which
    /// is fine once you know and invisible until then. It is a labelled target
    /// now, and it is no longer the only way to take something down.
    private var binTarget: some View {
        let active = targeted == "bin"
        return HStack(spacing: NotchSpace.tight) {
            Image(systemName: active ? "trash.fill" : "trash")
                .font(.system(size: 12, weight: .medium))
            Text("Drop to remove")
                .font(NotchType.rowDetail)
        }
        .foregroundStyle(active ? NotchTint.stuck : .secondary)
        .padding(.horizontal, NotchSpace.snug)
        .padding(.vertical, NotchSpace.tight)
        .background(
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .fill(active ? NotchTint.stuck.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .strokeBorder(active ? NotchTint.stuck : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .contentShape(RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
        .onDrop(of: [UTType.plainText.identifier],
                isTargeted: Binding(get: { targeted == "bin" },
                                    set: { targeted = $0 ? "bin" : (targeted == "bin" ? nil : targeted) })) { providers in
            targeted = nil
            return handleDrop(providers) { payload in
                withAnimation(NotchMotion.settle) {
                    switch payload {
                    case let .slot(side, index): NotchHeaderLayout.remove(on: side, at: index)
                    case let .item(item): NotchHeaderLayout.remove(item)
                    }
                }
                notice = nil
            }
        }
        .animation(NotchMotion.settle, value: active)
    }

    // MARK: - Items

    private var itemsCard: some View {
        SettingCard("Features",
                    detail: "An item whose feature is switched off keeps its slot but stays hidden.") {
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
                    if let name = item.featurePaneName, !item.isEnabled {
                        Button {
                            if let route = item.featureRoute { router?.go(route) }
                        } label: {
                            SettingBadge("Off in \(name)", tint: NotchTint.attention)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(name)")
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

        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Still draggable, so the row you are reading is also a place you can
        // pick the thing up from. Placement itself lives in the palette above.
        .onDrag {
            NSItemProvider(object: NSString(string: "item:\(item.rawValue)"))
        }
    }

    private func detail(for item: NotchHeaderItem) -> String? {
        guard let side = NotchHeaderLayout.side(of: item),
              let index = slots(side).firstIndex(of: item) else { return nil }
        return "\(side.title) · slot \(index + 1)"
    }


    // MARK: - Drag payloads

    private enum DropPayload {
        /// Something already placed, being moved.
        case slot(NotchHeaderSide, Int)
        /// Something from the palette, being placed for the first time.
        case item(NotchHeaderItem)
    }

    private func drop(_ payload: DropPayload, on side: NotchHeaderSide, at index: Int) {
        withAnimation {
            switch payload {
            case let .slot(fromSide, fromIndex):
                NotchHeaderLayout.move(from: (fromSide, fromIndex), to: (side, index))
            case let .item(item):
                // Placing something that is already up there is a move, not a
                // second copy of it.
                if let from = NotchHeaderLayout.side(of: item),
                   let fromIndex = slots(from).firstIndex(of: item) {
                    NotchHeaderLayout.move(from: (from, fromIndex), to: (side, index))
                } else {
                    NotchHeaderLayout.place(item, on: side, at: index)
                }
            }
        }
        notice = nil
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
        switch parts.first {
        case "slot":
            guard parts.count == 3,
                  let side = NotchHeaderSide(rawValue: parts[1]),
                  let index = Int(parts[2]),
                  (0..<NotchHeaderItem.slotsPerSide).contains(index) else { return nil }
            return .slot(side, index)
        case "item":
            guard parts.count == 2, let item = NotchHeaderItem(rawValue: parts[1]),
                  item != .none else { return nil }
            return .item(item)
        default:
            return nil
        }
    }

    // MARK: - Reads

    private func slots(_ side: NotchHeaderSide) -> [NotchHeaderItem] {
        NotchHeaderLayout.padded(side == .leading ? leading : trailing)
    }

    private func filled(_ side: NotchHeaderSide) -> Int {
        slots(side).filter { $0 != .none }.count
    }
}
