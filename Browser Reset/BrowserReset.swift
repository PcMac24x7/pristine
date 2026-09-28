import SwiftUI
import AppKit

// MARK: - Model

enum DataCategory: String, CaseIterable, Identifiable {
    case history = "History"
    case cookies = "Cookies"
    case cache = "Cache"
    case siteData = "Site data (local storage, IndexedDB)"
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
        }
    }
]

// MARK: - Engine

enum ResetError: LocalizedError {
    case couldNotQuit(String)
    var errorDescription: String? {
        switch self { case .couldNotQuit(let n): return "\(n) would not quit. Close it manually and try again." }
    }
}

struct ResetResult { var trashed = 0; var failed: [String] = [] }

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
    static func reset(_ browser: Browser, categories: Set<DataCategory>) async throws -> ResetResult {
        try await quit(browser)
        var result = ResetResult()
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

// MARK: - UI

@MainActor
final class ViewModel: ObservableObject {
    @Published var browsers = allBrowsers.filter(\.isInstalled)
    @Published var selectedID: String?
    @Published var categories: Set<DataCategory> = [.history, .cookies, .cache]
    @Published var hasAccess = Engine.hasFullDiskAccess()
    @Published var status = ""
    @Published var busy = false
    @Published var showConfirm = false

    var selected: Browser? { browsers.first { $0.id == selectedID } }
    var preview: [URL] { selected.map { Engine.paths(for: $0, categories: categories) } ?? [] }

    func refreshAccess() { hasAccess = Engine.hasFullDiskAccess() }

    func reset() {
        guard let b = selected else { return }
        busy = true; status = "Closing \(b.name)…"
        Task {
            do {
                let r = try await Engine.reset(b, categories: categories)
                status = "Done. \(r.trashed) item(s) moved to the Trash." + (r.failed.isEmpty ? "" : " Failed: \(r.failed.joined(separator: "; "))")
            } catch { status = error.localizedDescription }
            busy = false
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = ViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Browser Reset").font(.title2.bold())

            if !vm.hasAccess {
                HStack {
                    Text("Full Disk Access is required to clear Safari and other browser data.")
                    Spacer()
                    Button("Open Settings") { Engine.openFullDiskAccessSettings() }
                    Button("Recheck") { vm.refreshAccess() }
                }
                .padding(10).background(.yellow.opacity(0.2)).cornerRadius(8)
            }

            Picker("Browser", selection: $vm.selectedID) {
                Text("Choose…").tag(String?.none)
                ForEach(vm.browsers) { Text($0.name).tag(Optional($0.id)) }
            }

            VStack(alignment: .leading) {
                ForEach(DataCategory.allCases) { cat in
                    Toggle(cat.rawValue, isOn: Binding(
                        get: { vm.categories.contains(cat) },
                        set: { on in if on { vm.categories.insert(cat) } else { vm.categories.remove(cat) } }))
                }
            }

            Text("\(vm.preview.count) item(s) will be moved to the Trash").foregroundStyle(.secondary)
            List(vm.preview, id: \.self) { Text($0.path).font(.caption.monospaced()) }
                .frame(minHeight: 120)

            HStack {
                Button("Reset…", role: .destructive) { vm.showConfirm = true }
                    .disabled(vm.selected == nil || vm.preview.isEmpty || vm.busy || !vm.hasAccess)
                if vm.busy { ProgressView().controlSize(.small) }
                Text(vm.status).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .confirmationDialog("Reset \(vm.selected?.name ?? "browser")?", isPresented: $vm.showConfirm) {
            Button("Quit browser and reset", role: .destructive) { vm.reset() }
        } message: {
            Text("The browser will be closed and the listed items moved to the Trash. Synced data may come back from the cloud.")
        }
    }
}

@main
struct BrowserResetApp: App {
    @ObservedObject private var auto = AutoReset.shared

    init() { AutoReset.shared.start() }

    var body: some Scene {
        MenuBarExtra("Browser Reset", systemImage: "arrow.counterclockwise.circle") {
            MenuContent(auto: auto)
        }
        Window("Browser Reset", id: "main") { ContentView() }
        Window("Schedule & Settings", id: "settings") { SettingsView(auto: auto) }
    }
}
