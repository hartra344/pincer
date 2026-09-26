#if os(macOS)
import AppKit
import PincerKit
import SwiftUI

/// The Quick Capture panel's content: who it goes to, the message, and how to send it.
struct QuickCaptureView: View {
    @Bindable var model: QuickCaptureModel
    let controller: QuickCaptureController
    @Environment(\.appTheme) private var theme
    @State private var attachmentError: String?
    @State private var isTargeted = false
    @FocusState private var searchFocused: Bool

    static let width: CGFloat = 600
    private static let corner: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if self.model.hasGateways {
                self.targetRow
                if self.model.isPickerOpen {
                    Divider()
                    self.picker
                }
                Divider()
                self.messageArea
                self.footer
            } else {
                self.noGateways
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).strokeBorder(.separator))
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(self.theme.accent, lineWidth: 2)
                .opacity(self.isTargeted ? 1 : 0))
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .onDrop(of: [.fileURL, .image, .audiovisualContent, .pdf], isTargeted: self.$isTargeted) { providers in
            guard self.model.hasGateways else { return false }
            self.ingest.ingest(providers.map(PastedMedia.provider))
            return true
        }
        .onChange(of: self.model.isPickerOpen) { _, open in
            if open {
                // The message field keeps focus unless it's resigned first.
                DispatchQueue.main.async {
                    self.controller.clearFocus()
                    self.searchFocused = true
                }
            } else {
                self.searchFocused = false
                self.controller.focusComposer()
            }
        }
    }

    // MARK: Target

    private var targetRow: some View {
        HStack(spacing: 8) {
            Text("To:")
                .foregroundStyle(.secondary)
            Button {
                self.model.togglePicker()
            } label: {
                HStack(spacing: 6) {
                    Text(self.model.targetTitle)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let subtitle = self.model.targetSubtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Choose a chat (⌘J or Tab)")
            .accessibilityLabel("Send to \(self.model.targetTitle)")
            Spacer(minLength: 8)
            if let shortcut = self.controller.displayShortcut {
                Text(shortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var picker: some View {
        let items = self.model.items
        let highlighted = self.model.highlighted(in: items)?.id
        let showsSections = self.model.query.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search chats and agents…", text: self.$model.query)
                    .textFieldStyle(.plain)
                    .focused(self.$searchFocused)
                    .accessibilityLabel("Search chats and agents")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if items.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if showsSections, index == 0 || items[index - 1].section != item.section {
                                    Text(item.section.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.top, index == 0 ? 2 : 8)
                                        .padding(.bottom, 2)
                                }
                                self.row(item, selected: item.id == highlighted)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: self.model.highlightedId) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        Button {
            self.model.pick(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .frame(width: 20)
                    .foregroundStyle(selected ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let shortcut = item.shortcut {
                    Text(shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? AnyShapeStyle(self.theme.accent.opacity(0.2)) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.45)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Message

    private var messageArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = self.model.connectionStatus {
                Label(status, systemImage: "bolt.horizontal.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            if let error = self.model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !self.model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(self.model.attachments) { attachment in
                            AttachmentThumb(attachment: attachment, size: 52) {
                                self.model.attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                    .padding(.trailing, 6)
                }
            }
            ComposerTextView(
                placeholder: self.model.placeholder,
                text: self.$model.text,
                maxLines: 8,
                isEditable: !self.model.isSending,
                onSubmit: { self.controller.send(reveal: false) },
                onMedia: { self.ingest.ingest($0) })
                .frame(minHeight: 22)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("↩ Send · ⌘↩ Send & Open · esc Close")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if self.model.isSending {
                ProgressView().controlSize(.small)
            }
            Button("Send & Open") { self.controller.send(reveal: true) }
                .controlSize(.small)
                .glassButton()
                .disabled(!self.model.canSend)
            Button("Send") { self.controller.send(reveal: false) }
                .controlSize(.small)
                .glassProminentButton()
                .disabled(!self.model.canSend)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var noGateways: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Add a Gateway in Pincer to use Quick Capture")
                .font(.headline)
            Button("Open Pincer") {
                self.controller.showMainWindow()
                self.controller.hide()
            }
            .glassProminentButton()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var ingest: AttachmentIngest {
        let model = self.model
        return AttachmentIngest(
            limits: UploadLimits(hello: model.gateway?.hello),
            add: { model.attachments.append($0) },
            report: { self.attachmentError = $0 })
    }
}
#endif
