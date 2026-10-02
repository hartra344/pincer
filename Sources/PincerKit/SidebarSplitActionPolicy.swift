/// Whether the sidebar can offer its Open in Split View action for the current layout.
public enum SidebarSplitActionPolicy {
    public static func shouldOffer(supportsSplitView: Bool, isCompactWidth: Bool) -> Bool {
        supportsSplitView && !isCompactWidth
    }
}

/// Whether a chat should carry the sidebar marker for the split pane.
public enum SidebarSplitPaneMarker {
    public static func isVisible(sessionKey: String, splitKey: String?) -> Bool {
        splitKey == sessionKey
    }
}
