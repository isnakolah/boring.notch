//
//  SweepPane.swift
//  boringNotch
//
//  Moved out of SettingsView.swift. That file had grown to 2076 lines holding
//  eleven panes and an XPC subsystem, while every newer pane already lived in
//  its own file under Panes/.
//

import SwiftUI

/// Which Sweep page is showing.
///
/// Derived from the route by whoever builds the view, rather than mirrored from
/// a sidebar binding inside the pane. Sweep's four pages are the one place where
/// the pages share a coordinator and an in-flight scan, so they stay one view;
/// what changed is that the view no longer owns the navigation *or* the service
/// lifetime.
enum SweepWorkspaceTab: String, CaseIterable, Identifiable {
    case overview = "Overview", cleanUp = "Clean Up", history = "History", options = "Options"
    var id: Self { self }
}
private enum SweepSizeUnit: String, CaseIterable, Identifiable { case bytes = "bytes", kilobytes = "KB", megabytes = "MB", gigabytes = "GB"; var id: String { rawValue }; var multiplier: Double { switch self { case .bytes: return 1; case .kilobytes: return 1_024; case .megabytes: return 1_048_576; case .gigabytes: return 1_073_741_824 } } }
private enum SweepIntervalUnit: String, CaseIterable, Identifiable { case seconds = "seconds", minutes = "minutes", hours = "hours"; var id: String { rawValue }; var multiplier: Double { switch self { case .seconds: return 1; case .minutes: return 60; case .hours: return 3_600 } } }

struct SweepSettings: View {
    @ObservedObject private var sweep = BoringSweepCoordinator.shared
    @State private var minimumValue = ""
    @State private var minimumUnit: SweepSizeUnit = .megabytes
    @State private var refreshValue = ""
    @State private var refreshUnit: SweepIntervalUnit = .minutes
    @State private var scanRoots: [String] = []
    @State private var exclusions: [String] = []
    @State private var expandedCategoryID: String?
    @State private var optionsLoaded = false

    let selectedTab: SweepWorkspaceTab

    /// Moving the reader on is navigation, so it goes through the router like
    /// every other move in this window.
    @Environment(\.settingsRouter) private var router

    private var page: SettingsPage? {
        switch selectedTab {
        case .overview: nil
        case .cleanUp: .sweepCleanUp
        case .history: .sweepHistory
        case .options: .sweepOptions
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let page {
                    SettingsPane(page) {
                        paneContent
                    }
                } else {
                    SettingsPane(.sweep) {
                        paneContent
                    }
                }
            }
            if selectedTab == .cleanUp { cleanupBar }
            if selectedTab == .options { optionsBar }
        }
        // No service lifecycle here. A scan takes minutes and these four pages
        // push and pop between each other, so starting the helper on `onAppear`
        // and stopping it on `onDisappear` would tear down the scan that is
        // still running. `View.sweepLifetime(_:)` owns it one level up, where
        // the unit is the Sweep *section* rather than any one of its pages.
        .onAppear { expandedCategoryID = nil; loadOptions() }
        .onChange(of: sweep.snapshot?.preferences.candidateThresholdBytes) { loadOptions() }
        .task(id: selectedTab) { if selectedTab == .history { sweep.loadHistory() } }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedTab {
        case .overview: overview
        case .cleanUp: cleanUp
        case .history: history
        case .options: options
        }
        if let error = sweep.error {
            SettingCard(tint: NotchTint.stuck) {
                Text(error).font(NotchType.rowDetail).foregroundStyle(NotchTint.stuck)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingCard("Disk") {
                if let volume = sweep.snapshot?.volume {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 28) {
                            metric("Free", sweepFormatBytes(volume.available))
                            metric("Reclaimable", sweepFormatBytes(sweep.snapshot?.reclaimableBytes ?? 0))
                            Spacer(minLength: 0)
                        }
                        Text("\(volume.name) · \(sweepFormatBytes(volume.available)) free of \(sweepFormatBytes(volume.total))")
                            .font(NotchType.rowDetail).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Reading disk").font(NotchType.rowDetail)
                }
            }

            SettingCard("Scan", tint: sweep.isSurveying ? NotchTint.active : nil) {
                VStack(alignment: .leading, spacing: 10) {
                    if sweep.isSurveying {
                        ProgressView(value: sweep.surveyProgress) { Text("Scanning").font(NotchType.rowTitle) }
                        Text("\(Int(sweep.surveyProgress * 100))% complete. Saved findings stay available while this runs.")
                            .font(NotchType.rowDetail).foregroundStyle(.secondary)
                    } else {
                        Text("Ready to scan").font(NotchType.rowTitle)
                    }
                    if let date = sweep.snapshot?.lastSurvey {
                        Text("\(sweep.snapshot?.analysisIsCached == true ? "Saved" : "Fresh") findings · \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(NotchType.rowDetail).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Scan now") { sweep.rescan() }
                        if sweep.isSurveying { Button("Stop", role: .destructive) { sweep.cancel() } }
                        Button("Open Clean Up") { router?.push(.sweepCleanUp) }.disabled(sweep.snapshot == nil)
                        Spacer()
                    }
                    .controlSize(.small)
                }
            }

            if sweep.snapshot?.fullDiskAccess == false {
                SettingCard("Full Disk Access",
                            detail: "Without it Sweep can only see part of the disk, so the figures above are an undercount.",
                            tint: NotchTint.attention) {
                    HStack {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                }
            }
        }
    }

    private var cleanUp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sweep.isSurveying && sweep.snapshot?.analysisIsCached == true ? "Using saved findings while a fresh scan runs." : "Open a category to load its first 25 items.").font(NotchType.rowDetail).foregroundStyle(.secondary)
            let categories = sweep.snapshot?.categories ?? []
            if categories.isEmpty { sweep.isSurveying ? AnyView(ProgressView("Scanning for reclaimable space")) : AnyView(Text("No reclaimable items found.").foregroundStyle(.secondary)) }
            ForEach(categories) { category in categoryGroup(id: category.id, label: category.label, count: category.count, bytes: category.reclaimableBytes, protected: false) }
            if let protected = sweep.snapshot?.protected, protected.count > 0 { categoryGroup(id: BoringSweepProtected.id, label: "Protected items", count: protected.count, bytes: protected.bytes, protected: true) }
        }
    }

    private func categoryGroup(id: String, label: String, count: Int, bytes: Int64, protected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if expandedCategoryID == id { expandedCategoryID = nil } else { expandedCategoryID = id; if sweep.categoryPages[id] == nil { sweep.loadCategory(id) } }
            } label: {
                HStack { Image(systemName: expandedCategoryID == id ? "chevron.down" : "chevron.right").font(.caption); VStack(alignment: .leading) { Text(label).fontWeight(.semibold); Text("^[\(count) item](inflect: true)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(sweepFormatBytes(bytes)).foregroundStyle(.secondary) }
            }.buttonStyle(.plain)
            if expandedCategoryID == id {
                if let page = sweep.categoryPages[id] {
                    ForEach(page.targets) { target in targetRow(target, protected: protected) }
                    if page.nextOffset != nil { Button("Load 25 more") { sweep.loadMoreCategory(id) }.font(.caption) }
                } else { ProgressView("Loading \(label.lowercased())") }
            }
        }.padding(12).background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func targetRow(_ target: BoringSweepTarget, protected: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if protected { Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 18) }
            else { Button { sweep.toggle(target) } label: { Image(systemName: sweep.snapshot?.selectedIDs.contains(target.id) == true ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.effectiveAccent) }.buttonStyle(.plain).accessibilityLabel("Select \(target.title)") }
            VStack(alignment: .leading, spacing: 2) { HStack { Text(target.title).fontWeight(.medium); Spacer(); Text(sweepFormatBytes(target.bytes)).foregroundStyle(.secondary) }; Text(target.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2); Text(target.defaultReclaim).font(.caption2).foregroundStyle(.secondary) }
        }.padding(.vertical, 3)
    }

    private var cleanupBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading) { Text("\(sweep.snapshot?.selectedIDs.count ?? 0) selected").fontWeight(.medium); Text(sweepFormatBytes(sweep.snapshot?.selectedBytes ?? 0)).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Button("Clear") { sweep.clearSelection() }.disabled((sweep.snapshot?.selectedIDs.isEmpty ?? true)); Button("Select recommended") { sweep.selectRecommended() }; Button("Review cleanup") { sweep.prepareReclaim() }.buttonStyle(.borderedProminent).disabled((sweep.snapshot?.selectedBytes ?? 0) == 0)
        }.padding(12).background(.bar)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            if sweep.snapshot?.includesHistory != true { ProgressView("Loading completed cleanups") }
            else {
                metric("Measured space freed", sweepFormatBytes(sweep.snapshot?.history.cumulativeFreedBytes ?? 0))
                ForEach((sweep.snapshot?.history.entries ?? []).prefix(10)) { entry in HStack { VStack(alignment: .leading) { Text(entry.date.formatted(date: .abbreviated, time: .shortened)); Text("\(entry.itemCount) items").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(sweepFormatBytes(entry.measuredFreedBytes)) } }
                if let regrowth = sweep.snapshot?.regrowth, !regrowth.isEmpty { Divider(); Text("Learned regrowth").fontWeight(.semibold); ForEach(regrowth.prefix(8)) { item in HStack { Text(item.path).lineLimit(1); Spacer(); Text("\(item.count) times · \(sweepFormatBytes(item.lastBytes))").font(.caption).foregroundStyle(.secondary) } }; Button("Clear learned history", role: .destructive) { sweep.clearRegrowth() } }
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingCard("Scanner") {
                VStack(alignment: .leading, spacing: 12) {
                    unitField("Minimum item size", value: $minimumValue, unit: $minimumUnit)
                    intervalField("Refresh interval", value: $refreshValue, unit: $refreshUnit)
                    pathEditor("Additional scan locations", paths: $scanRoots, placeholder: "/Users/me/Library/Caches")
                    pathEditor("Excluded locations", paths: $exclusions, placeholder: "/Users/me/Library/Application Support")
                }
            }
            SettingCard("Service lifetime",
                        detail: "A scan is long-running, so this decides how much of it survives you navigating away.") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $sweep.lifetime) {
                        ForEach(SweepProcessLifetime.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 240)
                    Text("Leaving Sweep ends the scan · Closing Settings ends it · Keep until Boring quits lets it finish.")
                        .font(NotchType.rowDetail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let migration = sweep.snapshot?.migration {
                SettingCard(tint: migration.complete ? nil : NotchTint.attention) {
                    Label(migration.message,
                          systemImage: migration.complete ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(migration.complete ? Color.secondary : NotchTint.attention)
                }
            }
        }
    }

    private var optionsBar: some View { HStack { Button("Discard") { optionsLoaded = false; loadOptions() }; Spacer(); Button("Save and rescan") { saveOptions(); router?.popToRoot() }.buttonStyle(.borderedProminent) }.padding(12).background(.bar) }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(NotchType.stat)
            Text(label).font(NotchType.rowDetail).foregroundStyle(.secondary)
        }
    }
    private func unitField(_ label: String, value: Binding<String>, unit: Binding<SweepSizeUnit>) -> some View { HStack { Text(label); Spacer(); TextField("0", text: value).multilineTextAlignment(.trailing).frame(width: 84); Picker(label, selection: unit) { ForEach(SweepSizeUnit.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 78) } }
    private func intervalField(_ label: String, value: Binding<String>, unit: Binding<SweepIntervalUnit>) -> some View { HStack { Text(label); Spacer(); TextField("0", text: value).multilineTextAlignment(.trailing).frame(width: 84); Picker(label, selection: unit) { ForEach(SweepIntervalUnit.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 92) } }
    private func pathEditor(_ title: String, paths: Binding<[String]>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).fontWeight(.medium); ForEach(paths.wrappedValue.indices, id: \.self) { index in HStack { TextField(placeholder, text: Binding(get: { paths.wrappedValue[index] }, set: { paths.wrappedValue[index] = $0 })); Button(role: .destructive) { paths.wrappedValue.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) } }; Button { paths.wrappedValue.append("") } label: { Label("Add location", systemImage: "plus") }.font(.caption) }
    }
    private func loadOptions() {
        guard !optionsLoaded, let preferences = sweep.snapshot?.preferences else { return }
        minimumUnit = bestSizeUnit(preferences.candidateThresholdBytes); minimumValue = formattedValue(Double(preferences.candidateThresholdBytes) / minimumUnit.multiplier)
        refreshUnit = bestIntervalUnit(preferences.resurveyInterval); refreshValue = formattedValue(preferences.resurveyInterval / refreshUnit.multiplier)
        scanRoots = preferences.extraScanRoots; exclusions = preferences.userExclusions; optionsLoaded = true
    }
    private func saveOptions() {
        guard let minimum = Double(minimumValue), let interval = Double(refreshValue) else { return }
        let paths: ([String]) -> [String] = { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        optionsLoaded = false
        sweep.apply(BoringSweepPreferences(candidateThresholdBytes: max(1, Int64(minimum * minimumUnit.multiplier)), extraScanRoots: paths(scanRoots), userExclusions: paths(exclusions), resurveyInterval: max(60, interval * refreshUnit.multiplier)))
    }
    private func bestSizeUnit(_ bytes: Int64) -> SweepSizeUnit { bytes >= Int64(SweepSizeUnit.gigabytes.multiplier) ? .gigabytes : bytes >= Int64(SweepSizeUnit.megabytes.multiplier) ? .megabytes : bytes >= Int64(SweepSizeUnit.kilobytes.multiplier) ? .kilobytes : .bytes }
    private func bestIntervalUnit(_ seconds: TimeInterval) -> SweepIntervalUnit { seconds >= 3_600 ? .hours : seconds >= 60 ? .minutes : .seconds }
    private func formattedValue(_ value: Double) -> String { value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value) }
}
