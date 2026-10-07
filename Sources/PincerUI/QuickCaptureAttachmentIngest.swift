#if os(macOS)
import PincerKit

/// The actual panel's ingestion callbacks; injected queue is owned by deterministic callers.
@MainActor
enum QuickCaptureAttachmentIngest {
    static func make(model: QuickCaptureModel,
                     imageQueue: BoundedPreparationQueue<AttachmentIngestResult>? = nil,
                     report: @escaping @MainActor @Sendable (String?) -> Void) -> AttachmentIngest {
        AttachmentIngest(limits: model.gateway?.uploadLimits ?? UploadLimits(hello: nil),
            limitsAreLastKnown: model.gateway?.uploadLimitsAreLastKnown ?? false,
            imageQueue: imageQueue,
            reserve: { model.reserveAttachmentPreparation() },
            add: { model.attachments.append($0) }, report: report)
    }
}
#endif
