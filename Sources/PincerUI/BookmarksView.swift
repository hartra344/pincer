import PincerKit
import SwiftUI

/// One chat's bookmarked messages (#42); tapping one scrolls to it.
struct BookmarksView: View {
    let store: BookmarkStore
    let sessionKey: String
    var syncProblem: String?
    let open: (Bookmark) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let bookmarks = self.store.bookmarks(in: self.sessionKey)
            Group {
                if bookmarks.isEmpty {
                    ContentUnavailableView(L("No Bookmarks"), systemImage: "star",
                                           description: Text(L("Bookmark a message from its menu to find it here.")))
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                self.open(bookmark)
                                self.dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.preview.isEmpty ? L("(No text)") : bookmark.preview).lineLimit(3)
                                    if let date = bookmark.messageDate {
                                        Text(date, format: .dateTime.month().day().hour().minute())
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(L("Remove Bookmark"), systemImage: "star.slash", role: .destructive) {
                                    self.store.remove(sessionKey: bookmark.sessionKey, messageId: bookmark.messageId)
                                }
                            }
                            .swipeActions {
                                Button(L("Remove"), role: .destructive) {
                                    self.store.remove(sessionKey: bookmark.sessionKey, messageId: bookmark.messageId)
                                }
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let problem = self.syncProblem {
                    Label(L("Some bookmarks couldn't be saved to the gateway: \(problem)"), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange).padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
            }
            .navigationTitle(L("Bookmarks"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { self.dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 320)
        #endif
    }
}

extension CommandPalette {
    /// Bookmarks across `gateways`, newest first, for the palette's Bookmarks section.
    @MainActor
    static func bookmarkItems(gateways: [GatewayStore]) -> [PaletteItem] {
        let multiple = gateways.count > 1
        var items: [PaletteItem] = []
        for gateway in gateways {
            for bookmark in BookmarkStore.shared(gatewayId: gateway.id).bookmarks {
                let title = gateway.sessions[bookmark.sessionKey]?.title ?? bookmark.sessionKey
                let target = Notifier.Target(gatewayId: gateway.id, sessionKey: bookmark.sessionKey)
                items.append(PaletteItem(
                    id: "bookmark:\(gateway.id.uuidString):\(bookmark.id)",
                    title: bookmark.preview.isEmpty ? title : bookmark.preview,
                    subtitle: multiple ? "\(title) · \(gateway.profile.name)" : title,
                    symbol: "star",
                    keywords: [title],
                    section: .bookmarks,
                    action: .openBookmark(target, messageId: bookmark.messageId)))
            }
        }
        return items
    }
}
