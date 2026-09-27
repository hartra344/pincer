import PincerKit
import SwiftUI

/// Link a channel account by scanning a QR code (`web.login.start` / `web.login.wait`). Shared by the
/// setup wizard's Channels step and Gateway Settings → Channel Status.
struct ChannelQRLoginView: View {
    let state: ChannelQRLoginState
    let channelLabel: String
    /// Already linked: the button relinks (`force`).
    let linked: Bool
    /// Full Management and a channel that supports QR login.
    let canStart: Bool
    var linkTitle = "Link with QR Code…"
    var relinkTitle = "Relink with QR Code…"
    /// Offer Relink after linking (the sheet on Channel Status closes instead).
    var offersRelinkWhenLinked = true
    let start: (_ force: Bool) -> Void
    let cancel: () -> Void

    var body: some View {
        switch self.state {
        case .idle, .failed:
            if case let .failed(message) = self.state {
                Text(message).font(.caption).foregroundStyle(.red)
                Button { self.start(self.linked) } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(!self.canStart)
            } else {
                Button { self.start(self.linked) } label: {
                    Label(self.linked ? self.relinkTitle : self.linkTitle, systemImage: "qrcode")
                }
                .buttonStyle(.borderless)
                .disabled(!self.canStart)
            }
        case .starting:
            ProgressView("Getting a QR code…").controlSize(.small)
        case let .showing(qr, message):
            VStack(alignment: .leading, spacing: 6) {
                QRCodeImage(data: qr, label: "QR code for \(self.channelLabel)")
                    .equatable()
                    .frame(width: 200, height: 200)
                Text(message ?? "Scan this with \(self.channelLabel) on your phone to link it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel", action: self.cancel)
                    .buttonStyle(.borderless)
            }
        case let .connected(message):
            Label(message.map(Self.linkedMessage) ?? "Linked", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
            if self.offersRelinkWhenLinked {
                Button { self.start(true) } label: {
                    Label(self.relinkTitle, systemImage: "qrcode")
                }
                .buttonStyle(.borderless)
                .disabled(!self.canStart)
            }
        }
    }

    /// Drops upstream's chat-agent hint ("Say “relink” …"): here it's the Relink button.
    static func linkedMessage(_ message: String) -> String {
        guard let range = message.range(of: " Say “relink”") else { return message }
        return String(message[..<range.lowerBound])
    }
}

/// The QR PNG, decoded only when the data changes.
private struct QRCodeImage: View, Equatable {
    let data: Data
    let label: String

    var body: some View {
        if let image = PlatformImage(data: self.data) {
            Self.image(image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(self.label)
        }
    }

    static func image(_ image: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }
}
