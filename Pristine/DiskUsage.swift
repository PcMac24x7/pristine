import SwiftUI
import Combine

// MARK: - Model

struct DiskUsage: Equatable {
    let total: Int64
    let free: Int64
    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// Reads the boot volume's capacity. Returns nil if the values aren't available.
    static func current() -> DiskUsage? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        return DiskUsage(total: Int64(total), free: free)
    }
}

/// Owns the current reading so several windows can each refresh independently.
@MainActor
final class DiskMonitor: ObservableObject {
    @Published private(set) var usage: DiskUsage?
    @Published private(set) var lastUpdated = Date()

    init() { refresh() }

    func refresh() {
        usage = DiskUsage.current()
        lastUpdated = Date()
    }
}

// MARK: - UI

struct DiskUsageCard: View {
    @ObservedObject var monitor: DiskMonitor
    var compact = false
    @State private var hover = false

    private var levelColor: Color {
        guard let u = monitor.usage else { return .secondary }
        switch u.usedFraction {
        case ..<0.7: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(levelColor.opacity(0.15))
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: compact ? 13 : 16, weight: .semibold))
                        .foregroundStyle(levelColor)
                }
                .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Disk Space").font(.callout.weight(.semibold))
                    if let u = monitor.usage {
                        Text("\(byteString(u.used)) used of \(byteString(u.total))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Unable to read disk usage").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let u = monitor.usage {
                    Text("\(byteString(u.free)) free")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(levelColor)
                }
                Button {
                    withAnimation(.snappy) { monitor.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(hover ? 360 : 0))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Refresh")
                .onHover { hover = $0 }
                .animation(.easeInOut(duration: 0.5), value: hover)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: compact ? 3 : 5, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: compact ? 3 : 5, style: .continuous)
                        .fill(LinearGradient(colors: [levelColor.opacity(0.7), levelColor], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * (monitor.usage?.usedFraction ?? 0))
                        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: monitor.usage?.usedFraction)
                }
            }
            .frame(height: compact ? 6 : 10)
        }
        .card(padding: compact ? 11 : 16)
        .onAppear { monitor.refresh() }
    }

    private func byteString(_ bytes: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
