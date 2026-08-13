import Foundation

// Everything the survey and analysis stages need from the disk, behind one
// protocol so no stage above this line ever touches FileManager directly. Tests
// drive the whole pipeline through FakeFileSystem, including sparse files, which
// cannot otherwise be created reliably on every filesystem.

struct FileAttributes: Equatable {
    /// The standardised absolute path. A `String` rather than a `URL` because the
    /// walk touches millions of entries and keeps thousands; a `URL` is built
    /// only for a node that survives pruning.
    var path: String
    /// The last path component, carried rather than derived: the walk tests it
    /// against the structural markers and the exclusion rules for every entry.
    var name: String
    /// On-disk bytes (C1): allocated blocks, which is also what `du` counts.
    var allocated: Int64
    /// Logical bytes. Zero for a directory, whose own `st_size` describes its
    /// entry table rather than any content and would distort the sparseness
    /// ratio C3 reads.
    var apparent: Int64
    var isDirectory: Bool
    var isSymbolicLink: Bool
    var modified: Date?
    var accessed: Date?
    /// The volume this entry lives on. Entries whose device differs from the scan
    /// root's are skipped, which is what stops firmlinks and mounted volumes from
    /// being counted twice (C1).
    var volumeID: UInt64?
    /// Number of directory entries pointing at this file's data. Greater than 1
    /// means the same bytes are reachable by another path.
    var linkCount: Int = 1
    /// Stable per-file token, used to recognise a second link to bytes already
    /// counted. Populated only when `linkCount > 1`, because that is the only
    /// time it is consulted and the walk pays for every field it fills.
    var fileID: UInt64?

    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
}

protocol FileSystem: Sendable {
    /// Attributes for a single item. Returns nil when the item cannot be stat'd.
    func attributes(of url: URL) -> FileAttributes?

    /// Immediate children of a directory. Throws when the directory exists but
    /// cannot be read — the caller flags that node unreadable rather than
    /// recording it as empty (C8).
    func contentsOfDirectory(at url: URL) throws -> [URL]

    /// Immediate children *with* their attributes. The walk's entry point: one
    /// directory read plus one stat per entry, with no `URL` or resource-value
    /// bridging. The default composes the two calls above, so a conforming type
    /// overrides it only if it can do better.
    func entries(of url: URL) throws -> [FileAttributes]

    func fileExists(at url: URL) -> Bool

    /// The leading bytes of a small text file (a `.gitignore`, a manifest). Bounded
    /// so a signal cannot be made to read a huge file. nil when unreadable.
    func readFileHead(at url: URL, maxBytes: Int) -> Data?
}

extension FileSystem {
    func entries(of url: URL) throws -> [FileAttributes] {
        try contentsOfDirectory(at: url).compactMap { attributes(of: $0) }
    }

    /// Convenience: a small text file decoded as UTF-8 lines.
    func readLines(at url: URL, maxBytes: Int = 64 * 1024) -> [String]? {
        guard let data = readFileHead(at: url, maxBytes: maxBytes) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

struct RealFileSystem: FileSystem {

    func attributes(of url: URL) -> FileAttributes? {
        let standardized = url.standardizedFileURL
        var status = stat()
        guard lstat(standardized.path, &status) == 0 else { return nil }
        return FileAttributes(path: standardized.path,
                              name: standardized.lastPathComponent,
                              status: status)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            // Package contents are descended into for sizing (C1); hidden files
            // count, since dotfile directories are much of what Sweep looks at.
            options: [])
    }

    // `readdir` plus `fstatat` against the open directory descriptor. The
    // previous implementation read ten `URLResourceValues` per entry, each key
    // boxed into a dictionary and two of them turned into description strings;
    // over a home directory of millions of files that dominated the walk.
    // The URL is used for its path alone and is not standardised again: the walk
    // builds every child path by appending to a standardised parent, and paying
    // for standardisation once per directory adds up over a whole volume.
    func entries(of url: URL) throws -> [FileAttributes] {
        let directoryPath = url.path
        let descriptor = open(directoryPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(errno) }
        guard let handle = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw posixError(code)
        }
        defer { closedir(handle) }        // also closes the descriptor
        let directoryFD = dirfd(handle)

        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        var result: [FileAttributes] = []
        result.reserveCapacity(32)

        while let entry = readdir(handle) {
            let length = Int(entry.pointee.d_namlen)
            guard length > 0 else { continue }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
                    String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
                }
            }
            if name == "." || name == ".." { continue }

            var status = stat()
            guard fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            result.append(FileAttributes(path: prefix + name, name: name, status: status))
        }
        return result
    }

    func fileExists(at url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    func readFileHead(at url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    private func posixError(_ code: Int32) -> Error {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

extension FileAttributes {
    /// Builds attributes from a `stat` record. `st_blocks` counts 512-byte
    /// blocks — the same figure `du` reports, and the allocated size C1 requires.
    init(path: String, name: String, status: stat) {
        let kind = status.st_mode & S_IFMT
        let isDirectory = kind == S_IFDIR
        let linkCount = Int(status.st_nlink)
        self.init(
            path: path,
            name: name,
            allocated: Int64(status.st_blocks) * 512,
            apparent: isDirectory ? 0 : Int64(status.st_size),
            isDirectory: isDirectory,
            isSymbolicLink: kind == S_IFLNK,
            modified: Date(timespec: status.st_mtimespec),
            accessed: Date(timespec: status.st_atimespec),
            volumeID: UInt64(bitPattern: Int64(status.st_dev)),
            linkCount: linkCount,
            fileID: linkCount > 1 ? UInt64(status.st_ino) : nil)
    }
}

extension Date {
    init(timespec time: timespec) {
        self.init(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }
}
