import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class TranscriptThinkingHeaderView: TranscriptTapView {
    private var thinking: TranscriptPart.Thinking?
    private let spinner = TranscriptSpinner(size: 10)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.spinner)
    }

    private var title: String { self.thinking?.title ?? L("Thinking") }

    private var titleWidth: CGFloat {
        singleLine(self.title, TranscriptStyle.shared.calloutMedium, TranscriptColors.secondary).lineWidth
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .thinkingHeader(thinking) = part else { return }
        let changed = self.thinking?.isExpanded != thinking.isExpanded || self.thinking?.isStreaming != thinking.isStreaming
            || self.thinking?.title != thinking.title || self.thinking?.symbol != thinking.symbol
        self.thinking = thinking
        self.spinner.setAnimating(thinking.isStreaming)
        let rowId = row.id
        self.onTap = { [weak actions] in actions?.setExpanded(thinking.key, !thinking.isExpanded, row: rowId) }
        self.accessibilityText = thinking.isExpanded ? L("Hide \(thinking.title.lowercased())") : L("Show \(thinking.title.lowercased())")
        self.hitWidth = self.contentWidth
        if changed { self.redraw() }
    }

    private var contentWidth: CGFloat {
        22 + self.titleWidth + (self.thinking?.isStreaming == true ? 16 : 0) + 6 + 10
    }

    override func layoutContent() {
        self.spinner.place(center: CGPoint(x: 22 + self.titleWidth + 6 + 5, y: self.bounds.midY))
    }

    override func draw(_ rect: CGRect) {
        guard let thinking else { return }
        let style = TranscriptStyle.shared
        let color = self.isPressed ? TranscriptColors.tertiary : TranscriptColors.secondary
        let height = self.bounds.height
        TranscriptSymbols.draw(thinking.symbol, in: CGRect(x: 0, y: 0, width: 16, height: height), size: style.callout.pointSize, color: color)
        let title = singleLine(self.title, style.calloutMedium, color)
        title.drawLine(at: CGPoint(x: 22, y: (height - TranscriptStyle.lineHeight(style.calloutMedium)) / 2), width: title.lineWidth, font: style.calloutMedium)
        let chevronX = 22 + title.lineWidth + 6 + (thinking.isStreaming ? 16 : 0)
        TranscriptSymbols.draw(thinking.isExpanded ? "chevron.down" : "chevron.right",
                               in: CGRect(x: chevronX, y: 0, width: 10, height: height),
                               size: style.caption2Medium.pointSize, weight: .bold, color: color)
    }
}

final class TranscriptToolView: TranscriptBaseView {
    private var part: TranscriptPart.Tool?
    private let header = TranscriptToolHeaderView()
    private let runButton = TranscriptLabelButton()
    private var sections: [TranscriptToolSectionView] = []
    private var rowId: String?
    private let copyButton = TranscriptLabelButton()
    private let toggleButton = TranscriptLabelButton()
    private var copiedToken = 0
    private var controlButtons: [TranscriptLabelButton] = []
    private var noteViews: [TranscriptNoteView] = []
    private var copiedControl: String?
    private weak var actions: TranscriptRowActions?
    let searchBar = TranscriptToolSearchBar()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.header)
        self.addSubview(self.searchBar)
        self.addSubview(self.runButton)
        self.runButton.set(title: L("Open run"), symbol: "sparkles")
        self.addSubview(self.copyButton)
        self.addSubview(self.toggleButton)
        self.copyButton.isSubdued = true
        self.showCopy()
        self.copyButton.onTap = { [weak self] in self?.copyDiff() }
    }

    private func showCopy() {
        self.copyButton.set(title: L("Copy"), symbol: "doc.on.doc")
        self.copyButton.accessibilityText = self.part?.edit?.kind == .write ? L("Copy file contents") : L("Copy diff")
    }

    private func copyDiff() {
        guard let diff = self.part?.diff else { return }
        // Announces "Copied" through `AccessibilityAnnouncer.announceCopied()`.
        Clipboard.copy(diff.copyText)
        self.copyButton.set(title: L("Copied"), symbol: "checkmark")
        self.copiedToken += 1
        let token = self.copiedToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.copiedToken == token else { return }
            self.showCopy()
        }
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .tool(tool) = part else { return }
        let sameTool = self.part?.tool.id == tool.tool.id && self.rowId == row.id
        self.part = tool
        self.rowId = row.id
        self.actions = actions
        let rowId = row.id
        self.header.configure(tool, trailing: tool.run == nil ? 10 : 6,
                              contextMenu: tool.mcpContextMenu
                                  ?? TranscriptToolContextMenu.make(toolName: tool.tool.name, controls: tool.controls))
        self.header.onOpenMCPServer = { [weak actions] name in actions?.openMCPServer(name) }
        self.header.onTap = { [weak actions] in actions?.setExpanded(tool.key, !tool.isExpanded, row: rowId) }
        let spokenDuration = tool.tool.isRunning ? nil : tool.tool.durationMs.map { ToolDuration.format($0).spoken }
        if let edit = tool.edit {
            #if os(macOS)
            self.header.toolTip = edit.fullPaths
            #endif
            self.header.accessibilityText = AccessibilityText.join([
                edit.accessibilitySummary(isRunning: tool.tool.isRunning), spokenDuration,
                tool.tool.isRunning ? L("running") : nil, tool.tool.isError ? L("failed") : nil,
                tool.isExpanded ? L("expanded") : L("collapsed"),
            ])
        } else {
            let parts = ToolCardName(tool.tool.name)
            #if os(macOS)
            self.header.toolTip = parts.server.map { L("\(parts.tool) on \($0)") }
            #endif
            self.header.accessibilityText = AccessibilityText.join(
                [parts.server.map { L("\(parts.tool) on \($0)") } ?? tool.tool.name, tool.tool.summary, spokenDuration]
                    + [tool.tool.isRunning ? L("running") : nil, tool.tool.isError ? L("failed") : nil,
                       tool.isExpanded ? L("expanded") : L("collapsed")])
        }
        if !sameTool {
            self.copiedToken += 1
            self.copiedControl = nil
            self.showCopy()
        }
        self.configureControls(tool.controls)
        while self.noteViews.count < tool.notes.count {
            let view = TranscriptNoteView()
            self.noteViews.append(view)
            self.addSubview(view)
        }
        for (index, view) in self.noteViews.enumerated() {
            view.isHidden = index >= tool.notes.count
            if index < tool.notes.count { view.set(tool.notes[index].text) }
        }
        if let diff = tool.diff {
            self.copyButton.isHidden = false
            if let title = diff.toggleTitle {
                self.toggleButton.isHidden = false
                self.toggleButton.set(title: title, symbol: diff.isExpanded ? "chevron.up" : "chevron.down")
                self.toggleButton.onTap = { [weak actions] in actions?.setExpanded(diff.key, !diff.isExpanded, row: rowId) }
            } else {
                self.toggleButton.isHidden = true
                self.toggleButton.onTap = nil
            }
        } else {
            self.copyButton.isHidden = true
            self.toggleButton.isHidden = true
            self.toggleButton.onTap = nil
        }
        if let run = tool.run {
            self.runButton.isHidden = false
            self.runButton.onTap = { [weak actions] in actions?.openRun(run.key) }
            #if os(macOS)
            self.runButton.toolTip = L("Open “\(run.title)” to see what this helper did")
            #endif
        } else {
            self.runButton.isHidden = true
            self.runButton.onTap = nil
        }
        while self.sections.count < tool.sections.count {
            let view = TranscriptToolSectionView()
            self.sections.append(view)
            self.addSubview(view)
        }
        for (index, view) in self.sections.enumerated() {
            if index < tool.sections.count {
                view.isHidden = false
                view.configure(tool.sections[index], row: row, resetScroll: !sameTool)
            } else {
                view.isHidden = true
            }
        }
        self.searchBar.configure(tool.search, toolId: tool.tool.id, row: rowId, actions: actions)
        self.redraw()
    }

    private func configureControls(_ controls: [TranscriptPart.Tool.Control]) {
        while self.controlButtons.count < controls.count {
            let button = TranscriptLabelButton()
            button.isSubdued = true
            self.controlButtons.append(button)
            self.addSubview(button)
        }
        for (index, button) in self.controlButtons.enumerated() {
            guard index < controls.count else {
                button.isHidden = true
                button.onTap = nil
                continue
            }
            let control = controls[index]
            button.isHidden = false
            button.isSubdued = control.id != "toggle-output"
            self.applyAppearance(control, to: button)
            button.onTap = { [weak self] in self?.tapped(control) }
        }
    }

    private func applyAppearance(_ control: TranscriptPart.Tool.Control, to button: TranscriptLabelButton) {
        if case .copy = control.action, self.copiedControl == control.id {
            button.set(title: control.iconOnly ? "" : L("Copied"), symbol: "checkmark")
        } else {
            button.set(title: control.title, symbol: control.symbol)
        }
        button.accessibilityText = control.spoken
        // Icon-only buttons are 18×16; 28×28 is the least a finger can hit.
        button.hitOutset = control.iconOnly ? CGSize(width: 5, height: 6) : .zero
    }

    private func tapped(_ control: TranscriptPart.Tool.Control) {
        switch control.action {
        case let .copy(text):
            Clipboard.copy(text)
            self.copiedControl = control.id
            self.copiedToken += 1
            let token = self.copiedToken
            self.refreshControls()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.copiedToken == token else { return }
                self.copiedControl = nil
                self.refreshControls()
            }
        case let .toggle(key, value):
            guard let rowId else { return }
            self.actions?.setExpanded(key, value, row: rowId)
        case let .openMCPServer(_, toolName: toolName):
            self.actions?.openMCPServer(toolName)
        }
    }

    private func refreshControls() {
        guard let part else { return }
        for (index, control) in part.controls.enumerated() where index < self.controlButtons.count {
            self.applyAppearance(control, to: self.controlButtons[index])
        }
        self.layoutContent()
    }

    override func layoutContent() {
        guard let part else { return }
        let bounds = self.bounds
        for (index, note) in part.notes.enumerated() where index < self.noteViews.count {
            if self.noteViews[index].frame != note.frame { self.noteViews[index].frame = note.frame }
        }
        for (index, control) in part.controls.enumerated() where index < self.controlButtons.count {
            let button = self.controlButtons[index]
            let size = button.buttonSize
            let x = control.trailing ? control.frame.maxX - size.width : control.frame.minX
            let frame = CGRect(x: x, y: control.frame.minY, width: size.width, height: control.frame.height)
            if button.frame != frame { button.frame = frame }
        }
        var headerWidth = bounds.width
        if part.run != nil {
            let size = self.runButton.buttonSize
            let frame = CGRect(x: bounds.width - 10 - size.width, y: (part.headerHeight - size.height) / 2,
                               width: size.width, height: size.height)
            self.runButton.frame = frame
            headerWidth = frame.minX - 4
        }
        let headerFrame = CGRect(x: 0, y: 0, width: headerWidth, height: part.headerHeight)
        if self.header.frame != headerFrame { self.header.frame = headerFrame }
        self.header.layoutContent()
        if let diff = part.diff {
            // The layout sized Copy for "Copied"; pin it to the card's trailing edge at its own width.
            let size = self.copyButton.buttonSize
            let copyFrame = CGRect(x: diff.copyFrame.maxX - size.width, y: diff.copyFrame.minY, width: size.width, height: size.height)
            if self.copyButton.frame != copyFrame { self.copyButton.frame = copyFrame }
            if self.toggleButton.frame != diff.toggleFrame { self.toggleButton.frame = diff.toggleFrame }
        }
        for (index, section) in part.sections.enumerated() where index < self.sections.count {
            let view = self.sections[index]
            if view.frame != section.frame { view.frame = section.frame }
            view.layoutContent()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let part else { return }
        let bounds = self.bounds
        let style = TranscriptStyle.shared
        let shape = PBezierPath.rounded(bounds.insetBy(dx: 0.5, dy: 0.5), radius: TranscriptMetrics.cardRadius)
        TranscriptColors.fill.setFill()
        shape.fill()
        (part.tool.isError ? TranscriptColors.red.withAlphaComponent(0.5) : TranscriptColors.stroke).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        guard part.isExpanded else { return }
        TranscriptColors.separator.setFill()
        PBezierPath(rect: CGRect(x: 0, y: part.headerHeight, width: bounds.width, height: 1)).fill()
        for item in part.decor {
            switch item {
            case let .block(rect, tone, stroke):
                let shape = PBezierPath.rounded(rect.insetBy(dx: 0.5, dy: 0.5), radius: 6)
                tone.color.setFill()
                shape.fill()
                (stroke.map { $0.color.withAlphaComponent(0.5) } ?? TranscriptColors.stroke).setStroke()
                shape.lineWidth = 1
                shape.stroke()
            case let .pill(rect, tone):
                tone.badgeFill.setFill()
                PBezierPath.rounded(rect, radius: rect.height / 2).fill()
            case let .label(text, origin, width, face, tone, truncation):
                let font = face.font(style)
                singleLine(text, font, tone.color, truncation: truncation).drawLine(at: origin, width: width, font: font)
            case let .symbol(name, rect, tone):
                TranscriptSymbols.draw(name, in: rect, size: style.caption.pointSize, color: tone.color)
            }
        }
        for section in part.sections where !section.title.isEmpty {
            singleLine(section.title, style.captionSemibold, TranscriptColors.secondary)
                .drawLine(at: CGPoint(x: 10, y: section.titleY), width: bounds.width - 20, font: style.captionSemibold)
        }
        if let y = part.runningY {
            singleLine(L("Running…"), style.caption, TranscriptColors.secondary)
                .drawLine(at: CGPoint(x: 10, y: y), width: bounds.width - 20, font: style.caption)
        }
    }
}

/// An invisible, click-through element that gives drawn chips and badges a VoiceOver label.
final class TranscriptNoteView: TranscriptBaseView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(macOS)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.staticText)
        #else
        self.isAccessibilityElement = true
        self.isUserInteractionEnabled = false
        self.accessibilityTraits = .staticText
        #endif
    }

    func set(_ text: String) {
        #if os(macOS)
        self.setAccessibilityLabel(text)
        #else
        self.accessibilityLabel = text
        #endif
    }

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif
}
