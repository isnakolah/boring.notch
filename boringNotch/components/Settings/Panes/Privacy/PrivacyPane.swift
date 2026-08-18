//
//  PrivacyPane.swift
//  boringNotch
//

import SwiftUI

/// Everything macOS has been asked to allow, in one place.
///
/// Five panes had each written their own permission row, and they disagreed on
/// the verb, on whether "not asked yet" counted as a failure, and on what colour
/// a missing permission is. That was five chances to describe the same six
/// switches differently.
///
/// This page does not take permissions away from the panes that need them: one
/// that blocks HUDs still has to be visible *in* HUDs, or the reader is sent
/// hunting for it. It mirrors them. The owning pane says "this is why the thing
/// in front of you does not work"; this page says "here is everything, and here
/// is what each one buys". Both draw `SettingsPermissionRow`, so the two cannot
/// disagree about what "allowed" looks like.
struct PrivacyPane: View {
    @StateObject private var monitor = PermissionMonitor.shared

    var body: some View {
        SettingsPane(.privacy) {
            SettingCard(detail: "Boring asks for a permission only when a feature that needs it is switched on. Turning a feature off does not revoke anything — that happens in System Settings.") {
                VStack(spacing: NotchSpace.row) {
                    ForEach(Array(SystemPermission.allCases.enumerated()), id: \.element) { index, permission in
                        if index > 0 { Divider().opacity(0.35) }
                        SettingsPermissionRow(
                            permission: permission,
                            status: monitor.status(of: permission),
                            why: permission.whatItUnlocks,
                            request: monitor.canRequest(permission) ? { monitor.request(permission) } : nil)
                    }
                }
            }
        }
        .task { await monitor.refresh() }
    }
}
