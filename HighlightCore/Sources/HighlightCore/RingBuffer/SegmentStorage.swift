import Foundation

/// Where segment bytes live. The default implementation is disk; tests use
/// the in-memory variant.
public protocol SegmentStorage: Sendable {
    /// Persists `data` and returns the URL it can be read back from.
    func write(_ data: Data, sessionID: SessionID, seq: Int, kind: SegmentKind) throws -> URL
    /// Removes one segment. Deleting a URL that no longer exists is not an error.
    func delete(_ url: URL) throws
    /// Removes every segment belonging to `sessionID`.
    func deleteAll(for sessionID: SessionID) throws
    /// Removes every segment this storage manages.
    func deleteEverything() throws
}

// MARK: - Disk

/// Disk-backed storage. Layout: `<root>/<sessionID>/<seq>.<init|m4s>`.
public struct FileSegmentStorage: SegmentStorage {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// Directory holding all segments of `sessionID`.
    public func sessionDirectory(for sessionID: SessionID) -> URL {
        rootDirectory.appendingPathComponent(sessionID.rawValue.uuidString, isDirectory: true)
    }

    /// The URL a segment with these coordinates is (or would be) written to.
    public func url(sessionID: SessionID, seq: Int, kind: SegmentKind) -> URL {
        sessionDirectory(for: sessionID)
            .appendingPathComponent("\(seq).\(kind.fileExtension)", isDirectory: false)
    }

    public func write(_ data: Data, sessionID: SessionID, seq: Int, kind: SegmentKind) throws -> URL {
        let fileManager = FileManager.default
        let directory = sessionDirectory(for: sessionID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = url(sessionID: sessionID, seq: seq, kind: kind)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public func delete(_ url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    public func deleteAll(for sessionID: SessionID) throws {
        let fileManager = FileManager.default
        let directory = sessionDirectory(for: sessionID)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    public func deleteEverything() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for child in children {
            try fileManager.removeItem(at: child)
        }
    }
}

// MARK: - Memory

/// In-memory storage for tests. URLs are synthetic: `memory://<sessionID>/<seq>.<ext>`.
///
/// The struct is a cheap handle onto a shared, lock-protected store, so copies
/// of the same `InMemorySegmentStorage` see the same contents.
public struct InMemorySegmentStorage: SegmentStorage {
    private let store: Store

    public init() {
        self.store = Store()
    }

    /// Bytes previously written to `url`, or nil if it was never written or was deleted.
    public func data(at url: URL) -> Data? {
        store.data(at: url)
    }

    /// Every URL currently held, in no particular order.
    public var storedURLs: [URL] {
        store.urls()
    }

    /// Number of segments currently held.
    public var count: Int {
        store.count()
    }

    /// The URL a segment with these coordinates is (or would be) stored at.
    public static func url(sessionID: SessionID, seq: Int, kind: SegmentKind) -> URL {
        // A UUID string is a valid host component, so this always parses.
        URL(string: "memory://\(sessionID.rawValue.uuidString)/\(seq).\(kind.fileExtension)")!
    }

    public func write(_ data: Data, sessionID: SessionID, seq: Int, kind: SegmentKind) throws -> URL {
        let url = Self.url(sessionID: sessionID, seq: seq, kind: kind)
        store.write(data, at: url, sessionID: sessionID)
        return url
    }

    public func delete(_ url: URL) throws {
        store.delete(url)
    }

    public func deleteAll(for sessionID: SessionID) throws {
        store.deleteAll(for: sessionID)
    }

    public func deleteEverything() throws {
        store.deleteEverything()
    }

    /// Reference storage shared between copies of the struct.
    ///
    /// `@unchecked Sendable` is justified because every access to the two
    /// mutable dictionaries goes through `lock`.
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [URL: Data] = [:]
        private var sessions: [SessionID: Set<URL>] = [:]

        func write(_ data: Data, at url: URL, sessionID: SessionID) {
            lock.withLock {
                bytes[url] = data
                sessions[sessionID, default: []].insert(url)
            }
        }

        func data(at url: URL) -> Data? {
            lock.withLock { bytes[url] }
        }

        func urls() -> [URL] {
            lock.withLock { Array(bytes.keys) }
        }

        func count() -> Int {
            lock.withLock { bytes.count }
        }

        func delete(_ url: URL) {
            lock.withLock {
                bytes.removeValue(forKey: url)
                for key in sessions.keys {
                    sessions[key]?.remove(url)
                }
            }
        }

        func deleteAll(for sessionID: SessionID) {
            lock.withLock {
                for url in sessions.removeValue(forKey: sessionID) ?? [] {
                    bytes.removeValue(forKey: url)
                }
            }
        }

        func deleteEverything() {
            lock.withLock {
                bytes.removeAll()
                sessions.removeAll()
            }
        }
    }
}
