//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

/// One side of the open notch's header, drawn from its three slots.
///
/// This replaces the old hand-rolled tab list plus the run of `if Defaults[...]`
/// buttons on the other side. Both sides are the same view now, so the two
/// halves cannot drift apart in spacing, tint or selection behaviour, and
/// neither can grow past three items.
struct TabSelectionView: View {
    let side: NotchHeaderSide

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var callaEngine = CallaEngineClient.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    @EnvironmentObject var vm: BoringViewModel

    @Default(.notchHeaderLeading) private var leading
    @Default(.notchHeaderTrailing) private var trailing
    @Default(.boringShelf) private var boringShelf
    @Default(.pomodoroTab) private var pomodoroTab
    @Default(.usageMonitorTab) private var usageMonitorTab
    @Default(.callaTutorEnabled) private var callaTutorEnabled
    @Default(.callaCopilotEnabled) private var callaCopilotEnabled
    @Default(.showMirror) private var showMirror
    @Namespace private var animation

    init(side: NotchHeaderSide) {
        self.side = side
    }

    /// Slots whose feature is on. Reading the `@Default` properties above rather
    /// than `NotchHeaderItem.isEnabled` is what makes the row live-update when a
    /// toggle changes in Settings.
    private var items: [NotchHeaderItem] {
        NotchHeaderLayout.padded(side == .leading ? leading : trailing)
            .filter { isVisible($0) }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(items) { item in
                view(for: item)
            }
        }
        .clipShape(Capsule())
    }

    private func isVisible(_ item: NotchHeaderItem) -> Bool {
        switch item {
        case .none: return false
        case .home, .settings, .battery: return true
        case .pomodoro: return pomodoroTab
        case .usage: return usageMonitorTab
        // The shelf tab still hides itself while the shelf is empty unless the
        // reader asked for the tabs to stay put.
        case .shelf: return boringShelf && (!tvm.isEmpty || coordinator.alwaysShowTabs)
        case .tutor: return callaTutorEnabled
        case .copilot: return callaCopilotEnabled
        case .mirror: return showMirror
        }
    }

    @ViewBuilder
    private func view(for item: NotchHeaderItem) -> some View {
        switch item {
        case .none:
            EmptyView()
        case .battery:
            BoringBatteryView(
                batteryWidth: 30,
                isCharging: batteryModel.isCharging,
                isInLowPowerMode: batteryModel.isInLowPowerMode,
                isPluggedIn: batteryModel.isPluggedIn,
                levelBattery: batteryModel.levelBattery,
                maxCapacity: batteryModel.maxCapacity,
                timeToFullCharge: batteryModel.timeToFullCharge,
                isForNotification: false
            )
        case .mirror:
            circleButton(icon: item.icon) { vm.toggleCameraPreview() }
        case .settings:
            circleButton(icon: item.icon) {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
        default:
            if let destination = item.destination {
                tabButton(item, destination: destination)
            }
        }
    }

    private func tabButton(_ item: NotchHeaderItem, destination: NotchViews) -> some View {
        let selected = coordinator.currentView == destination
        return TabButton(label: item.label, icon: item.icon, selected: selected) {
            withAnimation(.smooth) {
                coordinator.currentView = destination
            }
        }
        .frame(height: 26)
        .foregroundStyle(tint(for: item, selected: selected))
        .background {
            Capsule()
                .fill(selected ? Color(nsColor: .secondarySystemFill) : .clear)
                .matchedGeometryEffect(id: "capsule", in: animation, isSource: selected)
        }
    }

    /// Selection is white; a live call keeps the copilot tab green even when
    /// another tab is showing, since that is the state worth noticing mid-call.
    private func tint(for item: NotchHeaderItem, selected: Bool) -> Color {
        if item == .copilot, callaEngine.status.copilot.running, !selected {
            return NotchTint.healthy
        }
        return selected ? .white : .gray
    }

    private func circleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Capsule()
                .fill(.black)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: icon)
                        .foregroundColor(.white)
                        .padding()
                        .imageScale(.medium)
                }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
