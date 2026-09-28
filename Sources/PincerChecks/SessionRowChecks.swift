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

/// "Session rows", then "Discord channels" (its header prints here: they share `row`).
@MainActor
func runSessionRowChecks() {
    let row = SessionRow(json("""
    {"key":"agent:research:dashboard:x","label":"Papers","pinned":true,"unread":true,"channel":"discord",
     "parentSessionKey":"agent:research:main","lastActivityAt":1700000000000,"updatedAt":1600000000000}
    """))!
    check(row.agentId == "research", "agentId from key")
    check(row.title == "Papers" && row.isPinned && row.isUnread, "title/pinned/unread")
    check(row.parentKey == "agent:research:main", "parent key → thread")
    check(row.originLabel == "Discord", "origin label")
    check(row.activityMs == 1_700_000_000_000, "activity uses latest timestamp")
    check(SessionRow(json(#"{"label":"no key"}"#)) == nil, "rows without key rejected")
    do {
        let withPreview = SessionRow(json(#"{"key":"p","lastMessagePreview":"Found 3 rentals"}"#))!
        let bareUpdate = SessionRow(json(#"{"key":"p","pinned":true}"#))!
        let newer = SessionRow(json(#"{"key":"p","lastMessagePreview":"Booked a viewing"}"#))!
        check(bareUpdate.keepingPreview(of: withPreview).preview == "Found 3 rentals", "partial row keeps previous preview")
        check(bareUpdate.keepingPreview(of: withPreview).isPinned, "partial row keeps its own fields")
        check(newer.keepingPreview(of: withPreview).preview == "Booked a viewing", "new preview replaces old")
    }

    print("Discord channels")
    let discord = SessionRow(json(##"{"key":"agent:main:discord:channel:1300000000000000001","displayName":"1100000000000000001 #finances","channel":"discord","chatType":"channel","groupChannel":"#finances","space":"1100000000000000001","origin":{"label":"Home Lab #finances channel id:1300000000000000001","provider":"discord","chatType":"channel"}}"##))!
    check(discord.title == "finances", "guild-id prefix dropped from channel title (got \(discord.title))")
    check(discord.server?.id == "1100000000000000001" && discord.server?.name == "Home Lab", "server id and name from origin")
    let bare = SessionRow(json(#"{"key":"k","displayName":"1100000000000000001 #gyms","label":"1100000000000000001 #gyms","chatType":"channel","channel":"discord","space":"1100000000000000001"}"#))!
    check(bare.title == "gyms", "generated label is cleaned (got \(bare.title))")
    check(bare.server?.name == nil && bare.server?.displayName == "Discord", "unnamed server fallback")
    let renamed = SessionRow(json(##"{"key":"k","label":"Money talk","groupChannel":"#finances","chatType":"channel","channel":"discord","space":"1"}"##))!
    check(renamed.title == "Money talk", "user label wins")
    let thread = SessionRow(json(##"{"key":"agent:main:discord:channel:1:thread:2","derivedTitle":"Todoist read for daily priorities","groupChannel":"#daily-tasks","chatType":"channel","channel":"discord","space":"1"}"##))!
    check(thread.title == "Todoist read for daily priorities" && thread.isChannelThread, "Discord thread keeps its own title")
    let direct = SessionRow(json(#"{"key":"agent:main:discord:direct:9","displayName":"Sam","chatType":"direct","channel":"discord"}"#))!
    check(direct.server == nil && direct.title == "Sam", "DMs are not server channels")
    let sub = SessionRow(json(#"{"key":"agent:main:subagent:1","spawnedBy":"agent:main:cron:job1:run:r1","label":"Uptown rentals","channel":"discord"}"#))!
    check(sub.isSubagent && !discord.isSubagent && !row.isSubagent, "subagent detection by key")
    check(sub.parentCandidates == ["agent:main:cron:job1:run:r1", "agent:main:cron:job1"], "automation run subagents fall back to the automation")
    check(sub.server == nil, "subagents are not server channels")
    let webReply = SessionRow(json(##"{"key":"agent:main:discord:channel:5","kind":"group","chatType":"direct","channel":"discord","groupChannel":"#gyms","space":"1","origin":{"provider":"webchat"}}"##))!
    check(webReply.server?.provider == "discord" && webReply.title == "gyms", "channel stays in server after a web UI reply")
    let slash = SessionRow(json(#"{"key":"agent:main:discord:slash:3","kind":"group","displayName":"1100000000000000001","channel":"discord","space":"1100000000000000001"}"#))!
    check(slash.title == "Slash commands", "slash session titled (got \(slash.title))")
    let newChat = SessionRow(json(#"{"key":"agent:main:dashboard:1","parentSessionKey":"agent:main:main","createdVia":"operator","spawnDepth":0}"#))!
    check(newChat.isStandaloneChat && newChat.parentCandidates.isEmpty, "new chats started from main aren't nested under it")
    let branch = SessionRow(json(#"{"key":"agent:main:dashboard:2","parentSessionKey":"agent:main:main","createdVia":"operator","forkedFromParent":true}"#))!
    check(!branch.isStandaloneChat && branch.parentCandidates == ["agent:main:main"], "forks stay nested")
    let channelChild = SessionRow(json(#"{"key":"agent:main:dashboard:3","parentSessionKey":"agent:main:discord:channel:5","createdVia":"operator"}"#))!
    check(!channelChild.isStandaloneChat, "chats branched from a channel stay nested")
    let automation = SessionRow(json(#"{"key":"agent:main:cron:job1","label":"Automation: Daily budget summary"}"#))!
    check(automation.isAutomation && automation.title == "Daily budget summary", "automation title")
}
