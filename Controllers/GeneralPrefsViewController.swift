import Cocoa
import KeyboardShortcuts

@MainActor
final class GeneralPrefsViewController: BasePrefsViewController {
    private var settings = GeneralSettings()

    private var storageRow: PrefsRowView!
    private var storageRestartButton: PrefsPillButton!
    private var appearanceDropdown: PrefsDropdown!
    private var languageDropdown: PrefsDropdown!
    private var languageRestartButton: PrefsPillButton!
    private var buttonDisplayDropdown: PrefsDropdown!
    private var alwaysOnTopSwitch: PrefsSwitch!
    private var shortcutRecorder: PrefsShortcutRecorder!
    private var syncRow: PrefsRowView!
    private var syncButton: PrefsPillButton!
    private var syncDetailsButton: PrefsPillButton!

    private var s3Sync: S3SyncManager? { (NSApp.delegate as? AppDelegate)?.s3Sync }

    /// What the running app was launched with, so the Restart pill shows only
    /// while a change is waiting for a relaunch.
    private var launchLanguage = 0
    private var launchStoragePath: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(handleAlwaysOnTopChanged), name: .alwaysOnTopChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateSyncStatus), name: .s3SyncStatusChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAlwaysOnTopChanged() {
        alwaysOnTopSwitch?.isOn = UserDefaultsManagement.alwaysOnTop
    }

    override func setupUI() {
        let changeButton = PrefsPillButton(title: I18n.str("Change"), target: self, action: #selector(changeStorageLocation(_:)))
        storageRestartButton = makeRestartButton()
        storageRow = PrefsRowView(
            title: I18n.str("Note Location"), detail: "", controls: [storageRestartButton, changeButton], detailTruncation: .byTruncatingMiddle)

        appearanceDropdown = PrefsDropdown()
        appearanceDropdown.target = self
        appearanceDropdown.action = #selector(appearanceChanged(_:))
        appearanceDropdown.addOption(I18n.str("System"), value: AppearanceType.System.rawValue)
        appearanceDropdown.addOption(I18n.str("Light"), value: AppearanceType.Light.rawValue)
        appearanceDropdown.addOption(I18n.str("Dark"), value: AppearanceType.Dark.rawValue)

        languageDropdown = PrefsDropdown()
        languageDropdown.target = self
        languageDropdown.action = #selector(languageChanged(_:))
        for language in [LanguageType.Chinese, .English, .Japanese, .ChineseTC] {
            languageDropdown.addOption(language.description, value: language.rawValue)
        }
        languageRestartButton = makeRestartButton()

        buttonDisplayDropdown = PrefsDropdown()
        buttonDisplayDropdown.target = self
        buttonDisplayDropdown.action = #selector(buttonDisplayChanged(_:))
        buttonDisplayDropdown.addOption(I18n.str("Always"), value: "Always")
        buttonDisplayDropdown.addOption(I18n.str("On Hover"), value: "Hover")

        alwaysOnTopSwitch = PrefsSwitch(target: self, action: #selector(alwaysOnTopChanged(_:)))
        alwaysOnTopSwitch.setAccessibilityLabel(I18n.str("Always On Top"))
        shortcutRecorder = PrefsShortcutRecorder(for: .activateWindow)
        let configureSyncButton = PrefsPillButton(title: I18n.str("Configure"), target: self, action: #selector(configureSync(_:)))
        syncButton = PrefsPillButton(title: I18n.str("Sync Now"), target: self, action: #selector(syncNow(_:)))
        syncDetailsButton = PrefsPillButton(title: I18n.str("Details"), target: self, action: #selector(showSyncDetails(_:)))
        syncDetailsButton.isHidden = true
        syncRow = PrefsRowView(
            title: I18n.str("S3 Sync"), detail: I18n.str("S3 sync is off"),
            controls: [syncDetailsButton, syncButton, configureSyncButton])

        addSections([
            [storageRow, syncRow],
            [
                PrefsRowView(title: I18n.str("Appearance"), detail: I18n.str("Follow the system, or stay light or dark"), controls: [appearanceDropdown]),
                PrefsRowView(title: I18n.str("Language"), detail: I18n.str("Takes effect after MiaoYan restarts"), controls: [languageRestartButton, languageDropdown]),
                PrefsRowView(title: I18n.str("Button Display"), detail: I18n.str("When the title bar buttons show"), controls: [buttonDisplayDropdown]),
            ],
            [
                PrefsRowView(title: I18n.str("Always On Top"), detail: I18n.str("Keep this window above other apps"), controls: [alwaysOnTopSwitch]),
                PrefsRowView(title: I18n.str("Activate Shortcut"), detail: I18n.str("Bring MiaoYan to the front from any app"), controls: [shortcutRecorder]),
            ],
        ])
    }

    override func setupValues() {
        launchLanguage = settings.defaultLanguage
        launchStoragePath = settings.storagePath
        appearanceDropdown.selectOption { $0 as? Int == settings.appearanceType.rawValue }
        languageDropdown.selectOption { $0 as? Int == settings.defaultLanguage }
        // "On Hover" is what older versions stored for the same choice.
        let buttonShow = ["Hover", "On Hover"].contains(settings.buttonShow) ? "Hover" : "Always"
        buttonDisplayDropdown.selectOption { $0 as? String == buttonShow }
        alwaysOnTopSwitch.isOn = UserDefaultsManagement.alwaysOnTop
        showStoragePath(settings.storagePath)
        updateSyncStatus()
    }

    @objc private func updateSyncStatus() {
        guard syncRow != nil else { return }
        syncRow.detail = I18n.str(s3Sync?.status ?? "S3 sync is off")
        syncButton.isEnabled = s3Sync?.configuration != nil
        syncDetailsButton.isHidden = s3Sync?.details == nil
    }

    @objc private func syncNow(_ sender: NSButton) {
        s3Sync?.syncNow()
    }

    @objc private func showSyncDetails(_ sender: NSButton) {
        guard let details = s3Sync?.details else { return }
        MiaoYanAlert.show(message: I18n.str("S3 Sync"), informativeText: details, style: .informational, for: view.window)
    }

    @objc private func configureSync(_ sender: NSButton) {
        showS3Configuration(s3Sync?.configuration, secret: "")
    }

    private func showS3Configuration(_ current: S3Configuration?, secret: String) {
        guard let window = view.window, let manager = s3Sync else { return }
        var buttons = [I18n.str("Save and Sync"), I18n.str("Cancel")]
        if manager.configuration != nil { buttons.append(I18n.str("Turn Off")) }
        let alert = MiaoYanAlert.make(
            message: I18n.str("Configure S3 Sync"),
            informativeText: I18n.str("Sync this notes folder with an S3-compatible bucket. Deleted files remain on S3 for recovery."), buttons: buttons)

        let endpoint = NSTextField(string: current?.endpoint ?? "https://s3.amazonaws.com")
        let region = NSTextField(string: current?.region ?? "us-east-1")
        let bucket = NSTextField(string: current?.bucket ?? "")
        let prefix = NSTextField(string: current?.prefix ?? "MiaoYan")
        let accessKey = NSTextField(string: current?.accessKey ?? "")
        let secretKey = NSSecureTextField(string: secret)
        secretKey.placeholderString = manager.configuration == nil ? "" : I18n.str("Leave blank to keep the saved key")
        let fields: [(String, NSTextField)] = [
            ("Endpoint", endpoint), ("Region", region), ("Bucket", bucket),
            ("Prefix", prefix), ("Access Key ID", accessKey), ("Secret Access Key", secretKey),
        ]
        let rows = fields.map { name, field -> [NSView] in
            let label = NSTextField(labelWithString: I18n.str(name))
            field.setAccessibilityLabel(I18n.str(name))
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            return [label, field]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.xPlacement = .leading
        grid.yPlacement = .center
        alert.accessoryView = grid
        MiaoYanAlert.present(alert, for: window) { [weak self, weak manager] response in
            Task { @MainActor [weak self, weak manager] in
                guard let self, let manager else { return }
                if response == .alertThirdButtonReturn {
                    do { try manager.disable() } catch { self.showS3Error(error) }
                    return
                }
                guard response == .alertFirstButtonReturn else { return }
                let values = S3Configuration(
                    endpoint: endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    region: region.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    bucket: bucket.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    prefix: prefix.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    accessKey: accessKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
                let suppliedSecret = secretKey.stringValue
                do {
                    try values.validate()
                    let savedSecret = suppliedSecret.isEmpty ? try manager.storedSecret() : suppliedSecret
                    guard let savedSecret, !savedSecret.isEmpty else { throw S3Error.invalidConfiguration }
                    try await S3Client(configuration: values, secret: savedSecret).verifyConditionalWrites()
                    try manager.configure(values, secret: savedSecret)
                } catch {
                    MiaoYanAlert.show(
                        message: I18n.str("S3 sync failed"), informativeText: S3SyncManager.message(for: error), style: .warning, for: self.view.window
                    ) { [weak self] _ in
                        self?.showS3Configuration(values, secret: suppliedSecret)
                    }
                }
            }
        }
    }

    private func showS3Error(_ error: Error) {
        MiaoYanAlert.show(message: I18n.str("S3 sync failed"), informativeText: S3SyncManager.message(for: error), style: .warning, for: view.window)
    }

    /// The folder as people know it, `~/Documents/Notes` rather than the full
    /// path, with the middle truncated when it is still too long.
    private func showStoragePath(_ path: String?) {
        guard let path, !path.isEmpty else {
            storageRow.detail = I18n.str("The folder your notes are stored in")
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? home
        for prefix in [realHome, home] where path == prefix || path.hasPrefix(prefix + "/") {
            storageRow.detail = "~" + path.dropFirst(prefix.count)
            return
        }
        storageRow.detail = path
    }

    // MARK: - Actions
    @objc private func appearanceChanged(_ sender: PrefsDropdown) {
        guard let raw = sender.selectedItem?.representedObject as? Int, let appearanceType = AppearanceType(rawValue: raw) else { return }
        settings.appearanceType = appearanceType

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.applyAppearance()
            appDelegate.mainWindowController?.applyMiaoYanAppearance()
        }

        if let prefsWindow = view.window?.windowController as? PrefsWindowController {
            prefsWindow.refreshThemeAppearance()
        }

        if let vc = ViewController.shared() {
            vc.editArea.recreatePreviewView()

            let sidebarSelectedRows = vc.storageOutlineView.selectedRowIndexes
            let notesSelectedRows = vc.notesTableView.selectedRowIndexes

            vc.storageOutlineView.reloadData()
            vc.notesTableView.reloadData()

            if !sidebarSelectedRows.isEmpty {
                vc.storageOutlineView.selectRowIndexes(sidebarSelectedRows, byExtendingSelection: false)
            }
            if !notesSelectedRows.isEmpty {
                vc.notesTableView.selectRowIndexes(notesSelectedRows, byExtendingSelection: false)
            }
        }
    }

    @objc private func languageChanged(_ sender: PrefsDropdown) {
        guard let raw = sender.selectedItem?.representedObject as? Int, let languageType = LanguageType(rawValue: raw) else { return }
        if settings.defaultLanguage != languageType.rawValue {
            settings.defaultLanguage = languageType.rawValue
            UserDefaults.standard.set([languageType.code, "en"], forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        }
        languageRestartButton.isHidden = settings.defaultLanguage == launchLanguage
    }

    @objc private func changeStorageLocation(_ sender: NSButton) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.canChooseFiles = false

        let handleResult: (NSApplication.ModalResponse) -> Void = { result in
            guard result == .OK, let url = openPanel.url else { return }
            do {
                try StorageLocationValidator.validateWritableDirectory(url)
            } catch {
                self.showStorageLocationError(error)
                return
            }

            // The bookmark comes first: storageUrl prefers it over the path,
            // so saving the path alone left the next launch on the old folder
            // while Settings showed the new one.
            let bookmarkData: Data
            do {
                bookmarkData = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil)
            } catch {
                AppDelegate.trackError(error, context: "GeneralPrefsViewController.changeStorageLocation.bookmarkData")
                self.showStorageLocationError(error)
                return
            }
            UserDefaultsManagement.storageBookmark = bookmarkData
            self.settings.storagePath = url.path
            self.showStoragePath(url.path)

            UserDefaults.standard.synchronize()
            // The library is opened at launch; the new folder is used from the
            // next start, which the Restart pill offers right away.
            self.storageRestartButton.isHidden = url.path == self.launchStoragePath
        }

        if let window = view.window {
            openPanel.beginSheetModal(for: window, completionHandler: handleResult)
        } else {
            openPanel.begin(completionHandler: handleResult)
        }
    }

    private func showStorageLocationError(_ error: Error) {
        let message: String
        if let validationError = error as? StorageLocationValidationError {
            message = validationError.localizedMessage
        } else {
            message = error.localizedDescription
        }
        MiaoYanAlert.show(
            message: I18n.str("Could not use this folder"),
            informativeText: message,
            style: .warning,
            for: view.window
        )
    }

    @objc private func buttonDisplayChanged(_ sender: PrefsDropdown) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        settings.buttonShow = raw
        if let vc = ViewController.shared() {
            vc.applyButtonVisibilityPreference()
        }
    }

    @objc private func alwaysOnTopChanged(_ sender: PrefsSwitch) {
        UserDefaultsManagement.alwaysOnTop = sender.isOn
        NotificationCenter.default.post(name: .alwaysOnTopChanged, object: nil)
    }
}
