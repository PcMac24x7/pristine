import SwiftUI
import AppKit
import Combine
import Darwin

// MARK: - Sampling (runs off the main thread)

struct RawProcess {
    let pid: pid_t
    let name: String
    let path: String
    let cpu: Double          // percent of one core (can exceed 100 for multithreaded work)
    let memory: UInt64       // physical footprint, in bytes
    let ownedByMe: Bool
}

struct SystemSample {
    var processes: [RawProcess] = []
    var cpuFraction: Double = 0
    var memUsed: UInt64 = 0
}

private func decodeCString(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Reads per-process and system-wide numbers using libproc / Mach. Call from one task at a time.
final class ProcessSampler: @unchecked Sendable {
    private var prevCPU: [pid_t: UInt64] = [:]
    private var prevTime: UInt64 = 0
    private var prevHost: (busy: UInt64, total: UInt64)?
    private var timebase = mach_timebase_info_data_t()

    init() { mach_timebase_info(&timebase) }

    func sample() -> SystemSample {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed: Double = prevTime == 0 ? 0 : Double(now &- prevTime)
        let me = getuid()
        let numer = UInt64(timebase.numer)
        let denom = UInt64(max(1, timebase.denom))

        var pids = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        let usable = max(0, min(n, pids.count))

        var out: [RawProcess] = []
        var nextCPU: [pid_t: UInt64] = [:]

        for pid in pids.prefix(usable) where pid > 0 {
            var ti = proc_taskinfo()
            let tiSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, tiSize) == tiSize else { continue }

            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let owned = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize && bsd.pbi_uid == me

            // CPU: change in cumulative CPU time divided by wall-clock time.
            let cpuNs = (ti.pti_total_user &+ ti.pti_total_system) &* numer / denom
            nextCPU[pid] = cpuNs
            var cpu = 0.0
            if elapsed > 0, let before = prevCPU[pid], cpuNs >= before {
                cpu = Double(cpuNs - before) / elapsed * 100
            }

            // Memory: physical footprint (what Activity Monitor reports), falling back to resident size.
            var footprint = ti.pti_resident_size
            var ru = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ru) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            if rc == 0 { footprint = ru.ri_phys_footprint }

            // Name and path.
            var pathBuf = [CChar](repeating: 0, count: 4096)
            let plen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = plen > 0 ? decodeCString(pathBuf) : ""
            var name = path.isEmpty ? "" : URL(fileURLWithPath: path).lastPathComponent
            if name.isEmpty {
                var nameBuf = [CChar](repeating: 0, count: 256)
                proc_name(pid, &nameBuf, UInt32(nameBuf.count))
                name = decodeCString(nameBuf)
            }
            if name.isEmpty { name = "Process \(pid)" }

            out.append(RawProcess(pid: pid, name: name, path: path, cpu: cpu, memory: footprint, ownedByMe: owned))
        }

        prevCPU = nextCPU
        prevTime = now

        var cpuFraction = 0.0
        if let h = hostCPU() {
            if let p = prevHost, h.total > p.total, h.busy >= p.busy {
                cpuFraction = Double(h.busy - p.busy) / Double(h.total - p.total)
            }
            prevHost = h
        }

        return SystemSample(processes: out, cpuFraction: min(1, max(0, cpuFraction)), memUsed: hostMemoryUsed())
    }

    private func hostCPU() -> (busy: UInt64, total: UInt64)? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        return (user + system + nice, user + system + nice + idle)
    }

    /// Approximates Activity Monitor's "Memory Used": active + wired + compressed pages.
    private func hostMemoryUsed() -> UInt64 {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64_data_t()
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(getpagesize())
        return (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }
}

// MARK: - Rows

private let protectedProcessNames: Set<String> = [
    "Finder", "Dock", "WindowServer", "loginwindow", "SystemUIServer", "launchd", "kernel_task",
    "ControlCenter", "NotificationCenter", "WindowManager", "coreservicesd", "cfprefsd", "UserEventAgent"
]

struct ActivityRow: Identifiable {
    let id: String
    let name: String
    let iconPath: String?
    let pids: [pid_t]
    let cpu: Double
    let memory: UInt64
    let ownedByMe: Bool

    var count: Int { pids.count }
    var canQuit: Bool { ownedByMe && !protectedProcessNames.contains(name) && !pids.contains(getpid()) }
}

private func enclosingAppPath(_ path: String) -> String? {
    guard let r = path.range(of: ".app/") else { return nil }
    return String(path[..<r.upperBound].dropLast())
}

@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func icon(forFile path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

private func memString(_ bytes: UInt64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .memory
    return f.string(fromByteCount: Int64(bytes))
}

// MARK: - Model

@MainActor
final class ActivityModel: ObservableObject {
    enum SortKey: String, CaseIterable, Identifiable {
        case cpu = "CPU", memory = "Memory", name = "Name"
        var id: String { rawValue }
    }

    @Published private(set) var raw: [RawProcess] = []
    @Published private(set) var cpuFraction = 0.0
    @Published private(set) var memUsed: UInt64 = 0
    let memTotal = ProcessInfo.processInfo.physicalMemory

    @Published var sort: SortKey = .cpu
    @Published var search = ""
    @Published var grouped = true
    @Published var showSystem = false
    @Published var status = ""

    private let sampler = ProcessSampler()
    private var loop: Task<Void, Never>?

    var rows: [ActivityRow] {
        let procs = raw.filter { showSystem || $0.ownedByMe }
        var buckets: [String: [RawProcess]] = [:]
        for p in procs {
            if grouped, let app = enclosingAppPath(p.path) {
                buckets["app:" + app, default: []].append(p)
            } else {
                buckets["pid:\(p.pid)", default: []].append(p)
            }
        }
        var rows: [ActivityRow] = buckets.map { key, items in
            let first = items.min { $0.pid < $1.pid } ?? items[0]
            let appPath = enclosingAppPath(first.path)
            let isAppGroup = key.hasPrefix("app:")
            let name = isAppGroup
                ? URL(fileURLWithPath: appPath ?? "").deletingPathExtension().lastPathComponent
                : first.name
            return ActivityRow(
                id: key, name: name, iconPath: appPath,
                pids: items.map(\.pid).sorted(),
                cpu: items.reduce(0) { $0 + $1.cpu },
                memory: items.reduce(0) { $0 + $1.memory },
                ownedByMe: items.allSatisfy(\.ownedByMe))
        }
        if !search.isEmpty { rows = rows.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        switch sort {
        case .cpu: rows.sort { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }
        case .memory: rows.sort { $0.memory > $1.memory }
        case .name: rows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return rows
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            await self.refresh()                                  // primes the CPU baseline
            try? await Task.sleep(nanoseconds: 700_000_000)
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    private func refresh() async {
        let sampler = self.sampler
        let snap = await Task.detached(priority: .utility) { sampler.sample() }.value
        raw = snap.processes
        cpuFraction = snap.cpuFraction
        memUsed = snap.memUsed
    }

    func quit(_ row: ActivityRow, force: Bool) {
        guard row.canQuit else { return }
        var handled = false
        for pid in row.pids {
            if let app = NSRunningApplication(processIdentifier: pid) {
                if force { _ = app.forceTerminate() } else { _ = app.terminate() }
                handled = true
            }
        }
        if !handled {
            for pid in row.pids where pid > 1 { kill(pid, force ? SIGKILL : SIGTERM) }
        }
        status = force ? "Force quit \(row.name)." : "Asked \(row.name) to quit."
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await refresh()
        }
    }
}

// MARK: - Components

struct MeterCard: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Text(value).font(.title3.bold().monospacedDigit()).contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: 8)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .card()
        .animation(.snappy, value: value)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: fraction)
    }
}

struct ActivityRowView: View {
    let row: ActivityRow
    let onQuit: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(row.count > 1 ? "\(row.count) processes" : "PID \(row.pids.first ?? 0)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.1f%%", row.cpu))
                .font(.callout.monospacedDigit())
                .foregroundStyle(row.cpu > 80 ? Color.orange : Color.primary)
                .frame(width: 70, alignment: .trailing)
            Text(memString(row.memory))
                .font(.callout.monospacedDigit())
                .frame(width: 90, alignment: .trailing)
            Menu {
                Button("Quit") { onQuit(false) }
                Button("Force Quit", role: .destructive) { onQuit(true) }
            } label: {
                Image(systemName: "xmark.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .disabled(!row.canQuit)
            .help(row.canQuit ? "Quit \(row.name)" : "This process can't be quit from here")
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
    }

    @ViewBuilder private var icon: some View {
        if let path = row.iconPath {
            Image(nsImage: IconCache.icon(forFile: path)).resizable().interpolation(.high)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.gray.opacity(0.2))
                Image(systemName: "gearshape.fill").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Window

struct ActivityMonitorView: View {
    @StateObject private var model = ActivityModel()
    @State private var pending: PendingQuit?

    struct PendingQuit: Identifiable {
        let id = UUID()
        let row: ActivityRow
        let force: Bool
    }

    private func tint(_ fraction: Double) -> Color {
        fraction < 0.6 ? .green : (fraction < 0.85 ? .orange : .red)
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            HStack(spacing: 14) {
                MeterCard(title: "CPU", symbol: "cpu",
                          value: "\(Int((model.cpuFraction * 100).rounded()))%",
                          detail: "System-wide load",
                          fraction: model.cpuFraction, tint: tint(model.cpuFraction))
                let memFraction = model.memTotal > 0 ? Double(model.memUsed) / Double(model.memTotal) : 0
                MeterCard(title: "Memory", symbol: "memorychip",
                          value: memString(model.memUsed),
                          detail: "of \(memString(model.memTotal)) in use",
                          fraction: memFraction, tint: tint(memFraction))
            }
            controls
            listCard
        }
        .padding(22)
        .frame(width: 780, height: 720)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .confirmationDialog(
            pending.map { $0.force ? "Force quit \($0.row.name)?" : "Quit \($0.row.name)?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { p in
            Button(p.force ? "Force Quit" : "Quit", role: .destructive) { model.quit(p.row, force: p.force) }
        } message: { p in
            Text(p.force
                 ? "Unsaved work in \(p.row.name) will be lost."
                 : "\(p.row.name) will be asked to quit. You may be asked to save changes.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [.teal, .green], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .shadow(color: .green.opacity(0.3), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity Monitor").font(.title2.bold())
                Text("Live CPU and memory use, updated every 2 seconds").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TextField("Search", text: $model.search)
                .textFieldStyle(.roundedBorder).frame(width: 180)
            Picker("", selection: $model.sort) {
                ForEach(ActivityModel.SortKey.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 210)
            Spacer()
            Toggle("Group by app", isOn: $model.grouped).toggleStyle(.switch).controlSize(.small)
            Toggle("System processes", isOn: $model.showSystem).toggleStyle(.switch).controlSize(.small)
        }
    }

    private var listCard: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text("Process").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 38)
                Text("CPU").frame(width: 70, alignment: .trailing)
                Text("Memory").frame(width: 90, alignment: .trailing)
                Color.clear.frame(width: 28, height: 1)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        ActivityRowView(row: row) { force in
                            pending = PendingQuit(row: row, force: force)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
        .frame(maxHeight: .infinity)
    }
}
