/// Shared row and source-text bounds for transcript premeasure eligibility memos.
/// The renderer uses these limits for retained source strings; offline checks exercise the same
/// bounded-cache policy without importing the UI target.
public enum TranscriptPremeasureBudget {
    public static let rowLimit = 800
    public static let sourceByteLimit = 4 * 1024 * 1024
}
