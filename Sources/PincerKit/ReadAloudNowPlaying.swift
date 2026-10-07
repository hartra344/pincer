import AVFoundation
import Foundation
#if os(iOS)
import MediaPlayer
import UIKit
#endif

/// System-level events that end a read: audio interruptions, route changes and lock-screen / headset
/// remote commands. `ReadAloudController.handle(_:)` is the single entry point (also used by tests).
public enum ReadAloudSystemEvent: Equatable, Sendable {
    /// AVAudioSession interruption began (phone call, Siri, another app took the audio session).
    case interruptionBegan
    /// The output device went away (headphones unplugged, Bluetooth disconnected).
    case oldDeviceUnavailable
    /// Remote command: pause, stop or togglePlayPause.
    case remoteStop
    /// The background task that keeps the Gateway fetch alive ran out of time.
    case backgroundTimeExpired
}

/// Bridges the controller to the OS: Now Playing, remote commands, interruptions, background task.
@MainActor
protocol ReadAloudSystemIntegrating: AnyObject {
    func phaseChanged(_ phase: ReadAloudController.Phase, title: String?)
}

#if os(iOS)
@MainActor
final class ReadAloudSystemIntegration: ReadAloudSystemIntegrating {
    private weak var controller: ReadAloudController?
    private var observers: [NSObjectProtocol] = []
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(controller: ReadAloudController) {
        self.controller = controller
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        self.observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                                 queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
            MainActor.assumeIsolated { self?.controller?.handle(.interruptionBegan) }
        })
        self.observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session,
                                                 queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.controller?.handle(.oldDeviceUnavailable) }
        })
    }

    func phaseChanged(_ phase: ReadAloudController.Phase, title: String?) {
        switch phase {
        case .idle:
            self.endBackgroundTask()
            self.clearNowPlaying()
        case .preparing:
            self.beginBackgroundTask()
            self.publishNowPlaying(title: title)
        case .speaking:
            self.endBackgroundTask()
            self.publishNowPlaying(title: title)
        }
    }

    private func beginBackgroundTask() {
        guard self.backgroundTask == .invalid else { return }
        self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "chat.pincer.readAloud.fetch") { @Sendable [weak self] in
            MainHop.run {
                self?.endBackgroundTask()
                self?.controller?.handle(.backgroundTimeExpired)
            }
        }
    }

    private func endBackgroundTask() {
        guard self.backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(self.backgroundTask)
        self.backgroundTask = .invalid
    }

    private func publishNowPlaying(title: String?) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title ?? L("Read Aloud"),
            MPMediaItemPropertyArtist: L("Read Aloud"),
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        guard self.commandTargets.isEmpty else { return }
        let commands = MPRemoteCommandCenter.shared()
        for command in [commands.pauseCommand, commands.stopCommand, commands.togglePlayPauseCommand] {
            command.isEnabled = true
            let target = command.addTarget { @Sendable [weak self] _ in
                MainHop.run { self?.controller?.handle(.remoteStop) }
                return .success
            }
            self.commandTargets.append((command, target))
        }
        commands.playCommand.isEnabled = false
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        for (command, target) in self.commandTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        self.commandTargets.removeAll()
    }
}
#endif

extension ReadAloudController {
    /// The Now Playing title: the first ~80 characters of what is being read.
    static func nowPlayingTitle(for text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
    }
}
