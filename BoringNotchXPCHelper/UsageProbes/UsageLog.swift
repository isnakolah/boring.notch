//
//  UsageLog.swift
//  BoringNotchXPCHelper
//
//  Logging shim for the ported usage-probe stack. Replaces ClaudeBar's
//  `AppLog.probes.*` with a single os.Logger scoped to this helper.
//

import Foundation
import os

enum AppLog {
    static let probes = Logger(
        subsystem: "theboringteam.boringnotch.BoringNotchXPCHelper",
        category: "usage-probes"
    )
}
