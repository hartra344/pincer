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
func runMediaDirectiveChecks() async {
    let media = MediaDirectives.extract(from: "Here's a real photograph of two mallard ducks.\nMEDIA:https://upload.wikimedia.org/wikipedia/commons/b/bf/Anas_platyrhynchos_male_female_quadrat.jpg\nPhoto: Richard Bartz / Wikimedia Commons.")
    check(media.images.first?.url == "https://upload.wikimedia.org/wikipedia/commons/b/bf/Anas_platyrhynchos_male_female_quadrat.jpg", "MEDIA: URL becomes an image")
    check(media.text == "Here's a real photograph of two mallard ducks.\nPhoto: Richard Bartz / Wikimedia Commons.", "directive line removed from text (got \(media.text))")
    check(media.images.first?.alt == "Anas_platyrhynchos_male_female_quadrat.jpg", "image named after file")
    let local = MediaDirectives.extract(from: "MEDIA: `/tmp/chart.png`\nMEDIA:~/report.pdf")
    check(local.images.first?.url == "/tmp/chart.png" && local.files == [FileRef(name: "report.pdf", url: "~/report.pdf")], "local image + non-image file")
    let fenced = MediaDirectives.extract(from: "```\nMEDIA:https://x.example/a.png\n```")
    check(fenced.images.isEmpty, "directives inside code fences stay text")
    check(MediaDirectives.withoutPartialDirective("Here:\nMEDIA:https://upl") == "Here:\n", "partial streamed directive hidden")
    check(MediaDirectives.withoutPartialDirective("Done") == "Done", "normal streaming text untouched")
    let svgMedia = MediaDirectives.extract(from: "Done.\nMEDIA:output/wolf.svg")
    check(svgMedia.images.count == 1 && svgMedia.files.isEmpty, "SVG directive renders as an image")
    let svgAttachment = ChatItem(json(#"{"role":"assistant","content":[{"type":"attachment","attachment":{"url":"output/wolf.svg","kind":"image","label":"wolf.svg","mimeType":"image/svg+xml"}}],"__openclaw":{"id":"sa1"}}"#), fallbackIndex: 0)
    if case let .image(ref)? = svgAttachment?.blocks.first { check(ref.url == "output/wolf.svg" && ref.alt == "wolf.svg", "attachment block SVG is an image") } else { check(false, "attachment block SVG is an image") }
    let codeFile = ChatItem(json(#"{"role":"assistant","content":[{"type":"attachment","attachment":{"url":"output/app.py","kind":"document","label":"app.py"}}],"__openclaw":{"id":"f1"}}"#), fallbackIndex: 0)
    if case let .file(file)? = codeFile?.blocks.first {
        check(file.url == "output/app.py" && file.isDownloadable && file.isText && file.language == "py", "code attachment keeps its source and previews")
    } else { check(false, "code attachment keeps its source and previews") }
    check(FileRef(name: "data", mimeType: "application/json").isText && !FileRef(name: "a.pdf", mimeType: "application/pdf").isText
          && FileRef(name: "Dockerfile").isText && !FileRef(name: "a.zip").isText, "text files recognized")
    let svgData = Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200"><rect width="400" height="200" fill="red"/></svg>"#.utf8)
    check(SVGSource.isSVG(svgData) && !SVGSource.isSVG(Data("<html><svg></svg>".utf8)), "SVG sniffing")
    check(SVGSource.intrinsicSize(svgData) == CGSize(width: 400, height: 200), "SVG size from viewBox")
    check(SVGSource.intrinsicSize(Data(#"<svg width="120px" height='60' viewBox="0 0 10 10">"#.utf8)) == CGSize(width: 120, height: 60), "SVG size from width/height")
    let turnEntries = TranscriptBuilder.build([ChatItem(json(#"{"role":"assistant","content":[{"type":"text","text":"Duck:\nMEDIA:https://e.example/d.webp"}]}"#), fallbackIndex: 0)!])
    if case let .assistant(turn) = turnEntries.first {
        check(turn.images.count == 1 && turn.body == "Duck:", "transcript turn renders MEDIA as image")
    } else {
        check(false, "assistant turn built")
    }
}

@MainActor
func runTranscriptChecks() {
    let history = json("""
    [
     {"role":"user","content":[{"type":"text","text":"check disk"}],"timestamp":1,"provenance":{"sourceChannel":"discord"},"__openclaw":{"id":"m1"}},
     {"role":"assistant","content":[{"type":"thinking","thinking":"Use df."},{"type":"toolCall","id":"c1","name":"exec","arguments":{"command":"df -h"}}],"__openclaw":{"id":"m2"}},
     {"role":"toolResult","toolCallId":"c1","toolName":"exec","content":[{"type":"text","text":"/ 50%"}],"__openclaw":{"id":"m3"}},
     {"role":"assistant","content":[{"type":"text","text":"Half full."},{"type":"image","artifactId":"a1","mimeType":"image/png","width":320,"height":200}],"__openclaw":{"id":"m4"}},
     {"role":"system","content":"ignored"},
     {"role":"user","content":"thanks","__openclaw":{"id":"m5"}}
    ]
    """)
    let items = history.array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) }
    check(items.count == 6, "parses all messages")
    check(items[0].via == "Discord", "user provenance → via Discord")
    let entries = TranscriptBuilder.build(items)
    check(entries.count == 3, "user / assistant turn / user (got \(entries.count))")
    if case let .assistant(turn) = entries[1] {
        check(turn.thinking == ["Use df."], "thinking folded into turn")
        check(turn.tools.count == 1 && turn.tools[0].result == "/ 50%", "tool call paired with result")
        check(turn.tools[0].arguments?.contains("df -h") == true, "tool arguments rendered")
        check(turn.body == "Half full.", "reply text")
        check(turn.images.first?.artifactId == "a1" && turn.images.first?.aspectRatio == 1.6, "image block")
    } else {
        check(false, "second entry is an assistant turn")
    }
    let backToBack = json("""
    [
     {"role":"assistant","content":[{"type":"text","text":"Checking."},{"type":"toolCall","id":"b1","name":"exec","arguments":{}}],"timestamp":1000,"__openclaw":{"id":"b1","runId":"r1"}},
     {"role":"toolResult","toolCallId":"b1","content":"ok","__openclaw":{"id":"b2","runId":"r1"}},
     {"role":"assistant","content":[{"type":"text","text":"Done."},{"type":"text","text":"More."}],"timestamp":2000,"__openclaw":{"id":"b3","runId":"r1"}},
     {"role":"assistant","content":[{"type":"text","text":"Daily digest"}],"timestamp":3000,"__openclaw":{"id":"b4","runId":"r2"}}
    ]
    """)
    let backToBackEntries = TranscriptBuilder.build(backToBack.array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) })
    check(backToBackEntries.count == 2, "a reply from another run gets its own row (got \(backToBackEntries.count))")
    if case let .assistant(turn)? = backToBackEntries.first {
        check(turn.text == ["Checking.", "Done.\n\nMore."], "each assistant message stays a separate text entry")
        check(turn.textTimestamps == [Date(timeIntervalSince1970: 1000), Date(timeIntervalSince1970: 2000)], "each message keeps its own timestamp")
        check(turn.body == "Checking.\n\nDone.\n\nMore.", "reply body still joins every message")
    } else {
        check(false, "back-to-back turn built")
    }
    check(ChatItem(json(#"{"role":"assistant","content":[],"errorMessage":"boom"}"#), fallbackIndex: 0)?.isError == true, "error-only assistant message")
    let spawn = ToolActivity(id: "t", name: "sessions_spawn", arguments: #"{"label":"Find rentals","task":"x"}"#, result: nil, isError: false, isRunning: false)
    check(spawn.spawnLabel == "Find rentals" && spawn.summary == nil, "spawn label derived once")
    var sent = ToolActivity(id: "t2", name: "sessions_send", arguments: #"{"command":"ls"}"#, result: nil, isError: false, isRunning: false)
    sent.result = #"{"sessionKey":"agent:main:subagent:1f2e-9a"}"#
    check(sent.summary == "ls" && sent.spawnedSessionKey == "agent:main:subagent:1f2e-9a", "subagent key found in tool result")
    check(ChatItem(json(#"{"role":"user","content":"hi","__openclaw":{"id":"abc"}}"#), fallbackIndex: 7)?.id == "abc", "row id is stable across pages")
    check(ChatItem(json(#"{"role":"assistant","content":"long\n...(truncated)...","__openclaw":{"id":"t1","truncated":true}}"#), fallbackIndex: 0)?.isCapped == true, "capped assistant message flagged")
    check(ChatItem(json(#"{"role":"assistant","content":"literal ...(truncated)...","__openclaw":{"id":"t2"}}"#), fallbackIndex: 0)?.isCapped == false, "sentinel text alone isn't a cap")
    check(ChatItem(json(#"{"role":"toolResult","content":"x","__openclaw":{"id":"t3","truncated":true}}"#), fallbackIndex: 0)?.isCapped == false, "only assistant/pending messages are recoverable")
    let uploaded = ChatItem(json(#"{"role":"user","content":[{"type":"text","text":"look"}],"__openclaw":{"id":"u1","media":[{"path":"media://inbound/abc.png","contentType":"image/png","fileName":"Pasted Image.png","origin":"paste"},{"path":"media://inbound/doc.pdf","contentType":"application/pdf","fileName":"doc.pdf"}]}}"#), fallbackIndex: 0)
    if case let .image(ref)? = uploaded?.blocks.dropFirst().first, case let .file(file)? = uploaded?.blocks.last {
        check(uploaded?.blocks.count == 3 && ref.url == "media://inbound/abc.png" && ref.alt == "Pasted Image.png" && file.name == "doc.pdf" && file.url == "media://inbound/doc.pdf", "uploaded media facts show on user messages")
    } else {
        check(false, "uploaded media facts show on user messages")
    }
    check(ChatItem(json(#"{"role":"user","content":[],"__openclaw":{"id":"u2","media":[{"path":"media://inbound/x.jpg","kind":"image"}]}}"#), fallbackIndex: 0)?.blocks.count == 1, "image-only upload keeps its row")
    let stripped = json(##"""
    [
     {"role":"assistant","content":[{"type":"thinking","thinking":""},{"type":"toolCall","id":"v1","name":"view_image","arguments":{"url":"https://x/y.jpg"}}],"__openclaw":{"id":"s1"}},
     {"role":"toolResult","toolCallId":"v1","toolName":"view_image","content":[{"type":"text","text":"Loaded 1 image"},{"type":"image","mimeType":"image/jpeg","bytes":226618,"omitted":true}],"__openclaw":{"id":"s2"}}
    ]
    """##)
    if case let .assistant(turn) = TranscriptBuilder.build(stripped.array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) }).first {
        check(turn.images.isEmpty, "omitted tool-result images don't leave blank slots")
        check(turn.thinking.isEmpty, "empty thinking blocks are hidden")
    } else {
        check(false, "omitted-image turn built")
    }
}

@MainActor
func runModelChecks() {
    check(ModelRef.qualified("claude-opus-4-8", provider: "anthropic") == "anthropic/claude-opus-4-8", "model ref qualified with provider")
    check(ModelRef.qualified("anthropic/claude-opus-4-8", provider: "anthropic") == "anthropic/claude-opus-4-8", "already-qualified ref kept")
    check(ModelRef.shortName("openrouter/meta/llama-4") == "llama-4" && ModelRef.shortName("gpt-5") == "gpt-5", "short model name")
    let choice = ModelChoice(json(#"{"id":"gpt-5.6-sol","name":"GPT-5.6 Sol","provider":"openai","available":false}"#))
    check(choice?.ref == "openai/gpt-5.6-sol" && choice?.isAvailable == false && choice?.displayName == "GPT-5.6 Sol", "models.list entry")
    let modelRow = SessionRow(json(#"{"key":"k","model":"claude-sonnet-5","modelProvider":"anthropic","modelOverrideSource":"user"}"#))!
    check(modelRow.modelRef == "anthropic/claude-sonnet-5" && modelRow.modelOverrideSource == "user", "session row model ref")
    let attributed = json(#"""
    [
     {"role":"user","content":"hi","__openclaw":{"id":"x1"}},
     {"role":"assistant","provider":"anthropic","model":"claude-opus-4-8","content":[{"type":"toolCall","id":"t1","name":"exec","arguments":{}}],"__openclaw":{"id":"x2"}},
     {"role":"toolResult","toolCallId":"t1","content":"ok","__openclaw":{"id":"x3"}},
     {"role":"assistant","provider":"openai","model":"gpt-5.6-sol","content":"done","__openclaw":{"id":"x4"}},
     {"role":"user","content":"again","__openclaw":{"id":"x5"}},
     {"role":"assistant","model":"gateway-injected","content":"notice","__openclaw":{"id":"x6"}}
    ]
    """#).array!.enumerated().compactMap { ChatItem($1, fallbackIndex: $0) }
    check(attributed[1].modelRef == "anthropic/claude-opus-4-8" && attributed[0].model == nil, "assistant messages carry their model")
    let attributedTurns = TranscriptBuilder.build(attributed).compactMap { entry -> AssistantTurn? in
        if case let .assistant(turn) = entry { return turn }
        return nil
    }
    check(attributedTurns.first?.modelRef == "openai/gpt-5.6-sol" && attributedTurns.first?.modelName == "gpt-5.6-sol", "turn takes its latest model")
    check(attributedTurns.first?.textModelNames.compactMap(\.self).last == "gpt-5.6-sol", "each message keeps its own model")
    check(attributedTurns.count == 2 && attributedTurns.last?.model == nil, "gateway-injected messages have no model")
    let roundTrip = try? JSONDecoder().decode(ChatItem.self, from: JSONEncoder().encode(attributed[1]))
    check(roundTrip?.modelRef == "anthropic/claude-opus-4-8", "model survives the transcript cache")
}
