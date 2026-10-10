import SwiftUI
import AppKit
import Combine
import ServiceManagement
import UserNotifications

// MARK: - Settings keys (stored in UserDefaults, edited via @AppStorage)

enum Key {
    static let mode = "mode"                 // "off" | "daily" | "interval"
    static let hour = "hour"
    static let minute = "minute"
    static let intervalHours = "intervalHours"
    static let browserIDs = "browserIDs"     // "|"-separated bundle IDs
    static let categories = "categories"     // "|"-separated DataCategory raw values
    static let allowQuit = "allowQuit"       // scheduled runs may quit a running browser
    static let lastRun = "lastRun"           // timeIntervalSince1970
}

private let sep: Character = "|"
private func parse(_ raw: String) -> Set<String> { Set(raw.split(separator: sep).map(String.init)) }

// MARK: - Scheduler

@MainActor
final class AutoReset: ObservableObject {
    static let shared = AutoReset()
    @Published var lastStatus = "No resets yet."
    private var loop: Task<Void, Never>?

    private var d: UserDefaults { .standard }
    private var categories: Set<DataCategory> {
        let raw = d.string(forKey: Key.categories) ?? "History|Cookies|Cache"
        return Set(parse(raw).compactMap(DataCategory.init(rawValue:)))
    }
    private var browserIDs: [String] { Array(parse(d.string(forKey: Key.browserIDs) ?? "")) }

    /// Start the once-a-minute check. Also re-check on wake, since timers don't fire during sleep.
    func start() {
        guard loop == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func isDue(now: Date = Date()) -> Bool {
        let last = Date(timeIntervalSince1970: d.double(forKey: Key.lastRun))
        switch d.string(forKey: Key.mode) ?? "off" {
        case "interval":
            let hours = max(1, d.integer(forKey: Key.intervalHours))
            return now.timeIntervalSince(last) >= Double(hours) * 3600
        case "daily":
            var c = Calendar.current.dateComponents([.year, .month, .day], from: now)
            c.hour = d.integer(forKey: Key.hour); c.minute = d.integer(forKey: Key.minute)
            guard let today = Calendar.current.date(from: c) else { return false }
            let latest = today <= now ? today : Calendar.current.date(byAdding: .day, value: -1, to: today)!
            return last < latest      // catches up after sleep or if the Mac was off
        default:
            return false
        }
    }

    private func tick() async {
        guard isDue() else { return }
        let finished = await run(ids: browserIDs, categories: categories,
                                 allowQuit: d.bool(forKey: Key.allowQuit), notifyUser: true)
        if finished { d.set(Date().timeIntervalSince1970, forKey: Key.lastRun) }  // otherwise retry next minute
    }

    /// Returns true if no browser had to be skipped.
    @discardableResult
    func run(ids: [String], categories: Set<DataCategory>, allowQuit: Bool, notifyUser: Bool = false) async -> Bool {
        guard Engine.hasFullDiskAccess() else {
            report("Full Disk Access is missing. Grant it in System Settings.", notifyUser); return false
        }
        var cleaned: [String] = [], skipped: [String] = [], errors: [String] = []
        for id in ids {
            guard let b = allBrowsers.first(where: { $0.id == id }), b.isInstalled else { continue }
            if !b.runningApps.isEmpty && !allowQuit { skipped.append(b.name); continue }
            do {
                let r = try await Engine.reset(b, categories: categories, backup: BackupSettings.request(reason: "Scheduled reset"))
                cleaned.append("\(b.name) (\(r.trashed))")
                errors += r.failed
            } catch { errors.append(error.localizedDescription) }
        }
        var msg = cleaned.isEmpty ? "Nothing was reset." : "Reset: " + cleaned.joined(separator: ", ") + "."
        if !skipped.isEmpty { msg += " Skipped (still open): " + skipped.joined(separator: ", ") + "." }
        if !errors.isEmpty { msg += " \(errors.count) error(s)." }
        report(msg, notifyUser)
        return skipped.isEmpty
    }

    private func report(_ text: String, _ notifyUser: Bool) {
        lastStatus = text
        guard notifyUser else { return }
        let c = UNMutableNotificationContent()
        c.title = "Pristine"; c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - Menu bar

struct MenuContent: View {
    @ObservedObject var auto: AutoReset
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Key.categories) private var catRaw = "History|Cookies|Cache"
    @AppStorage(Key.browserIDs) private var browserRaw = ""

    private var categories: Set<DataCategory> { Set(parse(catRaw).compactMap(DataCategory.init(rawValue:))) }

    private func confirmEmptyTrash() {
        let info = TrashTool.size()
        let alert = NSAlert()
        alert.messageText = info.count == 0 ? "The Trash is already empty." : "Empty the Trash?"
        alert.informativeText = info.count == 0
            ? "There's nothing to remove."
            : "This permanently deletes \(info.count) item(s). This cannot be undone."
        alert.addButton(withTitle: info.count == 0 ? "OK" : "Empty Trash")
        if info.count > 0 { alert.addButton(withTitle: "Cancel") }
        NSApp.activate(ignoringOtherApps: true)
        guard info.count > 0, alert.runModal() == .alertFirstButtonReturn else { return }
        _ = TrashTool.empty()
    }

    private func confirmAndRun(_ browsers: [Browser]) {
        guard !browsers.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Reset \(browsers.map(\.name).joined(separator: ", "))?"
        alert.informativeText = "The browser(s) will be closed (unsaved work may be lost) and data moved to the Trash."
        alert.addButton(withTitle: "Reset"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await auto.run(ids: browsers.map(\.id), categories: categories, allowQuit: true) }
    }

    var body: some View {
        let installed = allBrowsers.filter(\.isInstalled)
        ForEach(installed) { b in
            Button("Reset \(b.name)") { confirmAndRun([b]) }
        }
        Button("Reset all scheduled browsers") {
            confirmAndRun(installed.filter { parse(browserRaw).contains($0.id) })
        }
        Divider()
        Text(auto.lastStatus)
        Divider()
        Button("Open Full Window") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Find Large Files…") { openWindow(id: "largefiles"); NSApp.activate(ignoringOtherApps: true) }
        Button("Backups…") { openWindow(id: "backups"); NSApp.activate(ignoringOtherApps: true) }
        Button("Unused Apps…") { openWindow(id: "unusedapps"); NSApp.activate(ignoringOtherApps: true) }
        Button("Activity Monitor…") { openWindow(id: "activity"); NSApp.activate(ignoringOtherApps: true) }
        Button("Empty Trash…") { confirmEmptyTrash() }
        Button("Schedule & Settings…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
        Button("Support PcMac ♥…") { Branding.openSupportPage() }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var auto: AutoReset
    @AppStorage(Key.mode) private var mode = "off"
    @AppStorage(Key.hour) private var hour = 3
    @AppStorage(Key.minute) private var minute = 0
    @AppStorage(Key.intervalHours) private var intervalHours = 24
    @AppStorage(Key.browserIDs) private var browserRaw = ""
    @AppStorage(Key.categories) private var catRaw = "History|Cookies|Cache"
    @AppStorage(Key.allowQuit) private var allowQuit = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private func binding(_ raw: Binding<String>, _ item: String) -> Binding<Bool> {
        Binding(
            get: { parse(raw.wrappedValue).contains(item) },
            set: { on in
                var s = parse(raw.wrappedValue)
                if on { s.insert(item) } else { s.remove(item) }
                raw.wrappedValue = s.sorted().joined(separator: String(sep))
            })
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date() },
            set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); hour = c.hour ?? 0; minute = c.minute ?? 0 })
    }

    var body: some View {
        Form {
            Section("Schedule") {
                Picker("Run", selection: $mode) {
                    Text("Never").tag("off")
                    Text("Daily at a set time").tag("daily")
                    Text("Every N hours").tag("interval")
                }
                .onChange(of: mode) { _, _ in
                    // Start the clock now so enabling a schedule doesn't trigger an instant reset.
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.lastRun)
                }
                if mode == "daily" { DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute) }
                if mode == "interval" { Stepper("Every \(intervalHours) hour(s)", value: $intervalHours, in: 1...168) }
                Toggle("Quit the browser if it's open", isOn: $allowQuit)
                Text(allowQuit ? "Open browsers are closed automatically. Unsaved work may be lost."
                               : "Safe mode: browsers that are open are skipped and retried every minute.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Browsers") {
                ForEach(allBrowsers.filter(\.isInstalled)) { b in
                    Toggle(b.name, isOn: binding($browserRaw, b.id))
                }
            }
            Section("Data to clear") {
                ForEach(DataCategory.allCases) { c in
                    Toggle(c.rawValue, isOn: binding($catRaw, c.rawValue))
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Text(auto.lastStatus).font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                HStack(spacing: 12) {
                    LogoView(height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Made by \(Branding.creatorName)").font(.callout.weight(.semibold))
                        Text("Enjoying the app? You can support my work with a small tip.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Branding.openSupportPage()
                    } label: {
                        Label("Donate", systemImage: "heart.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 560)
    }
}
