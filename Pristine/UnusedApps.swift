import SwiftUI
import AppKit
import Combine
import CoreServices

// MARK: - Model

struct AppEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    let lastUsed: Date?
    let size: Int64
    var id: URL { url }
}

enum UnusedPeriod: Int, CaseIterable, Identifiable {
    case months3 = 3, months6 = 6, months12 = 12
    var id: Int { rawValue }
    var title: String { "\(rawValue) months" }
    var cutoff: Date { Calendar.current.date(byAdding: .month, value: -rawValue, to: Date()) ?? .distantPast }
}

enum AppSortKey: String, CaseIterable, Identifiable {
    case size = "Largest", oldest = "Least recent", name = "Name"
    var id: String { rawValue }
}

private func sizeString(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}

private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
}()

// MARK: - Scanning helpers (synchronous, run off the main thread)

private func findInstalledApps() -> [URL] {
    let fm = FileManager.default
    let roots = [URL(fileURLWithPath: "/Applications"),
                 fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    var result: [URL] = []
    for root in roots where fm.fileExists(atPath: root.path) {
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.isSymbolicLinkKey],
                                     options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
        while let obj = en.nextObject() {
            guard let url = obj as? URL else { continue }
            if url.pathExtension.lowercased() == "app" {
                let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                if isLink != true { result.append(url) }
                continue
            }
            if en.level > 2 { en.skipDescendants() }      // don't dig through deep folders
        }
    }
    return result
}

private func inspectApp(_ url: URL, broadCutoff: Date) -> AppEntry {
    let bundle = Bundle(url: url)
    let info = bundle?.infoDictionary ?? [:]
    let name = (info["CFBundleDisplayName"] as? String)
        ?? (info["CFBundleName"] as? String)
        ?? url.deletingPathExtension().lastPathComponent
    let version = info["CFBundleShortVersionString"] as? String

    var last: Date?
    if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
        last = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // Only measure apps that could appear in the list; recently used apps are skipped to save time.
    var size: Int64 = 0
    if last == nil || (last ?? .distantPast) < broadCutoff {
        size = directorySize(url)
    }
    return AppEntry(url: url, name: name, bundleID: bundle?.bundleIdentifier,
                    version: version, lastUsed: last, size: size)
}

// MARK: - Scanner

@MainActor
final class UnusedAppsScanner: ObservableObject {
    enum Phase: Equatable { case idle, scanning, done }

    @Published var phase: Phase = .idle
    @Published var apps: [AppEntry] = []
    @Published var progress = 0
    @Published var total = 0
    @Published var selected: Set<URL> = []
    @Published var message = ""

    private var task: Task<Void, Never>?

    func scan() {
        task?.cancel()
        apps = []; selected = []; progress = 0; total = 0; message = ""
        phase = .scanning

        // Apps that are open right now (and this app itself) are never candidates.
        var skip = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        skip.insert(Bundle.main.bundleURL.path)
        let skipPaths = skip
        let broadCutoff = UnusedPeriod.months3.cutoff

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let urls = findInstalledApps().filter { !skipPaths.contains($0.path) }
            await MainActor.run { self.total = urls.count }

            var found: [AppEntry] = []
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { break }
                found.append(inspectApp(url, broadCutoff: broadCutoff))
                if index % 2 == 0 {
                    let done = index + 1
                    await MainActor.run { self.progress = done }
                }
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                if cancelled {
                    self.phase = .idle
                } else {
                    self.apps = found
                    self.progress = urls.count
                    self.phase = .done
                }
            }
        }
    }

    func toggle(_ app: AppEntry) {
        if selected.contains(app.url) { selected.remove(app.url) } else { selected.insert(app.url) }
    }

    /// Moves the given apps to the Trash. Apps owned by the system may need administrator permission.
    func trash(_ targets: [AppEntry]) async {
        var moved: Set<URL> = []
        var failed: [AppEntry] = []
        for app in targets {
            do {
                try FileManager.default.trashItem(at: app.url, resultingItemURL: nil)
                moved.insert(app.url)
            } catch {
                failed.append(app)
            }
        }
        // Second attempt through the system, which can handle some protected items.
        if !failed.isEmpty {
            let urls = failed.map(\.url)
            let recycled: [URL: URL] = await withCheckedContinuation { cont in
                NSWorkspace.shared.recycle(urls) { newURLs, _ in cont.resume(returning: newURLs) }
            }
            for url in recycled.keys { moved.insert(url) }
            failed.removeAll { moved.contains($0.url) }
        }
        apps.removeAll { moved.contains($0.url) }
        selected.subtract(moved)

        var text = "Moved \(moved.count) app(s) to the Trash."
        if !failed.isEmpty {
            text += " \(failed.count) couldn't be moved (administrator permission needed). Use Reveal in Finder and drag \(failed.count == 1 ? "it" : "them") to the Trash."
        }
        message = text
    }
}

// MARK: - UI

struct AppRow: View {
    let app: AppEntry
    let selected: Bool
    let toggle: () -> Void

    private var detail: String {
        var parts: [String] = []
        if let v = app.version { parts.append("Version \(v)") }
        if let d = app.lastUsed {
            parts.append("Last opened " + relativeFormatter.localizedString(for: d, relativeTo: Date()))
        } else {
            parts.append("No usage record")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)

            Image(nsImage: IconCache.icon(forFile: app.url.path))
                .resizable().interpolation(.high).frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(sizeString(app.size))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(app.size > 1_000_000_000 ? Color.orange : Color.primary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(selected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

struct UnusedAppsView: View {
    @StateObject private var scanner = UnusedAppsScanner()
    @StateObject private var disk = DiskMonitor()
    @State private var period: UnusedPeriod = .months6
    @State private var sort: AppSortKey = .size
    @State private var includeUnknown = true
    @State private var showConfirm = false

    private var candidates: [AppEntry] {
        let cutoff = period.cutoff
        let list = scanner.apps.filter { app in
            if let d = app.lastUsed { return d < cutoff }
            return includeUnknown
        }
        switch sort {
        case .size: return list.sorted { $0.size > $1.size }
        case .oldest: return list.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .name: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private var selectedApps: [AppEntry] { candidates.filter { scanner.selected.contains($0.url) } }
    private var selectedSize: Int64 { selectedApps.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 16) {
            header
            DiskUsageCard(monitor: disk)
            controls
            listCard
        }
        .padding(22)
        .frame(width: 740, height: 780)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear {
            disk.refresh()
            if scanner.phase == .idle { scanner.scan() }
        }
        .confirmationDialog("Move \(selectedApps.count) app(s) to the Trash?", isPresented: $showConfirm) {
            Button("Move to Trash", role: .destructive) {
                let targets = selectedApps
                Task {
                    await scanner.trash(targets)
                    disk.refresh()
                }
            }
        } message: {
            Text("You can restore them from the Trash. Their settings and support files stay on your Mac.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .shadow(color: .purple.opacity(0.3), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unused Apps").font(.title2.bold())
                Text("Apps you haven't opened in a while").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("Not opened in").font(.callout).foregroundStyle(.secondary)
                Picker("", selection: $period) {
                    ForEach(UnusedPeriod.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 120)

                Picker("", selection: $sort) {
                    ForEach(AppSortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)

                Spacer()

                if scanner.phase == .scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        scanner.scan()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
            HStack {
                Toggle("Include apps with no usage record", isOn: $includeUnknown)
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
            }
        }
    }

    private var summary: String {
        switch scanner.phase {
        case .idle: return "Scan to find apps you haven't opened in a while."
        case .scanning: return "Checking installed apps… \(scanner.progress) of \(scanner.total)"
        case .done:
            if candidates.isEmpty { return "No apps found that haven't been opened in \(period.rawValue)+ months." }
            let total = candidates.reduce(Int64(0)) { $0 + $1.size }
            return "\(candidates.count) app(s) not opened in \(period.rawValue)+ months · \(sizeString(total))"
        }
    }

    private var listCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !candidates.isEmpty {
                    let allSelected = selectedApps.count == candidates.count
                    Button(allSelected ? "Clear" : "Select All") {
                        if allSelected {
                            scanner.selected.subtract(candidates.map(\.url))
                        } else {
                            scanner.selected.formUnion(candidates.map(\.url))
                        }
                    }
                    .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                }
            }

            if scanner.phase == .scanning {
                ProgressView(value: Double(scanner.progress), total: Double(max(scanner.total, 1)))
                    .frame(maxWidth: .infinity)
            }

            if candidates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: scanner.phase == .scanning ? "magnifyingglass" : "checkmark.seal")
                        .font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(scanner.phase == .scanning ? "Looking at your apps…" : "Nothing to show.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(candidates) { app in
                            AppRow(app: app, selected: scanner.selected.contains(app.url)) {
                                withAnimation(.snappy) { scanner.toggle(app) }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            if !scanner.message.isEmpty {
                Text(scanner.message).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !selectedApps.isEmpty {
                Button {
                    showConfirm = true
                } label: {
                    Label("Move \(selectedApps.count) app(s) to Trash · \(sizeString(selectedSize))", systemImage: "trash")
                }
                .buttonStyle(PrimaryButtonStyle(colors: [.red, .orange]))
            }
        }
        .card()
        .frame(maxHeight: .infinity)
    }
}
