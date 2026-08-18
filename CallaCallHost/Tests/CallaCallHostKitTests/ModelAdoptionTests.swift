import XCTest
@testable import CallaCallHostKit

/// Adopting a model means installing bytes this process did not download — from
/// another app's directory, no less. The pinned SHA-256 is the only thing that
/// makes that safe, so these pin the rule rather than the convenience.
final class ModelAdoptionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A file of exactly the right length but the wrong contents must be refused.
    /// Size is only used to avoid hashing every large file in someone else's model
    /// directory; it is never the decision.
    func testRightSizeWrongBytesIsNotAdopted() throws {
        let model = WhisperModel.baseEn
        let impostor = scratch.appendingPathComponent("wrong.bin")
        try Data(repeating: 0x41, count: Int(model.sizeBytes)).write(to: impostor)

        let destination = scratch.appendingPathComponent("installed.bin")
        let adopted = try ModelStore.adopt(model, into: destination, fromDirectories: [scratch.path])

        XCTAssertNil(adopted, "a file that fails the hash must never be installed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testWrongSizeIsSkippedWithoutHashing() throws {
        let model = WhisperModel.baseEn
        try Data(repeating: 0x41, count: 1024).write(to: scratch.appendingPathComponent("small.bin"))

        let destination = scratch.appendingPathComponent("installed.bin")
        XCTAssertNil(try ModelStore.adopt(model, into: destination, fromDirectories: [scratch.path]))
    }

    func testMissingDirectoryIsNotAnError() throws {
        let model = WhisperModel.baseEn
        let destination = scratch.appendingPathComponent("installed.bin")
        XCTAssertNil(try ModelStore.adopt(
            model,
            into: destination,
            fromDirectories: ["/nowhere/at/all"]))
    }

    /// The real one, when it is there: Mila ships the same whisper.cpp pin, so its
    /// copy is byte-for-byte what this host would otherwise download.
    func testAdoptsAVerifiedCopyAsAHardLink() throws {
        let model = WhisperModel.largeV3Turbo
        let mila = ("~/Library/Application Support/Mila/Models" as NSString).expandingTildeInPath
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: mila),
            "no second app with whisper weights on this machine")

        let destination = scratch.appendingPathComponent("installed.bin")
        guard let adopted = try ModelStore.adopt(model, into: destination, fromDirectories: [mila]) else {
            throw XCTSkip("no matching model in that directory")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: adopted.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, model.sizeBytes)
        // Hard-linked, so adoption costs no disk.
        XCTAssertGreaterThan((attributes[.referenceCount] as? NSNumber)?.intValue ?? 0, 1)
    }
}
