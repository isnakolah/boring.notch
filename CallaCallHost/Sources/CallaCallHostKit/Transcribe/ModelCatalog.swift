import CryptoKit
import Foundation
import os.log

private let modelLog = Logger(subsystem: "theboringteam.boringnotch.callhost", category: "models")

/// A ggml whisper model plus, optionally, its CoreML encoder build.
public struct WhisperModel: Identifiable, Hashable, Codable, Sendable {
    public var id: String { name }
    public var name: String
    public var displayName: String
    public var url: URL
    public var sizeBytes: Int64
    /// Lowercase hex SHA-256 of the file at `url`.
    ///
    /// Pinned so a compromised upstream repo — or any swap of the `.bin`
    /// between the fetch and whisper's GGML loader opening it — is rejected
    /// before those bytes are ever parsed.
    public var sha256: String
    public var languageHint: String

    /// `<name>-encoder.mlmodelc.zip`. When present the encoder runs on
    /// CoreML/ANE; when nil the encoder stays on Metal, which is what lets
    /// `audio_ctx` truncation work.
    public var coreMLURL: URL?
    public var coreMLSizeBytes: Int64
    public var coreMLSHA256: String?

    public init(
        name: String,
        displayName: String,
        url: URL,
        sizeBytes: Int64,
        sha256: String,
        languageHint: String,
        coreMLURL: URL? = nil,
        coreMLSizeBytes: Int64 = 0,
        coreMLSHA256: String? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.languageHint = languageHint
        self.coreMLURL = coreMLURL
        self.coreMLSizeBytes = coreMLSizeBytes
        self.coreMLSHA256 = coreMLSHA256
    }
}

public extension WhisperModel {
    /// The live leg. Deliberately **no CoreML sibling**.
    ///
    /// A CoreML encoder has a fixed 30s input shape and ignores `audio_ctx`, so
    /// every 1-5s utterance would pay a full 30s encode. Staying on Metal lets
    /// `computeAudioCtx` return 750 — measured 4x faster on short clips at
    /// identical WER. That tradeoff is the entire reason the live leg runs a
    /// small model instead of the archive one.
    static let smallEn = WhisperModel(
        name: "whisper-small-en",
        displayName: "Whisper · small.en (live)",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!,
        sizeBytes: 487_614_201,
        sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
        languageHint: "en")

    /// Fallback for machines where small.en cannot keep up with the call.
    static let baseEn = WhisperModel(
        name: "whisper-base-en",
        displayName: "Whisper · base.en (live, fast)",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!,
        sizeBytes: 147_964_211,
        sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
        languageHint: "en")

    /// The archive leg: re-transcribes the saved audio after the call, where the
    /// fixed CoreML encode cost is amortized over the whole recording instead of
    /// paid per utterance.
    static let largeV3Turbo = WhisperModel(
        name: "whisper-large-v3-turbo",
        displayName: "Whisper · large-v3-turbo (archive)",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
        sizeBytes: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        languageHint: "en",
        coreMLURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-encoder.mlmodelc.zip")!,
        coreMLSizeBytes: 1_173_393_014,
        coreMLSHA256: "84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a")

    static let all: [WhisperModel] = [.smallEn, .baseEn, .largeV3Turbo]

    static func named(_ name: String) -> WhisperModel? {
        all.first { $0.name == name }
    }
}

/// Downloads, verifies and installs models.
///
/// Headless by design — no Combine, no `@Published`. The host asks for a model
/// and awaits a URL; progress is a callback.
public actor ModelStore {
    public enum Failure: Swift.Error, LocalizedError {
        case httpStatus(Int)
        case sha256Mismatch(expected: String, computed: String)
        case unzipFailed(Int32)
        case missingModelDirectory

        public var errorDescription: String? {
            switch self {
            case .httpStatus(let code): return "Model download failed with HTTP \(code)"
            case .sha256Mismatch(let expected, let computed):
                return "SHA-256 mismatch (expected \(expected), got \(computed))"
            case .unzipFailed(let code): return "unzip failed (status \(code))"
            case .missingModelDirectory: return "Extracted archive contained no .mlmodelc"
            }
        }
    }

    private let directory: URL
    private var inFlight: [String: Task<URL, Swift.Error>] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    public nonisolated func localURL(for model: WhisperModel) -> URL {
        directory.appendingPathComponent("\(model.name).bin")
    }

    public nonisolated func coreMLDirectory(for model: WhisperModel) -> URL? {
        guard model.coreMLURL != nil else { return nil }
        return directory.appendingPathComponent("\(model.name)-encoder.mlmodelc")
    }

    public nonisolated func isInstalled(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: model).path)
    }

    /// Returns the on-disk URL, downloading and verifying first if needed.
    ///
    /// Concurrent callers for the same model share one download.
    public func ensure(_ model: WhisperModel, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let destination = localURL(for: model)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        if let existing = inFlight[model.name] { return try await existing.value }

        let task = Task<URL, Swift.Error> {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Adopt a copy that is already on this Mac before spending the download.
            if let adopted = try Self.adopt(model, into: destination, progress: progress) {
                return adopted
            }
            let temporary = try await Self.download(from: model.url, expectedBytes: model.sizeBytes, progress: progress)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Self.verifySHA256(at: temporary, expected: model.sha256)
            // Replace rather than move-if-absent: a partial file from a killed
            // process must never be mistaken for an installed model.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            modelLog.notice("installed \(model.name, privacy: .public)")
            return destination
        }
        inFlight[model.name] = task
        defer { inFlight[model.name] = nil }
        return try await task.value
    }

    /// Best-effort CoreML encoder install. Never throws: without it the encoder
    /// simply stays on Metal, which is a slower archive pass, not a failure.
    @discardableResult
    public func ensureCoreML(_ model: WhisperModel, progress: (@Sendable (Double) -> Void)? = nil) async -> URL? {
        guard let remote = model.coreMLURL, let destination = coreMLDirectory(for: model) else { return nil }
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard let expected = model.coreMLSHA256 else {
            // Refuse to install bytes we cannot verify.
            modelLog.error("no sha256 pinned for \(model.name, privacy: .public) CoreML encoder; skipping")
            return nil
        }

        do {
            let archive = try await Self.download(from: remote, expectedBytes: model.coreMLSizeBytes, progress: progress)
            defer { try? FileManager.default.removeItem(at: archive) }
            try Self.verifySHA256(at: archive, expected: expected)

            let staging = directory.appendingPathComponent("staging-\(model.name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            try Self.unzip(archive, into: staging)
            guard let extracted = try Self.findModelDirectory(in: staging) else {
                throw Failure.missingModelDirectory
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: extracted, to: destination)
            modelLog.notice("installed CoreML encoder for \(model.name, privacy: .public)")
            return destination
        } catch {
            modelLog.error("CoreML encoder install failed for \(model.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Internal

    private static func download(
        from url: URL,
        expectedBytes: Int64,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        // Check the status first: an upstream 404 returns an HTML page, and
        // hashing that would report a confusing "checksum mismatch".
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.httpStatus(http.statusCode)
        }

        let total = response.expectedContentLength > 0 ? response.expectedContentLength : expectedBytes
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("callhost-model-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0
        var lastReported = 0.0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 {
                    let fraction = min(1, Double(written) / Double(total))
                    // Report at most every percent; a byte-stream callback per
                    // MiB is still thousands of calls on a multi-GB model.
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress?(fraction)
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        progress?(1)
        return temporary
    }

    /// Streaming SHA-256 in 1 MiB chunks — a multi-GB model must never be
    /// loaded into memory just to hash it.
    /// Places other apps on this Mac keep whisper weights.
    ///
    /// Mila ships the same whisper.cpp pin this host does — that is why the two
    /// agree on behaviour — so its `large-v3-turbo` is byte-for-byte the file this
    /// would otherwise fetch. Re-downloading 1.6GB that is already on the disk is
    /// pure waste, and on a metered connection it is worse than waste.
    static let adoptionDirectories: [String] = [
        "~/Library/Application Support/Mila/Models",
    ]

    /// Links an already-present copy into our store, if one checks out.
    ///
    /// Verified by SHA-256, not by name or size: adopting another app's file means
    /// trusting bytes this process did not fetch, and the pinned hash is the only
    /// thing that makes that safe. Hard-linked rather than copied, so it costs no
    /// extra disk and cannot drift; a link across volumes falls back to a copy.
    static func adopt(
        _ model: WhisperModel,
        into destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil,
        fromDirectories directories: [String] = adoptionDirectories
    ) throws -> URL? {
        let manager = FileManager.default
        for directory in directories {
            let expanded = (directory as NSString).expandingTildeInPath
            guard let entries = try? manager.contentsOfDirectory(atPath: expanded) else { continue }
            for entry in entries where entry.hasSuffix(".bin") {
                let candidate = URL(fileURLWithPath: expanded).appendingPathComponent(entry)
                let size = (try? manager.attributesOfItem(atPath: candidate.path)[.size] as? NSNumber)??.int64Value
                // Size first: hashing every large file in someone else's model
                // directory to find one match would take minutes.
                guard size == model.sizeBytes else { continue }
                progress?(0.5)
                do {
                    try verifySHA256(at: candidate, expected: model.sha256)
                } catch {
                    modelLog.notice("\(entry, privacy: .public) is the right size for \(model.name, privacy: .public) but not the right file")
                    continue
                }
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                do {
                    try manager.linkItem(at: candidate, to: destination)
                } catch {
                    // Different volume, or a filesystem without hard links.
                    try manager.copyItem(at: candidate, to: destination)
                }
                progress?(1)
                modelLog.notice("adopted \(model.name, privacy: .public) from \(candidate.deletingLastPathComponent().path, privacy: .public)")
                return destination
            }
        }
        return nil
    }

    static func verifySHA256(at fileURL: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let computed = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard computed.lowercased() == expected.lowercased() else {
            throw Failure.sha256Mismatch(expected: expected, computed: computed)
        }
    }

    private static func unzip(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", archive.path, "-d", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.unzipFailed(process.terminationStatus)
        }
    }

    private static func findModelDirectory(in root: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        for entry in contents where entry.pathExtension == "mlmodelc" {
            return entry
        }
        // Some archives nest the payload one level down.
        for entry in contents {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            if let nested = try findModelDirectory(in: entry) { return nested }
        }
        return nil
    }
}
