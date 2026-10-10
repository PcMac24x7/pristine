import SwiftUI
import AppKit

// MARK: - Branding constants

enum Branding {
    static let creatorName = "PcMac"
    static let paypalURL = URL(string: "https://paypal.me/pcmac24x7")!
    static let paypalDisplay = "paypal.me/pcmac24x7"

    /// Decoded once from the embedded PNG. Falls back to nil (the views show a placeholder) if decoding fails.
    @MainActor static let logoImage: NSImage? = {
        guard let data = Data(base64Encoded: PcMacLogoData.base64, options: .ignoreUnknownCharacters) else { return nil }
        return NSImage(data: data)
    }()

    @MainActor static func openSupportPage() {
        NSWorkspace.shared.open(paypalURL)
    }

    @MainActor static func copySupportLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paypalURL.absoluteString, forType: .string)
    }
}

// MARK: - Logo

struct LogoView: View {
    var height: CGFloat

    var body: some View {
        if let image = Branding.logoImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(height: height)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: height * 0.85))
                .foregroundStyle(.secondary)
                .frame(height: height)
        }
    }
}

// MARK: - Support popover

struct SupportPopover: View {
    @State private var copied = false

    var body: some View {
        VStack(spacing: 12) {
            LogoView(height: 120)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)

            VStack(spacing: 4) {
                Text("Made by \(Branding.creatorName)").font(.headline)
                Text("If this app saved you time and you'd like to say thanks, you can support my work with a small tip. It's completely optional, and the app works fully without it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Branding.openSupportPage()
            } label: {
                Label("Donate with PayPal", systemImage: "heart.fill")
            }
            .buttonStyle(PrimaryButtonStyle(colors: [.pink, .red]))

            HStack(spacing: 8) {
                Text(Branding.paypalDisplay)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Button {
                    Branding.copySupportLink()
                    withAnimation(.smooth(duration: 0.25)) { copied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        withAnimation(.smooth(duration: 0.25)) { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.green : Color.accentColor)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

// MARK: - Header button

struct SupportButton: View {
    @State private var showPopover = false
    @State private var hover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                LogoView(height: 22)
                Text(Branding.creatorName).font(.caption.weight(.semibold))
                Image(systemName: "heart.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.pink)
                    .symbolEffect(.bounce, value: hover)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.pink.opacity(hover ? 0.20 : 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.pink.opacity(0.25)))
            .scaleEffect(hover ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.smooth(duration: 0.25), value: hover)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) { SupportPopover() }
        .help("Support \(Branding.creatorName) with a PayPal tip")
    }
}
