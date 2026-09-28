import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

@MainActor
func runCommandPaletteChecks() {
    do {
        var history = ChatHistory<String>(limit: 3)
        check(!history.canGoBack && !history.canGoForward && history.current == nil, "history starts empty")
        history.visit("a")
        history.visit("a")
        check(!history.canGoBack && history.current == "a", "revisiting the current chat isn't recorded")
        history.visit("b")
        history.visit("c")
        check(history.backStack == ["a", "b"] && history.recent == ["b", "a"], "visits build the back stack; recent is newest first")
        check(history.goBack() == "b" && history.current == "b" && history.forwardStack == ["c"], "back moves to the previous chat")
        check(history.goBack() == "a" && !history.canGoBack && history.goBack() == nil, "back stops at the first chat")
        check(history.goForward() == "b" && history.goForward() == "c" && !history.canGoForward, "forward retraces")
        _ = history.goBack()
        history.visit("d")
        check(!history.canGoForward && history.backStack == ["a", "b"], "a new visit clears forward")
        history.visit("e")
        history.visit("f")
        check(history.backStack == ["b", "d", "e"], "back stack is capped at the limit")
        check(history.goBack(where: { $0 != "e" && $0 != "d" }) == "b" && history.current == "b" && history.forwardStack == ["f"],
              "back skips chats that no longer exist")
        history.visit("x")
        history.visit("b")
        check(history.recent == ["x"], "recent drops the current chat and duplicates (\(history.recent))")
        history.prune { $0 != "b" }
        check(history.current == nil && history.backStack == ["x"], "prune drops removed chats")

        func item(_ title: String, keywords: [String] = []) -> PaletteItem {
            PaletteItem(id: title, title: title, symbol: "x", keywords: keywords, section: .chats, action: .command(title))
        }
        check(PaletteMatcher.score("", in: "Anything") == 0, "empty query matches")
        check(PaletteMatcher.score("xyz", in: "Japan trip") == nil, "non-matching query rejected")
        check(PaletteMatcher.score("JAPAN", in: "Japan trip") != nil, "case-insensitive")
        check(PaletteMatcher.score("cafe", in: "Café plans") != nil, "diacritic-insensitive")
        check(PaletteMatcher.score("jptr", in: "Japan trip") != nil && PaletteMatcher.score("rtj", in: "Japan trip") == nil,
              "in-order subsequence only")
        check(PaletteMatcher.score("trip", in: "Japan trip")! > PaletteMatcher.score("jptr", in: "Japan trip")!, "substring beats subsequence")
        check(PaletteMatcher.score("jap", in: "Japan trip")! > PaletteMatcher.score("rip", in: "Japan trip")!, "prefix beats mid-word")
        let items = [item("Paper digest"), item("Japan trip"), item("home-lab", keywords: ["Discord"]), item("New Chat with Scout")]
        check(PaletteMatcher.rank(items, query: "").map(\.title) == items.map(\.title), "empty query keeps order")
        check(PaletteMatcher.rank(items, query: "trip").map(\.title) == ["Japan trip"], "filters by title")
        check(PaletteMatcher.rank(items, query: "discord").map(\.title) == ["home-lab"], "matches keywords")
        check(PaletteMatcher.rank(items, query: "new scout").map(\.title) == ["New Chat with Scout"], "every word must match")
        check(PaletteMatcher.rank(items, query: "p").first?.title == "Paper digest", "best match first")
        check(PaletteMatcher.rank([item("Scratch pad"), item("Pad")], query: "pad").map(\.title) == ["Pad", "Scratch pad"],
              "exact title outranks a later match")
    }
}
