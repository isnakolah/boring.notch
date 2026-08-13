import AppKit
import Foundation

/// Cache result crosses from utility decode back to main actor after construction
/// only. Analysis models are immutable here but predate Swift Sendable markings.
private final class CachedAnalysisBox: @unchecked Sendable {
    let value: AnalysisResult?
    init(_ value: AnalysisResult?) { self.value = value }
}

@MainActor
final class SweepServiceStore {
    private let defaults = UserDefaults.standard
    private let migration: SweepWireMigration
    private let cache = SurveyCache()
    private let regrowth = RegrowthStore()
    private let history = History()
    private var preferences: Preferences
    private var analysis: AnalysisResult?
    private var selection = SelectionModel(targets: [])
    private var volume: VolumeInfo?
    private var isSurveying = false
    private var progress = 0.0
    private var analysisIsCached = false
    private var pendingPlan: ReclaimPlan?
    private var lastReport: ReclaimReport?
    private var surveyTask: Task<Void, Never>?
    private var cacheLoaded = false

    init() {
        migration = SweepDataMigration.runIfNeeded()
        preferences = Preferences.load(from: defaults)
        volume = VolumeReader.read()
    }

    func handle(_ request: SweepWireRequest) async -> SweepWireReply {
        guard request.version == SweepWireRequest.version else {
            return SweepWireReply(snapshot: nil, progress: nil, error: "Unsupported Sweep service version.")
        }
        switch request.command {
        case .open:
            await refreshForVisibleTab()
            // Return cached rollups immediately. Row pages stay lazy and may be
            // read from this saved result while a replacement survey runs.
            return SweepWireReply(snapshot: snapshot(), progress: progressReply(), error: nil)
        case .status:
            break
        case .loadCategory:
            guard let categoryID = request.categoryID else {
                return SweepWireReply(snapshot: snapshot(), progress: progressReply(), error: "Missing Sweep category.")
            }
            // Bounded (25 row) cache reads remain available during refresh. This
            // lets users inspect and plan saved findings without waiting on disk.
            return SweepWireReply(snapshot: snapshot(categoryID: categoryID,
                targetOffset: max(0, request.targetOffset ?? 0), targetLimit: 25), progress: progressReply(), error: nil)
        case .loadHistory:
            return SweepWireReply(snapshot: snapshot(includeHistory: true), progress: progressReply(), error: nil)
        case .rescan:
            startSurvey()
        case .cancel, .shutdown:
            surveyTask?.cancel()
            surveyTask = nil
            isSurveying = false
            progress = 0
        case .toggleSelection:
            if let id = request.targetID, let target = findTarget(id) {
                selection.toggle(target)
            }
        case .selectAll:
            selection.selectAll()
        case .selectRecommended:
            selection.selectRecommended()
        case .clearSelection:
            selection.clear()
        case .updatePreferences:
            if let incoming = request.preferences {
                preferences = Preferences(candidateThresholdBytes: max(1, incoming.candidateThresholdBytes),
                                          extraScanRoots: incoming.extraScanRoots,
                                          userExclusions: incoming.userExclusions,
                                          resurveyInterval: max(60, incoming.resurveyInterval))
                preferences.persist(to: defaults)
                analysis = nil
                selection = SelectionModel(targets: [])
                startSurvey()
            }
        case .prepareReclaim:
            prepareReclaim()
        case .confirmReclaim:
            await confirmReclaim(typed: request.typedConfirmation)
        case .clearRegrowth:
            regrowth.clear()
            if analysis != nil { startSurvey() }
        }
        if request.command == .status, isSurveying {
            return SweepWireReply(snapshot: nil, progress: progressReply(), error: nil)
        }
        return SweepWireReply(snapshot: snapshot(), progress: progressReply(), error: nil)
    }

    private func refreshForVisibleTab() async {
        await loadCachedAnalysisIfNeeded()
        volume = VolumeReader.read()
        guard !isSurveying else { return }
        guard analysis == nil || Date().timeIntervalSince(analysis!.generatedAt) >= preferences.resurveyInterval else { return }
        startSurvey()
    }

    private func loadCachedAnalysisIfNeeded() async {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        let cache = cache
        let fingerprint = SurveyCache.fingerprint(for: preferences)
        let cached = await Task.detached(priority: .utility) {
            CachedAnalysisBox(cache.load(fingerprint: fingerprint))
        }.value.value
        guard let cached else { return }
        analysis = cached
        selection = SelectionModel(targets: cached.offered)
        analysisIsCached = true
    }

    private func startSurvey() {
        surveyTask?.cancel()
        isSurveying = true
        progress = 0
        let prefs = preferences
        let store = regrowth
        surveyTask = Task(priority: .utility) { [weak self] in
            let throttle = ProgressThrottle(minimumInterval: 0.1)
            let result = await Self.performSurvey(preferences: prefs, regrowth: store) { [weak self] event in
                guard throttle.shouldEmit() else { return }
                let fraction = 1 - exp(-Double(event.entriesScanned) / 20_000)
                Task { @MainActor in self?.progress = fraction }
            }
            guard !Task.isCancelled, let self else { return }
            self.analysis = result
            self.selection = SelectionModel(targets: result.offered)
            self.volume = result.volume
            self.analysisIsCached = false
            self.isSurveying = false
            self.progress = 1
            if let volume = result.volume { self.history.recordSample(used: volume.used, total: volume.total, at: result.generatedAt) }
            let cache = self.cache
            let fingerprint = SurveyCache.fingerprint(for: prefs)
            Task.detached(priority: .background) { cache.save(result, fingerprint: fingerprint) }
        }
    }

    private nonisolated static func performSurvey(preferences: Preferences, regrowth: RegrowthStore,
                                                   onProgress: @escaping @Sendable (SurveyProgress) -> Void) async -> AnalysisResult {
        let surveyor = Surveyor(config: preferences.surveyConfig(), exclusions: preferences.exclusions())
        let now = Date()
        do {
            let survey = try await surveyor.run(onProgress: onProgress)
            regrowth.observePresence(survey.candidates.map { ($0.url.path, $0.fingerprint) }, at: now)
            let analyzer = Analyzer(attributor: Attributor(registry: SystemAppRegistry()),
                                    context: SignalContext(fileSystem: RealFileSystem(), now: now, regrowth: regrowth))
            return AnalysisResult(volume: VolumeReader.read(), targets: analyzer.targets(for: survey.candidates),
                                  unreadableRoots: survey.unreadableRoots, generatedAt: now)
        } catch {
            return AnalysisResult(volume: VolumeReader.read(), targets: [], unreadableRoots: [], generatedAt: now)
        }
    }

    private func prepareReclaim() {
        let runner = ProcessRunner()
        let planner = ReclaimPlanner(registry: KnownTools(), runner: runner,
            preconditions: SystemPreconditionChecker(runner: runner,
                runningBundleIdentifiers: { SystemAppRegistry().runningBundleIdentifiers() }),
            permanentDefault: defaults.bool(forKey: "sweep.reclaim.permanentByDefault"))
        let filesystem = RealFileSystem()
        let items = selection.selectedTargets.compactMap { target -> ReclaimItem? in
            guard filesystem.attributes(of: target.url) != nil else { return nil }
            return ReclaimItem(target: target, method: planner.method(for: target))
        }
        pendingPlan = items.isEmpty ? nil : ReclaimPlan(items: items,
            sourceTimestamp: analysis?.generatedAt ?? Date(),
            sourceState: analysisIsCached ? "saved" : "fresh")
    }

    private func confirmReclaim(typed: String?) async {
        guard let plan = pendingPlan else { return }
        let engine = ReclaimEngine(trash: TrashReclaimer(), hard: HardReclaimer(),
            commandFactory: { CommandReclaimer(teardown: $0, runner: ProcessRunner()) },
            sampleVolume: { VolumeReader.read() })
        do {
            let report = try await engine.execute(plan, typedConfirmation: typed)
            for record in report.reclaimed { regrowth.recordReclaim(path: record.path, fingerprint: record.fingerprint, bytes: record.bytes, at: Date()) }
            history.recordSweep(History.ReclaimLogEntry(id: ISO8601DateFormatter().string(from: Date()), date: Date(),
                measuredFreedBytes: report.measuredFreedBytes, trashedBytes: report.trashedBytes,
                items: plan.actionable.map { History.ReclaimLogEntry.Item(title: $0.target.title, path: $0.target.url.path,
                    mechanism: String(describing: $0.method), allocatedBytes: $0.target.bytes, risk: $0.target.risk.rawValue,
                    category: $0.target.category.label, summary: $0.target.verdict.summary) }))
            pendingPlan = nil
            lastReport = report
            startSurvey()
        } catch {
            // Keep plan visible only for the typed confirmation retry.
        }
    }

    private func findTarget(_ id: String) -> Target? {
        func descend(_ targets: [Target]) -> Target? {
            for target in targets { if target.id == id { return target }; if let nested = descend(target.components) { return nested } }
            return nil
        }
        return descend(analysis?.offered ?? [])
    }

    private func progressReply() -> SweepWireProgress {
        SweepWireProgress(isSurveying: isSurveying, progress: progress)
    }

    private func snapshot(categoryID: String? = nil, targetOffset: Int = 0, targetLimit: Int = 0,
                          includeHistory: Bool = false) -> SweepWireSnapshot {
        let isProtectedPage = categoryID == SweepWireProtectedSummary.id
        let allTargets: [Target]
        if isProtectedPage {
            allTargets = analysis?.withheld ?? []
        } else if let categoryID {
            allTargets = (analysis?.offered ?? []).filter { $0.category.rawValue == categoryID }
                .sorted { $0.bytes > $1.bytes }
        } else {
            allTargets = []
        }
        let firstTarget = min(max(0, targetOffset), allTargets.count)
        let lastTarget = min(firstTarget + targetLimit, allTargets.count)
        let targets = categoryID != nil && targetLimit > 0
            ? allTargets[firstTarget..<lastTarget].map(wireTarget)
            : []
        let nextTargetOffset = categoryID != nil && lastTarget < allTargets.count ? lastTarget : nil
        let prefs = SweepWirePreferences(candidateThresholdBytes: preferences.candidateThresholdBytes,
            extraScanRoots: preferences.extraScanRoots, userExclusions: preferences.userExclusions,
            resurveyInterval: preferences.resurveyInterval)
        let historyWire: SweepWireHistory
        let regrowthWire: [SweepWireRegrowth]
        if includeHistory {
            let entries = history.log.map { SweepWireHistoryEntry(id: $0.id, date: $0.date,
                measuredFreedBytes: $0.measuredFreedBytes, trashedBytes: $0.trashedBytes, itemCount: $0.items.count) }
            historyWire = SweepWireHistory(samples: history.samples.map { SweepWireSample(date: $0.date, usedBytes: $0.usedBytes, totalBytes: $0.totalBytes) },
                cumulativeFreedBytes: history.cumulativeFreedBytes, entries: entries)
            regrowthWire = regrowth.entries.map { SweepWireRegrowth(id: $0.path, path: $0.path, count: $0.history.count, lastBytes: $0.history.lastBytes) }
        } else {
            historyWire = SweepWireHistory(samples: [], cumulativeFreedBytes: 0, entries: [])
            regrowthWire = []
        }
        let categories = analysis?.rollups.map {
            SweepWireCategorySummary(id: $0.category.rawValue, label: $0.category.label,
                                     count: $0.count, reclaimableBytes: $0.bytes)
        } ?? []
        let withheld = analysis?.withheld ?? []
        return SweepWireSnapshot(isSurveying: isSurveying, progress: progress, analysisIsCached: analysisIsCached,
            lastSurvey: analysis?.generatedAt, volume: volume.map { SweepWireVolume(name: $0.name, total: $0.total, available: $0.available, availableStrict: $0.availableStrict) },
            categories: categories,
            protected: SweepWireProtectedSummary(count: withheld.count, bytes: withheld.reduce(0) { $0 + $1.bytes }),
            includesCategoryPage: categoryID != nil, categoryID: categoryID, targets: targets,
            nextTargetOffset: nextTargetOffset,
            reclaimableBytes: analysis?.reclaimableBytes ?? 0, includesHistory: includeHistory,
            unreadableRoots: analysis?.unreadableRoots.map(\.path) ?? [], selectedIDs: selection.selected,
            selectedBytes: selection.selectedBytes, preferences: prefs, history: historyWire, regrowth: regrowthWire,
            pendingPlan: pendingPlan.map { SweepWirePlan(itemCount: $0.actionable.count, requiresTypedConfirmation: $0.requiresTypedConfirmation, estimatedBytes: $0.totalBytes,
                sourceTimestamp: $0.sourceTimestamp, sourceState: $0.sourceState) },
            lastReport: lastReport.map { SweepWireReport(measuredFreedBytes: $0.measuredFreedBytes, trashedBytes: $0.trashedBytes, failedCount: $0.failures.count) },
            fullDiskAccess: Permissions.hasFullDiskAccess(), migration: migration)
    }

    private func wireTarget(_ target: Target) -> SweepWireTarget {
        let reclaim: String
        switch target.defaultReclaim { case .trash: reclaim = "Trash"; case .hardDelete: reclaim = "Permanent delete"; case .command: reclaim = "Tool cleanup" }
        return SweepWireTarget(id: target.id, title: target.title, path: target.url.path, bytes: target.bytes,
            risk: target.risk.rawValue, category: target.category.label, summary: target.verdict.summary,
            defaultReclaim: reclaim, components: [])
    }
}

final class SweepService: NSObject, SweepServiceProtocol {
    // XPC constructs exported objects off main actor. Create store only inside
    // first request so its @MainActor state remains isolated.
    private var store: SweepServiceStore?
    func send(_ request: Data, with reply: @escaping (Data) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let decoded = try? JSONDecoder().decode(SweepWireRequest.self, from: request) else {
                reply((try? JSONEncoder().encode(SweepWireReply(snapshot: nil, progress: nil, error: "Invalid Sweep service request."))) ?? Data())
                return
            }
            let store = self.store ?? SweepServiceStore()
            self.store = store
            reply((try? JSONEncoder().encode(await store.handle(decoded))) ?? Data())
        }
    }
}
