import Darwin
import Foundation

struct S3FileSnapshot: Codable, Sendable, Equatable {
    let hash: String
    let size: UInt64
    let inode: UInt64
    let modified: Date
    let changed: Date

    static func read(_ url: URL) throws -> S3FileSnapshot {
        let before = try metadata(url)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let after = try metadata(url)
        guard before == after else { throw S3Error.changed(url.path) }
        return S3FileSnapshot(hash: S3Client.hash(data), size: before.size, inode: before.inode, modified: before.modified, changed: before.changed)
    }

    private struct Metadata: Equatable {
        let size: UInt64
        let inode: UInt64
        let modified: Date
        let changed: Date
    }

    private static func metadata(_ url: URL) throws -> Metadata {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw S3Error.unavailable(url.path) }
        return Metadata(
            size: UInt64(info.st_size), inode: UInt64(info.st_ino),
            modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
            changed: Date(timeIntervalSince1970: Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000))
    }

    func stillMatches(_ url: URL) -> Bool {
        guard let current = try? Self.metadata(url) else { return false }
        return size == current.size && inode == current.inode && modified == current.modified && changed == current.changed
    }
}

struct S3SyncRecord: Codable, Sendable {
    var hash: String
    var etag: String
    var local: S3FileSnapshot?
}

struct S3SyncResult: Sendable {
    var conflicts = [String]()
    var deferred = false
}

enum S3LocalChange: Sendable {
    case install(path: String, data: Data, previous: S3FileSnapshot?)
    case trash(path: String, previous: S3FileSnapshot)
}

actor S3SyncEngine {
    typealias Apply = @Sendable (S3LocalChange) async throws -> Bool
    private static let markerPrefix = ".miaoyan-sync/deletions/"
    private struct Marker: Codable, Sendable {
        let path: String
        let fileETag: String
        let deleted: Bool
    }
    private struct RemoteMarker: Sendable {
        let etag: String
        let value: Marker
    }
    private let root: URL
    private let stateURL: URL
    private let remote: any S3ObjectStore
    private let apply: Apply
    private var records: [String: S3SyncRecord] = [:]

    init(root: URL, stateURL: URL, remote: any S3ObjectStore, apply: @escaping Apply) {
        self.root = Self.resolvedRoot(root)
        self.stateURL = stateURL
        self.remote = remote
        self.apply = apply
    }

    static func resolvedRoot(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    func sync() async throws -> S3SyncResult {
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: stateURL.path) {
            records = try JSONDecoder().decode([String: S3SyncRecord].self, from: Data(contentsOf: stateURL))
        }
        let local = try scan()
        let objects = try await remote.list()
        let markers = try await loadMarkers(objects)
        var result = S3SyncResult()
        for path in Set(local.files.keys).union(objects.keys).union(records.keys).sorted() {
            try Task.checkCancellation()
            guard Self.isSafe(path) else { throw S3Error.unsafePath(path) }
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            if local.excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            let physicalETag = objects[path]
            let marker = markers[path]
            let deleted = marker?.value.deleted == true && marker?.value.fileETag == physicalETag
            try await reconcile(path, local: local.files[path], remoteETag: deleted ? nil : physicalETag, physicalETag: physicalETag, marker: marker, result: &result)
        }
        return result
    }

    private func loadMarkers(_ objects: [String: String]) async throws -> [String: RemoteMarker] {
        var result: [String: RemoteMarker] = [:]
        for (key, etag) in objects where key.hasPrefix(Self.markerPrefix) {
            let data = try await remote.get(key, matching: etag)
            let marker = try JSONDecoder().decode(Marker.self, from: data)
            guard Self.isSafe(marker.path), Self.markerKey(marker.path) == key, !marker.fileETag.isEmpty,
                result.updateValue(RemoteMarker(etag: etag, value: marker), forKey: marker.path) == nil
            else { throw S3Error.invalidResponse }
        }
        return result
    }

    private static func markerKey(_ path: String) -> String {
        markerPrefix + S3Client.hash(Data(path.utf8)) + ".json"
    }

    private func writeMarker(_ path: String, fileETag: String, deleted: Bool, previous: RemoteMarker?) async throws {
        let marker = Marker(path: path, fileETag: fileETag, deleted: deleted)
        _ = try await remote.put(Self.markerKey(path), data: JSONEncoder().encode(marker), matching: previous?.etag)
    }

    private func reconcile(
        _ path: String, local: S3FileSnapshot?, remoteETag: String?, physicalETag: String?,
        marker: RemoteMarker?, result: inout S3SyncResult
    ) async throws {
        let previous = records[path]
        switch (local, remoteETag, previous) {
        case (nil, nil, _):
            if previous != nil { try save(path, nil) }
        case (let file?, nil, nil):
            try await upload(path, file: file, etag: physicalETag, marker: marker)
        case (nil, let etag?, nil):
            try await download(path, etag: etag, replacing: nil, result: &result)
        case (let file?, nil, let old?):
            if file.hash == old.hash {
                if try await apply(.trash(path: path, previous: file)) { try save(path, nil) } else { result.deferred = true }
            } else {
                try await upload(path, file: file, etag: physicalETag, marker: marker)
            }
        case (nil, let etag?, let old?):
            if etag == old.etag {
                guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else { throw S3Error.changed(path) }
                try await writeMarker(path, fileETag: etag, deleted: true, previous: marker)
                try save(path, nil)
            } else {
                try await download(path, etag: etag, replacing: nil, result: &result)
            }
        case (let file?, let etag?, let old):
            let localChanged = old == nil || file.hash != old?.hash
            let remoteChanged = old == nil || etag != old?.etag
            if !localChanged && !remoteChanged {
                if old?.local != file { try save(path, S3SyncRecord(hash: file.hash, etag: etag, local: file)) }
                return
            }
            if localChanged && !remoteChanged {
                try await upload(path, file: file, etag: etag, marker: marker)
            } else if !localChanged {
                try await download(path, etag: etag, replacing: file, result: &result)
            } else {
                let data = try await remote.get(path, matching: etag)
                if S3Client.hash(data) == file.hash {
                    try save(path, S3SyncRecord(hash: file.hash, etag: etag, local: file))
                } else {
                    let conflict = try await installConflict(path, data: data)
                    guard conflict else { result.deferred = true; return }
                    result.conflicts.append(path)
                    try await upload(path, file: file, etag: etag, marker: marker)
                }
            }
        }
    }

    private func upload(_ path: String, file: S3FileSnapshot, etag: String?, marker: RemoteMarker?) async throws {
        let url = root.appendingPathComponent(path)
        guard file.stillMatches(url) else { throw S3Error.changed(path) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard file.stillMatches(url), S3Client.hash(data) == file.hash else { throw S3Error.changed(path) }
        let newETag = try await remote.put(path, data: data, matching: etag)
        if marker?.value.deleted == true {
            try await writeMarker(path, fileETag: newETag, deleted: false, previous: marker)
        }
        try save(path, S3SyncRecord(hash: file.hash, etag: newETag, local: file))
    }

    private func download(_ path: String, etag: String, replacing file: S3FileSnapshot?, result: inout S3SyncResult) async throws {
        let data = try await remote.get(path, matching: etag)
        if try await apply(.install(path: path, data: data, previous: file)) {
            try save(path, S3SyncRecord(hash: S3Client.hash(data), etag: etag, local: nil))
        } else {
            result.deferred = true
        }
    }

    private func installConflict(_ path: String, data: Data) async throws -> Bool {
        let url = URL(fileURLWithPath: path)
        let suffix = String(S3Client.hash(data).prefix(10))
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let name = "\(stem) (S3 conflict \(suffix))" + (ext.isEmpty ? "" : ".\(ext)")
        let conflict = parent.isEmpty ? name : parent + "/" + name
        let target = root.appendingPathComponent(conflict)
        if FileManager.default.fileExists(atPath: target.path) {
            return try S3FileSnapshot.read(target).hash == S3Client.hash(data)
        }
        return try await apply(.install(path: conflict, data: data, previous: nil))
    }

    private func save(_ path: String, _ record: S3SyncRecord?) throws {
        records[path] = record
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: stateURL, options: .atomic)
    }

    private func scan() throws -> (files: [String: S3FileSnapshot], excluded: [String]) {
        let fm = FileManager.default
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var enumerationError: Error?
        guard
            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey],
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                })
        else { throw S3Error.unavailable(root.path) }
        var files: [String: S3FileSnapshot] = [:]
        var excluded: [String] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard url.path.hasPrefix(rootPath) else { throw S3Error.unsafePath(url.path) }
            let relative = String(url.path.dropFirst(rootPath.count))
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                if name.hasSuffix(".icloud") { throw S3Error.unavailable(relative) }
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
            if values.isSymbolicLink == true || values.isPackage == true {
                excluded.append(relative)
                enumerator.skipDescendants()
            } else if values.isRegularFile == true {
                if let cached = records[relative]?.local, cached.stillMatches(url) {
                    files[relative] = cached
                } else {
                    files[relative] = try S3FileSnapshot.read(url)
                }
            } else if values.isDirectory != true {
                excluded.append(relative)
            }
        }
        if let enumerationError { throw enumerationError }
        return (files, excluded)
    }

    static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}
