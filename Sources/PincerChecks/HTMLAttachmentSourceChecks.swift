import Foundation
@testable import PincerKit

/// #873: HTML/SVG attachments open in the locked-down preview only when small, UTF-8 and non-blank.
@MainActor func runHTMLAttachmentSourceChecks() {
    check(HTMLAttachmentSource.decode(Data("<svg/>\r\n".utf8)) == "<svg/>\n", "html attachment: UTF-8 source decodes with LF endings")
    check(HTMLAttachmentSource.decode(Data("  \n".utf8)) == nil, "html attachment: blank file is rejected")
    check(HTMLAttachmentSource.decode(Data([0x3C, 0x00])) == nil, "html attachment: binary file is rejected")
    let oversized = Data(repeating: 0x20, count: HTMLAttachmentSource.maxBytes) + Data("x".utf8)
    check(HTMLAttachmentSource.decode(oversized) == nil, "html attachment: files over the preview cap are rejected")
}
