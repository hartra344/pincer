import Foundation

/// Speaks one selected suggestion without scanning remote descriptions or the entire result list.
public enum SlashSuggestionAnnouncement {
    public static func selected(_ suggestion: SlashSuggestion) -> String {
        switch suggestion.kind {
        case let .command(command):
            guard let bytes = self.byteCount(command.name), bytes <= 255 else { return L("Command suggestion") }
            return "/" + command.name
        case let .argument(choice, _, _):
            guard let valueBytes = self.byteCount(choice.value), let labelBytes = self.byteCount(choice.label),
                  valueBytes <= 256, labelBytes <= 256 else { return L("Argument suggestion") }
            if choice.label == choice.value { return choice.value }
            guard valueBytes + labelBytes + 3 <= 256 else { return L("Argument suggestion") }
            return "\(choice.label) (\(choice.value))"
        }
    }

    public static func count(_ count: Int) -> String {
        let bounded = min(max(count, 0), SlashCompletion.limit)
        return bounded == 1 ? L("1 command suggestion") : L("\(bounded) command suggestions")
    }

    private static func byteCount(_ text: String) -> Int? {
        guard text.isContiguousUTF8 else { return nil }
        return text.utf8.withContiguousStorageIfAvailable { $0.count }
    }
}
