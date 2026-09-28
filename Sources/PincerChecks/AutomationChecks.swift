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
func runAutomationChecks() {
    do {
        let job = CronJob(json(#"""
        {"id":"j1","agentId":"main","name":"Sync calendar","enabled":true,"configRevision":"rev1",
         "schedule":{"kind":"cron","expr":"0 */6 * * *","tz":"America/New_York"},"sessionTarget":"isolated","wakeMode":"now",
         "payload":{"kind":"agentTurn","message":"Sync it.","model":"gpt-5"},
         "delivery":{"mode":"announce","channel":"telegram","to":"@ops"},
         "state":{"nextRunAtMs":1790000000000,"lastRunAtMs":1789990000000,"lastRunStatus":"error","lastError":"invalid_grant","consecutiveErrors":2}}
        """#))!
        check(job.health == .failing && job.consecutiveErrors == 2 && job.lastError == "invalid_grant", "job state from `state`")
        check(job.nextRunAt == Date(timeIntervalSince1970: 1_790_000_000), "next run date")
        check(job.schedule.summary == "0 */6 * * * (America/New_York)" && job.deliveryTarget == "telegram @ops", "schedule and delivery")
        check(job.chatKey(defaultAgentId: "x") == "agent:main:cron:j1", "automation chat key")
        check(CronSchedule(json(#"{"kind":"every","everyMs":900000}"#)).summary == "Every 15 minutes"
              && CronSchedule(json(#"{"kind":"every","everyMs":3600000}"#)).summary == "Every hour", "interval summaries")
        check(!CronSchedule(json(#"{"kind":"on-exit","command":"make"}"#)).isEditable, "event schedules aren't editable")
        let legacy = CronJob(json(#"{"id":"j2","name":"Old","enabled":false,"schedule":{"kind":"every","everyMs":60000},"lastStatus":"ok","nextRunAtMs":1}"#))!
        check(legacy.health == .paused && legacy.lastStatus == .ok && legacy.nextRunAt != nil, "top-level state fields (older gateways)")
        let running = CronJob(json(#"{"id":"j3","name":"R","enabled":true,"schedule":{"kind":"every","everyMs":60000},"state":{"runningAtMs":5}}"#))!
        check(running.health == .running, "running job")

        let run = CronRun(json(#"{"ts":2000,"runAtMs":1000,"jobId":"j1","action":"finished","status":"ok","summary":"Done","sessionKey":"agent:main:cron:j1:run:abc","durationMs":900}"#))!
        check(run.id == "j1@2000" && run.startedAt == Date(timeIntervalSince1970: 1) && run.sessionKey == "agent:main:cron:j1:run:abc",
              "run log entry links to its chat")
        check(CronRun(json(#"{"jobId":"j1"}"#)) == nil, "run entries need a timestamp")

        var draft = CronJobDraft(job: job, defaultAgentId: "main")
        check(draft.scheduleKind == .cron && draft.announce && !draft.hasChanges && draft.patch.isEmpty, "draft from job, unchanged")
        draft.name = "Sync team calendar"
        check(draft.patch.keys.sorted() == ["name"], "patch sends only what changed (keeps delivery target, model)")
        draft.message = "Sync the team calendar."
        check(draft.patch["payload"] == ["kind": "agentTurn", "message": "Sync the team calendar."], "payload patch")
        draft.announce = false
        check(draft.patch["delivery"] == ["mode": "none"], "delivery patch when toggled")
        draft.target = .main
        check(draft.patch["sessionTarget"] == "main" && draft.patch["payload"]?["kind"] == "systemEvent", "main chat → systemEvent")
        draft.cronExpr = "0 7 * *"
        check(draft.problem?.contains("five fields") == true, "cron expression validated")

        var every = CronJobDraft(job: CronJob(json(#"{"id":"e","name":"E","enabled":true,"schedule":{"kind":"every","everyMs":7200000,"anchorMs":5},"payload":{"kind":"agentTurn","message":"m"}}"#))!, defaultAgentId: "main")
        check(every.everyAmount == 2 && every.everyUnit == .hours && every.patch.isEmpty, "interval shown in the largest unit; anchor kept")
        every.everyAmount = 3
        check(every.patch["schedule"] == ["kind": "every", "everyMs": 10_800_000], "schedule patch")

        let script = CronJob(json(#"{"id":"s","name":"S","enabled":true,"schedule":{"kind":"stream","command":["tail"]},"payload":{"kind":"script","script":"x"}}"#))!
        var scriptDraft = CronJobDraft(job: script, defaultAgentId: "main")
        scriptDraft.enabled = false
        check(!scriptDraft.isTaskEditable && !scriptDraft.isScheduleEditable && scriptDraft.problem == nil
              && scriptDraft.patch.keys.sorted() == ["enabled"], "script jobs: only name, agent and enabled are edited")

        var new = CronJobDraft(agentId: "main")
        check(new.problem != nil, "new draft needs a name and task")
        new.name = " Nightly check "
        new.message = "Check backups"
        new.everyAmount = 1
        new.everyUnit = .days
        new.announce = true
        check(new.problem == nil && new.addParams["name"] == "Nightly check" && new.addParams["sessionTarget"] == "isolated"
              && new.addParams["schedule"] == ["kind": "every", "everyMs": 86_400_000]
              && new.addParams["delivery"] == ["mode": "announce", "channel": "last"]
              && new.addParams["payload"] == ["kind": "agentTurn", "message": "Check backups"], "cron.add params")
        new.target = .main
        check(new.addParams["payload"] == ["kind": "systemEvent", "text": "Check backups"] && new.addParams["delivery"] == nil,
              "main-chat job has no delivery")
    }
}
