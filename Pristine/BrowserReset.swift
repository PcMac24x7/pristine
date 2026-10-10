import SwiftUI
import AppKit
import Combine

// MARK: - Model

enum DataCategory: String, CaseIterable, Identifiable {
    case history = "History"
    case cookies = "Cookies"
    case cache = "Cache"
    case siteData = "Site data (local storage, IndexedDB)"
    case sessions = "Open tabs"
    var id: String { rawValue }
}

struct Browser: Identifiable {
    let id: String            // bundle identifier
    let name: String
    let targets: (DataCategory) -> [URL]

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }
    var runningApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: id)
    }
}

private let home = FileManager.default.homeDirectoryForCurrentUser
private func lib(_ path: String) -> URL { home.appendingPathComponent("Library/\(path)") }

/// Subfolders of `dir` (e.g. browser profiles) matching a predicate.
private func subfolders(_ dir: URL, where match: (String) -> Bool) -> [URL] {
    let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return items.filter(match).map { dir.appendingPathComponent($0) }
}

/// Chromium-based browsers share one layout.
private func chromium(id: String, name: String, support: String, cache: String) -> Browser {
    Browser(id: id, name: name) { category in
        let root = lib("Application Support/\(support)")
        let profiles = subfolders(root) { $0 == "Default" || $0.hasPrefix("Profile ") }
        switch category {
        case .history:
            return profiles.flatMap { p in ["History", "History-journal", "Top Sites", "Visited Links"].map { p.appendingPathComponent($0) } }
        case .cookies:
            return profiles.flatMap { p in ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"].map { p.appendingPathComponent($0) } }
        case .cache:
            return [lib("Caches/\(cache)")] + profiles.flatMap { p in ["Cache", "Code Cache", "GPUCache"].map { p.appendingPathComponent($0) } }
        case .siteData:
            return profiles.flatMap { p in ["Local Storage", "IndexedDB", "Session Storage", "Service Worker"].map { p.appendingPathComponent($0) } }
        case .sessions:
            return profiles.flatMap { p in ["Sessions", "Current Session", "Current Tabs", "Last Session", "Last Tabs"].map { p.appendingPathComponent($0) } }
        }
    }
}

let allBrowsers: [Browser] = [
    Browser(id: "com.apple.Safari", name: "Safari") { category in
        let c = "Containers/com.apple.Safari/Data/Library"
        switch category {
        case .history:
            return ["History.db", "History.db-lock", "History.db-shm", "History.db-wal"].map { lib("Safari/\($0)") }
        case .cookies:
            return [lib("Cookies/Cookies.binarycookies"), lib("\(c)/Cookies/Cookies.binarycookies")]
        case .cache:
            return [lib("Caches/com.apple.Safari"), lib("\(c)/Caches")]
        case .siteData:
            return [lib("Safari/LocalStorage"), lib("WebKit/com.apple.Safari"), lib("\(c)/WebKit")]
        case .sessions:
            return [lib("Safari/LastSession.plist"), lib("\(c)/Safari/LastSession.plist"),
                    lib("Saved Application State/com.apple.Safari.savedState")]
        }
    },
    chromium(id: "com.google.Chrome", name: "Google Chrome", support: "Google/Chrome", cache: "Google/Chrome"),
    chromium(id: "com.microsoft.edgemac", name: "Microsoft Edge", support: "Microsoft Edge", cache: "Microsoft Edge"),
    chromium(id: "com.brave.Browser", name: "Brave", support: "BraveSoftware/Brave-Browser", cache: "BraveSoftware/Brave-Browser"),
    chromium(id: "company.thebrowser.Browser", name: "Arc", support: "Arc/User Data", cache: "Arc"),
    Browser(id: "org.mozilla.firefox", name: "Firefox") { category in
        let profiles = subfolders(lib("Application Support/Firefox/Profiles")) { _ in true }
        switch category {
        // NOTE: places.sqlite also holds bookmarks. Deleting it removes bookmarks too.
        case .history:  return profiles.map { $0.appendingPathComponent("places.sqlite") }
        case .cookies:  return profiles.flatMap { p in ["cookies.sqlite", "cookies.sqlite-wal"].map { p.appendingPathComponent($0) } }
        case .cache:    return [lib("Caches/Firefox")]
        case .siteData: return profiles.map { $0.appendingPathComponent("storage") }
        case .sessions: return profiles.flatMap { p in ["sessionstore.jsonlz4", "sessionstore-backups", "sessionCheckpoints.json"].map { p.appendingPathComponent($0) } }
        }
    }
]

// MARK: - Engine

enum ResetError: LocalizedError {
    case couldNotQuit(String)
    case backupFailed(String)
    var errorDescription: String? {
        switch self {
        case .couldNotQuit(let n): return "\(n) would not quit. Close it manually and try again."
        case .backupFailed(let why): return "Backup failed, so nothing was deleted. (\(why))"
        }
    }
}

struct ResetResult {
    var trashed = 0
    var failed: [String] = []
    var backupFiles = 0          // items saved in the pre-reset backup (0 if none was made)
}

enum Engine {
    /// Reading ~/Library/Safari throws if Full Disk Access hasn't been granted.
    static func hasFullDiskAccess() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: lib("Safari").path)) != nil
    }

    static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Ask the browser to quit, wait up to `timeout` seconds, then force-quit as a last resort.
    static func quit(_ browser: Browser, timeout: TimeInterval = 8) async throws {
        let apps = browser.runningApps
        guard !apps.isEmpty else { return }
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !browser.runningApps.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if !browser.runningApps.isEmpty {
            browser.runningApps.forEach { $0.forceTerminate() }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if !browser.runningApps.isEmpty { throw ResetError.couldNotQuit(browser.name) }
    }

    static func paths(for browser: Browser, categories: Set<DataCategory>) -> [URL] {
        categories.flatMap(browser.targets).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Moves files to the Trash (recoverable) rather than deleting them.
    /// Order of operations: close the browser, back up (if requested), then move files to the Trash.
    /// If the backup fails the reset is aborted before anything is touched.
    static func reset(_ browser: Browser, categories: Set<DataCategory>, backup: BackupRequest? = nil) async throws -> ResetResult {
        try await quit(browser)
        var result = ResetResult()
        if let backup {
            do {
                let record = try await BackupEngine.create(browserID: browser.id, browserName: browser.name,
                                                           items: backup.items, root: backup.folder,
                                                           reason: backup.reason, keep: backup.keep)
                result.backupFiles = record?.manifest.files.count ?? 0
            } catch {
                throw ResetError.backupFailed(error.localizedDescription)
            }
        }
        for url in paths(for: browser, categories: categories) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                result.trashed += 1
            } catch {
                result.failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }
}

@main
struct BrowserResetApp: App {
    @ObservedObject private var auto = AutoReset.shared

    init() { AutoReset.shared.start() }

    var body: some Scene {
        MenuBarExtra("Pristine", systemImage: "arrow.counterclockwise.circle") {
            MenuContent(auto: auto)
        }
        Window("Pristine", id: "main") { ContentView() }
            .windowResizability(.contentSize)
        Window("Schedule & Settings", id: "settings") { SettingsView(auto: auto) }
        Window("Large Files & Trash", id: "largefiles") { LargeFilesView() }
            .windowResizability(.contentSize)
        Window("Backups", id: "backups") { BackupsView() }
            .windowResizability(.contentSize)
        Window("Activity Monitor", id: "activity") { ActivityMonitorView() }
            .windowResizability(.contentSize)
        Window("Unused Apps", id: "unusedapps") { UnusedAppsView() }
            .windowResizability(.contentSize)
    }
}
