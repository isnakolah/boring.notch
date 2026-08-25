//
//  SweepPane.swift
//  boringNotch
//

import AppKit
import SwiftUI

/// Which Sweep page is showing.
///
/// Three, not four. Overview and Clean Up were reporting the same scan from the
/// same snapshot, and Overview's whole job was to stand in front of the page
/// everybody wanted with a button labelled "Open Clean Up". So the section's
/// landing pane *is* the clean-up list, and History and Options are reached from
/// the header rather than from a card of links.
///
/// Sweep's pages stay one view because they share a coordinator and an in-flight
/// scan; what changed is that the view owns neither the navigation nor the
/// service lifetime.
enum SweepWorkspaceTab: String, CaseIterable, Identifiable {
    case cleanUp = "Clean Up", history = "History", options = "Options"
    var id: Self { self }
}

struct SweepSettings: View {
    @ObservedObject private var sweep = BoringSweepCoordinator.shared
    @State private var thresholdBytes: Double = 0
    @State private var refreshSeconds: Double = 0
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
        case .cleanUp: nil
        case .history: .sweepHistory
        case .options: .sweepOptions
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let page {
                    SettingsPane(page) { paneContent }
                } else {
                    SettingsPane(.sweep, nav: [.sweepHistory, .sweepOptions]) { paneContent }
                }
            }
            if selectedTab == .cleanUp { cleanupBar }
            if selectedTab == .options { optionsBar }
        }
        // No service lifecycle here. A scan takes minutes and these pages push
        // and pop between each other, so starting the helper on `onAppear` and
        // stopping it on `onDisappear` would tear down the scan that is still
        // running. `View.sweepLifetime(_:)` owns it one level up, where the unit
        // is the Sweep *section* rather than any one of its pages.
        .onAppear { expandedCategoryID = nil; loadOptions() }
        .onChange(of: sweep.snapshot?.preferences.candidateThresholdBytes) { loadOptions() }
        .task(id: selectedTab) { if selectedTab == .history { sweep.loadHistory() } }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedTab {
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

    // MARK: - Clean up (the landing pane)

    private var cleanUp: some View {
        VStack(alignment: .leading, spacing: NotchSpace.stack) {
            diskCard
            if sweep.snapshot?.fullDiskAccess == false { fullDiskCard }
            categoriesCard
        }
    }

    /// The volume, once, honestly.
    ///
    /// Reclaimable is a slice of what is *used*, not a separate figure parked
    /// beside it — the old two-metric row let "12 GB free" and "48 GB
    /// reclaimable" sit next to each other as if they were the same kind of
    /// number. Drawn inside the bar, the relationship is unmistakable.
    @ViewBuilder private var diskCard: some View {
        if let volume = sweep.snapshot?.volume {
            SettingCard(volume.name, detail: diskDetail(volume), tint: scanTint) {
                DiskBar(total: volume.total,
                        available: volume.available,
                        reclaimable: sweep.snapshot?.reclaimableBytes ?? 0)
                HStack(spacing: NotchSpace.snug) {
                    if sweep.isSurveying {
                        ProgressView(value: sweep.surveyProgress)
                            .frame(width: 120)
                        Text("\(Int(sweep.surveyProgress * 100))%")
                            .font(NotchType.figure).foregroundStyle(.secondary)
                        Button("Stop", role: .destructive) { sweep.cancel() }
                    } else {
                        Button("Scan again") { sweep.rescan() }
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
        } else {
            SettingCard {
                ProgressView("Reading disk").font(NotchType.rowDetail)
            }
        }
    }

    private func diskDetail(_ volume: BoringSweepVolume) -> String {
        var line = "\(sweepFormatBytes(volume.total)) total"
        if let date = sweep.snapshot?.lastSurvey {
            let freshness = sweep.snapshot?.analysisIsCached == true ? "Saved" : "Fresh"
            line += " · \(freshness.lowercased()) findings from \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        if sweep.isSurveying {
            line += " · a fresh scan is running"
        }
        return line
    }

    private var scanTint: Color? { sweep.isSurveying ? NotchTint.active : nil }

    private var fullDiskCard: some View {
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

    private var categoriesCard: some View {
        let categories = sweep.snapshot?.categories ?? []
        let largest = max(1, categories.map(\.reclaimableBytes).max() ?? 1)
        return SettingCard("What can be reclaimed",
                           detail: "Open a category to load its first 25 items.") {
            if categories.isEmpty {
                if sweep.isSurveying {
                    ProgressView("Scanning for reclaimable space").font(NotchType.rowDetail)
                } else {
                    SettingsEmptyState(symbol: "sparkles",
                                       title: "Nothing to reclaim",
                                       detail: "The last scan found no items above your size threshold.")
                }
            } else {
                ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                    if index > 0 { Divider().opacity(0.35) }
                    categoryGroup(id: category.id, label: category.label,
                                  count: category.count, bytes: category.reclaimableBytes,
                                  largest: largest, protected: false)
                }
                if let protected = sweep.snapshot?.protected, protected.count > 0 {
                    Divider().opacity(0.35)
                    categoryGroup(id: BoringSweepProtected.id, label: "Protected — never removed",
                                  count: protected.count, bytes: protected.bytes,
                                  largest: largest, protected: true)
                }
            }
        }
    }

    private func categoryGroup(id: String, label: String, count: Int, bytes: Int64,
                               largest: Int64, protected: Bool) -> some View {
        let open = expandedCategoryID == id
        return VStack(alignment: .leading, spacing: NotchSpace.tight) {
            Button {
                if open { expandedCategoryID = nil }
                else {
                    expandedCategoryID = id
                    if sweep.categoryPages[id] == nil { sweep.loadCategory(id) }
                }
            } label: {
                HStack(spacing: NotchSpace.snug) {
                    Image(systemName: protected ? "lock.fill" : "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(protected ? AnyShapeStyle(.secondary)
                                                   : AnyShapeStyle(NotchTint.active))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: NotchSpace.tight) {
                            Text(label).font(NotchType.rowTitle)
                            Text("^[\(count) item](inflect: true)")
                                .font(NotchType.rowDetail).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(sweepFormatBytes(bytes))
                                .font(NotchType.figure).foregroundStyle(.primary)
                        }
                        // How big this category is against the biggest one. A
                        // column of byte counts is a table; a column of bars is
                        // a ranking, which is the question being asked.
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.10))
                                Capsule()
                                    .fill(protected ? Color.secondary : NotchTint.active)
                                    .frame(width: max(2, geometry.size.width
                                        * min(1, Double(bytes) / Double(largest))))
                            }
                        }
                        .frame(height: 3)
                    }
                    Image(systemName: open ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, NotchSpace.tight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                if let page = sweep.categoryPages[id] {
                    ForEach(page.targets) { target in targetRow(target, protected: protected) }
                    if page.nextOffset != nil {
                        Button("Load 25 more") { sweep.loadMoreCategory(id) }
                            .controlSize(.small)
                            .padding(.leading, 26)
                    }
                } else {
                    ProgressView("Loading \(label.lowercased())")
                        .font(NotchType.rowDetail)
                        .padding(.leading, 26)
                }
            }
        }
    }

    private func targetRow(_ target: BoringSweepTarget, protected: Bool) -> some View {
        HStack(alignment: .top, spacing: NotchSpace.snug) {
            if protected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary).frame(width: 16)
            } else {
                Button { sweep.toggle(target) } label: {
                    Image(systemName: sweep.snapshot?.selectedIDs.contains(target.id) == true
                          ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(sweep.snapshot?.selectedIDs.contains(target.id) == true
                                         ? AnyShapeStyle(Color.effectiveAccent)
                                         : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Select \(target.title)")
                .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: NotchSpace.hair) {
                HStack(alignment: .firstTextBaseline) {
                    Text(target.title).font(NotchType.rowTitle)
                    Spacer(minLength: 8)
                    Text(sweepFormatBytes(target.bytes))
                        .font(NotchType.figure).foregroundStyle(.secondary)
                }
                Text(target.summary)
                    .font(NotchType.rowDetail).foregroundStyle(.secondary).lineLimit(2)
                Text(target.defaultReclaim)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 26)
        .padding(.vertical, 3)
    }

    private var cleanupBar: some View {
        SettingsActionBar {
            VStack(alignment: .leading, spacing: 1) {
                Text(sweepFormatBytes(sweep.snapshot?.selectedBytes ?? 0))
                    .font(NotchType.rowTitle).fontWeight(.medium)
                    .contentTransition(.numericText())
                Text("^[\(sweep.snapshot?.selectedIDs.count ?? 0) item](inflect: true) selected")
                    .font(NotchType.rowDetail).foregroundStyle(.secondary)
            }
        } trailing: {
            Button("Clear") { sweep.clearSelection() }
                .disabled(sweep.snapshot?.selectedIDs.isEmpty ?? true)
            Button("Select recommended") { sweep.selectRecommended() }
            Button("Review cleanup") { sweep.prepareReclaim() }
                .buttonStyle(.borderedProminent)
                .disabled((sweep.snapshot?.selectedBytes ?? 0) == 0)
        }
    }

    // MARK: - History

    private var history: some View {
        VStack(alignment: .leading, spacing: NotchSpace.stack) {
            if sweep.snapshot?.includesHistory != true {
                ProgressView("Loading completed cleanups").font(NotchType.rowDetail)
            } else {
                SettingCard {
                    SettingsStatRow {
                        SettingsStatTile(
                            value: sweepFormatBytes(sweep.snapshot?.history.cumulativeFreedBytes ?? 0),
                            label: "Measured space freed",
                            caption: "Across every cleanup you have run")
                        SettingsStatTile(
                            value: "\(sweep.snapshot?.history.entries.count ?? 0)",
                            label: "Cleanups")
                    }
                }
                SettingCard("Recent cleanups") {
                    let entries = Array((sweep.snapshot?.history.entries ?? []).prefix(10))
                    if entries.isEmpty {
                        SettingsEmptyState(symbol: "clock.arrow.circlepath",
                                           title: "Nothing reclaimed yet",
                                           detail: "Cleanups you run will be listed here with what they actually freed.")
                    } else {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().opacity(0.35) }
                            SettingFact(title: entry.date.formatted(date: .abbreviated, time: .shortened),
                                        value: sweepFormatBytes(entry.measuredFreedBytes))
                        }
                    }
                }
                if let regrowth = sweep.snapshot?.regrowth, !regrowth.isEmpty {
                    SettingCard("Learned regrowth",
                                detail: "Paths that come back after a cleanup. Sweep uses this to decide what is worth recommending.") {
                        ForEach(Array(regrowth.prefix(8).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().opacity(0.35) }
                            SettingFact(title: item.path,
                                        value: "\(item.count)× · \(sweepFormatBytes(item.lastBytes))")
                        }
                        HStack {
                            Button("Clear learned history", role: .destructive) { sweep.clearRegrowth() }
                                .controlSize(.small)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Options

    private var options: some View {
        VStack(alignment: .leading, spacing: NotchSpace.stack) {
            SettingsColumns {
                scannerCard
            } trailing: {
                whereCard
            }
            lifetimeCard
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

    /// The threshold was a text field plus a unit picker, which meant choosing it
    /// was: type a number, choose a unit, press Save, run a scan, find out. The
    /// slider is logarithmic because the useful range spans four orders of
    /// magnitude and a linear one would spend nine tenths of its travel between
    /// 1 GB and 10 GB.
    private var scannerCard: some View {
        SettingCard("Scanner") {
            NotchSlider(value: Binding(get: { log2(max(thresholdBytes, 1)) },
                                       set: { thresholdBytes = pow(2, $0) }),
                        range: 20...33,
                        step: 0.5,
                        label: "Ignore anything smaller than",
                        format: { sweepFormatBytes(Int64(pow(2, $0))) },
                        ends: ("1 MB", "8 GB"))
            Text("Smaller items are never listed, which is what keeps a scan from returning a hundred thousand rows. Applies from the next scan.")
                .font(NotchType.rowDetail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().opacity(0.35)

            NotchStopSlider(
                selection: Binding(get: { nearestInterval(refreshSeconds) },
                                   set: { refreshSeconds = $0 }),
                stops: [
                    .init(value: 900.0, title: "15 min"),
                    .init(value: 3_600.0, title: "1 hour"),
                    .init(value: 21_600.0, title: "6 hours"),
                    .init(value: 86_400.0, title: "A day"),
                ],
                label: "Rescan",
                detail: "How stale the findings are allowed to get before the helper looks again on its own.")
        }
    }

    private func nearestInterval(_ seconds: Double) -> Double {
        [900.0, 3_600.0, 21_600.0, 86_400.0]
            .min { abs($0 - seconds) < abs($1 - seconds) } ?? 3_600
    }

    private var whereCard: some View {
        SettingCard("Where it looks",
                    detail: "Sweep always covers the standard caches. These are on top of that.") {
            pathEditor("Also scan", paths: $scanRoots, add: "Add a location")
            Divider().opacity(0.35)
            pathEditor("Never touch", paths: $exclusions, add: "Add an exclusion")
        }
    }

    private var lifetimeCard: some View {
        SettingCard("Service lifetime",
                    detail: "A scan takes minutes, so this decides how much of one survives you navigating away.") {
            // Ordered by how much of the scan survives, so the slider's direction
            // means something. A picker of three strings said nothing about which
            // was the most forgiving.
            NotchStopSlider(
                selection: $sweep.lifetime,
                stops: [
                    .init(value: SweepProcessLifetime.tab, title: "Leaving Sweep",
                          caption: "ends the scan"),
                    .init(value: SweepProcessLifetime.settings, title: "Closing Settings",
                          caption: "ends the scan"),
                    .init(value: SweepProcessLifetime.app, title: "Quitting Boring",
                          caption: "lets it finish"),
                ],
                detail: lifetimeDetail)
        }
    }

    private var lifetimeDetail: String {
        switch sweep.lifetime {
        case .tab:
            return "A scan stops the moment you leave Sweep, so nothing runs that you are not looking at — and nothing finishes either."
        case .settings:
            return "A scan keeps running while you use the rest of Settings, and stops when the window closes."
        case .app:
            return "A scan runs to completion in the background, whatever you do with Settings. It stops when Boring quits."
        }
    }

    private func pathEditor(_ title: String, paths: Binding<[String]>, add: String) -> some View {
        VStack(alignment: .leading, spacing: NotchSpace.tight) {
            Text(title).font(NotchType.rowTitle)
            ForEach(paths.wrappedValue.indices, id: \.self) { index in
                HStack(spacing: NotchSpace.tight) {
                    TextField("/Users/me/Library/Caches", text: Binding(
                        get: { paths.wrappedValue[index] },
                        set: { paths.wrappedValue[index] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(NotchType.mono)
                    Button(role: .destructive) { paths.wrappedValue.remove(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            Button { paths.wrappedValue.append("") } label: {
                Label(add, systemImage: "plus")
            }
            .controlSize(.small)
        }
    }

    private var optionsBar: some View {
        SettingsActionBar {
            Button("Discard") { optionsLoaded = false; loadOptions() }
        } trailing: {
            Button("Save and rescan") { saveOptions(); router?.popToRoot() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func loadOptions() {
        guard !optionsLoaded, let preferences = sweep.snapshot?.preferences else { return }
        thresholdBytes = Double(preferences.candidateThresholdBytes)
        refreshSeconds = preferences.resurveyInterval
        scanRoots = preferences.extraScanRoots
        exclusions = preferences.userExclusions
        optionsLoaded = true
    }

    private func saveOptions() {
        let paths: ([String]) -> [String] = {
            $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        optionsLoaded = false
        sweep.apply(BoringSweepPreferences(
            candidateThresholdBytes: max(1, Int64(thresholdBytes)),
            extraScanRoots: paths(scanRoots),
            userExclusions: paths(exclusions),
            resurveyInterval: max(60, refreshSeconds)))
    }
}

/// The volume as one bar: what is used, what of that is reclaimable, what is
/// free.
private struct DiskBar: View {
    let total: Int64
    let available: Int64
    let reclaimable: Int64

    private var used: Int64 { max(0, total - available) }
    /// Reclaimable is part of used, so it is drawn out of it rather than added
    /// to it. Clamped because a stale snapshot can report more reclaimable than
    /// the volume currently says is used.
    private var reclaimableShown: Int64 { min(reclaimable, used) }
    private var otherUsed: Int64 { used - reclaimableShown }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchSpace.snug) {
            GeometryReader { geometry in
                let scale = geometry.size.width / CGFloat(max(total, 1))
                HStack(spacing: 1.5) {
                    Rectangle().fill(Color.primary.opacity(0.28))
                        .frame(width: max(0, CGFloat(otherUsed) * scale))
                    Rectangle().fill(NotchTint.active)
                        .frame(width: max(0, CGFloat(reclaimableShown) * scale))
                    Rectangle().fill(Color.primary.opacity(0.07))
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .frame(height: 24)

            HStack(spacing: NotchSpace.group) {
                legend("Used", sweepFormatBytes(otherUsed), Color.primary.opacity(0.28))
                legend("Reclaimable", sweepFormatBytes(reclaimableShown), NotchTint.active)
                legend("Free", sweepFormatBytes(available), Color.primary.opacity(0.12))
                Spacer(minLength: 0)
            }
        }
        .animation(NotchMotion.settle, value: reclaimable)
    }

    private func legend(_ label: String, _ value: String, _ colour: Color) -> some View {
        VStack(alignment: .leading, spacing: NotchSpace.hair) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 8, height: 8)
                SettingsMicroLabel(text: label)
            }
            Text(value)
                .font(NotchType.figure)
                .foregroundStyle(.primary)
                .padding(.leading, 13)
        }
    }
}
