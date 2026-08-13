//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.boringShelf) var boringShelf
    @Default(.usageMonitorTab) var usageMonitorTab
    @Default(.pomodoroTab) var pomodoroTab
    @Namespace var animation

    /// Home is always present; the rest are gated by their toggles so the bar
    /// live-updates when a setting changes.
    private var tabs: [TabModel] {
        var result = [TabModel(label: "Home", icon: "house.fill", view: .home)]
        if pomodoroTab {
            result.append(TabModel(label: "Pomodoro", icon: "timer.circle.fill", view: .pomodoro))
        }
        if usageMonitorTab {
            result.append(TabModel(label: "Usage", icon: "chart.bar.xaxis", view: .usage))
        }
        return result
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(tabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
