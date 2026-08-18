//
//  QuickShareService.swift
//  boringNotch
//
//  Native LocalSend v2 sender for Shelf.
//

import AppKit
import Combine
import CryptoKit
import Defaults
import Darwin
import Foundation
import Network
import Security
import UniformTypeIdentifiers

/// Per-item send progress, keyed by `ShelfItem.id` so the queue chips can show
/// where each file is without knowing anything about the transport.
enum ShelfTransferState: Equatable, Sendable {
    case pending
    case sending(fraction: Double)
    case sent
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .sent, .failed: true
        case .pending, .sending: false
        }
    }
}

enum LocalSendDestination: String, CaseIterable, Codable, Identifiable {
    case phone
    case tv

    var id: String { rawValue }
    var title: String { self == .phone ? "Phone" : "TV" }
    var symbolName: String { self == .phone ? "iphone" : "tv" }
}

struct LocalSendDevice: Codable, Hashable, Identifiable {
    let alias: String
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String
    let host: String
    let port: Int
    let transport: String
    var lastSeen: Date

    var id: String { fingerprint }
    var displayName: String {
        guard let deviceModel, !deviceModel.isEmpty else { return alias }
        return "\(alias) (\(deviceModel))"
    }
}

struct LocalSendBinding: Codable, Equatable {
    let destination: LocalSendDestination
    var device: LocalSendDevice
}

enum LocalSendError: LocalizedError {
    case unpaired(LocalSendDestination)
    case offline(LocalSendDestination)
    case rejected
    case pinRequired
    case invalidResponse
    case tlsFingerprintMismatch
    case noFilesAccepted

    var errorDescription: String? {
        switch self {
        case .unpaired(let destination): return "Pair \(destination.title) in Shelf settings first."
        case .offline(let destination): return "\(destination.title) is offline. Open LocalSend on same Wi-Fi."
        case .rejected: return "Receiver rejected transfer."
        case .pinRequired: return "Receiver requires LocalSend PIN."
        case .invalidResponse: return "LocalSend receiver returned invalid response."
        case .tlsFingerprintMismatch: return "Receiver certificate changed. Re-pair device before sending."
        case .noFilesAccepted: return "Receiver accepted no files."
        }
    }
}

@MainActor
final class QuickShareService: NSObject, ObservableObject {
    static let shared = QuickShareService()

    @Published private(set) var availableDevices: [LocalSendDevice] = []
    @Published private(set) var bindings: [LocalSendDestination: LocalSendBinding] = [:]
    @Published private(set) var selectedDestination: LocalSendDestination = .phone
    @Published private(set) var isDiscovering = false
    @Published private(set) var isSending = false
    @Published private(set) var completedFileCount = 0
    @Published private(set) var totalFileCount = 0
    @Published private(set) var transfers: [UUID: ShelfTransferState] = [:]
    @Published var lastError: String?
    /// Off means off: no listener, no multicast socket, no subnet probing, and
    /// so nothing that makes macOS ask for the local network permission.
    @Published private(set) var isEnabled = true

    private var transferClearTask: Task<Void, Never>?

    private static let multicastHost = "224.0.0.167"
    private static let defaultPort = 53_317
    private static let deviceTTL: TimeInterval = 20
    private var connectionGroup: NWConnectionGroup?
    private var registrationListener: NWListener?
    private var registrationResponse = Data()
    private var discoveryTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var enabledObserver: AnyCancellable?

    private override init() {
        super.init()
        selectedDestination = LocalSendDestination(rawValue: Defaults[.localSendDestination]) ?? .phone
        loadBindings()
        registrationResponse = makeRegistrationResponse()
        isEnabled = Defaults[.localSendEnabled]
        observeEnabled()
        guard isEnabled else { return }
        startNetworking()
    }

    deinit {
        discoveryTask?.cancel()
        refreshTask?.cancel()
        connectionGroup?.cancel()
        registrationListener?.cancel()
    }

    var selectedDevice: LocalSendDevice? { device(for: selectedDestination) }
    var selectedDestinationReady: Bool { isOnline(selectedDestination) }
    var progressLabel: String? {
        guard isSending else { return nil }
        return "Sending \(completedFileCount) of \(totalFileCount)"
    }

    /// Aggregate 0...1 progress. Falls back to whole-file granularity when no
    /// shelf items were tagged (dropped files and the file picker have none).
    var sendFraction: Double {
        guard isSending, totalFileCount > 0 else { return 0 }
        let inFlight = transfers.values.compactMap { state -> Double? in
            if case .sending(let fraction) = state { return fraction }
            return nil
        }.max() ?? 0
        return min(1, (Double(completedFileCount) + inFlight) / Double(totalFileCount))
    }

    func clearTransfers() {
        transferClearTask?.cancel()
        transferClearTask = nil
        transfers.removeAll()
    }

    func select(_ destination: LocalSendDestination) {
        selectedDestination = destination
        Defaults[.localSendDestination] = destination.rawValue
        lastError = nil
    }

    var nearbyDevices: [LocalSendDevice] {
        availableDevices.filter { $0.lastSeen.addingTimeInterval(Self.deviceTTL) > .now }
    }

    func binding(for destination: LocalSendDestination) -> LocalSendBinding? { bindings[destination] }
    func device(for destination: LocalSendDestination) -> LocalSendDevice? {
        guard let binding = bindings[destination] else { return nil }
        return nearbyDevices.first(where: { $0.fingerprint == binding.device.fingerprint })
    }
    func isPaired(_ destination: LocalSendDestination) -> Bool { bindings[destination] != nil }
    func isOnline(_ destination: LocalSendDestination) -> Bool { device(for: destination) != nil }

    func bind(_ device: LocalSendDevice, to destination: LocalSendDestination) {
        bindings[destination] = LocalSendBinding(destination: destination, device: device)
        persistBindings()
    }

    func unbind(_ destination: LocalSendDestination) {
        bindings.removeValue(forKey: destination)
        persistBindings()
    }

    func refreshDiscovery() {
        guard isEnabled else { return }
        lastError = nil
        pruneExpiredDevices()
        beginRefreshWindow()
        startRegistrationListener()
        startDiscovery()
        announce()
        startNetworkScan()
    }

    // MARK: Enablement

    private func observeEnabled() {
        enabledObserver = Defaults.publisher(.localSendEnabled)
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor [weak self] in self?.setEnabled(enabled) }
            }
    }

    private func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        lastError = nil
        if enabled {
            startNetworking()
        } else {
            stopNetworking()
        }
    }

    private func startNetworking() {
        startRegistrationListener()
        startDiscovery()
        startDiscoveryPolling()
        startNetworkScan()
    }

    /// Bindings survive: turning the provider off is not unpairing, and coming
    /// back on should find the same devices where they were left.
    private func stopNetworking() {
        discoveryTask?.cancel()
        discoveryTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        connectionGroup?.cancel()
        connectionGroup = nil
        registrationListener?.cancel()
        registrationListener = nil
        availableDevices.removeAll()
        isDiscovering = false
    }

    // MARK: Discovery

    /// LocalSend members reply to an announcement by POSTing `/register` to the
    /// sender. We advertise HTTP deliberately: Shelf sends only and never
    /// exposes files, so no self-signed certificate or download server is needed.
    private func startRegistrationListener() {
        guard registrationListener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(Self.defaultPort))!)
            let response = registrationResponse
            listener.newConnectionHandler = { connection in
                LocalSendRegistrationConnection(connection: connection, response: response).receive()
            }
            listener.stateUpdateHandler = { [weak self] (state: NWListener.State) in
                guard case .failed = state else { return }
                Task { @MainActor [weak self] in
                    self?.registrationListener = nil
                }
            }
            registrationListener = listener
            listener.start(queue: .main)
        } catch {
            lastError = "LocalSend register listener unavailable: \(error.localizedDescription)"
        }
    }

    fileprivate func receiveRegistration(_ data: Data, host: String, port: Int) {
        guard let bodyStart = data.range(of: Data("\r\n\r\n".utf8)) else { return }
        let body = data[bodyStart.upperBound...]
        receiveAnnouncement(Data(body), host: host, port: port, shouldRegister: false)
    }

    private func makeRegistrationResponse() -> Data {
        let body = (try? JSONEncoder().encode(senderInfo)) ?? Data()
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    private func startDiscovery() {
        guard connectionGroup == nil else {
            announce()
            return
        }
        do {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(Self.multicastHost),
                port: NWEndpoint.Port(rawValue: UInt16(Self.defaultPort))!
            )
            let group = try NWMulticastGroup(for: [endpoint])
            let connectionGroup = NWConnectionGroup(with: group, using: .udp)
            connectionGroup.setReceiveHandler(maximumMessageSize: 16_384, rejectOversizedMessages: true) { [weak self] message, content, _ in
                guard let content else { return }
                guard case let .hostPort(host, port)? = message.remoteEndpoint else { return }
                let hostString = host.debugDescription
                Task { @MainActor [weak self] in
                    self?.receiveAnnouncement(content, host: hostString, port: Int(port.rawValue))
                }
            }
            connectionGroup.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        self?.announce()
                    case .failed:
                        self?.isDiscovering = false
                    default:
                        break
                    }
                }
            }
            self.connectionGroup = connectionGroup
            connectionGroup.start(queue: .main)
            beginRefreshWindow()
            announce()
        } catch {
            isDiscovering = false
            lastError = "LocalSend discovery unavailable: \(error.localizedDescription)"
        }
    }

    private func announce() {
        let announcement = LocalSendAnnouncement(
            alias: Host.current().localizedName ?? "boringNotch",
            version: "2.0",
            deviceModel: "Mac",
            deviceType: "desktop",
            fingerprint: senderFingerprint,
            port: Self.defaultPort,
            protocolName: "http",
            download: false,
            announce: true
        )
        guard let data = try? JSONEncoder().encode(announcement) else { return }
        connectionGroup?.send(content: data, to: nil) { _ in }
    }

    private func receiveAnnouncement(_ data: Data, host: String, port: Int, shouldRegister: Bool = true) {
        guard let announcement = try? JSONDecoder().decode(LocalSendAnnouncement.self, from: data),
              announcement.version.split(separator: ".").first == "2",
              announcement.fingerprint != senderFingerprint,
              !announcement.fingerprint.isEmpty else { return }

        let device = LocalSendDevice(
            alias: announcement.alias,
            deviceModel: announcement.deviceModel,
            deviceType: announcement.deviceType,
            fingerprint: announcement.fingerprint,
            host: host,
            port: announcement.port ?? port,
            transport: announcement.protocolName ?? "https",
            lastSeen: .now
        )
        if let index = availableDevices.firstIndex(where: { $0.fingerprint == device.fingerprint }) {
            availableDevices[index] = device
        } else {
            availableDevices.append(device)
            availableDevices.sort { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
        }
        for destination in LocalSendDestination.allCases where bindings[destination]?.device.fingerprint == device.fingerprint {
            bindings[destination] = LocalSendBinding(destination: destination, device: device)
        }
        persistBindings()
        if shouldRegister {
            Task { await register(with: device) }
        }
    }

    private func register(with device: LocalSendDevice) async {
        let request = LocalSendAnnouncement(
            alias: Host.current().localizedName ?? "boringNotch",
            version: "2.0",
            deviceModel: "Mac",
            deviceType: "desktop",
            fingerprint: senderFingerprint,
            port: Self.defaultPort,
            protocolName: "http",
            download: false,
            announce: false
        )
        _ = try? await requestData(
            device: device,
            path: "/api/localsend/v2/register",
            body: try JSONEncoder().encode(request),
            contentType: "application/json",
            pin: nil
        )
    }

    private func startDiscoveryPolling() {
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.pruneExpiredDevices()
                self?.announce()
            }
        }
    }

    /// LocalSend v2 specifies subnet probing as discovery fallback. Many phone
    /// and TV Wi-Fi clients suppress multicast while still accepting register
    /// requests, so multicast alone incorrectly reports a paired device offline.
    private func startNetworkScan() {
        let hosts = Self.localSubnetHosts()
        guard !hosts.isEmpty else { return }
        let sender = senderInfo
        Task { [weak self] in
            guard let self, let body = try? JSONEncoder().encode(sender) else { return }
            await withTaskGroup(of: LocalSendDevice?.self) { group in
                for host in hosts {
                    group.addTask {
                        await Self.probeLocalSend(host: host, body: body)
                    }
                }
                for await device in group {
                    guard let device else { continue }
                    self.recordScannedDevice(device)
                }
            }
        }
    }

    private func recordScannedDevice(_ device: LocalSendDevice) {
        guard device.fingerprint != senderFingerprint else { return }
        if let index = availableDevices.firstIndex(where: { $0.fingerprint == device.fingerprint }) {
            availableDevices[index] = device
        } else {
            availableDevices.append(device)
            availableDevices.sort { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
        }
        for destination in LocalSendDestination.allCases where bindings[destination]?.device.fingerprint == device.fingerprint {
            bindings[destination] = LocalSendBinding(destination: destination, device: device)
        }
        persistBindings()
        isDiscovering = false
    }

    private static func probeLocalSend(host: String, body: Data) async -> LocalSendDevice? {
        for transport in ["https", "http"] {
            var components = URLComponents()
            components.scheme = transport
            components.host = host
            components.port = defaultPort
            components.path = "/api/localsend/v2/register"
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 0.7
            do {
                let data: Data
                let response: URLResponse
                if transport == "https" {
                    let session = URLSession(
                        configuration: .ephemeral,
                        delegate: LocalSendDiscoveryTLSDelegate(),
                        delegateQueue: nil
                    )
                    (data, response) = try await session.data(for: request)
                } else {
                    (data, response) = try await URLSession.shared.data(for: request)
                }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let announcement = try? JSONDecoder().decode(LocalSendAnnouncement.self, from: data),
                      announcement.version.split(separator: ".").first == "2",
                      !announcement.fingerprint.isEmpty else { continue }
                return LocalSendDevice(
                    alias: announcement.alias,
                    deviceModel: announcement.deviceModel,
                    deviceType: announcement.deviceType,
                    fingerprint: announcement.fingerprint,
                    host: host,
                    port: announcement.port ?? defaultPort,
                    transport: announcement.protocolName ?? transport,
                    lastSeen: .now
                )
            } catch {
                continue
            }
        }
        return nil
    }

    private static func localSubnetHosts() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var subnets = Set<UInt32>()
        var ownAddresses = Set<UInt32>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let host = UInt32(bigEndian: ipv4.sin_addr.s_addr)
            ownAddresses.insert(host)
            subnets.insert(host & 0xFFFF_FF00)
        }

        return subnets.flatMap { subnet in
            (1...254).compactMap { hostPart -> String? in
                let address = subnet | UInt32(hostPart)
                guard !ownAddresses.contains(address) else { return nil }
                return "\((address >> 24) & 255).\((address >> 16) & 255).\((address >> 8) & 255).\(address & 255)"
            }
        }
    }

    private func beginRefreshWindow() {
        isDiscovering = true
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.isDiscovering = false
        }
    }

    private func pruneExpiredDevices() {
        let cutoff = Date.now.addingTimeInterval(-Self.deviceTTL)
        availableDevices.removeAll { $0.lastSeen < cutoff }
    }

    // MARK: Transfer

    func showFilePicker() async {
        guard !isSending else { return }
        guard selectedDestinationReady else {
            lastError = isPaired(selectedDestination)
                ? LocalSendError.offline(selectedDestination).localizedDescription
                : LocalSendError.unpaired(selectedDestination).localizedDescription
            return
        }

        SharingStateManager.shared.beginInteraction()
        defer { SharingStateManager.shared.endInteraction() }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Send to \(selectedDestination.title)"
        panel.message = "Choose files for LocalSend"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        await send(fileURLs: panel.urls, temporaryURLs: [], to: selectedDestination)
    }

    func shareDroppedFiles(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        var temporaryURLs: [URL] = []
        var text: String?
        for provider in providers {
            if let webURL = await provider.extractURL() {
                if webURL.isFileURL { urls.append(webURL) }
                else if let temporaryURL = await TemporaryFileStorageService.shared.createTempFile(for: .url(webURL)) {
                    urls.append(temporaryURL); temporaryURLs.append(temporaryURL)
                }
            } else if text == nil, let extracted = await provider.extractText() {
                text = extracted
            } else if let fileURL = await provider.extractItem() {
                urls.append(fileURL)
            }
        }
        if let text, let temporaryURL = await TemporaryFileStorageService.shared.createTempFile(for: .text(text)) {
            urls.append(temporaryURL)
            temporaryURLs.append(temporaryURL)
        }
        guard !urls.isEmpty else { return }
        await send(fileURLs: urls, temporaryURLs: temporaryURLs, to: selectedDestination)
    }

    func shareShelfItems(_ items: [ShelfItem], to destination: LocalSendDestination? = nil) async {
        let destination = destination ?? selectedDestination
        var urls: [URL] = []
        var temporaryURLs: [URL] = []
        // Several items can resolve to one URL once uniqueFileURLs dedupes, so
        // every URL keeps the full list of items it stands for.
        var itemIDsByURL: [URL: [UUID]] = [:]
        func tag(_ url: URL, _ id: UUID) {
            itemIDsByURL[url.standardizedFileURL, default: []].append(id)
        }
        for item in items {
            switch item.kind {
            case .file:
                if let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item) {
                    urls.append(url)
                    tag(url, item.id)
                }
            case .text(let text):
                if let url = await TemporaryFileStorageService.shared.createTempFile(for: .text(text)) {
                    urls.append(url); temporaryURLs.append(url)
                    tag(url, item.id)
                }
            case .link(let link):
                if let url = await TemporaryFileStorageService.shared.createTempFile(for: .url(link)) {
                    urls.append(url); temporaryURLs.append(url)
                    tag(url, item.id)
                }
            }
        }
        guard !urls.isEmpty else { return }
        await send(fileURLs: urls, temporaryURLs: temporaryURLs, to: destination, itemIDsByURL: itemIDsByURL)
    }

    private func send(
        fileURLs: [URL],
        temporaryURLs: [URL],
        to destination: LocalSendDestination,
        itemIDsByURL: [URL: [UUID]] = [:]
    ) async {
        // Untagged sends (dropped files, file picker) must not leave the last
        // run's badges sitting on unrelated chips.
        transferClearTask?.cancel()
        transferClearTask = nil
        transfers = Dictionary(uniqueKeysWithValues: itemIDsByURL.values.flatMap { $0 }.map { ($0, .pending) })

        guard !isSending else {
            lastError = "LocalSend transfer already in progress."
            failRemainingTransfers(with: "Transfer already in progress")
            cleanup(temporaryURLs)
            return
        }
        guard let device = device(for: destination) else {
            lastError = isPaired(destination)
                ? LocalSendError.offline(destination).localizedDescription
                : LocalSendError.unpaired(destination).localizedDescription
            failRemainingTransfers(with: lastError ?? "Destination unavailable")
            cleanup(temporaryURLs)
            return
        }
        let transferURLs = uniqueFileURLs(fileURLs)
        guard !transferURLs.isEmpty else {
            failRemainingTransfers(with: "Nothing to send")
            cleanup(temporaryURLs)
            return
        }
        let accessibleURLs = transferURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            accessibleURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            cleanup(temporaryURLs)
        }
        isSending = true
        completedFileCount = 0
        totalFileCount = transferURLs.count
        lastError = nil
        SharingStateManager.shared.beginInteraction()
        defer {
            isSending = false
            SharingStateManager.shared.endInteraction()
            finishTransfers()
        }
        do {
            try await send(fileURLs: transferURLs, to: device, pin: nil, itemIDsByURL: itemIDsByURL)
        } catch LocalSendError.pinRequired {
            guard let pin = promptForPIN(device: device) else {
                lastError = "LocalSend PIN required. Transfer cancelled."
                failRemainingTransfers(with: "PIN required")
                return
            }
            // The retry replays the whole transfer, so the counters restart too.
            for (id, state) in transfers where state != .sent { transfers[id] = .pending }
            completedFileCount = 0
            do {
                try await send(fileURLs: transferURLs, to: device, pin: pin, itemIDsByURL: itemIDsByURL)
            } catch {
                lastError = error.localizedDescription
                failRemainingTransfers(with: error.localizedDescription)
            }
        } catch {
            lastError = error.localizedDescription
            failRemainingTransfers(with: error.localizedDescription)
        }
    }

    private func setTransfer(_ state: ShelfTransferState, forURL url: URL, in map: [URL: [UUID]]) {
        for id in map[url.standardizedFileURL] ?? [] { transfers[id] = state }
    }

    private func failRemainingTransfers(with reason: String) {
        for (id, state) in transfers where !state.isTerminal { transfers[id] = .failed(reason) }
    }

    /// Leaves the ✓/✗ badges up briefly, then either drops the sent items or
    /// clears the badges so the queue reads as idle again.
    private func finishTransfers() {
        guard !transfers.isEmpty else { return }
        let sentIDs = transfers.compactMap { $0.value == .sent ? $0.key : nil }
        transferClearTask?.cancel()
        transferClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self, !self.isSending else { return }
            if Defaults[.autoRemoveShelfItems], !sentIDs.isEmpty {
                ShelfStateViewModel.shared.removeItems(withIDs: Set(sentIDs))
            }
            self.transfers.removeAll()
            self.transferClearTask = nil
        }
    }

    private func uniqueFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0.standardizedFileURL).inserted }
    }

    private func send(fileURLs: [URL], to device: LocalSendDevice, pin: String?, itemIDsByURL: [URL: [UUID]]) async throws {
        let files = try Dictionary(uniqueKeysWithValues: fileURLs.map { url in
            let id = UUID().uuidString
            return (id, try makeFileMetadata(id: id, url: url))
        })
        let preparation = LocalSendPrepareUpload(info: senderInfo, files: files)
        let data = try JSONEncoder().encode(preparation)
        let responseData: Data
        do {
            responseData = try await requestData(
                device: device,
                path: "/api/localsend/v2/prepare-upload",
                body: data,
                contentType: "application/json",
                pin: pin
            )
        } catch LocalSendHTTPError.status(let code) where code == 401 {
            throw LocalSendError.pinRequired
        } catch LocalSendHTTPError.status(let code) where code == 403 {
            throw LocalSendError.rejected
        }
        if responseData.isEmpty { return }
        let response = try JSONDecoder().decode(LocalSendPrepareResponse.self, from: responseData)
        guard !response.files.isEmpty else { throw LocalSendError.noFilesAccepted }
        for (fileID, token) in response.files {
            guard let metadata = files[fileID] else { continue }
            var components = URLComponents(string: "https://localhost")!
            components.path = "/api/localsend/v2/upload"
            components.queryItems = [
                URLQueryItem(name: "sessionId", value: response.sessionId),
                URLQueryItem(name: "fileId", value: fileID),
                URLQueryItem(name: "token", value: token)
            ]
            let path = components.url!.path + "?" + (components.url!.query ?? "")
            let fileURL = metadata.url
            setTransfer(.sending(fraction: 0), forURL: fileURL, in: itemIDsByURL)
            do {
                _ = try await uploadFile(device: device, path: path, fileURL: fileURL, onProgress: { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.isSending else { return }
                        self.setTransfer(.sending(fraction: fraction), forURL: fileURL, in: itemIDsByURL)
                    }
                })
            } catch {
                setTransfer(.failed(error.localizedDescription), forURL: fileURL, in: itemIDsByURL)
                throw error
            }
            setTransfer(.sent, forURL: fileURL, in: itemIDsByURL)
            completedFileCount += 1
        }
    }

    private func makeFileMetadata(id: String, url: URL) throws -> LocalSendFileMetadata {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .localizedNameKey])
        let type = values.contentType?.preferredMIMEType ?? "application/octet-stream"
        return LocalSendFileMetadata(
            id: id,
            fileName: values.localizedName ?? url.lastPathComponent,
            size: Int64(values.fileSize ?? 0),
            fileType: type,
            sha256: nil,
            url: url
        )
    }

    private func requestData(device: LocalSendDevice, path: String, body: Data, contentType: String, pin: String?) async throws -> Data {
        var request = URLRequest(url: try endpointURL(for: device, path: path, pin: pin))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (session, tls) = session(for: device)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if tls.didRejectServerTrust { throw LocalSendError.tlsFingerprintMismatch }
            throw error
        }
        try validate(response)
        return data
    }

    private func uploadFile(
        device: LocalSendDevice,
        path: String,
        fileURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        var request = URLRequest(url: try endpointURL(for: device, path: path, pin: nil))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (session, tls) = session(for: device)
        let data: Data
        let response: URLResponse
        do {
            if let onProgress {
                // Task-scoped delegate. It deliberately implements no auth
                // callback, so cert pinning stays with LocalSendTLSDelegate.
                (data, response) = try await session.upload(
                    for: request,
                    fromFile: fileURL,
                    delegate: UploadProgressDelegate(onProgress: onProgress)
                )
            } else {
                (data, response) = try await session.upload(for: request, fromFile: fileURL)
            }
        } catch {
            if tls.didRejectServerTrust { throw LocalSendError.tlsFingerprintMismatch }
            throw error
        }
        try validate(response)
        return data
    }

    private func endpointURL(for device: LocalSendDevice, path: String, pin: String?) throws -> URL {
        var components = URLComponents()
        components.scheme = device.transport.lowercased() == "http" ? "http" : "https"
        components.host = device.host
        components.port = device.port
        if let queryStart = path.firstIndex(of: "?") {
            components.path = String(path[..<queryStart])
            components.percentEncodedQuery = String(path[path.index(after: queryStart)...])
        } else {
            components.path = path
        }
        if let pin {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "pin", value: pin))
            components.queryItems = items
        }
        guard let url = components.url else { throw LocalSendError.invalidResponse }
        return url
    }

    private func session(for device: LocalSendDevice) -> (URLSession, LocalSendTLSDelegate) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let delegate = LocalSendTLSDelegate(expectedFingerprint: device.fingerprint, encrypted: device.transport.lowercased() != "http")
        return (URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil), delegate)
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw LocalSendError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw LocalSendHTTPError.status(response.statusCode) }
    }

    private func promptForPIN(device: LocalSendDevice) -> String? {
        let alert = NSAlert()
        alert.messageText = "LocalSend PIN required"
        alert.informativeText = "Enter PIN shown on \(device.alias)."
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty else { return nil }
        return input.stringValue
    }

    private var senderFingerprint: String {
        let stored = Defaults[.localSendIdentity]
        if !stored.isEmpty { return stored }
        let generated = UUID().uuidString.lowercased()
        Defaults[.localSendIdentity] = generated
        return generated
    }

    private var senderInfo: LocalSendAnnouncement {
        LocalSendAnnouncement(
            alias: Host.current().localizedName ?? "boringNotch",
            version: "2.0",
            deviceModel: "Mac",
            deviceType: "desktop",
            fingerprint: senderFingerprint,
            port: Self.defaultPort,
            protocolName: "http",
            download: false,
            announce: false
        )
    }

    private func loadBindings() {
        guard let data = Defaults[.localSendBindings].data(using: .utf8),
              let decoded = try? JSONDecoder().decode([LocalSendBinding].self, from: data) else { return }
        bindings = Dictionary(uniqueKeysWithValues: decoded.map { ($0.destination, $0) })
    }

    private func persistBindings() {
        let values = LocalSendDestination.allCases.compactMap { bindings[$0] }
        guard let data = try? JSONEncoder().encode(values), let value = String(data: data, encoding: .utf8) else { return }
        Defaults[.localSendBindings] = value
    }

    private func cleanup(_ urls: [URL]) {
        urls.forEach { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: $0) }
    }
}

private struct LocalSendAnnouncement: Codable {
    let alias: String
    let version: String
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String
    let port: Int?
    let protocolName: String?
    let download: Bool?
    let announce: Bool?

    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, download, announce
        case protocolName = "protocol"
    }
}

private struct LocalSendPrepareUpload: Encodable {
    let info: LocalSendAnnouncement
    let files: [String: LocalSendFileMetadata]
}

private struct LocalSendFileMetadata: Encodable {
    let id: String
    let fileName: String
    let size: Int64
    let fileType: String
    let sha256: String?
    var url: URL

    enum CodingKeys: String, CodingKey { case id, fileName, size, fileType, sha256 }
}

private struct LocalSendPrepareResponse: Decodable {
    let sessionId: String
    let files: [String: String]
}

private enum LocalSendHTTPError: Error {
    case status(Int)
}

/// Task-scoped upload progress. Implements no auth challenge method on purpose:
/// a task delegate only overrides what it declares, so the session-level
/// LocalSendTLSDelegate keeps handling certificate pinning.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var lastPercent = -1

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let percent = Int(fraction * 100)
        // The delegate queue is serial per task, so this caps us at 100 hops
        // per file instead of one per packet.
        guard percent != lastPercent else { return }
        lastPercent = percent
        onProgress(fraction)
    }
}

private final class LocalSendTLSDelegate: NSObject, URLSessionDelegate {
    let expectedFingerprint: String
    let encrypted: Bool
    private(set) var didRejectServerTrust = false

    init(expectedFingerprint: String, encrypted: Bool) {
        self.expectedFingerprint = expectedFingerprint.lowercased()
        self.encrypted = encrypted
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard encrypted, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        guard fingerprint == expectedFingerprint else {
            didRejectServerTrust = true
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// Discovery is unauthenticated by design. A device becomes trusted only when
/// user binds its advertised fingerprint; transfer later pins that certificate.
private final class LocalSendDiscoveryTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Accumulates a complete HTTP register request. TCP may split headers and JSON
/// body across reads, so decoding first packet alone loses otherwise valid peers.
private final class LocalSendRegistrationConnection {
    private let connection: NWConnection
    private let response: Data
    private var request = Data()

    init(connection: NWConnection, response: Data) {
        self.connection = connection
        self.response = response
    }

    func receive() {
        connection.start(queue: .main)
        readMore()
    }

    private func readMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            guard error == nil, let data else {
                connection.cancel()
                return
            }
            request.append(data)
            if completeRequest || isComplete {
                finish()
            } else {
                readMore()
            }
        }
    }

    private var completeRequest: Bool {
        guard let headerRange = request.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let header = String(decoding: request[..<headerRange.lowerBound], as: UTF8.self)
        let contentLength = header
            .split(separator: "\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") } ?? 0
        return request.count >= headerRange.upperBound + contentLength
    }

    private func finish() {
        guard case let .hostPort(host, port) = connection.endpoint else {
            connection.cancel()
            return
        }
        let request = request
        Task { @MainActor in
            QuickShareService.shared.receiveRegistration(request, host: host.debugDescription, port: Int(port.rawValue))
        }
        connection.send(content: response, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }
}

// MARK: - Shelf transport router

/// Shelf owns routing. LocalSend stays default so existing paired devices and
/// familiar drop behavior keep working while KDE Connect remains opt-in.
enum ShelfShareTransport: String, CaseIterable, Codable, Identifiable {
    case localSend
    case kdeConnect

    var id: String { rawValue }
    var title: String { self == .localSend ? "LocalSend" : "KDE Connect" }
    var symbolName: String { self == .localSend ? "bolt.horizontal.circle" : "link.circle" }
}

@MainActor
final class ShelfShareService: ObservableObject {
    static let shared = ShelfShareService()

    @Published private(set) var selectedTransport: ShelfShareTransport
    @Published private(set) var selectedDestination: LocalSendDestination
    /// False when every provider is switched off. Shelf still holds files and
    /// still hands them to the macOS Share sheet; it just has nowhere of its
    /// own to send them.
    @Published private(set) var isAvailable = false

    let localSend = QuickShareService.shared
    let kdeConnect = KDEConnectService.shared

    private var cancellables = Set<AnyCancellable>()

    private init() {
        selectedTransport = ShelfShareTransport(rawValue: Defaults[.shelfShareTransport]) ?? .localSend
        selectedDestination = LocalSendDestination(rawValue: Defaults[.localSendDestination]) ?? .phone
        kdeConnect.select(selectedDestination)
        // Everything below is a computed forward to a child object, so without
        // this relay SwiftUI never learns that isSending/lastError/transfers moved.
        localSend.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        kdeConnect.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        Defaults.publisher(keys: .localSendEnabled, .kdeConnectEnabled)
            .sink { [weak self] in
                Task { @MainActor [weak self] in self?.syncTransport() }
            }
            .store(in: &cancellables)
        syncTransport()
    }

    /// Read from the setting rather than the service, so routing is correct on
    /// the same tick the switch flips regardless of which observer ran first.
    func isEnabled(_ transport: ShelfShareTransport) -> Bool {
        switch transport {
        case .localSend: Defaults[.localSendEnabled]
        case .kdeConnect: Defaults[.kdeConnectEnabled]
        }
    }

    /// Keeps the routed transport on a provider that is actually running, so
    /// switching one off moves Shelf to the other rather than sending into a
    /// service that no longer has a socket open.
    private func syncTransport() {
        let enabled = ShelfShareTransport.allCases.filter(isEnabled)
        isAvailable = !enabled.isEmpty
        guard let fallback = enabled.first, !isEnabled(selectedTransport) else { return }
        select(fallback)
    }

    var transfers: [UUID: ShelfTransferState] {
        switch selectedTransport {
        case .localSend: localSend.transfers
        case .kdeConnect: kdeConnect.transfers
        }
    }

    var sendFraction: Double {
        switch selectedTransport {
        case .localSend: localSend.sendFraction
        case .kdeConnect: kdeConnect.sendFraction
        }
    }

    var isDiscovering: Bool {
        switch selectedTransport {
        case .localSend: localSend.isDiscovering
        case .kdeConnect: kdeConnect.isDiscovering
        }
    }

    var completedFileCount: Int {
        switch selectedTransport {
        case .localSend: localSend.completedFileCount
        case .kdeConnect: kdeConnect.completedFileCount
        }
    }

    var totalFileCount: Int {
        switch selectedTransport {
        case .localSend: localSend.totalFileCount
        case .kdeConnect: kdeConnect.totalFileCount
        }
    }

    func clearTransfers() {
        localSend.clearTransfers()
        kdeConnect.clearTransfers()
    }

    var selectedDestinationReady: Bool {
        switch selectedTransport {
        case .localSend: localSend.isOnline(selectedDestination)
        case .kdeConnect: kdeConnect.isOnline(selectedDestination)
        }
    }

    var isSending: Bool {
        switch selectedTransport {
        case .localSend: localSend.isSending
        case .kdeConnect: kdeConnect.isSending
        }
    }

    var progressLabel: String? {
        switch selectedTransport {
        case .localSend: localSend.progressLabel
        case .kdeConnect: kdeConnect.progressLabel
        }
    }

    var lastError: String? {
        switch selectedTransport {
        case .localSend: localSend.lastError
        case .kdeConnect: kdeConnect.lastError
        }
    }

    func isPaired(_ destination: LocalSendDestination) -> Bool {
        switch selectedTransport {
        case .localSend: localSend.isPaired(destination)
        case .kdeConnect: kdeConnect.isPaired(destination)
        }
    }

    func select(_ transport: ShelfShareTransport) {
        selectedTransport = transport
        Defaults[.shelfShareTransport] = transport.rawValue
    }

    func select(_ destination: LocalSendDestination) {
        selectedDestination = destination
        localSend.select(destination)
        kdeConnect.select(destination)
        clearTransfers()
    }

    func refreshDiscovery() {
        guard isAvailable else { return }
        switch selectedTransport {
        case .localSend: localSend.refreshDiscovery()
        case .kdeConnect: kdeConnect.refreshDiscovery()
        }
    }

    func showFilePicker() async {
        guard isAvailable else { return }
        switch selectedTransport {
        case .localSend:
            localSend.select(selectedDestination)
            await localSend.showFilePicker()
        case .kdeConnect:
            kdeConnect.select(selectedDestination)
            await kdeConnect.showFilePicker()
        }
    }

    func shareDroppedFiles(_ providers: [NSItemProvider]) async {
        guard isAvailable else { return }
        switch selectedTransport {
        case .localSend:
            localSend.select(selectedDestination)
            await localSend.shareDroppedFiles(providers)
        case .kdeConnect:
            kdeConnect.select(selectedDestination)
            await kdeConnect.shareDroppedFiles(providers)
        }
    }

    func shareShelfItems(_ items: [ShelfItem], to destination: LocalSendDestination? = nil) async {
        guard isAvailable else { return }
        let destination = destination ?? selectedDestination
        switch selectedTransport {
        case .localSend:
            await localSend.shareShelfItems(items, to: destination)
        case .kdeConnect:
            await kdeConnect.shareShelfItems(items, to: destination)
        }
    }
}

// MARK: - Native KDE Connect

/// KDE Connect LAN protocol v8 sender. This is protocol code, not a bridge to
/// a separately installed KDE Connect desktop app.
struct KDEConnectDevice: Codable, Hashable, Identifiable {
    let deviceID: String
    var name: String
    var type: String
    var host: String
    var port: UInt16
    var certificateDER: Data
    var lastSeen: Date
    var supportsShare: Bool

    var id: String { deviceID }
    var displayName: String { "\(name) (\(type))" }
}

struct KDEConnectBinding: Codable, Equatable {
    let destination: LocalSendDestination
    var device: KDEConnectDevice
}

enum KDEConnectError: LocalizedError {
    case unpaired(LocalSendDestination)
    case offline(LocalSendDestination)
    case certificateChanged
    case pairingRejected
    case pairingTimedOut
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unpaired(let destination): return "Pair \(destination.title) in Shelf settings first."
        case .offline(let destination): return "\(destination.title) is offline. Open KDE Connect on same Wi-Fi."
        case .certificateChanged: return "KDE Connect device certificate changed. Forget then pair again."
        case .pairingRejected: return "KDE Connect pairing was rejected."
        case .pairingTimedOut: return "KDE Connect pairing timed out."
        case .unavailable(let message): return message
        }
    }
}

private enum KDEConnectProtocol {
    static let udpPort: UInt16 = 1716
    static let tcpPort: UInt16 = 1716
    static let payloadPort: UInt16 = 1717
    static let protocolVersion = 8
    static let deviceTTL: TimeInterval = 30
    static let identity = "kdeconnect.identity"
    static let pair = "kdeconnect.pair"
    static let share = "kdeconnect.share.request"
}

/// Persistent P-256 Keychain identity. KDE Connect peers identify each other
/// with certificate pins, so this must survive app rebuilds and relaunches.
private final class KDECertificateIdentity {
    static let shared = KDECertificateIdentity()

    private let pkcs12Service = "theboringteam.boringnotch.kdeconnect.identity"
    private let pkcs12Account = "tls-p12"
    private let deviceIDDefaultsKey = "kdeConnectDeviceID"
    private(set) var identity: SecIdentity?
    private(set) var certificateDER = Data()
    private(set) var publicKeyDER = Data()
    private(set) var deviceID = ""

    private init() {
        do {
            try loadOrCreate()
            UserDefaults.standard.removeObject(forKey: "kdeConnectIdentityError")
        } catch {
            NSLog("KDE Connect identity unavailable: %@", error.localizedDescription)
            UserDefaults.standard.set(error.localizedDescription, forKey: "kdeConnectIdentityError")
            identity = nil
        }
    }

    private func loadOrCreate() throws {
        if let stored = loadPKCS12(),
           let storedDeviceID = UserDefaults.standard.string(forKey: deviceIDDefaultsKey),
           let existing = try? importIdentity(stored),
           try configure(existing, fallbackDeviceID: storedDeviceID) {
            return
        }

        let generatedID = UUID().uuidString.lowercased()
        var generationError: NSError?
        guard let pkcs12 = KDECreatePKCS12Identity(generatedID, &generationError) else {
            throw generationError ?? KDEConnectError.unavailable("KDE Connect certificate creation failed.")
        }
        let created = try importIdentity(pkcs12)

        guard try configure(created, fallbackDeviceID: generatedID), deviceID == generatedID else {
            throw KDEConnectError.unavailable("KDE Connect certificate identity is invalid.")
        }
        try storePKCS12(pkcs12)
        UserDefaults.standard.set(generatedID, forKey: deviceIDDefaultsKey)
    }

    private func importIdentity(_ pkcs12: Data) throws -> SecIdentity {
        var imported: CFArray?
        let options = [kSecImportExportPassphrase as String: ""] as CFDictionary
        let status = SecPKCS12Import(pkcs12 as CFData, options, &imported)
        guard status == errSecSuccess,
              let item = (imported as? [[String: Any]])?.first,
              let rawIdentity = item[kSecImportItemIdentity as String] else {
            throw KDEConnectError.unavailable("KDE Connect certificate import failed (\(status)).")
        }
        return rawIdentity as! SecIdentity
    }

    private func loadPKCS12() -> Data? {
        var result: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: pkcs12Service,
            kSecAttrAccount: pkcs12Account,
            kSecReturnData: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func storePKCS12(_ value: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: pkcs12Service,
            kSecAttrAccount: pkcs12Account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = value
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KDEConnectError.unavailable("KDE Connect certificate storage failed (\(status)).")
        }
    }

    @discardableResult
    private func configure(_ value: SecIdentity, fallbackDeviceID: String? = nil) throws -> Bool {
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(value, &certificate)
        guard let certificate,
              let commonName = (try Self.commonName(certificate)) ?? fallbackDeviceID,
              UUID(uuidString: commonName) != nil else { return false }
        identity = value
        certificateDER = SecCertificateCopyData(certificate) as Data
        publicKeyDER = try Self.publicKeyDER(certificate)
        deviceID = commonName.lowercased()
        return true
    }

    private static func publicKeyDER(_ certificate: SecCertificate) throws -> Data {
        guard let key = SecCertificateCopyKey(certificate),
              let publicData = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw KDEConnectError.unavailable("KDE Connect certificate public key unavailable.")
        }
        return derSequence([
            derSequence([derObjectIdentifier("1.2.840.10045.2.1"), derObjectIdentifier("1.2.840.10045.3.1.7")]),
            derBitString(publicData)
        ])
    }

    private static func commonName(_ certificate: SecCertificate) throws -> String? {
        let values = SecCertificateCopyValues(certificate, [kSecOIDCommonName] as CFArray, nil) as? [CFString: Any]
        let name = values?[kSecOIDCommonName] as? [CFString: Any]
        return name?[kSecPropertyKeyValue] as? String
    }

    func verificationCode(remoteCertificateDER: Data, timestamp: Int64) -> String? {
        guard let remote = SecCertificateCreateWithData(nil, remoteCertificateDER as CFData),
              let remoteKey = try? Self.publicKeyDER(remote) else { return nil }
        let ordered = [publicKeyDER, remoteKey].sorted { $0.lexicographicallyPrecedes($1) }
        var material = Data()
        material.append(contentsOf: ordered[0])
        material.append(contentsOf: ordered[1])
        material.append(Data(String(timestamp).utf8))
        return SHA256.hash(data: material).map { String(format: "%02X", $0) }.joined().prefix(8).description
    }

    private static func derSequence(_ values: [Data]) -> Data { der(0x30, values.reduce(into: Data(), { $0.append($1) })) }
    private static func derBitString(_ value: Data) -> Data { der(0x03, Data([0]) + value) }
    private static func derObjectIdentifier(_ oid: String) -> Data {
        let numbers = oid.split(separator: ".").compactMap { UInt64($0) }
        guard numbers.count >= 2 else { return Data() }
        var bytes = [UInt8(numbers[0] * 40 + numbers[1])]
        for number in numbers.dropFirst(2) {
            var value = number
            var encoded = [UInt8(value & 0x7f)]
            value >>= 7
            while value > 0 { encoded.insert(UInt8(value & 0x7f) | 0x80, at: 0); value >>= 7 }
            bytes += encoded
        }
        return der(0x06, Data(bytes))
    }
    private static func der(_ tag: UInt8, _ value: Data) -> Data {
        var output = Data([tag])
        if value.count < 128 { output.append(UInt8(value.count)) }
        else {
            var length = value.count
            var bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 0xff), at: 0); length >>= 8 }
            output.append(0x80 | UInt8(bytes.count)); output.append(contentsOf: bytes)
        }
        output.append(value)
        return output
    }
}

@MainActor
final class KDEConnectService: NSObject, ObservableObject {
    static let shared = KDEConnectService()

    @Published private(set) var availableDevices: [KDEConnectDevice] = []
    @Published private(set) var bindings: [LocalSendDestination: KDEConnectBinding] = [:]
    @Published private(set) var selectedDestination: LocalSendDestination = .phone
    @Published private(set) var isDiscovering = false
    @Published private(set) var isSending = false
    @Published private(set) var completedFileCount = 0
    @Published private(set) var totalFileCount = 0
    @Published private(set) var transfers: [UUID: ShelfTransferState] = [:]
    @Published var lastError: String?
    /// Off means off: no TLS identity, no UDP or control listener, no Bonjour
    /// publish or browse — so no local network prompt on this provider's behalf.
    @Published private(set) var isEnabled = false

    private var transferClearTask: Task<Void, Never>?

    /// Lazy on purpose: reading it creates the Keychain identity, and a
    /// disabled provider must not do that.
    private lazy var identity = KDECertificateIdentity.shared
    private var udpListener: NWListener?
    private var controlListener: NWListener?
    private var links: [String: KDEControlLink] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pendingPairs: [String: (destination: LocalSendDestination, timestamp: Int64)] = [:]
    private var netService: NetService?
    private var bonjourBrowser: NWBrowser?
    private var bonjourConnections: [UUID: NWConnection] = [:]
    private var enabledObserver: AnyCancellable?

    private override init() {
        super.init()
        selectedDestination = LocalSendDestination(rawValue: Defaults[.localSendDestination]) ?? .phone
        loadBindings()
        Self.migrateEnabledFlagIfNeeded(hasBindings: !bindings.isEmpty)
        isEnabled = Defaults[.kdeConnectEnabled]
        observeEnabled()
        guard isEnabled else { return }
        startNetworking()
    }

    /// KDE Connect used to run unconditionally, so anyone with a paired device
    /// gets the new switch already on. Everyone else starts opt-in and is never
    /// asked for the local network permission until they ask for the provider.
    private static func migrateEnabledFlagIfNeeded(hasBindings: Bool) {
        guard !Defaults[.didMigrateKDEConnectEnabled] else { return }
        Defaults[.didMigrateKDEConnectEnabled] = true
        if hasBindings { Defaults[.kdeConnectEnabled] = true }
    }

    deinit {
        discoveryTask?.cancel()
        refreshTask?.cancel()
        udpListener?.cancel()
        controlListener?.cancel()
        bonjourBrowser?.cancel()
        links.values.forEach { $0.cancel() }
    }

    var selectedDevice: KDEConnectDevice? { device(for: selectedDestination) }
    var selectedDestinationReady: Bool { isOnline(selectedDestination) }
    var progressLabel: String? {
        guard isSending else { return nil }
        return "Sending \(completedFileCount) of \(totalFileCount)"
    }
    var nearbyDevices: [KDEConnectDevice] {
        availableDevices.filter { $0.lastSeen.addingTimeInterval(KDEConnectProtocol.deviceTTL) > .now }
    }

    /// Matches QuickShareService.sendFraction so the router can forward either.
    var sendFraction: Double {
        guard isSending, totalFileCount > 0 else { return 0 }
        let inFlight = transfers.values.compactMap { state -> Double? in
            if case .sending(let fraction) = state { return fraction }
            return nil
        }.max() ?? 0
        return min(1, (Double(completedFileCount) + inFlight) / Double(totalFileCount))
    }

    func clearTransfers() {
        transferClearTask?.cancel()
        transferClearTask = nil
        transfers.removeAll()
    }

    func select(_ destination: LocalSendDestination) {
        selectedDestination = destination
        lastError = nil
    }

    func binding(for destination: LocalSendDestination) -> KDEConnectBinding? { bindings[destination] }
    func device(for destination: LocalSendDestination) -> KDEConnectDevice? {
        guard let binding = bindings[destination] else { return nil }
        return nearbyDevices.first(where: { $0.deviceID == binding.device.deviceID && $0.certificateDER == binding.device.certificateDER })
    }
    func isPaired(_ destination: LocalSendDestination) -> Bool { bindings[destination] != nil }
    func isOnline(_ destination: LocalSendDestination) -> Bool { device(for: destination) != nil && links[bindings[destination]?.device.deviceID ?? ""] != nil }

    func refreshDiscovery() {
        guard isEnabled else { return }
        lastError = nil
        pruneExpiredDevices()
        isDiscovering = true
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.isDiscovering = false
        }
        announceIdentity()
    }

    private func observeEnabled() {
        enabledObserver = Defaults.publisher(.kdeConnectEnabled)
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor [weak self] in self?.setEnabled(enabled) }
            }
    }

    private func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        lastError = nil
        if enabled {
            startNetworking()
        } else {
            stopNetworking()
        }
    }

    private func startNetworking() {
        guard identity.identity != nil else {
            lastError = "KDE Connect identity unavailable. Open Shelf settings after restarting app."
            return
        }
        startListeners()
        startDiscovery()
    }

    /// Pairings survive being switched off — they are certificate pins, and
    /// throwing them away would mean re-verifying a code on the phone.
    private func stopNetworking() {
        discoveryTask?.cancel()
        discoveryTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        udpListener?.cancel()
        udpListener = nil
        controlListener?.cancel()
        controlListener = nil
        netService?.stop()
        netService = nil
        bonjourBrowser?.cancel()
        bonjourBrowser = nil
        bonjourConnections.values.forEach { $0.cancel() }
        bonjourConnections.removeAll()
        links.values.forEach { $0.cancel() }
        links.removeAll()
        pendingPairs.removeAll()
        availableDevices.removeAll()
        isDiscovering = false
    }

    func beginPair(_ device: KDEConnectDevice, to destination: LocalSendDestination) {
        guard isEnabled else { return }
        guard !device.certificateDER.isEmpty else {
            lastError = "KDE Connect TLS identity unavailable for \(device.name). Refresh then try again."
            return
        }
        guard let link = links[device.deviceID] else {
            establishLink(to: device)
            lastError = "Connecting to \(device.name). Choose Pair again when it shows online."
            return
        }
        let timestamp = Int64(Date().timeIntervalSince1970)
        let code = identity.verificationCode(remoteCertificateDER: device.certificateDER, timestamp: timestamp) ?? "Unavailable"
        let alert = NSAlert()
        alert.messageText = "Pair with \(device.name)?"
        alert.informativeText = "Verify this code matches KDE Connect on other device:\n\n\(code)\n\nPairing is needed once."
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        pendingPairs[device.deviceID] = (destination, timestamp)
        link.send(type: KDEConnectProtocol.pair, body: ["pair": true, "timestamp": timestamp])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, self.pendingPairs.removeValue(forKey: device.deviceID) != nil else { return }
            self.lastError = KDEConnectError.pairingTimedOut.localizedDescription
        }
    }

    func unbind(_ destination: LocalSendDestination) {
        guard let binding = bindings.removeValue(forKey: destination) else { return }
        links[binding.device.deviceID]?.send(type: KDEConnectProtocol.pair, body: ["pair": false])
        persistBindings()
    }

    func showFilePicker() async {
        guard !isSending else { return }
        guard selectedDestinationReady else {
            lastError = isPaired(selectedDestination)
                ? KDEConnectError.offline(selectedDestination).localizedDescription
                : KDEConnectError.unpaired(selectedDestination).localizedDescription
            return
        }
        SharingStateManager.shared.beginInteraction()
        defer { SharingStateManager.shared.endInteraction() }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Send to \(selectedDestination.title)"
        panel.message = "Choose files for KDE Connect"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        await send(fileURLs: panel.urls, text: [], links: [], temporaryURLs: [], to: selectedDestination)
    }

    func shareDroppedFiles(_ providers: [NSItemProvider]) async {
        var files: [URL] = []
        var texts: [String] = []
        var links: [URL] = []
        for provider in providers {
            if let url = await provider.extractURL() {
                url.isFileURL ? files.append(url) : links.append(url)
            } else if let text = await provider.extractText() {
                texts.append(text)
            } else if let file = await provider.extractItem() {
                files.append(file)
            }
        }
        await send(fileURLs: files, text: texts, links: links, temporaryURLs: [], to: selectedDestination)
    }

    func shareShelfItems(_ items: [ShelfItem], to destination: LocalSendDestination? = nil) async {
        var files: [URL] = []
        var texts: [String] = []
        var links: [URL] = []
        // KDE Connect sends text and links as inline packets rather than files,
        // so the item ids ride along as arrays parallel to each payload list.
        var fileItemIDs: [URL: [UUID]] = [:]
        var textItemIDs: [UUID] = []
        var linkItemIDs: [UUID] = []
        for item in items {
            switch item.kind {
            case .file:
                if let file = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item) {
                    files.append(file)
                    fileItemIDs[file.standardizedFileURL, default: []].append(item.id)
                }
            case .text(let text):
                texts.append(text)
                textItemIDs.append(item.id)
            case .link(let link):
                links.append(link)
                linkItemIDs.append(item.id)
            }
        }
        await send(
            fileURLs: files,
            text: texts,
            links: links,
            temporaryURLs: [],
            to: destination ?? selectedDestination,
            fileItemIDs: fileItemIDs,
            inlineItemIDs: textItemIDs + linkItemIDs
        )
    }

    fileprivate func setTransfer(_ state: ShelfTransferState, forURL url: URL, in map: [URL: [UUID]]) {
        for id in map[url.standardizedFileURL] ?? [] { transfers[id] = state }
    }

    fileprivate func setTransfers(_ state: ShelfTransferState, for ids: [UUID]) {
        for id in ids { transfers[id] = state }
    }

    fileprivate func seedTransfers(_ ids: [UUID]) {
        transferClearTask?.cancel()
        transferClearTask = nil
        transfers = Dictionary(uniqueKeysWithValues: ids.map { ($0, .pending) })
    }

    fileprivate func failRemainingTransfers(with reason: String) {
        for (id, state) in transfers where !state.isTerminal { transfers[id] = .failed(reason) }
    }

    fileprivate func finishTransfers() {
        guard !transfers.isEmpty else { return }
        let sentIDs = transfers.compactMap { $0.value == .sent ? $0.key : nil }
        transferClearTask?.cancel()
        transferClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self, !self.isSending else { return }
            if Defaults[.autoRemoveShelfItems], !sentIDs.isEmpty {
                ShelfStateViewModel.shared.removeItems(withIDs: Set(sentIDs))
            }
            self.transfers.removeAll()
            self.transferClearTask = nil
        }
    }

    // MARK: Discovery and control links

    private func startListeners() {
        guard let localIdentity = identity.identity else { return }
        do {
            let udp = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: KDEConnectProtocol.udpPort)!)
            udp.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.receiveUDP(connection) }
            }
            udp.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { Task { @MainActor in self?.lastError = "KDE Connect discovery failed: \(error.localizedDescription)" } }
            }
            udpListener = udp
            udp.start(queue: .main)

            let control = try NWListener(using: kdeTLSParameters(identity: localIdentity, expectedCertificate: nil), on: NWEndpoint.Port(rawValue: KDEConnectProtocol.tcpPort)!)
            control.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.acceptControl(connection) }
            }
            control.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { Task { @MainActor in self?.lastError = "KDE Connect listener failed: \(error.localizedDescription)" } }
            }
            controlListener = control
            control.start(queue: .main)
            let service = NetService(domain: "", type: "_kdeconnect._udp.", name: identity.deviceID, port: Int32(KDEConnectProtocol.tcpPort))
            service.setTXTRecord(NetService.data(fromTXTRecord: [
                "id": Data(identity.deviceID.utf8),
                "name": Data((Host.current().localizedName ?? "boringNotch").utf8),
                "type": Data("desktop".utf8),
                "protocol": Data("\(KDEConnectProtocol.protocolVersion)".utf8)
            ]))
            service.includesPeerToPeer = true
            service.publish()
            netService = service
            let browserParameters = NWParameters.udp
            browserParameters.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_kdeconnect._udp", domain: ""), using: browserParameters)
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                guard case .ready = state, let browser else { return }
                Task { @MainActor in self?.announceIdentity(to: browser.browseResults) }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.announceIdentity(to: results) }
            }
            bonjourBrowser = browser
            browser.start(queue: .main)
        } catch {
            lastError = "KDE Connect listener unavailable: \(error.localizedDescription)"
        }
    }

    private func startDiscovery() {
        refreshDiscovery()
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.pruneExpiredDevices()
                self?.announceIdentity()
            }
        }
    }

    private func receiveUDP(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receiveMessage { [weak self] data, _, _, _ in
            defer { connection.cancel() }
            guard let data,
                  case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint else { return }
            Task { @MainActor in self?.receiveIdentity(data, host: host.debugDescription) }
        }
    }

    private func announceIdentity() {
        guard let data = identityPacket() else { return }
        var error: NSError?
        if !KDESendUDPBroadcast(data, &error) {
            lastError = error?.localizedDescription ?? "KDE Connect discovery broadcast failed."
        }
    }

    private func announceIdentity(to results: Set<NWBrowser.Result>) {
        guard let packet = identityPacket() else { return }
        for result in results {
            if case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint,
               name == identity.deviceID { continue }
            let token = UUID()
            let connection = NWConnection(to: result.endpoint, using: .udp)
            bonjourConnections[token] = connection
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    connection.send(content: packet, completion: .contentProcessed { _ in
                        connection.cancel()
                        Task { @MainActor in self?.bonjourConnections.removeValue(forKey: token) }
                    })
                case .failed, .cancelled:
                    Task { @MainActor in self?.bonjourConnections.removeValue(forKey: token) }
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    private func identityPacket() -> Data? {
        KDEPacket.make(type: KDEConnectProtocol.identity, body: [
            "deviceId": identity.deviceID,
            "deviceName": Host.current().localizedName ?? "boringNotch",
            "deviceType": "desktop",
            "protocolVersion": KDEConnectProtocol.protocolVersion,
            "tcpPort": KDEConnectProtocol.tcpPort,
            "incomingCapabilities": [KDEConnectProtocol.share, KDEConnectProtocol.pair],
            "outgoingCapabilities": [KDEConnectProtocol.share, KDEConnectProtocol.pair]
        ])
    }

    private func receiveIdentity(_ data: Data, host: String) {
        guard let packet = KDEPacket.parse(data), packet.type == KDEConnectProtocol.identity,
              let identifier = packet.body["deviceId"] as? String,
              identifier != identity.deviceID,
              let name = packet.body["deviceName"] as? String else { return }
        let port = UInt16((packet.body["tcpPort"] as? NSNumber)?.uint16Value ?? KDEConnectProtocol.tcpPort)
        let capabilities = (packet.body["incomingCapabilities"] as? [String] ?? [])
            + (packet.body["outgoingCapabilities"] as? [String] ?? [])
        let device = KDEConnectDevice(
            deviceID: identifier,
            name: name,
            type: packet.body["deviceType"] as? String ?? "device",
            host: host,
            port: port,
            certificateDER: links[identifier]?.remoteCertificateDER ?? availableDevices.first(where: { $0.deviceID == identifier })?.certificateDER ?? Data(),
            lastSeen: .now,
            supportsShare: capabilities.contains(KDEConnectProtocol.share)
        )
        guard device.supportsShare else { return }
        upsert(device)
        establishLink(to: device)
    }

    private func acceptControl(_ connection: NWConnection) {
        let host: String
        if case let .hostPort(endpointHost, _)? = connection.currentPath?.remoteEndpoint { host = endpointHost.debugDescription }
        else { host = "" }
        let link = KDEControlLink(connection: connection, host: host, owner: self)
        link.start()
    }

    private func establishLink(to device: KDEConnectDevice) {
        guard links[device.deviceID] == nil, let localIdentity = identity.identity else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(device.host), port: NWEndpoint.Port(rawValue: device.port) ?? NWEndpoint.Port(rawValue: KDEConnectProtocol.tcpPort)!)
        var capturedLink: KDEControlLink?
        let connection = NWConnection(
            to: endpoint,
            using: kdeTLSParameters(
                identity: localIdentity,
                expectedCertificate: bindings.values.first(where: { $0.device.deviceID == device.deviceID })?.device.certificateDER,
                certificateCapture: { capturedLink?.setRemoteCertificate($0) }
            )
        )
        let link = KDEControlLink(connection: connection, host: device.host, owner: self)
        capturedLink = link
        links[device.deviceID] = link
        link.start()
    }

    fileprivate func controlReady(_ link: KDEControlLink) {
        guard let packet = identityPacket() else { return }
        link.send(raw: packet)
    }

    fileprivate func controlClosed(_ link: KDEControlLink) {
        guard let identifier = link.deviceID else { return }
        if links[identifier] === link { links.removeValue(forKey: identifier) }
    }

    fileprivate func receiveControlPacket(_ packet: KDEPacket, from link: KDEControlLink) {
        switch packet.type {
        case KDEConnectProtocol.identity:
            receiveControlIdentity(packet, link: link)
        case KDEConnectProtocol.pair:
            receivePair(packet, link: link)
        default:
            break
        }
    }

    private func receiveControlIdentity(_ packet: KDEPacket, link: KDEControlLink) {
        guard let identifier = packet.body["deviceId"] as? String,
              identifier != identity.deviceID,
              let name = packet.body["deviceName"] as? String,
              let certificate = link.remoteCertificateDER, !certificate.isEmpty else {
            link.cancel()
            return
        }
        let port = UInt16((packet.body["tcpPort"] as? NSNumber)?.uint16Value ?? KDEConnectProtocol.tcpPort)
        let capabilities = (packet.body["incomingCapabilities"] as? [String] ?? [])
            + (packet.body["outgoingCapabilities"] as? [String] ?? [])
        let device = KDEConnectDevice(
            deviceID: identifier,
            name: name,
            type: packet.body["deviceType"] as? String ?? "device",
            host: link.host,
            port: port,
            certificateDER: certificate,
            lastSeen: .now,
            supportsShare: capabilities.contains(KDEConnectProtocol.share)
        )
        if let binding = bindings.values.first(where: { $0.device.deviceID == identifier }), binding.device.certificateDER != certificate {
            lastError = KDEConnectError.certificateChanged.localizedDescription
            link.cancel()
            return
        }
        link.deviceID = identifier
        links[identifier] = link
        upsert(device)
    }

    private func receivePair(_ packet: KDEPacket, link: KDEControlLink) {
        guard let identifier = link.deviceID,
              let device = availableDevices.first(where: { $0.deviceID == identifier }) else { return }
        let wantsPair = (packet.body["pair"] as? NSNumber)?.boolValue ?? false
        guard wantsPair else {
            pendingPairs.removeValue(forKey: identifier)
            lastError = KDEConnectError.pairingRejected.localizedDescription
            return
        }
        if let pending = pendingPairs.removeValue(forKey: identifier) {
            bind(device, to: pending.destination)
            return
        }
        let timestamp = (packet.body["timestamp"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970)
        guard abs(Int64(Date().timeIntervalSince1970) - timestamp) <= 1_800 else {
            lastError = "KDE Connect pairing failed: device clocks differ by over 30 minutes."
            return
        }
        let code = identity.verificationCode(remoteCertificateDER: device.certificateDER, timestamp: timestamp) ?? "Unavailable"
        let alert = NSAlert()
        alert.messageText = "Pair request from \(device.name)"
        alert.informativeText = "Verify this code matches KDE Connect on other device:\n\n\(code)"
        alert.addButton(withTitle: "Pair as Phone")
        alert.addButton(withTitle: "Pair as TV")
        alert.addButton(withTitle: "Reject")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            bind(device, to: .phone)
            link.send(type: KDEConnectProtocol.pair, body: ["pair": true])
        case .alertSecondButtonReturn:
            bind(device, to: .tv)
            link.send(type: KDEConnectProtocol.pair, body: ["pair": true])
        default:
            link.send(type: KDEConnectProtocol.pair, body: ["pair": false])
        }
    }

    private func bind(_ device: KDEConnectDevice, to destination: LocalSendDestination) {
        bindings[destination] = KDEConnectBinding(destination: destination, device: device)
        persistBindings()
        lastError = nil
    }

    private func upsert(_ device: KDEConnectDevice) {
        if let index = availableDevices.firstIndex(where: { $0.deviceID == device.deviceID }) { availableDevices[index] = device }
        else { availableDevices.append(device); availableDevices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
        for destination in LocalSendDestination.allCases where bindings[destination]?.device.deviceID == device.deviceID {
            bindings[destination] = KDEConnectBinding(destination: destination, device: device)
        }
        persistBindings()
    }

    private func pruneExpiredDevices() {
        let cutoff = Date().addingTimeInterval(-KDEConnectProtocol.deviceTTL)
        availableDevices.removeAll { $0.lastSeen < cutoff }
    }

    private func loadBindings() {
        guard let data = Defaults[.kdeConnectBindings].data(using: .utf8),
              let decoded = try? JSONDecoder().decode([KDEConnectBinding].self, from: data) else { return }
        bindings = Dictionary(uniqueKeysWithValues: decoded.map { ($0.destination, $0) })
    }

    private func persistBindings() {
        let values = LocalSendDestination.allCases.compactMap { bindings[$0] }
        guard let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) else { return }
        Defaults[.kdeConnectBindings] = text
    }

}

private func kdeTLSParameters(identity: SecIdentity, expectedCertificate: Data?, certificateCapture: ((Data) -> Void)? = nil) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate]
        let leaf = chain?.first.map { SecCertificateCopyData($0) as Data }
        if let leaf { certificateCapture?(leaf) }
        guard let expectedCertificate else { complete(true); return }
        complete(leaf == expectedCertificate)
    }, DispatchQueue.main)
    return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
}

private struct KDEPacket {
    let type: String
    let body: [String: Any]

    static func make(type: String, body: [String: Any], payloadSize: Int? = nil, payloadPort: UInt16? = nil) -> Data? {
        var packet: [String: Any] = ["id": Int64(Date().timeIntervalSince1970 * 1000), "type": type, "body": body]
        if let payloadSize, let payloadPort {
            packet["payloadSize"] = payloadSize
            packet["payloadTransferInfo"] = ["port": Int(payloadPort)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: packet, options: []) else { return nil }
        return data + Data([0x0A])
    }

    static func parse(_ data: Data) -> KDEPacket? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let packet = object as? [String: Any],
              let type = packet["type"] as? String,
              let body = packet["body"] as? [String: Any] else { return nil }
        return KDEPacket(type: type, body: body)
    }
}

private final class KDEControlLink {
    private let connection: NWConnection
    private weak var owner: KDEConnectService?
    private var buffer = Data()
    private var didClose = false
    var deviceID: String?
    let host: String
    private(set) var remoteCertificateDER: Data?

    init(connection: NWConnection, host: String, owner: KDEConnectService) {
        self.connection = connection
        self.host = host
        self.owner = owner
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { @MainActor in self.owner?.controlReady(self) }
                self.readMore()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func send(type: String, body: [String: Any]) {
        guard let data = KDEPacket.make(type: type, body: body) else { return }
        send(raw: data)
    }

    func send(raw: Data) {
        connection.send(content: raw, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    func setRemoteCertificate(_ certificate: Data) {
        remoteCertificateDER = certificate
    }

    func cancel() { connection.cancel() }

    private func readMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            guard error == nil else { self.close(); return }
            if let data { self.buffer.append(data); self.consumePackets() }
            if complete { self.close() } else { self.readMore() }
        }
    }

    private func consumePackets() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let packetData = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let packet = KDEPacket.parse(packetData) else { continue }
            Task { @MainActor in self.owner?.receiveControlPacket(packet, from: self) }
        }
    }

    private func close() {
        guard !didClose else { return }
        didClose = true
        connection.cancel()
        Task { @MainActor in self.owner?.controlClosed(self) }
    }
}

private final class KDEPayloadServer: @unchecked Sendable {
    private let identity: SecIdentity
    private let expectedCertificate: Data
    private let fileURL: URL
    private let totalBytes: Int64
    private let onProgress: (@Sendable (Double) -> Void)?
    private var listener: NWListener?
    private var completion: CheckedContinuation<Void, Error>?
    private var complete = false
    private var streamer: KDEFileStreamer?

    init(
        identity: SecIdentity,
        expectedCertificate: Data,
        fileURL: URL,
        totalBytes: Int64 = 0,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) {
        self.identity = identity
        self.expectedCertificate = expectedCertificate
        self.fileURL = fileURL
        self.totalBytes = totalBytes
        self.onProgress = onProgress
    }

    func start() async throws -> UInt16 {
        let parameters = kdeTLSParameters(identity: identity, expectedCertificate: expectedCertificate)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: KDEConnectProtocol.payloadPort)!)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.sendFile(on: connection) }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    continuation.resume(returning: listener.port?.rawValue ?? KDEConnectProtocol.payloadPort)
                case .failed(let error):
                    continuation.resume(throwing: error)
                    self?.listener = nil
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    func waitForTransfer() async throws {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard let self, !self.complete else { return }
                self.finish(.failure(KDEConnectError.unavailable("KDE Connect receiver did not connect for file transfer.")))
            }
        }
    }

    private func sendFile(on connection: NWConnection) {
        connection.start(queue: .main)
        let streamer = KDEFileStreamer(
            connection: connection,
            fileURL: fileURL,
            totalBytes: totalBytes,
            onProgress: onProgress
        ) { [weak self] result in
            self?.finish(result)
        }
        self.streamer = streamer
        streamer.start()
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !complete else { return }
        complete = true
        listener?.cancel()
        listener = nil
        streamer = nil
        guard let completion else { return }
        self.completion = nil
        switch result {
        case .success: completion.resume()
        case .failure(let error): completion.resume(throwing: error)
        }
    }
}

private final class KDEFileStreamer {
    private let connection: NWConnection
    private let fileURL: URL
    private let totalBytes: Int64
    private let onProgress: (@Sendable (Double) -> Void)?
    private let completion: (Result<Void, Error>) -> Void
    private var file: FileHandle?
    private var finished = false
    private var bytesSent: Int64 = 0
    private var lastPercent = -1

    init(
        connection: NWConnection,
        fileURL: URL,
        totalBytes: Int64 = 0,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.connection = connection
        self.fileURL = fileURL
        self.totalBytes = totalBytes
        self.onProgress = onProgress
        self.completion = completion
    }

    func start() {
        do {
            file = try FileHandle(forReadingFrom: fileURL)
            sendNextChunk()
        } catch {
            finish(.failure(error))
        }
    }

    private func sendNextChunk() {
        guard let file else { finish(.success(())); return }
        do {
            let chunk = try file.read(upToCount: 64 * 1024) ?? Data()
            guard !chunk.isEmpty else { finish(.success(())); return }
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error { self.finish(.failure(error)) }
                else {
                    self.report(sent: chunk.count)
                    self.sendNextChunk()
                }
            })
        } catch {
            finish(.failure(error))
        }
    }

    /// Chunk sends are serialized on the connection queue, so this caps the
    /// hop rate at one update per whole percent.
    private func report(sent count: Int) {
        guard let onProgress, totalBytes > 0 else { return }
        bytesSent += Int64(count)
        let fraction = min(1, Double(bytesSent) / Double(totalBytes))
        let percent = Int(fraction * 100)
        guard percent != lastPercent else { return }
        lastPercent = percent
        onProgress(fraction)
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        try? file?.close()
        connection.cancel()
        completion(result)
    }
}

private extension KDEConnectService {
    func send(
        fileURLs: [URL],
        text: [String],
        links urlShares: [URL],
        temporaryURLs: [URL],
        to destination: LocalSendDestination,
        fileItemIDs: [URL: [UUID]] = [:],
        inlineItemIDs: [UUID] = []
    ) async {
        seedTransfers(fileItemIDs.values.flatMap { $0 } + inlineItemIDs)

        guard !isSending else {
            lastError = "KDE Connect transfer already in progress."
            failRemainingTransfers(with: "Transfer already in progress")
            return
        }
        guard let device = device(for: destination), let link = links[device.deviceID] else {
            lastError = isPaired(destination)
                ? KDEConnectError.offline(destination).localizedDescription
                : KDEConnectError.unpaired(destination).localizedDescription
            failRemainingTransfers(with: lastError ?? "Destination unavailable")
            return
        }
        let uniqueFiles = uniqueFileURLs(fileURLs)
        guard !uniqueFiles.isEmpty || !text.isEmpty || !urlShares.isEmpty else {
            failRemainingTransfers(with: "Nothing to send")
            return
        }
        let accessible = uniqueFiles.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessible.forEach { $0.stopAccessingSecurityScopedResource() } }
        isSending = true
        completedFileCount = 0
        totalFileCount = uniqueFiles.count
        lastError = nil
        SharingStateManager.shared.beginInteraction()
        defer {
            isSending = false
            SharingStateManager.shared.endInteraction()
            finishTransfers()
        }
        do {
            for value in text { link.send(type: KDEConnectProtocol.share, body: ["text": value]) }
            for value in urlShares { link.send(type: KDEConnectProtocol.share, body: ["url": value.absoluteString]) }
            // Inline share packets are fire-and-forget on this link, so they are
            // done the moment they are written.
            setTransfers(.sent, for: inlineItemIDs)
            for file in uniqueFiles {
                setTransfer(.sending(fraction: 0), forURL: file, in: fileItemIDs)
                do {
                    try await send(file: file, to: device, via: link) { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, self.isSending else { return }
                            self.setTransfer(.sending(fraction: fraction), forURL: file, in: fileItemIDs)
                        }
                    }
                } catch {
                    setTransfer(.failed(error.localizedDescription), forURL: file, in: fileItemIDs)
                    throw error
                }
                setTransfer(.sent, forURL: file, in: fileItemIDs)
                completedFileCount += 1
            }
        } catch {
            lastError = error.localizedDescription
            failRemainingTransfers(with: error.localizedDescription)
        }
    }

    func send(
        file: URL,
        to device: KDEConnectDevice,
        via link: KDEControlLink,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let localIdentity = identity.identity else { throw KDEConnectError.unavailable("KDE Connect identity unavailable.") }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .localizedNameKey])
        let server = KDEPayloadServer(
            identity: localIdentity,
            expectedCertificate: device.certificateDER,
            fileURL: file,
            totalBytes: Int64(values.fileSize ?? 0),
            onProgress: onProgress
        )
        let port = try await server.start()
        guard let packet = KDEPacket.make(type: KDEConnectProtocol.share, body: [
            "filename": values.localizedName ?? file.lastPathComponent,
            "creationTime": Int64((values.creationDate ?? .now).timeIntervalSince1970 * 1000),
            "lastModified": Int64((values.contentModificationDate ?? .now).timeIntervalSince1970 * 1000),
            "open": false,
            "numberOfFiles": 1,
            "totalPayloadSize": values.fileSize ?? 0
        ], payloadSize: values.fileSize ?? 0, payloadPort: port) else {
            throw KDEConnectError.unavailable("KDE Connect could not create file packet.")
        }
        link.send(raw: packet)
        try await server.waitForTransfer()
    }

    func uniqueFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0.standardizedFileURL).inserted }
    }
}
