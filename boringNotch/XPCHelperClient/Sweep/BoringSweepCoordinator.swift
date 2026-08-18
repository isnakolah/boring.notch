//
//  BoringSweepCoordinator.swift
//  boringNotch
//
//  The client half of the Sweep XPC connection.
//

import Defaults
import Foundation

@MainActor
final class BoringSweepCoordinator: ObservableObject {
    static let shared = BoringSweepCoordinator()
    @Published private(set) var snapshot: BoringSweepSnapshot?
    @Published private(set) var categoryPages: [String: BoringSweepPage] = [:]
    @Published private(set) var isSurveying = false
    @Published private(set) var surveyProgress = 0.0
    @Published private(set) var error: String?
    @Published var showConfirmation = false
    @Published var lifetime: SweepProcessLifetime { didSet { Defaults[.sweepServiceLifetime] = lifetime } }

    private let serviceName = "theboringteam.boringnotch.SweepService"
    private var connection: NSXPCConnection?
    private var pollTask: Task<Void, Never>?
    /// Whether the Sweep section is the one on screen. Gates polling.
    private var visible = false
    private var historyRequested = false

    private init() { lifetime = Defaults[.sweepServiceLifetime] }
    /// The Sweep section was selected. Not "a Sweep page appeared" — the four
    /// pages push and pop between each other, and the helper has to survive that.
    func sectionOpened() { visible = true; send(command: "open") }
    /// The reader left Sweep entirely.
    func sectionClosed() { visible = false; stopPolling(); if lifetime == .tab { stopService() } }
    func settingsClosed() { if lifetime != .app { stopService() } }
    func rescan() { send(command: "rescan") }
    func cancel() { send(command: "cancel") }
    func loadHistory() { historyRequested = true; send(command: "loadHistory") }
    func loadCategory(_ id: String) { send(command: "loadCategory", categoryID: id, targetOffset: 0) }
    func loadMoreCategory(_ id: String) { guard let offset = categoryPages[id]?.nextOffset else { return }; send(command: "loadCategory", categoryID: id, targetOffset: offset) }
    func toggle(_ target: BoringSweepTarget) { send(command: "toggleSelection", targetID: target.id) }
    func selectRecommended() { send(command: "selectRecommended") }
    func clearSelection() { send(command: "clearSelection") }
    func clearRegrowth() { send(command: "clearRegrowth") }
    func apply(_ preferences: BoringSweepPreferences) { send(command: "updatePreferences", preferences: preferences) }
    func prepareReclaim() { send(command: "prepareReclaim") { [weak self] reply in self?.showConfirmation = reply.snapshot?.pendingPlan != nil } }
    func confirmReclaim(_ typed: String?) { showConfirmation = false; send(command: "confirmReclaim", typed: typed) }

    private func ensureConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BoringSweepServiceProtocol.self)
        connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
        connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
        connection.resume(); self.connection = connection
        return connection
    }

    private func send(command: String, targetID: String? = nil, categoryID: String? = nil, targetOffset: Int? = nil, typed: String? = nil, preferences: BoringSweepPreferences? = nil, completion: ((BoringSweepReply) -> Void)? = nil) {
        let request = BoringSweepRequest(command: command, targetID: targetID, categoryID: categoryID, targetOffset: targetOffset, typedConfirmation: typed, preferences: preferences)
        guard let data = try? JSONEncoder().encode(request) else { return }
        let proxy = ensureConnection().remoteObjectProxyWithErrorHandler { [weak self] error in Task { @MainActor in self?.error = "Sweep service unavailable: \(error.localizedDescription)" } } as? BoringSweepServiceProtocol
        proxy?.send(data) { [weak self] data in
            guard let reply = try? JSONDecoder().decode(BoringSweepReply.self, from: data) else { return }
            Task { @MainActor in
                guard let self else { return }
                let wasSurveying = self.isSurveying
                if let snapshot = reply.snapshot { self.merge(snapshot) }
                if let progress = reply.progress { self.isSurveying = progress.isSurveying; self.surveyProgress = progress.progress }
                self.error = reply.error; self.reconcilePolling()
                if wasSurveying, !self.isSurveying, self.historyRequested { self.send(command: "loadHistory") }
                completion?(reply)
            }
        }
    }

    private func merge(_ incoming: BoringSweepSnapshot) {
        let previous = snapshot
        let changedAnalysis = previous?.lastSurvey != nil && previous?.lastSurvey != incoming.lastSurvey
        if changedAnalysis { categoryPages = [:] }
        if incoming.includesCategoryPage, let categoryID = incoming.categoryID {
            let old = changedAnalysis ? nil : categoryPages[categoryID]
            let rows = old.map { $0.targets + incoming.targets } ?? incoming.targets
            categoryPages[categoryID] = BoringSweepPage(targets: rows, nextOffset: incoming.nextTargetOffset)
        }
        var merged = incoming
        if !incoming.includesHistory, let previous, previous.lastSurvey == incoming.lastSurvey, previous.includesHistory {
            merged.history = previous.history; merged.regrowth = previous.regrowth; merged.includesHistory = true
        }
        snapshot = merged; isSurveying = incoming.isSurveying; surveyProgress = incoming.progress
    }

    private func reconcilePolling() {
        guard visible, isSurveying else { stopPolling(); return }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(500)); guard !Task.isCancelled, self?.visible == true else { break }; self?.send(command: "status") } }
    }
    private func stopPolling() { pollTask?.cancel(); pollTask = nil }
    private func stopService() {
        stopPolling(); guard let connection else { return }
        send(command: "shutdown") { [weak self] _ in self?.connection?.invalidate(); self?.connection = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, connection] in if self?.connection === connection { connection.invalidate(); self?.connection = nil } }
    }
}
