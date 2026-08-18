//
//  CallFormatting.swift
//  boringNotch
//

import Foundation

/// How long a call ran, said the same way in the list and on the call's page.
func callClock(_ duration: TimeInterval) -> String {
    let total = Int(duration)
    return String(format: "%d:%02d", total / 60, total % 60)
}

