//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    /// Drives the copilot button's live tint; without observing it the icon
    /// would stay white through an entire call.
    @ObservedObject var callaEngine = CallaEngineClient.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if (!tvm.isEmpty || coordinator.alwaysShowTabs) && (Defaults[.boringShelf] || Defaults[.usageMonitorTab] || Defaults[.pomodoroTab]) {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                        OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        if (!tvm.isEmpty || coordinator.alwaysShowTabs) && Defaults[.boringShelf] {
                            TabButton(label: "Shelf", icon: "tray.fill", selected: coordinator.currentView == .shelf) {
                                withAnimation(.smooth) {
                                    coordinator.currentView = .shelf
                                }
                            }
                            .frame(height: 26)
                            .foregroundStyle(coordinator.currentView == .shelf ? .white : .gray)
                            .background {
                                Capsule()
                                    .fill(coordinator.currentView == .shelf ? Color(nsColor: .secondarySystemFill) : .clear)
                            }
                        }
                        if Defaults[.callaTutorEnabled] {
                            TabButton(label: "Calla", icon: "graduationcap.fill", selected: coordinator.currentView == .tutor) {
                                withAnimation(.smooth) {
                                    coordinator.currentView = .tutor
                                }
                            }
                            .frame(height: 26)
                            .foregroundStyle(coordinator.currentView == .tutor ? .white : .gray)
                            .background {
                                Capsule()
                                    .fill(coordinator.currentView == .tutor ? Color(nsColor: .secondarySystemFill) : .clear)
                            }
                        }
                        if Defaults[.callaCopilotEnabled] {
                            TabButton(label: "Call", icon: "waveform.badge.mic", selected: coordinator.currentView == .copilot) {
                                withAnimation(.smooth) {
                                    coordinator.currentView = .copilot
                                }
                            }
                            .frame(height: 26)
                            .foregroundStyle(coordinator.currentView == .copilot ? .white : .gray)
                            .background {
                                Capsule()
                                    .fill(coordinator.currentView == .copilot ? Color(nsColor: .secondarySystemFill) : .clear)
                            }
                        }
                        if Defaults[.showMirror] {
                            Button(action: {
                                vm.toggleCameraPreview()
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "web.camera")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        if Defaults[.settingsIconInNotch] {
                            // Opens the call copilot rather than Settings. Same
                            // slot, same visibility toggle, but during a call
                            // this is the thing worth one tap — Settings is
                            // still on the menu bar item and ⌘,.
                            Button(action: {
                                DispatchQueue.main.async {
                                    CopilotWindowController.shared.show()
                                }
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "waveform.badge.mic")
                                            .foregroundColor(
                                                callaEngine.status.copilot.running ? .green : .white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Call copilot")
                        }
                        if Defaults[.showBatteryIndicator] {
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
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
