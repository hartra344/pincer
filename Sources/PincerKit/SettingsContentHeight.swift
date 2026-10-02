/// Shared sizing policy for native Settings content; window chrome is reserved separately.
public enum SettingsContentHeight {
    public static let windowChrome: Double = 140
    public static let comfortableMax: Double = 720
    public static let minimum: Double = 240

    public static func limit(visibleScreenHeight: Double?) -> Double {
        guard let visibleScreenHeight else { return self.comfortableMax }
        return max(self.minimum, min(self.comfortableMax, visibleScreenHeight - self.windowChrome))
    }
}
