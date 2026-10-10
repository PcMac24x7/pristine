import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Model

struct FoundFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date?
    let isPackage: Bool
    var id: URL { url }
}

enum ScanLocation: String, CaseIterable, Identifiable {
    case home = "Home Folder"
    case downloads = "Downloads"
    case desktop = "Desktop"
    case documents = "Documents"
    case movies = "Movies"
    case applications = "Applications"
    var id: String { rawValue }

    var url: URL {
        let fm = FileManager.default
        switch self {
        case .home: return fm.homeDirectoryForCurrentUser
        case .downloads: return fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        case .desktop: return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        case .documents: return fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        case .movies: return fm.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        case .applications: return URL(fileURLWithPath: "/Applications")
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .desktop: return "menubar.dock.rectangle"
        case .documents: return "doc.fill"
        case .movies: return "film.fill"
        case .applications: return "app.badge.fill"
        }
    }
}

enum SizeThreshold: Int64, CaseIterable, Identifiable {
    case mb100 = 100_000_000
    case mb500 = 500_000_000
    case gb1   = 1_000_000_000
    case gb2   = 2_000_000_000
    case gb5   = 5_000_000_000
    var id: Int64 { rawValue }
    var title: String {
        switch self {
        case .mb100: return "100 MB+"
        case .mb500: return "500 MB+"
        case .gb1:   return "1 GB+"
        case .gb2:   return "2 GB+"
        case .gb5:   return "5 GB+"
        }
    }
}

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter(); f.countStyle = .file; return f
}()

/// Recursively sums file sizes under a folder. Used to size app bundles and other packages as one unit.
func directorySize(_ url: URL) -> Int64 {
    guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
    var total: Int64 = 0
    for case let item as URL in en {
        if Task.isCancelled { break }
        if let s = try? item.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize { total += Int64(s) }
    }
    return total
}

// MARK: - Scanner

@MainActor
final class LargeFileScanner: ObservableObject {
    enum Phase: Equatable { case idle, scanning, done, cancelled, failed(String) }

    @Published var phase: Phase = .idle
    @Published var results: [FoundFile] = []
    @Published var scannedCount = 0
    @Published var selected: Set<URL> = []
    private var task: Task<Void, Never>?

    var selectedSize: Int64 { results.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func start(location: ScanLocation, minBytes: Int64) {
        task?.cancel()
        results = []; selected = []; scannedCount = 0
        phase = .scanning
        let root = location.url
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: root.path) else {
                await MainActor.run { self.phase = .failed("That folder doesn't exist.") }
                return
            }
            let found = self.walk(root: root, minBytes: minBytes) { [weak self] count in
                Task { @MainActor in self?.scannedCount = count }
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                if cancelled {
                    self.phase = .cancelled
                } else {
                    self.results = found.sorted { $0.size > $1.size }.prefix(300).map { $0 }
                    self.phase = .done
                }
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Synchronous on purpose: enumerating with FileManager's NSEnumerator isn't safe to resume
    /// across suspension points, so this never awaits. Progress is reported via `onProgress`
    /// instead of hopping to the main actor mid-loop.
    nonisolated private func walk(root: URL, minBytes: Int64, onProgress: @escaping (Int) -> Void) -> [FoundFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var found: [FoundFile] = []
        var count = 0
        for case let url as URL in en {
            if Task.isCancelled { break }
            guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if vals.isSymbolicLink == true { continue }

            if vals.isDirectory == true {
                if vals.isPackage == true {
                    let size = directorySize(url)
                    if size >= minBytes { found.append(FoundFile(url: url, size: size, modified: vals.contentModificationDate, isPackage: true)) }
                    en.skipDescendants()
                }
                continue
            }
            count += 1
            if count % 150 == 0 { onProgress(count) }
            let size = Int64(vals.fileSize ?? 0)
            if size >= minBytes {
                found.append(FoundFile(url: url, size: size, modified: vals.contentModificationDate, isPackage: false))
            }
        }
        onProgress(count)
        return found
    }

    func toggle(_ f: FoundFile) {
        if selected.contains(f.url) { selected.remove(f.url) } else { selected.insert(f.url) }
    }
    func selectAll() { selected = Set(results.map(\.url)) }
    func clearSelection() { selected.removeAll() }

    /// Moves the selected items to the Trash (recoverable).
    func trashSelected() {
        for url in selected {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        results.removeAll { selected.contains($0.url) }
        selected.removeAll()
    }
}

// MARK: - Empty Trash

enum TrashTool {
    static var trashURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }

    static func size() -> (count: Int, bytes: Int64) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil) else { return (0, 0) }
        let bytes = items.reduce(Int64(0)) { $0 + directorySize($1) }
        return (items.count, bytes)
    }

    /// Permanently deletes everything in the user's Trash. This cannot be undone.
    static func empty() -> Result<Int, Error> {
        do {
            let items = try FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)
            var count = 0
            var lastError: Error?
            for item in items {
                do { try FileManager.default.removeItem(at: item); count += 1 }
                catch { lastError = error }
            }
            if let lastError, count == 0 { return .failure(lastError) }
            return .success(count)
        } catch { return .failure(error) }
    }
}

// MARK: - UI

struct FileRow: View {
    let file: FoundFile
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary.opacity(0.5))
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)

            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable().frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                Text(file.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(byteFormatter.string(fromByteCount: file.size))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(file.size > 1_000_000_000 ? Color.orange : .primary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
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

struct LargeFilesView: View {
    @StateObject private var scanner = LargeFileScanner()
    @StateObject private var disk = DiskMonitor()
    @State private var location: ScanLocation = .home
    @State private var threshold: SizeThreshold = .gb1
    @State private var showTrashConfirm = false
    @State private var trashInfo = TrashTool.size()
    @State private var emptyStatus = ""
    @State private var showEmptyConfirm = false

    var body: some View {
        VStack(spacing: 18) {
            header
            DiskUsageCard(monitor: disk)
            controls
            resultsCard
            trashCard
        }
        .padding(22)
        .frame(width: 720, height: 760)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear { trashInfo = TrashTool.size(); disk.refresh() }
        .confirmationDialog("Move \(scanner.selected.count) item(s) to the Trash?", isPresented: $showTrashConfirm) {
            Button("Move to Trash", role: .destructive) {
                withAnimation(.snappy) { scanner.trashSelected() }
                disk.refresh()
            }
        } message: {
            Text("You can restore these from the Trash afterwards.")
        }
        .confirmationDialog("Empty the Trash?", isPresented: $showEmptyConfirm) {
            Button("Empty Trash", role: .destructive) { emptyTrash() }
        } message: {
            Text("This permanently deletes everything in the Trash. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "externaldrive.fill.badge.minus")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .shadow(color: .orange.opacity(0.3), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Large Files & Trash").font(.title2.bold())
                Text("Find what's taking up space, then clear it").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $location) {
                ForEach(ScanLocation.allCases) { loc in
                    Label(loc.rawValue, systemImage: loc.symbol).tag(loc)
                }
            }
            .labelsHidden().frame(width: 190)

            Picker("", selection: $threshold) {
                ForEach(SizeThreshold.allCases) { t in Text(t.title).tag(t) }
            }
            .labelsHidden().frame(width: 110)

            Spacer()

            if scanner.phase == .scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanned \(scanner.scannedCount) items…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Stop") { scanner.cancel() }.buttonStyle(.bordered)
            } else {
                Button {
                    scanner.start(location: location, minBytes: threshold.rawValue)
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var resultsCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text(resultsSummary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !scanner.results.isEmpty {
                    Button(scanner.selected.count == scanner.results.count ? "Clear" : "Select All") {
                        scanner.selected.count == scanner.results.count ? scanner.clearSelection() : scanner.selectAll()
                    }
                    .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                }
            }

            if scanner.results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: scanner.phase == .scanning ? "magnifyingglass" : "tray")
                        .font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(emptyMessage).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(scanner.results) { f in
                            FileRow(file: f, selected: scanner.selected.contains(f.url)) {
                                withAnimation(.snappy) { scanner.toggle(f) }
                            }
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 280)
            }

            if !scanner.selected.isEmpty {
                Button {
                    showTrashConfirm = true
                } label: {
                    Label("Move \(scanner.selected.count) item(s) to Trash · \(byteFormatter.string(fromByteCount: scanner.selectedSize))",
                          systemImage: "trash")
                }
                .buttonStyle(PrimaryButtonStyle(colors: [.red, .orange]))
            }
        }
        .card()
    }

    private var resultsSummary: String {
        switch scanner.phase {
        case .idle: return "Choose a location and a minimum size, then scan."
        case .scanning: return "Scanning \(location.rawValue)…"
        case .cancelled: return "Scan stopped."
        case .failed(let msg): return msg
        case .done: return scanner.results.isEmpty
            ? "No files at or above \(threshold.title) found in \(location.rawValue)."
            : "\(scanner.results.count) file(s) found, largest first."
        }
    }
    private var emptyMessage: String {
        scanner.phase == .scanning ? "Looking for large files…" : "Nothing to show yet."
    }

    private var trashCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "trash.fill").font(.system(size: 22)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Trash").font(.callout.weight(.semibold))
                Text(trashInfo.count == 0
                     ? "Empty"
                     : "\(trashInfo.count) item(s) · \(byteFormatter.string(fromByteCount: trashInfo.bytes))")
                    .font(.caption).foregroundStyle(.secondary)
                if !emptyStatus.isEmpty {
                    Text(emptyStatus).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Refresh") { trashInfo = TrashTool.size() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
            Button(role: .destructive) { showEmptyConfirm = true } label: {
                Label("Empty Trash", systemImage: "trash.slash")
            }
            .buttonStyle(.bordered)
            .disabled(trashInfo.count == 0)
        }
        .card()
    }

    private func emptyTrash() {
        switch TrashTool.empty() {
        case .success(let count):
            emptyStatus = "Removed \(count) item(s)."
        case .failure(let error):
            emptyStatus = "Some items couldn't be removed: \(error.localizedDescription)"
        }
        trashInfo = TrashTool.size()
        disk.refresh()
    }
}
