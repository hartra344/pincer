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
func runProgressCardChecks() {
    let card = ProgressCard(json("""
    {"sessionKey":"agent:main:main","revision":5,"updatedAt":1700000000000,
     "markdown":"**Three-step task: wolf SVG**\\n\\nI'll update the card between phases.",
     "steps":[{"step":"Plan the composition","status":"completed"},
              {"step":"Create the SVG","status":"in_progress"},
              {"step":"Validate","status":"pending"},
              {"step":"  ","status":"pending"},
              {"step":"Bad","status":"done"}]}
    """))
    check(card?.revision == 5 && card?.steps.count == 3, "card parses, drops blank/unknown steps")
    check(card?.completedCount == 1 && card?.currentStep?.text == "Create the SVG" && card?.currentPosition == 2,
          "current step is the in-progress one")
    check(card?.markdownSummary == "Three-step task: wolf SVG", "markdown summary strips emphasis")
    check(card?.isComplete == false, "incomplete card")
    check(ProgressCard(json(#"{"revision":1,"updatedAt":1,"markdown":"  "}"#)) == nil, "empty card is nil")
    let htmlCard = ProgressCard(json(#"""
    {"revision":1,"markdown":"<progress aria-label=\"Snap · 0/5\" value=\"0\" max=\"5\"></progress>\n**System health** (a < b)",
     "steps":[{"step":"Disk","status":"in_progress"}]}
    """#))
    check(htmlCard?.markdown == "**System health** (a < b)" && htmlCard?.markdownSummary == "System health (a < b)",
          "markdown drops raw HTML tags")
    check(ProgressCard(.null) == nil, "null card is nil")
    let done = ProgressCard(json(#"{"revision":2,"updatedAt":1,"steps":[{"step":"A","status":"completed"}]}"#))
    check(done?.isComplete == true && done?.currentStep?.text == "A", "complete card keeps last step current")
    let legacy = ProgressCard(legacyPlan: json("""
    {"phase":"update","explanation":"Why","steps":["First",{"step":"Second","status":"in_progress"},
     {"step":"Third","status":"in_progress"}]}
    """), revision: 1)
    check(legacy?.steps.map(\.text) == ["First", "Second"] && legacy?.markdown == "Why",
          "legacy plan: string steps, one in-progress step")
}
