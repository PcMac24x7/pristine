import SwiftUI
import AppKit
import Combine

// MARK: - Presentation helpers

extension DataCategory {
    var title: String {
        switch self {
        case .history:  return "History"
        case .cookies:  return "Cookies"
        case .cache:    return "Cache"
        case .siteData: return "Site data"
        case .sessions: return "Open tabs"
        }
    }
    var detail: String {
        switch self {
        case .history:  return "Sites you've visited"
        case .cookies:  return "Logins and trackers"
        case .cache:    return "Temporary files"
        case .siteData: return "Storage and databases"
        case .sessions: return "Stops old tabs reopening"
        }
    }
    var symbol: String {
        switch self {
        case .history:  return "clock.arrow.circlepath"
        case .cookies:  return "key.fill"
        case .cache:    return "internaldrive.fill"
        case .siteData: return "cylinder.split.1x2.fill"
        case .sessions: return "rectangle.stack.fill"
        }
    }
}

extension Browser {
    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
}

extension View {
    /// Fade-and-rise entrance, staggered by index.
    func reveal(_ index: Int, _ appeared: Bool) -> some View {
        opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(.smooth(duration: 0.55).delay(Double(index) * 0.06), value: appeared)
    }

    func card(padding amount: CGFloat = 16) -> some View {
        padding(amount)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

// MARK: - View model

@MainActor
final class ViewModel: ObservableObject {
    enum Phase: Equatable { case idle, working, done, failed }

    let browsers = allBrowsers
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published var selectedID: String?
    @Published var categories: Set<DataCategory> = [.history, .cookies, .cache, .sessions]
    @Published private(set) var previewPaths: [URL] = []
    @Published var hasAccess = Engine.hasFullDiskAccess()
    @Published var phase: Phase = .idle
    @Published var status = ""
    @Published var showConfirm = false
    @Published var showFiles = false

    init() { refreshInstalled() }

    var selected: Browser? { browsers.first { $0.id == selectedID } }
    var canReset: Bool { selected != nil && !previewPaths.isEmpty && hasAccess && phase != .working }

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
        if let s = selectedID, !ids.contains(s) { selectedID = nil }
        refreshPreview()
    }

    func refreshAccess() { hasAccess = Engine.hasFullDiskAccess() }

    func refreshPreview() {
        previewPaths = selected.map { Engine.paths(for: $0, categories: categories) } ?? []
    }

    func select(_ b: Browser) {
        selectedID = (selectedID == b.id) ? nil : b.id
        refreshPreview()
    }

    func toggle(_ c: DataCategory) {
        if categories.contains(c) { categories.remove(c) } else { categories.insert(c) }
        refreshPreview()
    }

    func reset() {
        guard let b = selected else { return }
        withAnimation(.snappy) { phase = .working }
        let backup = BackupSettings.request(reason: "Before reset")
        status = backup == nil
            ? "Closing \(b.name) and clearing data…"
            : "Closing \(b.name), backing up, then clearing data…"
        Task {
            do {
                let r = try await Engine.reset(b, categories: categories, backup: backup)
                var text = r.failed.isEmpty
                    ? "Done. \(r.trashed) item(s) moved to the Trash."
                    : "Finished with \(r.failed.count) error(s): \(r.failed.first ?? "")"
                if r.backupFiles > 0 { text += " Backup saved." }
                status = text
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { phase = r.failed.isEmpty ? .done : .failed }
            } catch {
                status = error.localizedDescription
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { phase = .failed }
            }
            withAnimation(.snappy) { refreshPreview() }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            withAnimation(.snappy) { phase = .idle }
        }
    }
}

// MARK: - Components

struct BrowserTile: View {
    let name: String
    let icon: NSImage?
    let installed: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                iconView
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(installed ? 0.16 : 0), radius: 4, y: 2)
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(installed ? (selected ? "Selected" : "Ready") : "Not installed")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .scaleEffect(installed && hover ? 1.03 : 1)
            .shadow(color: .black.opacity(installed && hover ? 0.10 : 0), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!installed)
        .opacity(installed ? 1 : 0.4)
        .saturation(installed ? 1 : 0)
        .onHover { hover = $0 }
        .animation(.smooth(duration: 0.25), value: hover)
        .animation(.smooth(duration: 0.3), value: selected)
        .help(installed ? name : "\(name) is not installed on this Mac")
    }

    @ViewBuilder private var iconView: some View {
        if let icon {
            Image(nsImage: icon).resizable().interpolation(.high)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.gray.opacity(0.25))
                Image(systemName: "globe").font(.system(size: 17, weight: .light)).foregroundStyle(.secondary)
            }
        }
    }
}

struct CategoryChip: View {
    let category: DataCategory
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: category.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(on ? Color.accentColor : Color.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(category.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.85)
                Text(category.detail)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.vertical, 9).padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(on ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(on ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1.5))
            .overlay(alignment: .topTrailing) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.45))
                    .contentTransition(.symbolEffect(.replace))
                    .padding(6)
            }
            .scaleEffect(hover ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.smooth(duration: 0.25), value: hover)
        .animation(.smooth(duration: 0.3), value: on)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    let colors: [Color]
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .shadow(color: (colors.first ?? .blue).opacity(0.35), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Toolbar button (icon with label)

struct ToolButton: View {
    let symbol: String
    let title: String
    let help: String
    let colors: [Color]
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: (colors.first ?? .gray).opacity(hover ? 0.40 : 0.18), radius: hover ? 8 : 4, y: hover ? 4 : 2)
                    .scaleEffect(hover ? 1.08 : 1)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(hover ? Color.primary : Color.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 80)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.smooth(duration: 0.25), value: hover)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Main window

struct ContentView: View {
    @StateObject private var vm = ViewModel()
    @StateObject private var disk = DiskMonitor()
    @AppStorage(BackupSettings.enabledKey) private var backupFirst = true
    @State private var appeared = false
    @Environment(\.openWindow) private var openWindow
    private let spring = Animation.smooth(duration: 0.3)

    var body: some View {
        VStack(spacing: 14) {
            header.reveal(0, appeared)
            HStack(alignment: .center, spacing: 14) {
                toolbarRow
                DiskUsageCard(monitor: disk, compact: true)
            }
            .reveal(1, appeared)
            browserSection.reveal(2, appeared)
            categorySection.reveal(3, appeared)
            summaryCard.reveal(4, appeared)
            Spacer(minLength: 0)
            resetSection.reveal(5, appeared)
        }
        .padding(18)
        .frame(width: 820, height: 560)
        .background(background)
        .onAppear { appeared = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.refreshAccess()
            vm.refreshInstalled()
            disk.refresh()
        }
        .onChange(of: vm.phase) { _, newValue in
            if newValue == .done { disk.refresh() }
        }
        .confirmationDialog("Reset \(vm.selected?.name ?? "browser")?", isPresented: $vm.showConfirm) {
            Button("Quit browser and reset", role: .destructive) { vm.reset() }
        } message: {
            Text("The browser will be closed and the selected data moved to the Trash. Synced data may return from the cloud.")
        }
    }

    // Header
    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 1) {
                Text("Pristine").font(.title3.bold())
                Text("Reset browsers, clear space, stay tidy").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SupportButton()
            accessPill
        }
    }

    private var accessPill: some View {
        let color: Color = vm.hasAccess ? .green : .orange
        return Button {
            if !vm.hasAccess { Engine.openFullDiskAccessSettings() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: vm.hasAccess ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                Text(vm.hasAccess ? "Access granted" : "Grant access")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(vm.hasAccess ? "Full Disk Access is enabled" : "Open System Settings to grant Full Disk Access")
        .animation(.smooth(duration: 0.3), value: vm.hasAccess)
    }

    private var toolbarRow: some View {
        HStack(spacing: 2) {
            ToolButton(symbol: "externaldrive.fill.badge.minus", title: "Large Files",
                       help: "Find large files and empty the Trash", colors: [.orange, .red]) { openWindow(id: "largefiles") }
            ToolButton(symbol: "archivebox.fill", title: "Unused Apps",
                       help: "Apps you haven't opened in a while", colors: [.purple, .pink]) { openWindow(id: "unusedapps") }
            ToolButton(symbol: "waveform.path.ecg", title: "Activity Monitor",
                       help: "Live CPU and memory use", colors: [.teal, .green]) { openWindow(id: "activity") }
            ToolButton(symbol: "externaldrive.badge.timemachine", title: "Backups",
                       help: "Back up bookmarks and settings, and restore them", colors: [.blue, .cyan]) { openWindow(id: "backups") }
            ToolButton(symbol: "gearshape.fill", title: "Settings",
                       help: "Schedule & Settings", colors: [.gray, .secondary]) { openWindow(id: "settings") }
        }
    }

    // Sections
    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var browserSection: some View {
        VStack(spacing: 8) {
            sectionTitle("Choose a browser")
            HStack(spacing: 10) {
                ForEach(vm.browsers) { b in
                    BrowserTile(name: b.name,
                                icon: vm.icons[b.id],
                                installed: vm.installed.contains(b.id),
                                selected: vm.selectedID == b.id) {
                        withAnimation(spring) { vm.select(b) }
                    }
                }
            }
        }
    }

    private var categorySection: some View {
        VStack(spacing: 8) {
            sectionTitle("What to clear")
            HStack(spacing: 10) {
                ForEach(DataCategory.allCases) { c in
                    CategoryChip(category: c, on: vm.categories.contains(c)) {
                        withAnimation(spring) { vm.toggle(c) }
                    }
                }
            }
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.circle.fill")
                .font(.system(size: 26))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(vm.previewPaths.isEmpty ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("\(vm.previewPaths.count)")
                        .font(.headline.bold())
                        .contentTransition(.numericText())
                    Text("item(s) will move to the Trash").font(.callout)
                }
                Text(summarySubtitle)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer()
            Toggle(isOn: $backupFirst) {
                Label("Back up first", systemImage: "externaldrive.badge.checkmark")
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Save a copy of your bookmarks and settings before resetting. Choose what's included in Backups.")
            if !vm.previewPaths.isEmpty {
                Button {
                    vm.showFiles.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("Show files")
                        Image(systemName: "list.bullet")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .popover(isPresented: $vm.showFiles, arrowEdge: .top) { filesPopover }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .card(padding: 12)
        .animation(.smooth(duration: 0.3), value: vm.previewPaths.count)
        .animation(.smooth(duration: 0.3), value: summarySubtitle)
    }

    private var filesPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(vm.previewPaths, id: \.self) { url in
                    Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .frame(width: 480, height: 220)
    }

    private var summarySubtitle: String {
        if !vm.hasAccess { return "Grant Full Disk Access to enable resetting." }
        guard let b = vm.selected else { return "Select a browser to see what will be cleared." }
        if vm.previewPaths.isEmpty { return "Nothing to clear for \(b.name) with these options." }
        return backupFirst
            ? "Closes \(b.name), saves a backup, then moves files to the Trash."
            : "\(b.name) will be closed first. You can restore files from the Trash."
    }

    private var resetSection: some View {
        VStack(spacing: 6) {
            Button { vm.showConfirm = true } label: {
                resetLabel
                    .id(vm.phase)
                    .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity),
                                            removal: .opacity))
            }
            .buttonStyle(PrimaryButtonStyle(colors: buttonColors))
            .disabled(!vm.canReset)
            .opacity(vm.canReset || vm.phase != .idle ? 1 : 0.45)
            .animation(.smooth(duration: 0.3), value: vm.phase)
            .animation(.smooth(duration: 0.3), value: vm.canReset)
            .animation(.smooth(duration: 0.25), value: vm.selectedID)

            Text(vm.status.isEmpty ? " " : vm.status)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 14)
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.3), value: vm.status)
        }
    }

    @ViewBuilder private var resetLabel: some View {
        HStack(spacing: 10) {
            switch vm.phase {
            case .working:
                ProgressView().controlSize(.small).tint(.white)
                Text("Resetting…")
            case .done:
                Image(systemName: "checkmark.circle.fill").symbolEffect(.bounce, value: vm.phase)
                Text("All clean")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Something went wrong")
            case .idle:
                Image(systemName: "sparkles")
                Text(vm.selected.map { "Reset \($0.name)" } ?? "Reset browser")
            }
        }
    }

    private var buttonColors: [Color] {
        switch vm.phase {
        case .done:   return [.green, .mint]
        case .failed: return [.orange, .red]
        default:      return [.blue, .indigo]
        }
    }

    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Circle().fill(Color.blue.opacity(0.18)).frame(width: 300, height: 300)
                .blur(radius: 90).offset(x: -190, y: -210)
            Circle().fill(Color.purple.opacity(0.14)).frame(width: 280, height: 280)
                .blur(radius: 90).offset(x: 200, y: 230)
        }
        .ignoresSafeArea()
    }
}
