#if os(iOS)
import Foundation
import PincerKit

/// One active iOS staging request plus one replaceable latest request, scoped to its chat view.
@MainActor final class SharedFilePreparation {
    private let staging: ExportFileStaging
    private let preparer = LatestWinsPreparer<SharedFile?>(cancelsSupersededWork: true)
    private var discards: [Task<Void, Never>] = []
    init(staging: ExportFileStaging? = nil) { self.staging = staging ?? ExportFileStaging() }

    func request(name: String, data: Data, publish: @escaping @MainActor (SharedFile?) -> Void) {
        let staging = self.staging
        var written: SharedFile?
        // A superseded staging write is cancelled; anything it still wrote is discarded when it lands.
        preparer.submit(work: { await SharedFile.write(name: name, data: data, staging: staging) },
                        finished: { written = $0 },
                        completion: { [weak self] result in
            if let result { publish(result) }
            else if let stale = written { self?.discard(stale.url) }
        })
    }
    func cancel() { preparer.invalidate() }
    func waitForIdle() async {
        await preparer.waitForIdle()
        while let discard = discards.popLast() { await discard.value }
    }
    private func discard(_ url: URL) {
        discards.append(Task { await ExportFileStaging.discard(url) })
    }
    #if DEBUG
    var actualTask: Task<Void, Never>? { preparer.workerTask }
    var pendingCount: Int { preparer.pendingCount }
    #endif
}
#endif
