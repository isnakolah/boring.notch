//
//  BoringSweepProtocol.swift
//  boringNotch
//
//  The wire contract with theboringteam.boringnotch.SweepService.
//
//  This lived in SettingsView.swift, which is where it was written and not
//  where it belongs: an @objc XPC protocol and the enum describing when to tear
//  the connection down are not view code, and keeping them there meant the only
//  way to read the Sweep protocol was to scroll past eleven settings panes.
//

import Defaults
import Foundation

/// When the Sweep helper process is allowed to stop.
///
/// The unit of lifetime is the Sweep *section*, not any one of its pages — a
/// survey takes minutes, and pushing Clean Up would otherwise tear down the
/// service that is still scanning. See `View.sweepLifetime(_:)`.
enum SweepProcessLifetime: String, CaseIterable, Identifiable, Defaults.Serializable {
    case tab = "Stop when leaving Sweep"
    case settings = "Stop when Settings closes"
    case app = "Keep until Boring quits"
    var id: String { rawValue }
}

@objc protocol BoringSweepServiceProtocol { func send(_ request: Data, with reply: @escaping (Data) -> Void) }
