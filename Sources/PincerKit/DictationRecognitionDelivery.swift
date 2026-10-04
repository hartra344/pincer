/// Actual Speech recognition callback publication, extracted without changing its ownership policy.
package enum DictationRecognitionOutcome: Sendable {
    case text(String, isFinal: Bool)
    case failure(DictationIssue)
    case ignorable
}
@MainActor package final class DictationRecognitionDelivery {
    package private(set) var lastText = ""
    private var generation: UInt64 = 0
    package init() {}
    package func begin(isActive: @escaping @MainActor () -> Bool,
                       onPartial: @escaping @MainActor (String, Bool) -> Void,
                       onError: @escaping @MainActor (DictationIssue) -> Void) -> @MainActor @Sendable (DictationRecognitionOutcome) -> Void {
        self.generation &+= 1
        let generation = self.generation
        self.lastText = ""
        return { [weak self] outcome in
            guard let self, self.generation == generation, isActive() else { return }
            switch outcome {
            case let .text(text, isFinal): self.lastText = text; onPartial(text, isFinal)
            case let .failure(issue): onError(issue)
            case .ignorable: onPartial(self.lastText, true)
            }
        }
    }
}
