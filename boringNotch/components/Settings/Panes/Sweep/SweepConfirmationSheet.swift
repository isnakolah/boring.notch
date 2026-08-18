//
//  SweepConfirmationSheet.swift
//  boringNotch
//

import SwiftUI

/// The last word before anything is removed.
///
/// A separate view because it is presented from the Sweep *section*, not from
/// the Clean Up page. Attached to the page, confirming a reclaim and then
/// navigating would dismiss the sheet while the operation it authorised was
/// still running.
struct SweepConfirmationSheet: View {
    @ObservedObject private var sweep = BoringSweepCoordinator.shared
    @State private var typedDelete = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review cleanup").font(.title2.bold())
            if let plan = sweep.snapshot?.pendingPlan { Text("\(plan.itemCount) items, up to \(sweepFormatBytes(plan.estimatedBytes))."); Text("Uses \(plan.sourceState) findings from \(plan.sourceTimestamp.formatted(date: .abbreviated, time: .shortened)). New scans will not change this plan.").font(.caption).foregroundStyle(.secondary) }
            if sweep.snapshot?.pendingPlan?.requiresTypedConfirmation == true { Text("Permanent deletion selected. Type DELETE to continue.").foregroundStyle(.orange); TextField("DELETE", text: $typedDelete) }
            HStack { Spacer(); Button("Cancel") { sweep.showConfirmation = false }; Button("Confirm") { sweep.confirmReclaim(sweep.snapshot?.pendingPlan?.requiresTypedConfirmation == true ? typedDelete : nil) }.disabled(sweep.snapshot?.pendingPlan?.requiresTypedConfirmation == true && typedDelete != "DELETE") }
        }.padding().frame(width: 440)
    }
}
