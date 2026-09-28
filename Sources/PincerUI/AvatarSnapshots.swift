#if os(macOS)
import AppKit
import PincerKit
import SwiftUI

/// Renders every creature in every state to PNGs, for reviewing the art without running a
/// Gateway: `swift run PincerMacDev --avatar-snapshots ~/Desktop/avatars`.
public enum AvatarSnapshots {
    /// The states shown, with the tool state twice (exec and search).
    static let states: [AvatarState] = [
        .idle, .thinking, .streaming, .tool(.exec), .tool(.search), .awaitingApproval, .success, .error, .compacting,
    ]

    /// Writes one PNG per creature × state × style × size × appearance into `directory`, plus
    /// a `contact-sheet-<style>.png` (every creature and state at 64pt) and `accessories-<style>.png` per
    /// render style, and `bitmaps.png`. Returns how many files it wrote.
    @MainActor
    public static func write(to directory: URL) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var count = 0
        for renderStyle in AvatarRenderStyle.allCases {
            for creature in AvatarCreature.allCases {
                let style = AvatarStyle(creature: creature, palette: self.palette(for: creature), renderStyle: renderStyle)
                for state in self.states {
                    for size in [24.0, 64.0] {
                        for dark in [false, true] {
                            let name = "\(renderStyle.rawValue)-\(creature.rawValue)-\(self.name(state))-\(Int(size))-\(dark ? "dark" : "light").png"
                            try self.png(self.tile(style, state, size: size, dark: dark, label: false), to: directory.appending(path: name))
                            count += 1
                        }
                    }
                }
            }
        }
        // One sheet per render style: every creature on one sheet is too tall to encode as a PNG.
        for renderStyle in AvatarRenderStyle.allCases {
            try self.png(self.contactSheet(renderStyle), to: directory.appending(path: "contact-sheet-\(renderStyle.rawValue).png"))
            try self.png(self.accessorySheet(renderStyle), to: directory.appending(path: "accessories-\(renderStyle.rawValue).png"))
            count += 2
        }
        try self.bitmapSheet(to: directory.appending(path: "bitmaps.png"))
        return count + 1
    }

    /// The AppKit/UIKit bitmaps (glow and badge drawn by `AvatarArt`, not SwiftUI): each state as
    /// the transcript's 32pt avatar and the sidebar's 18pt still, light rows then dark.
    @MainActor
    static func bitmapSheet(to url: URL) throws {
        let scale: CGFloat = 2, cell: CGFloat = 44, creatures = AvatarCreature.allCases
        let width = cell * CGFloat(self.states.count) * 2, height = cell * CGFloat(creatures.count * 2)
        guard let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        let accent = NSColor.controlAccentColor.cgColor
        for (d, dark) in [false, true].enumerated() {
            for (c, creature) in creatures.enumerated() {
                let y = CGFloat(d * creatures.count + c) * cell
                context.setFillColor(dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: height - y - cell, width: width, height: cell))
                let style = AvatarStyle(creature: creature, palette: self.palette(for: creature))
                for (i, state) in self.states.enumerated() {
                    let glow = AvatarArt.showsGlow(state) ? accent : nil
                    let items: [(CGImage?, CGFloat)] = [
                        (AvatarArt.image(style, pose: AvatarMotion.keyPose(for: state), dark: dark, accent: glow,
                                         badge: AgentAvatarView.badgeSymbol(for: state),
                                         size: CGSize(width: 32, height: 32), scale: scale), 32),
                        (AvatarArt.still(style, state: state, dark: dark, accent: accent, side: SidebarAvatar.side, scale: scale),
                         SidebarAvatar.side),
                    ]
                    for (j, (image, side)) in items.enumerated() {
                        guard let image else { continue }
                        let x = CGFloat(i * 2 + j) * cell + (cell - side) / 2
                        context.draw(image, in: CGRect(x: x, y: height - y - cell + (cell - side) / 2, width: side, height: side))
                    }
                }
            }
        }
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }

    static func palette(for creature: AvatarCreature) -> AvatarPalette {
        switch creature {
        case .blob, .sprout, .ghost, .mushroom: .cream
        case .owl, .fox, .bear: .apricot
        case .rock, .mouse, .hedgehog: .stone
        case .frog: .moss
        case .cat, .octopus: .lilac
        case .bunny, .pig, .axolotl: .peach
        case .penguin, .cloud: .sky
        case .chick: .lemon
        }
    }

    static func name(_ state: AvatarState) -> String {
        switch state {
        case let .tool(tool): "tool-\(tool.rawValue)"
        case .awaitingApproval: "approval"
        default: "\(state)"
        }
    }

    @MainActor
    static func tile(_ style: AvatarStyle, _ state: AvatarState, size: CGFloat, dark: Bool, label: Bool) -> some View {
        VStack(spacing: 4) {
            AgentAvatarView(state: state, style: style, size: size, animated: false)
            if label {
                Text(self.name(state)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(size < 32 ? 4 : 8)
        .background(dark ? Color(white: 0.12) : Color.white)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    @MainActor
    static func contactSheet(_ renderStyle: AvatarRenderStyle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                ForEach(AvatarCreature.allCases, id: \.self) { creature in
                    HStack(spacing: 0) {
                        Text("\(renderStyle.rawValue) \(creature.rawValue)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(dark ? .white : .black)
                            .frame(width: 90, alignment: .leading)
                            .padding(.leading, 8)
                        ForEach(Array(self.states.enumerated()), id: \.offset) { _, state in
                            let style = AvatarStyle(creature: creature, palette: self.palette(for: creature), renderStyle: renderStyle)
                            VStack(spacing: 2) {
                                AgentAvatarView(state: state, style: style, size: 64, animated: false)
                                AgentAvatarView(state: state, style: style, size: 24, animated: false)
                                Text(self.name(state)).font(.system(size: 9)).foregroundStyle(.gray)
                            }
                            .frame(width: 84)
                            .padding(.vertical, 6)
                        }
                    }
                    .background(dark ? Color(white: 0.12) : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                }
            }
        }
    }

    @MainActor
    static func accessorySheet(_ renderStyle: AvatarRenderStyle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AvatarCreature.allCases, id: \.self) { creature in
                HStack(spacing: 8) {
                    Text("\(renderStyle.rawValue) \(creature.rawValue)").font(.system(size: 11)).frame(width: 90, alignment: .leading)
                    ForEach(AvatarAccessory.allowed(for: creature), id: \.self) { accessory in
                        ForEach(AvatarPalette.allCases, id: \.self) { palette in
                            AgentAvatarView(state: .idle, style: AvatarStyle(creature: creature, accessory: accessory,
                                                                             palette: palette, renderStyle: renderStyle),
                                            size: 40, animated: false)
                        }
                        Divider().frame(height: 40)
                    }
                }
                .padding(6)
            }
        }
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    @MainActor
    static func png(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
#endif
