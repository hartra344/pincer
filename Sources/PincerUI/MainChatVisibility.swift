import PincerKit
import SwiftUI

/// Reports whether the main window's selected chat is on screen for the user (#374): the scene is
/// active and focused and, when the split view is collapsed (iPhone), the chat is pushed.
struct MainChatVisibility: ViewModifier {
    let compactColumn: NavigationSplitViewColumn
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    func body(content: Content) -> some View {
        content
            .onChange(of: self.visible, initial: true) { _, visible in self.app.mainChatVisible = visible }
            .onDisappear { self.app.mainChatVisible = false }
    }

    private var visible: Bool {
        #if os(macOS)
        return self.scenePhase == .active && self.controlActiveState == .key
        #else
        return self.scenePhase == .active && (self.sizeClass != .compact || self.compactColumn == .detail)
        #endif
    }
}
