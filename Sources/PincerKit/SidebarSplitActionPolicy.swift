/// Whether the sidebar can offer its Open in Split View action for the current layout.
public enum SidebarSplitActionPolicy {
    public static func shouldOffer(supportsSplitView: Bool, isCompactWidth: Bool) -> Bool {
        supportsSplitView && !isCompactWidth
    }
}
