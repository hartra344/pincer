import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class TranscriptImagePartView: TranscriptTapView {
    private var image: TranscriptPart.Image?
    private var tooLarge = false
    private let imageLayer = CALayer()
    private let spinner = TranscriptSpinner(size: 14)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.imageLayer.contentsGravity = .resizeAspect
        self.imageLayer.cornerRadius = 10
        self.imageLayer.masksToBounds = true
        self.imageLayer.borderWidth = 1
        self.imageLayer.minificationFilter = .trilinear
        self.hostLayer.addSublayer(self.imageLayer)
        self.addSubview(self.spinner)
        self.appearanceChanged()
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .image(image) = part else { return }
        self.image = image
        self.tooLarge = false
        if self.imageLayer.masksToBounds == image.plain {
            withoutLayerAnimations {
                self.imageLayer.masksToBounds = !image.plain
                self.imageLayer.cornerRadius = image.plain ? 0 : 10
                self.imageLayer.borderWidth = image.plain ? 0 : 1
            }
        }
        if case .failed = image.state {
            self.tooLarge = (actions as? TranscriptRenderer)?.context.gateway.images.failure(image.ref) == .tooLarge
        }
        self.accessibilityText = self.tooLarge ? self.tooLargeText(image.ref) : image.ref.alt ?? L("Image")
        switch image.state {
        case let .loaded(cgImage):
            withoutLayerAnimations {
                self.imageLayer.contents = cgImage
                self.imageLayer.isHidden = false
            }
            self.spinner.setAnimating(false)
            self.onTap = { [weak actions] in actions?.preview(image.ref) }
        case .loading:
            withoutLayerAnimations {
                self.imageLayer.contents = nil
                self.imageLayer.isHidden = true
            }
            self.spinner.setAnimating(true)
            self.onTap = nil
            actions.loadImage(image.ref)
        case .failed:
            withoutLayerAnimations {
                self.imageLayer.contents = nil
                self.imageLayer.isHidden = true
            }
            self.spinner.setAnimating(false)
            // Too large to render inline, but the preview sheet can still save or share the file.
            self.onTap = self.tooLarge ? { [weak actions] in actions?.preview(image.ref) } : nil
        }
        self.redraw()
    }

    override func didHide() {
        self.spinner.setAnimating(false)
    }

    override func appearanceChanged() {
        super.appearanceChanged()
        withoutLayerAnimations { self.imageLayer.borderColor = self.resolved(TranscriptColors.stroke) }
    }

    override func layoutContent() {
        withoutLayerAnimations { self.imageLayer.frame = self.bounds }
        self.spinner.place(center: CGPoint(x: self.bounds.midX, y: self.bounds.midY))
    }

    private func tooLargeText(_ ref: ImageRef) -> String {
        ref.alt.map { L("\($0) — too large to preview") } ?? L("Image too large to preview")
    }

    override func draw(_ rect: CGRect) {
        guard let image else { return }
        if case .loaded = image.state { return }
        let bounds = self.bounds
        TranscriptColors.fill.setFill()
        PBezierPath.rounded(bounds, radius: 10).fill()
        guard case .failed = image.state else { return }
        let style = TranscriptStyle.shared
        let text = singleLine(self.tooLarge ? self.tooLargeText(image.ref) : image.ref.alt ?? L("Image unavailable"), style.caption, TranscriptColors.secondary, truncation: .byTruncatingMiddle)
        let textWidth = min(text.lineWidth, bounds.width - 16)
        let iconHeight: CGFloat = 24
        let total = iconHeight + 4 + TranscriptStyle.lineHeight(style.caption)
        let top = (bounds.height - total) / 2
        TranscriptSymbols.draw("photo.badge.exclamationmark", in: CGRect(x: 0, y: top, width: bounds.width, height: iconHeight),
                               size: style.title3.pointSize, color: TranscriptColors.secondary)
        text.drawLine(at: CGPoint(x: (bounds.width - textWidth) / 2, y: top + iconHeight + 4), width: textWidth, font: style.caption)
    }
}

final class TranscriptImageLinkView: TranscriptTapView {
    private var title = ""

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .imageLink(title, url) = part else { return }
        self.title = title
        self.accessibilityText = title
        self.onTap = { [weak actions] in actions?.open(url) }
        #if os(macOS)
        self.toolTip = url.absoluteString
        #endif
        self.redraw()
    }

    override func draw(_ rect: CGRect) {
        let style = TranscriptStyle.shared
        let bounds = self.bounds
        TranscriptColors.fill.setFill()
        PBezierPath.rounded(bounds, radius: TranscriptMetrics.cardRadius).fill()
        let color = self.isPressed ? TranscriptColors.link.withAlphaComponent(0.5) : TranscriptColors.link
        TranscriptSymbols.draw("photo.badge.arrow.down", in: CGRect(x: 10, y: 0, width: 16, height: bounds.height), size: style.callout.pointSize, color: color)
        singleLine(self.title, style.callout, color)
            .drawLine(at: CGPoint(x: 32, y: (bounds.height - TranscriptStyle.lineHeight(style.callout)) / 2), width: bounds.width - 42, font: style.callout)
    }
}

final class TranscriptFileView: TranscriptBaseView {
    private var part: TranscriptPart.File?
    private let header = TranscriptFileHeaderView()
    private let saveButton = TranscriptLabelButton()
    private let section = TranscriptToolSectionView()
    private var identity: String?
    private var saveToken = 0

    static var saveButtonSize: CGSize {
        let font = TranscriptStyle.shared.caption
        return CGSize(width: 14 + 4 + singleLine(L("Save"), font, TranscriptColors.tint).lineWidth,
                      height: max(TranscriptStyle.lineHeight(font), 16))
    }

    /// Collapsed chip width; mirrors the header's drawing and `layoutContent` so the name never truncates needlessly.
    static func chipWidth(for ref: FileRef, canExpand: Bool) -> CGFloat {
        let name = singleLine(ref.name, TranscriptStyle.shared.callout, TranscriptColors.label).lineWidth.rounded(.up)
        var width = TranscriptFileHeaderView.textX + name + (canExpand ? TranscriptFileHeaderView.chevronSpace : 0) + 10
        if ref.isDownloadable { width += 4 + self.saveButtonSize.width.rounded(.up) + 10 }
        return width
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.header)
        self.addSubview(self.saveButton)
        self.addSubview(self.section)
        self.saveButton.set(title: L("Save"), symbol: "arrow.down.circle")
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .file(file) = part else { return }
        let identity = "\(row.id):\(file.key)"
        let sameFile = identity == self.identity
        if !sameFile {
            self.saveToken += 1
            self.saveButton.set(title: L("Save"), symbol: "arrow.down.circle")
            self.identity = identity
        }
        self.part = file
        let rowId = row.id
        self.header.configure(file)
        if HTMLPreview.isPreviewable(file: file.ref) {
            self.header.onTap = { [weak self, weak actions] in
                guard let actions else { return }
                self?.previewHTML(file.ref, actions: actions)
            }
            self.header.accessibilityText = L("Preview \(file.ref.name)")
        } else if file.canExpand {
            self.header.onTap = { [weak actions] in
                if !file.isExpanded { actions?.loadFilePreview(file.ref) }
                actions?.setExpanded(file.key, !file.isExpanded, row: rowId)
            }
            self.header.accessibilityText = file.isExpanded ? L("Attachment \(file.ref.name), expanded") : L("Attachment \(file.ref.name), collapsed")
        } else if FilePreviewFiles.isPreviewable(file.ref) {
            self.header.onTap = { [weak self, weak actions] in
                guard let actions else { return }
                self?.quickLook(file.ref, actions: actions)
            }
            self.header.accessibilityText = L("Preview \(file.ref.name)")
        } else if file.ref.isDownloadable {
            self.header.onTap = { [weak self, weak actions] in
                guard let actions else { return }
                self?.save(file.ref, actions: actions)
            }
            self.header.accessibilityText = L("Save \(file.ref.name)")
        } else {
            self.header.onTap = nil
            self.header.accessibilityText = L("Attachment \(file.ref.name)")
        }
        self.saveButton.isHidden = !file.ref.isDownloadable
        self.saveButton.onTap = { [weak self, weak actions] in
            guard let actions else { return }
            self?.save(file.ref, actions: actions)
        }
        #if os(macOS)
        self.saveButton.toolTip = L("Save “\(file.ref.name)”")
        #endif
        if file.isExpanded, file.section == nil, file.note == L("Loading…") { actions.loadFilePreview(file.ref) }
        if let section = file.section {
            self.section.isHidden = false
            self.section.configure(section, row: row, resetScroll: !sameFile)
        } else {
            self.section.isHidden = true
        }
        self.redraw()
    }

    /// Downloads the file for Quick Look; the Save button's symbol shows the download, as for saving.
    private func quickLook(_ file: FileRef, actions: TranscriptRowActions) {
        self.saveToken += 1
        let token = self.saveToken
        self.saveButton.set(title: L("Save"), symbol: "hourglass")
        Task { @MainActor [weak self] in
            let shown = await actions.quickLook(file)
            guard let self, self.saveToken == token else { return }
            self.saveButton.set(title: L("Save"), symbol: shown ? "arrow.down.circle" : "exclamationmark.triangle")
            guard !shown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.saveToken == token else { return }
                self.saveButton.set(title: L("Save"), symbol: "arrow.down.circle")
            }
        }
    }

    private func previewHTML(_ file: FileRef, actions: TranscriptRowActions) {
        self.saveToken += 1
        let token = self.saveToken
        self.saveButton.set(title: L("Save"), symbol: "hourglass")
        Task { @MainActor [weak self] in
            let shown = await actions.previewHTML(file)
            guard let self, self.saveToken == token else { return }
            self.saveButton.set(title: L("Save"), symbol: shown ? "arrow.down.circle" : "exclamationmark.triangle")
            #if os(macOS)
            if !shown { self.saveButton.toolTip = L("Couldn’t load “\(file.name)”") }
            #endif
            guard !shown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.saveToken == token else { return }
                self.saveButton.set(title: L("Save"), symbol: "arrow.down.circle")
            }
        }
    }

    /// The button keeps its "Save" title, so the chip keeps its width; the symbol shows progress.
    private func save(_ file: FileRef, actions: TranscriptRowActions) {
        self.saveToken += 1
        let token = self.saveToken
        self.saveButton.set(title: L("Save"), symbol: "hourglass")
        Task { @MainActor [weak self] in
            let saved = await actions.saveFile(file)
            guard let self, self.saveToken == token else { return }
            self.saveButton.set(title: L("Save"), symbol: saved ? "arrow.down.circle" : "exclamationmark.triangle")
            #if os(macOS)
            if !saved { self.saveButton.toolTip = L("Couldn’t download “\(file.name)”") }
            #endif
            guard !saved else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.saveToken == token else { return }
                self.saveButton.set(title: L("Save"), symbol: "arrow.down.circle")
            }
        }
    }

    override func layoutContent() {
        guard let part else { return }
        let bounds = self.bounds
        var headerWidth = bounds.width
        if part.ref.isDownloadable {
            let size = self.saveButton.buttonSize
            let frame = CGRect(x: bounds.width - 10 - size.width, y: (part.headerHeight - size.height) / 2,
                               width: size.width, height: size.height)
            if self.saveButton.frame != frame { self.saveButton.frame = frame }
            headerWidth = frame.minX - 4
        }
        let headerFrame = CGRect(x: 0, y: 0, width: max(headerWidth, 1), height: part.headerHeight)
        if self.header.frame != headerFrame { self.header.frame = headerFrame }
        self.header.layoutContent()
        if let section = part.section {
            if self.section.frame != section.frame { self.section.frame = section.frame }
            self.section.layoutContent()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let part else { return }
        let bounds = self.bounds
        let shape = PBezierPath.rounded(bounds.insetBy(dx: 0.5, dy: 0.5), radius: TranscriptMetrics.cardRadius)
        TranscriptColors.fill.setFill()
        shape.fill()
        guard part.isExpanded else { return }
        TranscriptColors.stroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        TranscriptColors.separator.setFill()
        PBezierPath(rect: CGRect(x: 0, y: part.headerHeight, width: bounds.width, height: 1)).fill()
        if let note = part.note {
            let font = TranscriptStyle.shared.caption
            singleLine(note, font, TranscriptColors.secondary)
                .drawLine(at: CGPoint(x: 10, y: part.noteY), width: bounds.width - 20, font: font)
        }
    }
}

final class TranscriptFileHeaderView: TranscriptTapView {
    private var part: TranscriptPart.File?
    static let textX: CGFloat = 32
    static let chevronSpace: CGFloat = 18

    func configure(_ part: TranscriptPart.File) {
        self.part = part
        self.redraw()
    }

    override func draw(_ rect: CGRect) {
        guard let part else { return }
        let style = TranscriptStyle.shared
        let bounds = self.bounds
        if self.isPressed {
            TranscriptColors.highlight.setFill()
            PBezierPath.rounded(bounds.insetBy(dx: 1, dy: 1), radius: TranscriptMetrics.cardRadius - 1).fill()
        }
        let symbol = part.ref.isText ? "doc.text" : "paperclip"
        TranscriptSymbols.draw(symbol, in: CGRect(x: 10, y: 0, width: 16, height: bounds.height),
                               size: style.callout.pointSize, color: TranscriptColors.label)
        var trailing = bounds.width - 10
        if part.canExpand {
            trailing -= 10
            TranscriptSymbols.draw(part.isExpanded ? "chevron.down" : "chevron.right",
                                   in: CGRect(x: trailing, y: 0, width: 10, height: bounds.height),
                                   size: style.caption2Medium.pointSize, weight: .bold, color: TranscriptColors.tertiary)
            trailing -= 8
        }
        singleLine(part.ref.name, style.callout, TranscriptColors.label, truncation: .byTruncatingMiddle)
            .drawLine(at: CGPoint(x: Self.textX, y: (bounds.height - TranscriptStyle.lineHeight(style.callout)) / 2),
                      width: max(trailing - Self.textX, 1), font: style.callout)
    }
}
