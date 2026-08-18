//
//  PermissionMonitor.swift
//  boringNotch
//

import AVFoundation
import AppKit
import EventKit
import SwiftUI

/// One place that knows what macOS has allowed.
///
/// Each of these was already being checked somewhere — accessibility by the HUD
/// pane, camera by `WebcamManager`, calendars and reminders by `CalendarManager`,
/// full disk access by the Sweep helper's own snapshot. What did not exist was
/// anywhere to ask all six at once, which is why the Privacy page could not have
/// been written before.
///
/// This deliberately does not own the *asking* for the things that already have
/// an owner: accessibility goes through the XPC helper and calendars through
/// `CalendarManager`, because those two do more than flip a bit.
@MainActor
final class PermissionMonitor: ObservableObject {
    static let shared = PermissionMonitor()

    @Published private(set) var statuses: [SystemPermission: PermissionStatus] = [:]

    private init() {}

    func status(of permission: SystemPermission) -> PermissionStatus {
        statuses[permission] ?? .checking
    }

    /// Whether macOS will still show a prompt. Once a permission has been
    /// refused, or is one of the two that can only be granted by hand, asking
    /// again does nothing — and a button that does nothing is worse than no
    /// button, so the row shows the System Settings route instead.
    func canRequest(_ permission: SystemPermission) -> Bool {
        switch permission {
        case .accessibility: return status(of: permission) != .granted
        case .microphone, .calendars, .reminders: return status(of: permission) == .undetermined
        case .screenRecording, .fullDiskAccess: return false
        }
    }

    func request(_ permission: SystemPermission) {
        switch permission {
        case .accessibility:
            XPCHelperClient.shared.requestAccessibilityAuthorization()
        case .microphone:
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                await refresh()
            }
        case .calendars:
            Task {
                await CalendarManager.shared.checkCalendarAuthorization()
                await refresh()
            }
        case .reminders:
            Task {
                await CalendarManager.shared.checkReminderAuthorization()
                await refresh()
            }
        case .screenRecording, .fullDiskAccess:
            permission.openSystemSettings()
        }
    }

    func refresh() async {
        var next: [SystemPermission: PermissionStatus] = [:]

        next[.accessibility] = AXIsProcessTrusted() ? .granted : .denied

        // Preflight rather than request: asking would pop a dialog the reader
        // did not press anything to get.
        next[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .denied

        next[.microphone] = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        next[.calendars] = Self.map(EKEventStore.authorizationStatus(for: .event))
        next[.reminders] = Self.map(EKEventStore.authorizationStatus(for: .reminder))
        next[.fullDiskAccess] = Self.probeFullDiskAccess()

        statuses = next
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    private static func map(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .fullAccess: return .granted
        case .notDetermined: return .undetermined
        case .writeOnly: return .denied
        default: return .denied
        }
    }

    /// There is no API that reports Full Disk Access, so the only honest test is
    /// to read something that requires it. `Mail`'s container is the
    /// conventional probe: present on every Mac and unreadable without the
    /// permission.
    private static func probeFullDiskAccess() -> PermissionStatus {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail", isDirectory: true)
        guard FileManager.default.fileExists(atPath: probe.path) else {
            // No Mail container to read: this Mac cannot answer the question, so
            // do not claim it was refused.
            return .undetermined
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil ? .granted : .denied
    }
}
