import Foundation
import XCTest

@testable import MiaoYan

private actor TestS3Store: S3ObjectStore {
    private var objects: [String: Data] = [:]
    var failList = false

    func list() async throws -> [String: String] {
        if failList { throw S3Error.invalidResponse }
        return objects.mapValues(Self.tag)
    }

    func get(_ key: String, matching etag: String) async throws -> Data {
        guard let data = objects[key], Self.tag(data) == etag else { throw S3Error.requestFailed(412, "PreconditionFailed") }
        return data
    }

    func put(_ key: String, data: Data, matching etag: String?) async throws -> String {
        guard objects[key].map(Self.tag) == etag else { throw S3Error.requestFailed(412, "PreconditionFailed") }
        objects[key] = data
        return Self.tag(data)
    }

    func delete(_ key: String, matching etag: String) async throws {
        guard objects[key].map(Self.tag) == etag else { throw S3Error.requestFailed(412, "PreconditionFailed") }
        objects[key] = nil
    }

    func set(_ key: String, _ value: String?) {
        objects[key] = value.map { Data($0.utf8) }
    }

    func value(_ key: String) -> String? { objects[key].flatMap { String(data: $0, encoding: .utf8) } }
    func setFailList(_ value: Bool) { failList = value }
    private static func tag(_ data: Data) -> String { "\"\(S3Client.hash(data))\"" }
}

@MainActor
private final class S3SyncEventHost: FileSystemEventHost {
    var sidebarReloads = 0
    var selectedNote: Note?
    var fsEditorBuffer: (owner: Note?, text: String)? { nil }
    func fsReloadList(selecting note: Note?, completion: (@MainActor @Sendable () -> Void)?) {
        selectedNote = note
        completion?()
    }
    func fsInsert(_ note: Note) {}
    func fsReloadSidebar() { sidebarReloads += 1 }
    func fsSelectFirstNote() {}
    func fsRemove(_ notes: [Note]) {}
    func fsReload(_ note: Note) {}
    func fsRefillEditor() {}
    func fsToast(_ message: String, style: ToastStyle) {}
}

final class S3SyncTests: XCTestCase {
    private func workspace() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("miaoyan-s3-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func engine(_ root: URL, state: URL, remote: TestS3Store) -> S3SyncEngine {
        let canonicalRoot = S3SyncEngine.resolvedRoot(root)
        return S3SyncEngine(root: canonicalRoot, stateURL: state, remote: remote) { change in
            try await S3LocalInstaller.apply(change, root: canonicalRoot) { _ in true }
        }
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url, options: .atomic)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testTwoDevicesSyncNotesAttachmentsAndEdits() async throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first")
        let second = folder.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try write("one", to: first.appendingPathComponent("Folder/note.md"))
        try write("image", to: first.appendingPathComponent("Folder/i/image.png"))
        let remote = TestS3Store()
        let a = engine(first, state: folder.appendingPathComponent("a.json"), remote: remote)
        let b = engine(second, state: folder.appendingPathComponent("b.json"), remote: remote)

        _ = try await a.sync()
        _ = try await b.sync()
        XCTAssertEqual(try read(second.appendingPathComponent("Folder/note.md")), "one")
        XCTAssertEqual(try read(second.appendingPathComponent("Folder/i/image.png")), "image")

        try write("two", to: second.appendingPathComponent("Folder/note.md"))
        _ = try await b.sync()
        _ = try await a.sync()
        XCTAssertEqual(try read(first.appendingPathComponent("Folder/note.md")), "two")
    }

    func testConcurrentEditsKeepBothVersionsAndSyncTheConflictCopy() async throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("notes")
        let note = root.appendingPathComponent("note.md")
        try write("base", to: note)
        let remote = TestS3Store()
        let sync = engine(root, state: folder.appendingPathComponent("state.json"), remote: remote)
        _ = try await sync.sync()
        try write("local", to: note)
        await remote.set("note.md", "remote")

        let result = try await sync.sync()
        XCTAssertEqual(result.conflicts, ["note.md"])
        XCTAssertEqual(try read(note), "local")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let conflict = try XCTUnwrap(names.first { $0.contains("S3 conflict") })
        XCTAssertEqual(try read(root.appendingPathComponent(conflict)), "remote")
        _ = try await sync.sync()
        let uploaded = await remote.value(conflict)
        XCTAssertEqual(uploaded, "remote")
    }

    func testDeletesAndConcurrentDeleteVersusEdit() async throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("notes")
        let note = root.appendingPathComponent("note.md")
        try write("base", to: note)
        let remote = TestS3Store()
        let sync = engine(root, state: folder.appendingPathComponent("state.json"), remote: remote)
        _ = try await sync.sync()
        try FileManager.default.removeItem(at: note)
        _ = try await sync.sync()
        let deleted = await remote.value("note.md")
        XCTAssertEqual(deleted, "base", "Deleted files remain on S3 for recovery")

        try write("base", to: note)
        _ = try await sync.sync()
        try FileManager.default.removeItem(at: note)
        await remote.set("note.md", "newer remote")
        _ = try await sync.sync()
        XCTAssertEqual(try read(note), "newer remote")

        await remote.set("note.md", nil)
        try write("newer local", to: note)
        _ = try await sync.sync()
        let restored = await remote.value("note.md")
        XCTAssertEqual(restored, "newer local")
    }

    func testDeletionPropagatesAndAnIdenticalRecreatedFileReturns() async throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first")
        let second = folder.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let firstNote = first.appendingPathComponent("note.md")
        let secondNote = second.appendingPathComponent("note.md")
        try write("same content", to: firstNote)
        let remote = TestS3Store()
        let a = engine(first, state: folder.appendingPathComponent("a.json"), remote: remote)
        let b = engine(second, state: folder.appendingPathComponent("b.json"), remote: remote)
        _ = try await a.sync()
        _ = try await b.sync()

        try FileManager.default.removeItem(at: firstNote)
        _ = try await a.sync()
        _ = try await b.sync()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondNote.path))

        try write("same content", to: firstNote)
        _ = try await a.sync()
        _ = try await b.sync()
        XCTAssertEqual(try read(secondNote), "same content")
    }

    func testDeletionMarkerNeverHidesANewerRemoteVersion() async throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("notes")
        let note = root.appendingPathComponent("note.md")
        try write("base", to: note)
        let remote = TestS3Store()
        let sync = engine(root, state: folder.appendingPathComponent("state.json"), remote: remote)
        _ = try await sync.sync()
        try FileManager.default.removeItem(at: note)
        _ = try await sync.sync()
        await remote.set("note.md", "new remote version")
        _ = try await sync.sync()
        XCTAssertEqual(try read(note), "new remote version")
    }

    func testFailedListAndMissingLibraryNeverDeleteRemoteFiles() async throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("notes")
        let note = root.appendingPathComponent("note.md")
        try write("safe", to: note)
        let remote = TestS3Store()
        let state = folder.appendingPathComponent("state.json")
        let sync = engine(root, state: state, remote: remote)
        _ = try await sync.sync()
        try FileManager.default.removeItem(at: note)
        await remote.setFailList(true)
        do { _ = try await sync.sync(); XCTFail("A failed listing must stop sync") } catch {}
        let afterFailure = await remote.value("note.md")
        XCTAssertEqual(afterFailure, "safe")
        await remote.setFailList(false)
        try FileManager.default.removeItem(at: root)
        do { _ = try await sync.sync(); XCTFail("A missing library must stop sync") } catch {}
        let afterMissingRoot = await remote.value("note.md")
        XCTAssertEqual(afterMissingRoot, "safe")
    }

    func testADownloadedFileRemovedBeforeInstallationIsNotAnError() async throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = S3SyncEngine.resolvedRoot(folder)
        let note = root.appendingPathComponent("note.md")
        try write("base", to: note)
        let snapshot = try S3FileSnapshot.read(note)
        try FileManager.default.removeItem(at: note)
        let applied = try await S3LocalInstaller.apply(.trash(path: "note.md", previous: snapshot), root: root) { _ in true }
        XCTAssertTrue(applied)
    }

    func testUnsafePathsAndSymlinkDirectoriesCannotEscapeLibrary() async throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("notes")
        let outside = folder.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        let remote = TestS3Store()
        await remote.set("linked/note.md", "unsafe")
        let sync = engine(root, state: folder.appendingPathComponent("state.json"), remote: remote)
        _ = try await sync.sync()
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("note.md").path))
        await remote.set("../escape.md", "unsafe")
        do { _ = try await sync.sync(); XCTFail("Path traversal must be rejected") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("escape.md").path))
    }

    func testRemoteCannotReplaceTheLibraryRootWithAFile() async throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = S3SyncEngine.resolvedRoot(folder.appendingPathComponent("notes"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            _ = try await S3LocalInstaller.apply(.install(path: "..", data: Data("x".utf8), previous: nil), root: root) { _ in true }
            XCTFail("The library root must never be written through a relative path")
        } catch {}
        XCTAssertTrue(FileManager.default.directoryExists(atUrl: root))
    }

    func testInstallerDoesNotReplaceAFileChangedAfterScanning() async throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = S3SyncEngine.resolvedRoot(folder)
        let note = root.appendingPathComponent("note.md")
        try write("base", to: note)
        let snapshot = try S3FileSnapshot.read(note)
        try write("user edit", to: note)
        let applied = try await S3LocalInstaller.apply(.install(path: "note.md", data: Data("remote".utf8), previous: snapshot), root: root) { _ in true }
        XCTAssertFalse(applied)
        XCTAssertEqual(try read(note), "user edit")
    }

    func testRequestEncodesUnicodeAndSignsCondition() throws {
        let config = S3Configuration(endpoint: "https://s3.example.com:9443/base", region: "us-east-1", bucket: "notes", prefix: "Miao Yan", accessKey: "AKIDEXAMPLE")
        let client = S3Client(configuration: config, secret: "secret")
        let request = try client.signedRequest(
            "PUT", key: "文件/hello #1.md", headers: ["if-none-match": "*"], body: Data("test".utf8), date: Date(timeIntervalSince1970: 1_369_353_600))
        XCTAssertEqual(request.url?.absoluteString, "https://s3.example.com:9443/base/notes/Miao%20Yan/%E6%96%87%E4%BB%B6/hello%20%231.md")
        XCTAssertEqual(request.value(forHTTPHeaderField: "if-none-match"), "*")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("SignedHeaders=host;if-none-match;x-amz-content-sha256;x-amz-date") == true)
    }

    func testListDecodesS3ObjectNamesWithSpacesAndLiteralPlusSigns() throws {
        let plus = "+"
        let xml = """
            <ListBucketResult><IsTruncated>false</IsTruncated><EncodingType>url</EncodingType>
            <Contents><Key>Miao\(plus)Yan/%E4%B8%AD%E6%96%87%2Btest.md</Key><ETag>&quot;abc&quot;</ETag></Contents>
            </ListBucketResult>
            """
        let result = try S3ListParser.parse(Data(xml.utf8))
        XCTAssertEqual(result.objects["Miao Yan/中文+test.md"], "\"abc\"")
    }

    func testPlainHTTPIsOnlyAllowedForLoopback() throws {
        var configuration = S3Configuration(
            endpoint: "http://s3.example.com", region: "us-east-1", bucket: "notes",
            prefix: "", accessKey: "KEY")
        XCTAssertThrowsError(try configuration.validate())
        configuration.endpoint = "https://user:password@s3.example.com"
        XCTAssertThrowsError(try configuration.validate(), "credentials never belong in the endpoint")
        configuration.endpoint = "http://127.0.0.1:9000"
        XCTAssertNoThrow(try configuration.validate())
        configuration.endpoint = "https://s3.example.com"
        configuration.prefix = "../outside"
        XCTAssertThrowsError(try configuration.validate())
    }

    func testListKeepsRawKeysWhenTheServiceIgnoresEncodingType() throws {
        let xml = """
            <ListBucketResult><IsTruncated>false</IsTruncated>
            <Contents><Key>notes/100% ready.md</Key><ETag>&quot;abc&quot;</ETag></Contents>
            </ListBucketResult>
            """
        let result = try S3ListParser.parse(Data(xml.utf8))
        XCTAssertEqual(result.objects["notes/100% ready.md"], "\"abc\"")
    }

    @MainActor
    func testDownloadedNoteInNewFolderAppearsInStorage() throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = S3SyncEngine.resolvedRoot(folder)
        let storage = Storage(loadsLibrary: false)
        _ = storage.add(project: Project(url: root, label: "test", isRoot: true, isDefault: true))
        let host = S3SyncEventHost()
        let manager = FileSystemEventManager(storage: storage, delegate: host)
        let existingURL = root.appendingPathComponent("open.md")
        try write("open", to: existingURL)
        let existing = try XCTUnwrap(storage.initNote(url: existingURL))
        storage.add(existing)
        let original = EditTextView.note
        EditTextView.note = existing
        defer { EditTextView.note = original }
        let note = root.appendingPathComponent("New Folder/note.md")
        try write("downloaded", to: note)
        NotificationCenter.default.post(name: .s3FileChanged, object: note)
        XCTAssertNotNil(storage.getBy(url: note))
        // The list refresh is coalesced behind the download burst.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(host.sidebarReloads, 1)
        XCTAssertTrue(host.selectedNote === existing)
        withExtendedLifetime(manager) {}
    }
}
