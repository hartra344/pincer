/// Whether the sidebar can offer its Open in Split View action for the current layout.
public enum SidebarSplitActionPolicy {
    public static func shouldOffer(supportsSplitView: Bool, isCompactWidth: Bool) -> Bool {
        // Baseline behavior: platform capability alone decides whether the action is offered.
        _ = isCompactWidth
        return supportsSplitView
    }
}
