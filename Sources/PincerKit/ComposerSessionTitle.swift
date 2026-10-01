/// Chooses the title to show in a chat composer while its session row refreshes.
public enum ComposerSessionTitle {
    /// Uses the selected chat's current title, or its own last-known title during a transient refresh.
    /// A row from another chat is never allowed to label this composer.
    public static func title(sessionKey: String, current: SessionRow?, lastKnown: SessionRow?) -> String? {
        if let current, current.key == sessionKey { return current.title }
        if let lastKnown, lastKnown.key == sessionKey { return lastKnown.title }
        return nil
    }
}
