import Foundation

/// Rebuilds the size fields of a WAV whose writer never finalized it.
///
/// `AVAudioFile` writes its RIFF header once, at creation, with both size fields
/// zero, and only patches them when the object deinits. This host ends a call by
/// calling `_exit(0)` — deliberately, because whisper.cpp 1.8.4 aborts inside
/// `ggml_metal_rsets_free` during static destruction — and a killed host never
/// reaches `CallArchive.close()` at all. Either way the deinit does not run, and
/// what is left on disk is a file whose audio is entirely intact and whose header
/// says it contains nothing.
///
/// Measured on this machine: **63 of 66 recorded calls**. `afinfo` reports
/// "audio bytes: 0" for a 3 MB file; `AVAudioFile(forReading:)` reports zero
/// frames; every archive re-transcription ever run produced zero turns against
/// audio that was sitting right there.
///
/// The repair is exact, not a guess. The samples are byte-for-byte where the
/// writer left them; only the two length fields are wrong, and both are
/// recomputable from the file's own size.
public enum WAVRepair {
    public enum Failure: Swift.Error, LocalizedError {
        case notRIFF
        case noDataChunk

        public var errorDescription: String? {
            switch self {
            case .notRIFF: return "Not a RIFF/WAVE file"
            case .noDataChunk: return "No data chunk found"
            }
        }
    }

    /// Repairs `url` in place when its header understates the audio it holds.
    ///
    /// Returns whether anything was written, so a bulk pass can report honestly
    /// rather than claiming to have fixed files that were already fine.
    ///
    /// Only ever *grows* the declared length, and only to what is physically
    /// present. A header that already describes its payload is left untouched, so
    /// this is safe to call unconditionally on every read.
    @discardableResult
    public static func repairIfNeeded(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let totalSize = try handle.seekToEnd()
        guard totalSize > 44 else { return false }
        try handle.seek(toOffset: 0)
        // 64 KiB covers any realistic chunk preamble; ExtAudioFile pads to 4096.
        guard let head = try handle.read(upToCount: min(Int(totalSize), 65_536)),
              head.count > 12,
              head.prefix(4).elementsEqual(Array("RIFF".utf8)),
              head[8..<12].elementsEqual(Array("WAVE".utf8))
        else { throw Failure.notRIFF }

        guard let dataChunk = findDataChunk(in: head) else { throw Failure.noDataChunk }
        let payloadStart = UInt64(dataChunk + 8)
        guard totalSize > payloadStart else { return false }

        let declared = readUInt32(head, at: dataChunk + 4)
        let actual = UInt32(clamping: totalSize - payloadStart)
        // Sample-aligned: a torn final write can leave a partial frame, and
        // handing whisper three bytes of a float is worse than dropping them.
        let aligned = actual - (actual % 4)
        guard aligned > 0, declared < aligned else { return false }

        try handle.seek(toOffset: UInt64(dataChunk + 4))
        try handle.write(contentsOf: uint32LE(aligned))
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: uint32LE(UInt32(clamping: payloadStart + UInt64(aligned) - 8)))
        return true
    }

    /// Walks the chunk list rather than assuming an offset. The layout is not
    /// fixed: `AVAudioFile` emits a `JUNK` pad so the payload starts on a 4096
    /// boundary, and other writers do not.
    static func findDataChunk(in head: Data) -> Int? {
        var offset = 12
        while offset + 8 <= head.count {
            let identifier = head[head.startIndex + offset ..< head.startIndex + offset + 4]
            if identifier.elementsEqual(Array("data".utf8)) { return offset }
            let size = readUInt32(head, at: offset + 4)
            // A zero-length chunk before `data` would loop forever.
            guard size > 0 else { return nil }
            // Chunks are word-aligned.
            offset += 8 + Int(size) + Int(size % 2)
        }
        return nil
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        guard base + 4 <= data.endIndex else { return 0 }
        return UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }

    private static func uint32LE(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}
