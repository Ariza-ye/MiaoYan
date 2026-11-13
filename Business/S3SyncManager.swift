import AppKit
import Darwin
import Foundation
import Security

extension Notification.Name {
    static let s3SyncStatusChanged = Notification.Name("S3SyncStatusChanged")
    static let s3FileChanged = Notification.Name("S3FileChanged")
}

@MainActor
final class S3SyncManager {
    private static let configurationKey = "S3SyncConfiguration"
    private static var keychainService: String { "\(AppIdentifier.bundleID).s3" }
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var verifiedConfiguration: S3Configuration?
    private(set) var status = "S3 sync is off" {
        didSet { NotificationCenter.default.post(name: .s3SyncStatusChanged, object: nil) }
    }
    private(set) var details: String?

    var configuration: S3Configuration? {
        guard let data = UserDefaults.standard.data(forKey: Self.configurationKey) else { return nil }
        return try? JSONDecoder().decode(S3Configuration.self, from: data)
    }

    func storedSecret() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "secret",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw keychainError(result)
        }
        return secret
    }

    func configure(_ configuration: S3Configuration, secret: String) throws {
        try configuration.validate()
        guard !secret.isEmpty else { throw S3Error.invalidConfiguration }
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "secret",
        ]
        let value = Data(secret.utf8)
        let result = SecItemUpdate(key as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if result == errSecItemNotFound {
            var item = key
            item[kSecValueData as String] = value
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw keychainError(added) }
        } else if result != errSecSuccess {
            throw keychainError(result)
        }
        UserDefaults.standard.set(try JSONEncoder().encode(configuration), forKey: Self.configurationKey)
        restart()
    }

    func disable() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "secret",
        ]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw keychainError(result) }
        UserDefaults.standard.removeObject(forKey: Self.configurationKey)
        restart()
    }

    func start() {
        guard timer == nil, configuration != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncNow() }
        }
        syncNow()
    }

    private func restart() {
        generation = UUID()
        verifiedConfiguration = nil
        task?.cancel()
        task = nil
        timer?.invalidate()
        timer = nil
        details = nil
        status = configuration == nil ? "S3 sync is off" : "Waiting to sync"
        start()
    }

    func syncNow() {
        guard task == nil, let configuration else { return }
        guard !UserDefaultsManagement.isSingleMode, let selectedRoot = AppEnvironment.current.storage.getDefault()?.url else {
            status = "S3 sync is paused in single-file mode"
            return
        }
        let secret: String
        do {
            guard let saved = try storedSecret(), !saved.isEmpty else { throw S3Error.invalidConfiguration }
            secret = saved
        } catch {
            details = Self.message(for: error)
            status = "S3 sync failed"
            return
        }
        let identifier = generation
        let root = S3SyncEngine.resolvedRoot(selectedRoot)
        let identity = [root.path, configuration.endpoint, configuration.bucket, configuration.objectPrefix].joined(separator: "\n")
        let stateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentifier.bundleID, isDirectory: true)
            .appendingPathComponent("S3Sync", isDirectory: true)
            .appendingPathComponent(S3Client.hash(Data(identity.utf8)) + ".json")
        status = "Syncing with S3"
        details = nil
        let client = S3Client(configuration: configuration, secret: secret)
        let engine = S3SyncEngine(root: root, stateURL: stateURL, remote: client) { [weak self] change in
            try await S3LocalInstaller.apply(change, root: root) { [weak self] url in
                guard let self, self.generation == identifier, !UserDefaultsManagement.isSingleMode,
                    AppEnvironment.current.storage.getDefault().map({ S3SyncEngine.resolvedRoot($0.url) }) == root,
                    !AppEnvironment.current.storage.isMovingFolder, !AppEnvironment.current.userData.fsUpdatesDisabled
                else { return false }
                if let note = AppEnvironment.current.storage.getBy(url: url), note.hasPendingSave || note.needsSave { return false }
                return true
            }
        }
        task = Task { [weak self] in
            do {
                if self?.verifiedConfiguration != configuration {
                    try await client.verifyConditionalWrites()
                    guard let self, self.generation == identifier else { return }
                    self.verifiedConfiguration = configuration
                }
                let result = try await engine.sync()
                guard let self, self.generation == identifier else { return }
                if !result.conflicts.isEmpty {
                    self.details = result.conflicts.joined(separator: "\n")
                    self.status = "S3 conflicts saved as separate files"
                } else {
                    self.status = result.deferred ? "Waiting for edits to finish" : "S3 sync complete"
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == identifier else { return }
                self.details = Self.message(for: error)
                self.status = "S3 sync failed"
                AppDelegate.trackError(error, context: "S3SyncManager.sync")
            }
            self?.task = nil
        }
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"])
    }

    static func message(for error: Error) -> String {
        guard let error = error as? S3Error else { return error.localizedDescription }
        switch error {
        case .invalidConfiguration, .invalidResponse, .unsupportedConditions:
            return I18n.str(error.localizedDescription)
        default:
            return error.localizedDescription
        }
    }
}

enum S3LocalInstaller {
    typealias Permission = @MainActor @Sendable (URL) -> Bool

    static func apply(_ change: S3LocalChange, root: URL, permission: @escaping Permission) async throws -> Bool {
        try Task.checkCancellation()
        let path: String
        switch change {
        case .install(let value, _, _), .trash(let value, _): path = value
        }
        guard S3SyncEngine.isSafe(path) else { throw S3Error.unsafePath(path) }
        let target = root.appendingPathComponent(path)
        try verifyParents(of: target, root: root, create: false)
        switch change {
        case .trash(_, let previous):
            return try await MainActor.run {
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: target.path) else { return true }
                guard permission(target), previous.stillMatches(target) else { return false }
                try verifyParents(of: target, root: root, create: false)
                try FileManager.default.trashItem(at: target, resultingItemURL: nil)
                NotificationCenter.default.post(name: .s3FileChanged, object: target)
                return true
            }
        case .install(_, let data, let previous):
            try verifyParents(of: target, root: root, create: true)
            let staging = target.deletingLastPathComponent().appendingPathComponent(".miaoyan-s3-\(UUID().uuidString)")
            try data.write(to: staging, options: .atomic)
            if previous != nil {
                let result = target.path.withCString { source in
                    staging.path.withCString { destination in copyfile(source, destination, nil, UInt32(COPYFILE_METADATA)) }
                }
                guard result == 0 else {
                    try? FileManager.default.removeItem(at: staging)
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            var installed = false
            do {
                installed = try await MainActor.run {
                    try Task.checkCancellation()
                    guard permission(target) else { return false }
                    try verifyParents(of: target, root: root, create: false)
                    if let previous {
                        guard previous.stillMatches(target) else { return false }
                        try rename(staging, target, flags: UInt32(RENAME_SWAP))
                    } else {
                        guard !FileManager.default.fileExists(atPath: target.path) else { return false }
                        try rename(staging, target, flags: UInt32(RENAME_EXCL))
                    }
                    NotificationCenter.default.post(name: .s3FileChanged, object: target)
                    return true
                }
                if installed, let previous {
                    let swapped = try S3FileSnapshot.read(staging)
                    if swapped.hash != previous.hash {
                        let name = target.deletingPathExtension().lastPathComponent + " (S3 conflict \(UUID().uuidString))" + (target.pathExtension.isEmpty ? "" : "." + target.pathExtension)
                        let backup = target.deletingLastPathComponent().appendingPathComponent(name)
                        do {
                            try FileManager.default.moveItem(at: staging, to: backup)
                            await MainActor.run { NotificationCenter.default.post(name: .s3FileChanged, object: backup) }
                        } catch {
                            await MainActor.run { AppDelegate.trackError(error, context: "S3LocalInstaller.changedWhileWriting") }
                        }
                    }
                }
                if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
                return installed
            } catch {
                // After a successful exchange the staging file is the previous
                // version; leave it intact if verification or backup failed.
                if !installed { try? FileManager.default.removeItem(at: staging) }
                throw error
            }
        }
    }

    private static func verifyParents(of target: URL, root: URL, create: Bool) throws {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(rootPath) else { throw S3Error.unsafePath(target.path) }
        let parent = target.deletingLastPathComponent()
        let rootDirectory = String(rootPath.dropLast())
        guard parent.path == rootDirectory || parent.path.hasPrefix(rootPath) else { throw S3Error.unsafePath(target.path) }
        let relative = parent.path == rootDirectory ? "" : String(parent.path.dropFirst(rootPath.count))
        var directory = root
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw S3Error.unavailable(root.path) }
        for part in relative.split(separator: "/") {
            directory.appendPathComponent(String(part), isDirectory: true)
            if lstat(directory.path, &info) != 0 {
                // A folder that does not exist yet cannot hide a symlink; the
                // write path checks again after it is made.
                if !create, errno == ENOENT { return }
                guard create, errno == ENOENT else { throw S3Error.unavailable(directory.path) }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                guard lstat(directory.path, &info) == 0 else { throw S3Error.unavailable(directory.path) }
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw S3Error.unsafePath(directory.path) }
        }
    }

    private static func rename(_ source: URL, _ target: URL, flags: UInt32) throws {
        let result = source.path.withCString { from in target.path.withCString { to in renamex_np(from, to, flags) } }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
