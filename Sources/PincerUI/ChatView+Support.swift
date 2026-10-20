import PincerKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// An attachment's bytes, handed to the system save panel.
struct ExportedFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let name: String
    let data: Data

    init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    init(logExport: GatewayLogExport) {
        self.init(name: logExport.name, data: logExport.data)
    }

    init(configuration: ReadConfiguration) throws {
        self.name = configuration.file.filename ?? "file"
        self.data = configuration.file.regularFileContents ?? Data()
    }

    var contentType: UTType {
        UTType(filenameExtension: (self.name as NSString).pathExtension) ?? .data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: self.data)
    }
}

extension ChatStore {
    /// Starts replying to a message: the composer shows the "Replying to" chip and takes focus.
    func beginReply(to messageId: String, agentName: String) {
        self.selectReply(to: messageId, you: Owner.displayName, agent: agentName)
    }
}

/// Reply to Last Message (⇧⌘R) for the chat that has focus.
@MainActor
/// Equatable so a fresh value from each `ChatView` body pass doesn't count as a focus change:
/// otherwise every update rebuilds the main menu, which updates the view again, forever.
struct ReplyToLast: Equatable {
    let chat: ChatStore
    let agentName: String

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chat === rhs.chat && lhs.agentName == rhs.agentName
    }

    var isAvailable: Bool { self.chat.latestReplyableId != nil }

    func perform() {
        guard let id = self.chat.latestReplyableId else { return }
        self.chat.beginReply(to: id, agentName: self.agentName)
    }
}

extension FocusedValues {
    @Entry var replyToLast: ReplyToLast?
    @Entry var transcriptNavigator: TranscriptNavigator?
}

/// Placeholder rows shown while a chat's history loads, laid out like real transcript rows: an
/// avatar circle, a name bar and a few text bars. Fixed shapes, so it looks the same every time.
struct ChatLoadingSkeleton: View {
    var label: LocalizedStringKey = "Loading messages"
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var onscreen = false
    @State private var dim = false

    private struct Row {
        let name: CGFloat
        /// Widths of the text bars as fractions of the available width; the last is the short one.
        let lines: [CGFloat]
    }

    private static let rows = [
        Row(name: 96, lines: [0.95, 0.85, 0.6]),
        Row(name: 84, lines: [0.9, 0.6]),
        Row(name: 108, lines: [0.92, 0.88, 0.6]),
        Row(name: 88, lines: [0.6]),
    ]

    private var pulses: Bool { !self.reduceMotion && self.scenePhase == .active && self.onscreen }

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptMetrics.messageSpacing + 2 * TranscriptMetrics.verticalPadding) {
            ForEach(Self.rows.indices, id: \.self) { index in
                self.row(Self.rows[index])
            }
        }
        .padding(.horizontal, TranscriptMetrics.sidePadding)
        .padding(.top, self.topInset)
        .padding(.bottom, self.bottomInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(self.pulses && self.dim ? 0.55 : 1)
        .onAppear { self.onscreen = true }
        .onDisappear { self.onscreen = false }
        .task(id: self.pulses) {
            guard self.pulses else {
                self.dim = false
                return
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { self.dim = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(self.label, bundle: .module))
    }

    private func row(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: TranscriptMetrics.avatarGap) {
            Circle().fill(Self.fill).frame(width: TranscriptMetrics.avatar, height: TranscriptMetrics.avatar)
            VStack(alignment: .leading, spacing: TranscriptMetrics.headerGap) {
                Self.bar(height: 10).frame(width: row.name)
                VStack(alignment: .leading, spacing: TranscriptMetrics.blockSpacing) {
                    ForEach(row.lines.indices, id: \.self) { line in
                        GeometryReader { proxy in
                            Self.bar(height: 12).frame(width: proxy.size.width * row.lines[line])
                        }
                        .frame(height: 12)
                    }
                }
            }
            .frame(maxWidth: TranscriptMetrics.maxCardWidth, alignment: .leading)
        }
    }

    private static let fill = Color.primary.opacity(0.09)

    private static func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(self.fill).frame(height: height)
    }
}
