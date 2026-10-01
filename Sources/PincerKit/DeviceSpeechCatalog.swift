import Foundation
import Observation

/// A value-only description of a voice offered by the operating system.
public struct DeviceSpeechVoice: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let language: String
    public let quality: Int

    public init(id: String, name: String, language: String, quality: Int) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
    }
}

/// The current system recognizer's on-device capability.
public struct DeviceDictationSupport: Sendable, Equatable {
    public let language: String
    public let supported: Bool

    public init(language: String, supported: Bool) {
        self.language = language
        self.supported = supported
    }
}

/// An immutable result suitable for crossing from the platform discovery worker to SwiftUI.
public struct DeviceSpeechCatalogSnapshot: Sendable, Equatable {
    public static let maximumVoiceCount = 256
    public static let maximumIdentifierBytes = 256
    public static let maximumNameBytes = 256
    public static let maximumLanguageBytes = 96
    public static let maximumSnapshotBytes = 160 * 1024

    public let localeIdentifier: String
    public let voices: [DeviceSpeechVoice]
    public let dictationSupport: DeviceDictationSupport?

    public init(localeIdentifier: String, voices: [DeviceSpeechVoice], dictationSupport: DeviceDictationSupport?) {
        self.localeIdentifier = Self.bounded(localeIdentifier, maximumBytes: Self.maximumLanguageBytes)
        self.voices = voices.lazy.filter {
            !$0.id.isEmpty && $0.id.utf8.count <= Self.maximumIdentifierBytes
                && $0.name.utf8.count <= Self.maximumNameBytes
                && $0.language.utf8.count <= Self.maximumLanguageBytes
        }.prefix(Self.maximumVoiceCount).map { $0 }
        if let dictationSupport,
           dictationSupport.language.utf8.count <= Self.maximumLanguageBytes
        {
            self.dictationSupport = dictationSupport
        } else {
            self.dictationSupport = nil
        }
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            guard result.utf8.count + scalar.utf8.count <= maximumBytes else { break }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

/// Latest operating-system speech choices. Discovery is injected so platform APIs can be queried
/// away from SwiftUI and deterministic callers can exercise refresh ordering.
@MainActor @Observable
public final class DeviceSpeechCatalog {
    private struct Request: Sendable {
        let localeIdentifier: String
        let generation: Int
    }

    public private(set) var snapshot: DeviceSpeechCatalogSnapshot?
    public private(set) var requestedLocaleIdentifier: String?
    public private(set) var isRefreshing = false

    @ObservationIgnored private let discover: @Sendable (String) -> DeviceSpeechCatalogSnapshot
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inFlight: Task<DeviceSpeechCatalogSnapshot, Never>?
    @ObservationIgnored private var pending: Request?

    public init(discover: @escaping @Sendable (String) -> DeviceSpeechCatalogSnapshot) {
        self.discover = discover
    }

    /// Refreshes the one retained locale snapshot. `force` is for system voice-list notifications.
    public func refresh(localeIdentifier: String, force: Bool = false) {
        guard force || self.requestedLocaleIdentifier != localeIdentifier else { return }
        self.generation += 1
        self.requestedLocaleIdentifier = localeIdentifier
        self.isRefreshing = true
        let request = Request(localeIdentifier: localeIdentifier, generation: self.generation)
        guard self.inFlight == nil else {
            self.pending = request
            return
        }
        self.start(request)
    }

    private func start(_ request: Request) {
        let discover = self.discover
        let work = Task.detached(priority: .utility) {
            discover(request.localeIdentifier)
        }
        self.inFlight = work
        Task { [weak self] in
            let discovered = await work.value
            guard let self else { return }
            self.inFlight = nil
            if request.generation == self.generation,
               discovered.localeIdentifier == request.localeIdentifier
            {
                self.snapshot = discovered
                self.isRefreshing = false
            }
            if let pending = self.pending {
                self.pending = nil
                self.start(pending)
            } else {
                self.isRefreshing = false
            }
        }
    }
}
