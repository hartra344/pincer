import PincerKit
import SwiftUI

/// What the chat's menus and the File menu use to open the export and bookmarks sheets (#42).
@MainActor
@Observable
final class ChatExportState {
    var showExport = false
    var showBookmarks = false
}

extension FocusedValues {
    @Entry var chatExport: ChatExportState?
}

/// Export Chat…: format, what to include, then a save panel (macOS) or Files/share (iOS).
struct ExportSheet: View {
    let chat: ChatStore
    let title: String
    let agentName: String
    let agents: [AgentSummary]
    /// Called with the built file; the chat saves or shares it once this sheet has gone (#430).
    let finish: (ExportedFile) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("pincer.export.format") private var formatRaw = TranscriptExport.Format.markdown.rawValue
    @AppStorage("pincer.export.thinking") private var includeThinking = false
    @AppStorage("pincer.export.tools") private var includeToolCalls = false
    @State private var isExporting = false
    @State private var failed = false

    private var format: Binding<TranscriptExport.Format> {
        Binding(get: { TranscriptExport.Format(rawValue: self.formatRaw) ?? .markdown },
                set: { self.formatRaw = $0.rawValue })
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker(L("Format"), selection: self.format) {
                    Text(L("Markdown")).tag(TranscriptExport.Format.markdown)
                    Text(L("Plain Text")).tag(TranscriptExport.Format.plainText)
                    Text(L("PDF")).tag(TranscriptExport.Format.pdf)
                }
                Toggle(L("Include thinking"), isOn: self.$includeThinking)
                Toggle(L("Include tool calls"), isOn: self.$includeToolCalls)
                if self.isExporting {
                    HStack(spacing: Theme.Spacing.md) {
                        ProgressView().controlSize(.small)
                        Text(L("Loading full history…")).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .alert(L("Couldn't Export Chat"), isPresented: self.$failed) {
                Button(L("OK")) {}
            } message: {
                Text(L("Couldn't load the full history. Try again."))
            }
            .navigationTitle(L("Export Chat"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Export")) { self.export() }.disabled(self.isExporting)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 260)
        #endif
    }

    private func export() {
        self.isExporting = true
        self.failed = false
        let format = self.format.wrappedValue
        let options = TranscriptExport.Options(includeThinking: self.includeThinking, includeToolCalls: self.includeToolCalls)
        let header = TranscriptExport.Header(title: self.title, agentName: self.agentName, agents: self.agents)
        Task {
            let file = await ChatExportBuilder.build(chat: self.chat, format: format, options: options, header: header)
            self.isExporting = false
            guard let file else {
                self.failed = true
                return
            }
            self.finish(file)
            self.dismiss()
        }
    }
}

/// Builds a chat's export file (#42): the whole history, not just the loaded window, in the chosen format.
enum ChatExportBuilder {
    /// Nil if the full history couldn't be loaded or the file came out empty.
    @MainActor
    static func build(chat: ChatStore, format: TranscriptExport.Format, options: TranscriptExport.Options,
                      header: TranscriptExport.Header) async -> ExportedFile? {
        guard let items = await chat.exportItems() else { return nil }
        let data: Data
        switch format {
        case .markdown: data = Data(TranscriptExport.markdown(items, header: header, options: options).utf8)
        case .plainText: data = Data(TranscriptExport.plainText(items, header: header, options: options).utf8)
        case .pdf:
            data = TranscriptPDF.render(markdown: TranscriptExport.markdown(items, header: header, options: options),
                                        title: header.title)
        }
        guard !data.isEmpty else { return nil }
        return ExportedFile(name: TranscriptExport.fileName(title: header.title, format: format), data: data)
    }
}

#if os(macOS)
/// File ▸ Export Chat… (⇧⌘E) for the focused chat.
struct ExportChatCommands: Commands {
    @FocusedValue(\.chatExport) private var chatExport

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button(L("Export Chat…")) { self.chatExport?.showExport = true }
                .shortcut(.exportChat)
                .disabled(self.chatExport == nil)
            Button(L("Bookmarks…")) { self.chatExport?.showBookmarks = true }
                .shortcut(.showBookmarks)
                .disabled(self.chatExport == nil)
        }
    }
}
#endif

#if os(iOS)
import UIKit

/// An exported file written to a temporary folder, ready to share.
struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL

    static func write(name: String, data: Data) -> SharedFile? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return SharedFile(url: url)
    }
}

/// The system share sheet for a file.
struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [self.url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
