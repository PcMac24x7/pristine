import SwiftUI
import AppKit
import Combine

// MARK: - What can be backed up

enum BackupItem: String, CaseIterable, Identifiable, Codable {
    case bookmarks, preferences, logins, extensions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .bookmarks:   return "Bookmarks"
        case .preferences: return "Settings"
        case .logins:      return "Logins & autofill"
        case .extensions:  return "Extensions"
        }
    }
    var detail: String {
        switch self {
        case .bookmarks:   return "Saved sites and folders"
        case .preferences: return "Browser preferences and profile options"
        case .logins:      return "Saved passwords (encrypted) and form data"
        case .extensions:  return "Installed extensions and their data"
        }
    }
    var symbol: String {
        switch self {
        case .bookmarks:   return "bookmark.fill"
        case .preferences: return "slider.horizontal.3"
        case .logins:      return "key.horizontal.fill"
        case .extensions:  return "puzzlepiece.extension.fill"
        }
    }
}

// MARK: - Backup records

struct BackupManifest: Codable {
    struct Entry: Codable {
        var path: String          // relative to the user's home folder
        var item: String          // BackupItem raw value
        var bytes: Int64
    }
    var version = 1
    var browserID: String
    var browserName: String
    var createdAt: Date
    var reason: String
    var files: [Entry]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var items: [BackupItem] {
        let present = Set(files.compactMap { BackupItem(rawValue: $0.item) })
        return BackupItem.allCases.filter { present.contains($0) }
    }
}

struct BackupRecord: Identifiable {
    let url: URL
    let manifest: BackupManifest
    var id: URL { url }
}

struct BackupRequest {
    let items: Set<BackupItem>
    let folder: URL
    let keep: Int            // 0 = keep everything
    let reason: String
}

// MARK: - Settings (shared by the UI, manual resets and scheduled resets)

enum BackupSettings {
    static let enabledKey = "backupBeforeReset"
    static let itemsKey = "backupItems"
    static let folderKey = "backupFolder"
    static let keepKey = "backupKeep"
    static let defaultItemsRaw = "bookmarks|preferences"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var keep: Int { UserDefaults.standard.object(forKey: keepKey) as? Int ?? 5 }

    static func parse(_ raw: String) -> Set<BackupItem> {
        Set(raw.split(separator: "|").compactMap { BackupItem(rawValue: String($0)) })
    }
    static var items: Set<BackupItem> {
        parse(UserDefaults.standard.string(forKey: itemsKey) ?? defaultItemsRaw)
    }
    static var folder: URL {
        if let p = UserDefaults.standard.string(forKey: folderKey), !p.isEmpty { return URL(fileURLWithPath: p) }
        return BackupEngine.defaultFolder()
    }

    /// nil when backups are switched off (or nothing is selected).
    static func request(reason: String) -> BackupRequest? {
        guard enabled else { return nil }
        let chosen = items
        guard !chosen.isEmpty else { return nil }
        return BackupRequest(items: chosen, folder: folder, keep: keep, reason: reason)
    }
}

// MARK: - Engine (synchronous file work, wrapped for async callers)

enum BackupEngine {
    private static let chromiumSupport: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "company.thebrowser.Browser": "Arc/User Data"
    ]

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static func lib(_ path: String) -> URL { home.appendingPathComponent("Library/\(path)") }

    static func defaultFolder() -> URL {
        home.appendingPathComponent("Documents/Pristine Backups")
    }

    /// Safari keeps passwords in iCloud Keychain, which can't be copied as a file.
    static func isSupported(browserID: String, item: BackupItem) -> Bool {
        !(browserID == "com.apple.Safari" && item == .logins)
    }

    private static func listDirs(_ dir: URL, where match: (String) -> Bool) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter(match).sorted().map { dir.appendingPathComponent($0) }
    }

    // Files and folders that make up each kind of data, per browser. Missing ones are skipped.
    static func targets(browserID: String, item: BackupItem) -> [URL] {
        if let support = chromiumSupport[browserID] {
            let root = lib("Application Support/\(support)")
            let profiles = listDirs(root) { $0 == "Default" || $0.hasPrefix("Profile ") }
            func inProfiles(_ names: [String]) -> [URL] {
                profiles.flatMap { p in names.map { p.appendingPathComponent($0) } }
            }
            switch item {
            case .bookmarks:
                return inProfiles(["Bookmarks", "Bookmarks.bak"])
            case .preferences:
                return [root.appendingPathComponent("Local State")] + inProfiles(["Preferences", "Secure Preferences"])
            case .logins:
                return inProfiles(["Login Data", "Login Data-journal", "Login Data For Account",
                                   "Login Data For Account-journal", "Web Data", "Web Data-journal"])
            case .extensions:
                return inProfiles(["Extensions", "Local Extension Settings", "Extension State"])
            }
        }

        switch browserID {
        case "com.apple.Safari":
            let container = "Containers/com.apple.Safari/Data/Library"
            switch item {
            case .bookmarks:
                return [lib("Safari/Bookmarks.plist"), lib("\(container)/Safari/Bookmarks.plist")]
            case .preferences:
                return [lib("Preferences/com.apple.Safari.plist"), lib("\(container)/Preferences/com.apple.Safari.plist"),
                        lib("Safari/UserNotificationPermissions.plist"), lib("Safari/PerSitePreferences.db")]
            case .logins:
                return []
            case .extensions:
                return [lib("Safari/Extensions")]
            }

        case "org.mozilla.firefox":
            let firefox = lib("Application Support/Firefox")
            let profiles = listDirs(firefox.appendingPathComponent("Profiles")) { _ in true }
            func inProfiles(_ names: [String]) -> [URL] {
                profiles.flatMap { p in names.map { p.appendingPathComponent($0) } }
            }
            switch item {
            case .bookmarks:
                // places.sqlite also contains history, so it is the bookmarks database too.
                return inProfiles(["places.sqlite", "places.sqlite-wal", "favicons.sqlite", "bookmarkbackups"])
            case .preferences:
                return [firefox.appendingPathComponent("profiles.ini")]
                    + inProfiles(["prefs.js", "user.js", "containers.json", "handlers.json",
                                  "permissions.sqlite", "content-prefs.sqlite"])
            case .logins:
                return inProfiles(["logins.json", "key4.db", "formhistory.sqlite"])
            case .extensions:
                return inProfiles(["extensions", "extensions.json", "addons.json", "browser-extension-data",
                                   "extension-preferences.json", "extension-settings.json"])
            }

        default:
            return []
        }
    }

    private static func relativePath(_ url: URL) -> String? {
        let prefix = home.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : nil
    }

    private static func sizeOf(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { return directorySize(url) }
        return Int64(values?.fileSize ?? 0)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    private static func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// Copies the chosen data into a new timestamped folder. All-or-nothing: on any error the partial copy is removed.
    /// Returns nil when the browser has none of the requested data.
    static func createSync(browserID: String, browserName: String, items: Set<BackupItem>,
                           root: URL, reason: String, keep: Int) throws -> BackupRecord? {
        let fm = FileManager.default

        var planned: [(url: URL, item: BackupItem)] = []
        var seen = Set<String>()
        for item in BackupItem.allCases where items.contains(item) {
            for url in targets(browserID: browserID, item: item) where fm.fileExists(atPath: url.path) {
                if seen.insert(url.path).inserted { planned.append((url: url, item: item)) }
            }
        }
        guard !planned.isEmpty else { return nil }

        let stamp = timestamp()
        let browserDir = root.appendingPathComponent(sanitized(browserName))
        var dest = browserDir.appendingPathComponent(stamp)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = browserDir.appendingPathComponent("\(stamp) (\(n))")
            n += 1
        }
        let filesRoot = dest.appendingPathComponent("files")
        try fm.createDirectory(at: filesRoot, withIntermediateDirectories: true)

        do {
            var entries: [BackupManifest.Entry] = []
            for (url, item) in planned {
                guard let rel = relativePath(url) else { continue }
                let target = filesRoot.appendingPathComponent(rel)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: target)
                entries.append(BackupManifest.Entry(path: rel, item: item.rawValue, bytes: sizeOf(url)))
            }
            let manifest = BackupManifest(browserID: browserID, browserName: browserName,
                                          createdAt: Date(), reason: reason, files: entries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: dest.appendingPathComponent("manifest.json"))

            let record = BackupRecord(url: dest, manifest: manifest)
            prune(browserID: browserID, root: root, keep: keep)
            return record
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    /// Moves the oldest backups for a browser to the Trash so only the newest `keep` remain.
    private static func prune(browserID: String, root: URL, keep: Int) {
        guard keep > 0 else { return }
        let mine = listSync(root: root).filter { $0.manifest.browserID == browserID }
        for old in mine.dropFirst(keep) {
            try? FileManager.default.trashItem(at: old.url, resultingItemURL: nil)
        }
    }

    static func listSync(root: URL) -> [BackupRecord] {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let browserDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles]) else { return [] }
        var out: [BackupRecord] = []
        for browserDir in browserDirs {
            guard let snapshots = try? fm.contentsOfDirectory(at: browserDir, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { continue }
            for snap in snapshots {
                let file = snap.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: file),
                      let manifest = try? decoder.decode(BackupManifest.self, from: data) else { continue }
                out.append(BackupRecord(url: snap, manifest: manifest))
            }
        }
        return out.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    /// Puts files back where they came from. Whatever is there now is moved to the Trash first.
    static func restoreSync(_ record: BackupRecord, only: Set<BackupItem>?) throws -> Int {
        let fm = FileManager.default
        var restored = 0
        for entry in record.manifest.files {
            if let only, let item = BackupItem(rawValue: entry.item), !only.contains(item) { continue }
            let source = record.url.appendingPathComponent("files").appendingPathComponent(entry.path)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = home.appendingPathComponent(entry.path)
            if fm.fileExists(atPath: destination.path) {
                try fm.trashItem(at: destination, resultingItemURL: nil)
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
            restored += 1
        }
        return restored
    }

    // Async wrappers keep the heavy copying off the main thread.
    static func create(browserID: String, browserName: String, items: Set<BackupItem>,
                       root: URL, reason: String, keep: Int) async throws -> BackupRecord? {
        try await Task.detached(priority: .userInitiated) {
            try createSync(browserID: browserID, browserName: browserName, items: items,
                           root: root, reason: reason, keep: keep)
        }.value
    }
}

// MARK: - View model

private func byteText(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}

@MainActor
final class BackupModel: ObservableObject {
    let browsers = allBrowsers
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var records: [BackupRecord] = []
    @Published var selectedBrowserID: String?
    @Published var busy = false
    @Published var status = ""

    init() { refreshInstalled() }

    func refreshInstalled() {
        var ids = Set<String>()
        var found = [String: NSImage]()
        for b in browsers {
            if let url = b.appURL {
                ids.insert(b.id)
                found[b.id] = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        installed = ids
        icons = found
        if let s = selectedBrowserID, !ids.contains(s) { selectedBrowserID = nil }
    }

    func reload() {
        let root = BackupSettings.folder
        Task {
            let list = await Task.detached(priority: .utility) { BackupEngine.listSync(root: root) }.value
            records = list
        }
    }

    func backupNow() {
        guard !busy else { return }
        guard let browser = browsers.first(where: { $0.id == selectedBrowserID }) else {
            status = "Choose a browser first."
            return
        }
        guard Engine.hasFullDiskAccess() else {
            status = "Grant Full Disk Access first. The main window has a button for it."
            return
        }
        let items = BackupSettings.items
        guard !items.isEmpty else {
            status = "Choose at least one thing to include."
            return
        }
        let id = browser.id, name = browser.name
        let wasOpen = !browser.runningApps.isEmpty
        let root = BackupSettings.folder, keep = BackupSettings.keep

        busy = true
        status = "Backing up \(name)…"
        Task {
            do {
                let record = try await BackupEngine.create(browserID: id, browserName: name, items: items,
                                                           root: root, reason: "Manual backup", keep: keep)
                if let record {
                    status = "Saved \(record.manifest.files.count) item(s), \(byteText(record.manifest.totalBytes))."
                        + (wasOpen ? " \(name) was open, so close it first next time for the most reliable copy." : "")
                } else {
                    status = "Nothing to back up for \(name) with these options."
                }
            } catch {
                status = "Backup failed: \(error.localizedDescription)"
            }
            busy = false
            reload()
        }
    }

    func restore(_ record: BackupRecord, only: Set<BackupItem>?) {
        guard !busy else { return }
        guard Engine.hasFullDiskAccess() else {
            status = "Grant Full Disk Access first. The main window has a button for it."
            return
        }
        busy = true
        status = "Restoring \(record.manifest.browserName)…"
        let browser = browsers.first { $0.id == record.manifest.browserID }
        Task {
            do {
                if let browser { try await Engine.quit(browser) }
                let count = try await Task.detached(priority: .userInitiated) {
                    try BackupEngine.restoreSync(record, only: only)
                }.value
                status = "Restored \(count) item(s). The files they replaced are in the Trash."
            } catch {
                status = "Restore failed: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    func delete(_ record: BackupRecord) {
        try? FileManager.default.trashItem(at: record.url, resultingItemURL: nil)
        reload()
    }

    func icon(for browserID: String) -> NSImage? { icons[browserID] }
}

// MARK: - Components

private struct BackupBrowserChip: View {
    let name: String
    let icon: NSImage?
    let installed: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "globe").font(.system(size: 18, weight: .light)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 30, height: 30)
                Text(name)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .scaleEffect(installed && hover ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!installed)
        .opacity(installed ? 1 : 0.35)
        .saturation(installed ? 1 : 0)
        .onHover { hover = $0 }
        .animation(.smooth(duration: 0.25), value: hover)
        .animation(.smooth(duration: 0.3), value: selected)
        .help(installed ? name : "\(name) is not installed on this Mac")
    }
}

private struct BackupRow: View {
    let record: BackupRecord
    let icon: NSImage?
    let onRestore: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    private var title: String {
        "\(record.manifest.browserName) · "
            + record.manifest.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
    private var detail: String {
        let names = record.manifest.items.map(\.title).joined(separator: ", ")
        return "\(record.manifest.reason) · \(names) · \(record.manifest.files.count) item(s) · \(byteText(record.manifest.totalBytes))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "globe").font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Restore…", action: onRestore).controlSize(.small)
            Button(action: onReveal) { Image(systemName: "folder") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Move this backup to the Trash")
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
    }
}

// MARK: - Backups window

struct BackupsView: View {
    @StateObject private var model = BackupModel()
    @AppStorage(BackupSettings.enabledKey) private var autoBackup = true
    @AppStorage(BackupSettings.itemsKey) private var itemsRaw = BackupSettings.defaultItemsRaw
    @AppStorage(BackupSettings.folderKey) private var folderPath = ""
    @AppStorage(BackupSettings.keepKey) private var keep = 5
    @State private var restoring: BackupRecord?

    private var folderURL: URL { folderPath.isEmpty ? BackupEngine.defaultFolder() : URL(fileURLWithPath: folderPath) }
    private var displayPath: String { folderURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    private func itemBinding(_ item: BackupItem) -> Binding<Bool> {
        Binding(
            get: { BackupSettings.parse(itemsRaw).contains(item) },
            set: { on in
                var chosen = BackupSettings.parse(itemsRaw)
                if on { chosen.insert(item) } else { chosen.remove(item) }
                itemsRaw = BackupItem.allCases.filter { chosen.contains($0) }.map(\.rawValue).joined(separator: "|")
            })
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                settingsCard.frame(maxWidth: .infinity)
                backupNowCard.frame(width: 390)
            }
            .fixedSize(horizontal: false, vertical: true)
            locationCard
            listCard
        }
        .padding(22)
        .frame(width: 860, height: 700)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear { model.refreshInstalled(); model.reload() }
        .onChange(of: folderPath) { _, _ in model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshInstalled()
            model.reload()
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
            titleVisibility: .visible,
            presenting: restoring
        ) { record in
            Button("Restore everything") { model.restore(record, only: nil) }
            if record.manifest.items.contains(.bookmarks) && record.manifest.items.count > 1 {
                Button("Restore bookmarks only") { model.restore(record, only: [.bookmarks]) }
            }
        } message: { record in
            Text("\(record.manifest.browserName) will be closed. Files it has now are moved to the Trash first, so you can undo this.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .shadow(color: .blue.opacity(0.3), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Backups").font(.title2.bold())
                Text("Safety copies of bookmarks and settings, saved before a reset").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $autoBackup) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Back up before every reset").font(.callout.weight(.semibold))
                    Text("Applies to manual and scheduled resets. If a backup fails, nothing is deleted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            Text("INCLUDE")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.8)

            ForEach(BackupItem.allCases) { item in
                Toggle(isOn: itemBinding(item)) {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol).foregroundStyle(Color.accentColor).frame(width: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.title).font(.callout)
                            Text(item.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }

    private var backupNowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Back up now").font(.callout.weight(.semibold))
            Text("Pick a browser and save a copy right away, using the items ticked on the left.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(model.browsers) { b in
                    BackupBrowserChip(name: b.name, icon: model.icon(for: b.id),
                                      installed: model.installed.contains(b.id),
                                      selected: model.selectedBrowserID == b.id) {
                        withAnimation(.smooth(duration: 0.3)) {
                            model.selectedBrowserID = (model.selectedBrowserID == b.id) ? nil : b.id
                        }
                    }
                }
            }

            Button {
                model.backupNow()
            } label: {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: "externaldrive.badge.plus") }
                    Text(model.busy ? "Working…" : "Back up now")
                }
            }
            .buttonStyle(PrimaryButtonStyle(colors: [.blue, .cyan]))
            .disabled(model.busy || model.selectedBrowserID == nil)
            .opacity(model.busy || model.selectedBrowserID == nil ? 0.5 : 1)
            .animation(.smooth(duration: 0.25), value: model.busy)

            Text(model.status.isEmpty ? " " : model.status)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.3), value: model.status)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }

    private var locationCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Backup location").font(.callout.weight(.semibold))
                Text(displayPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Picker("Keep", selection: $keep) {
                Text("Keep latest 3").tag(3)
                Text("Keep latest 5").tag(5)
                Text("Keep latest 10").tag(10)
                Text("Keep all").tag(0)
            }
            .labelsHidden().frame(width: 140)
            .help("Older backups for each browser are moved to the Trash automatically")
            Button("Choose…") { chooseFolder() }
            Button("Open") {
                try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folderURL)
            }
        }
        .card(padding: 12)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where backups are saved"
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }

    private var listSummary: String {
        if model.records.isEmpty { return "No backups yet." }
        let total = model.records.reduce(Int64(0)) { $0 + $1.manifest.totalBytes }
        return "\(model.records.count) backup(s) · \(byteText(total))"
    }

    private var listCard: some View {
        VStack(spacing: 8) {
            HStack {
                Text(listSummary).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            if model.records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("Backups appear here after your first reset or manual backup.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.records) { record in
                            BackupRow(record: record,
                                      icon: model.icon(for: record.manifest.browserID),
                                      onRestore: { restoring = record },
                                      onReveal: { NSWorkspace.shared.activateFileViewerSelecting([record.url]) },
                                      onDelete: { withAnimation(.smooth(duration: 0.3)) { model.delete(record) } })
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .card()
        .frame(maxHeight: .infinity)
    }
}
