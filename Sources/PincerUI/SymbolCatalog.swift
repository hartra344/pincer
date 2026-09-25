import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Curated SF Symbols offered for chat icons. SF Symbols has no public enumeration API, so the
/// picker ships its own list; names missing on the running OS are dropped at load time.
enum SymbolCatalog {
    struct Category: Identifiable, Sendable {
        let name: String
        let symbols: [String]
        var id: String { self.name }
    }

    static func isAvailable(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        #if os(macOS)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        return UIImage(systemName: name) != nil
        #endif
    }

    /// Other OpenClaw clients store these named glyphs in a session's `icon`.
    static let gatewayGlyphs: [String: String] = [
        "braces": "curlybraces",
        "book": "book",
        "monitor": "display",
        "bot": "cpu",
        "kanban": "rectangle.split.3x1",
        "coins": "dollarsign.circle",
    ]

    /// An SF Symbol for a raw icon value, or `nil` when it can't be drawn on this OS.
    static func symbol(for value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let name = self.gatewayGlyphs[value] ?? value
        return self.isAvailable(name) ? name : nil
    }

    static let categories: [Category] = raw.compactMap { name, symbols in
        var seen = Set<String>()
        let available = symbols.filter { seen.insert($0).inserted && isAvailable($0) }
        return available.isEmpty ? nil : Category(name: name, symbols: available)
    }

    static func search(_ query: String) -> [Category] {
        let terms = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "." }).map(String.init)
        guard !terms.isEmpty else { return self.categories }
        return self.categories.compactMap { category in
            let categoryMatch = terms.allSatisfy { category.name.lowercased().contains($0) }
            let symbols = categoryMatch ? category.symbols : category.symbols.filter { symbol in
                terms.allSatisfy { symbol.contains($0) }
            }
            return symbols.isEmpty ? nil : Category(name: category.name, symbols: symbols)
        }
    }

    private static let raw: [(String, [String])] = [
        ("Communication", [
            "number", "bubble.left", "bubble.left.fill", "bubble.left.and.bubble.right", "bubble.left.and.bubble.right.fill",
            "bubble.left.and.text.bubble.right", "text.bubble", "quote.bubble", "exclamationmark.bubble", "questionmark.bubble",
            "message", "message.fill", "envelope", "envelope.fill", "paperplane", "paperplane.fill", "phone", "phone.fill",
            "video", "video.fill", "megaphone", "megaphone.fill", "at", "bell", "bell.fill", "mic", "mic.fill",
            "person.wave.2", "antenna.radiowaves.left.and.right",
        ]),
        ("People", [
            "person", "person.fill", "person.2", "person.2.fill", "person.3", "person.3.fill", "person.crop.circle",
            "person.crop.circle.fill", "figure.walk", "figure.run", "figure.stand", "figure.2.and.child.holdinghands",
            "brain", "brain.head.profile", "hand.raised", "hand.thumbsup", "hands.clap", "eye", "face.smiling",
            "face.smiling.inverse", "graduationcap", "graduationcap.fill",
        ]),
        ("Work", [
            "briefcase", "briefcase.fill", "folder", "folder.fill", "doc", "doc.fill", "doc.text", "doc.text.fill",
            "list.bullet", "list.bullet.clipboard", "checklist", "checkmark.circle", "checkmark.circle.fill",
            "calendar", "calendar.badge.clock", "clock", "clock.fill", "alarm", "timer", "hourglass", "chart.bar",
            "chart.bar.fill", "chart.pie", "chart.line.uptrend.xyaxis", "tray", "tray.full", "archivebox", "paperclip",
            "pencil", "pencil.and.outline", "square.and.pencil", "highlighter", "signature", "building.2",
            "building.columns", "dollarsign.circle", "creditcard", "cart", "bag", "banknote",
        ]),
        ("Development", [
            "chevron.left.forwardslash.chevron.right", "curlybraces", "terminal", "terminal.fill", "apple.terminal",
            "hammer", "hammer.fill", "wrench.and.screwdriver", "wrench.and.screwdriver.fill", "gearshape", "gearshape.fill",
            "gearshape.2", "cpu", "memorychip", "server.rack", "externaldrive", "internaldrive", "network", "cloud",
            "cloud.fill", "icloud", "ladybug", "ladybug.fill", "ant", "shippingbox", "shippingbox.fill", "cube",
            "cube.fill", "puzzlepiece", "puzzlepiece.extension", "function", "sum", "command", "keyboard",
            "desktopcomputer", "laptopcomputer", "display", "iphone", "ipad", "applewatch", "rectangle.split.3x1",
            "square.stack.3d.up", "point.3.connected.trianglepath.dotted", "arrow.triangle.branch", "arrow.triangle.pull",
            "lock", "lock.fill", "key", "key.fill", "shield", "shield.fill", "checkmark.shield",
        ]),
        ("AI & Magic", [
            "sparkles", "sparkle", "wand.and.stars", "wand.and.rays", "lightbulb", "lightbulb.fill", "bolt", "bolt.fill",
            "atom", "brain", "text.magnifyingglass", "magnifyingglass", "eyeglasses", "binoculars", "scope", "target",
            "infinity", "questionmark.circle", "exclamationmark.triangle", "flame", "flame.fill",
        ]),
        ("Home & Places", [
            "house", "house.fill", "building", "building.fill", "bed.double", "sofa", "lamp.desk", "fork.knife",
            "cup.and.saucer", "mug", "wineglass", "birthday.cake", "gift", "gift.fill", "map", "map.fill", "mappin",
            "mappin.and.ellipse", "location", "location.fill", "globe", "globe.americas", "globe.europe.africa",
            "globe.asia.australia", "signpost.right", "tent", "mountain.2", "beach.umbrella",
        ]),
        ("Travel", [
            "airplane", "airplane.departure", "car", "car.fill", "bus", "tram", "train.side.front.car", "bicycle",
            "scooter", "sailboat", "ferry", "fuelpump", "suitcase", "suitcase.fill", "ticket", "passport",
        ]),
        ("Nature", [
            "leaf", "leaf.fill", "tree", "camera.macro", "sun.max", "sun.max.fill", "moon", "moon.fill", "moon.stars",
            "cloud.sun", "cloud.rain", "cloud.bolt", "snowflake", "wind", "drop", "drop.fill", "flame", "bolt.fill",
            "tortoise", "hare", "pawprint", "pawprint.fill", "bird", "fish", "lizard", "ant", "ladybug", "carrot",
            "globe", "sparkles",
        ]),
        ("Health & Fitness", [
            "heart", "heart.fill", "heart.text.square", "cross", "cross.fill", "pills", "pills.fill", "stethoscope",
            "bandage", "figure.run", "figure.strengthtraining.traditional", "figure.yoga", "figure.hiking",
            "dumbbell", "dumbbell.fill", "sportscourt", "soccerball", "basketball", "tennisball", "football",
            "bed.double", "lungs", "waveform.path.ecg",
        ]),
        ("Media & Fun", [
            "music.note", "music.note.list", "music.mic", "headphones", "guitars", "pianokeys", "film", "film.fill",
            "tv", "play.rectangle", "play.circle", "camera", "camera.fill", "photo", "photo.fill", "paintbrush",
            "paintbrush.fill", "paintpalette", "theatermasks", "gamecontroller", "gamecontroller.fill", "dice",
            "puzzlepiece.fill", "book", "book.fill", "books.vertical", "newspaper", "magazine", "bookmark",
            "bookmark.fill", "party.popper", "balloon", "crown", "crown.fill", "trophy", "trophy.fill", "medal",
        ]),
        ("Symbols", [
            "star", "star.fill", "heart", "heart.fill", "flag", "flag.fill", "tag", "tag.fill", "pin", "pin.fill",
            "bolt.circle", "circle", "circle.fill", "square", "square.fill", "triangle", "triangle.fill", "diamond",
            "diamond.fill", "hexagon", "hexagon.fill", "seal", "seal.fill", "checkmark", "xmark", "plus", "minus",
            "exclamationmark", "questionmark", "number.circle", "at.circle", "asterisk", "percent", "infinity",
            "arrow.up", "arrow.down", "arrow.clockwise", "arrow.2.squarepath", "clock.arrow.circlepath",
            "square.grid.2x2", "circle.grid.3x3", "rectangle.3.group",
        ]),
    ]
}
