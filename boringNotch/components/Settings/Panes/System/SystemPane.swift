//
//  SystemPane.swift
//  boringNotch
//

import SwiftUI

/// The machine's own numbers.
///
/// Battery, HUDs and the usage monitor were three sibling destinations in a flat
/// list of twenty-seven. They are one idea — readouts about the Mac that the
/// notch draws — and Battery's own copy already had to send the reader somewhere
/// else to finish the job.
///
/// Pomodoro is deliberately *not* here. A focus timer is something you drive,
/// not something you read, and folding it in would have produced a section whose
/// name meant nothing.
struct SystemPane: View {
    var body: some View {
        SettingsPane(.system) {
            SettingsSubpageList(section: .system)
        }
    }
}
