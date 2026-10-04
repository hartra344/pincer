#if os(iOS)
import Foundation
import PincerKit

/// One active iOS staging request plus one replaceable latest request, scoped to its chat view.
@MainActor final class SharedFilePreparation {
    private struct Request {
        let id: UUID
        let name: String
        let data: Data
        let publish: @MainActor (SharedFile?) -> Void
    }
    private let staging: ExportFileStaging
    private var current: UUID?
    private var pending: Request?
    private var active: Task<Void, Never>?
    init(staging: ExportFileStaging? = nil) { self.staging = staging ?? ExportFileStaging() }
    func request(name: String, data: Data, publish: @escaping @MainActor (SharedFile?) -> Void) {
        let request = Request(id: UUID(), name: name, data: data, publish: publish)
        current = request.id
        pending = request
        if let active { active.cancel() } else { startLatest() }
    }
    func cancel() { current = nil; pending = nil; active?.cancel() }
    func waitForIdle() async { while let active { await active.value } }
    private func startLatest() {
        guard let request = pending else { return }
        pending = nil
        active = Task { [self] in
            let result = await SharedFile.write(name: request.name, data: request.data, staging: staging)
            if !Task.isCancelled, current == request.id { request.publish(result) }
            else if let result { await ExportFileStaging.discard(result.url) }
            active = nil
            startLatest()
        }
    }
    #if DEBUG
    var actualTask: Task<Void, Never>? { active }
    var pendingCount: Int { pending == nil ? 0 : 1 }
    #endif
}
#endif
