# Pincer — App Store Release Audit

Audit snapshot: October 7, 2026.


## Current implementation tracker

Updated October 8, 2026. “Implemented” means changed in this branch; it does not mean merged, deployed, uploaded or approved.

| Item | Status | Evidence / remaining work |
| --- | --- | --- |
| Free pricing decision | Done in App Store Connect | Owner confirmed completely free; both saved current price schedules show $0.00. |
| Demo-only review access | Done in App Store Connect | Sign-in required is off on both records; demo-only review notes saved. No credentials/backend. |
| Privacy manifests | Implemented; validating | XcodeGen and compiled Kit checks pass; unsigned Mac and iOS Simulator app/extension/package bundle manifests verified. Signed archive still needed. |
| Privacy/support pages | Drafted locally | Privacy/support pages pass the 56-page website build; public deployment still needed. |
| In-app privacy/support links | Implemented; validating | Welcome and Settings; 83 targeted Swift tests, localization sync, Mac and iOS Simulator builds pass. |
| AI-sharing consent | Needed | Implement explicit destination disclosure and consent across applicable send paths. |
| App Privacy questionnaires | Needed | Reconcile user-controlled gateway/provider data paths, then publish both questionnaires. |
| Version 1.0 | Implemented locally | `project.yml`; matching TestFlight uploads and build selection still needed. |
| Release CI gate | Implemented; unit tests pass | TestFlight now requires successful Tests on the exact main commit before signing/upload. Workflow CI still needed. |
| Test reliability PR #938 | External work in progress | Recheck merge and complete CI on release candidate. |
| TestFlight crash triage | Needed | Build 48.1 crash reports require symbolication and candidate retest. |
| Listing copy | Drafted locally | `APP_STORE_SUBMISSION.md`; ASC fields still to populate. |
| Screenshots | Inventory audited; captures/upload needed | 29 full-size iPhone website images at 1206×2622; no iPad assets. Existing Mac images use website dimensions. Listing slots were empty. |
| Review contact | Done in App Store Connect | Owner-provided contact saved on both records; private details excluded from repository. |
| Territories | iOS done; Mac confirmation pending | Owner chose all countries. iOS shows 175 countries available on release. Mac final confirmation was interrupted; session now requires sign-in. |
| Manual release | Done in App Store Connect | Manual release after approval saved on both listings. |
| Extra-platform availability | Done in App Store Connect | iOS-on-Apple-Silicon-Mac and Vision Pro disabled. Dedicated native Mac listing retained. |
| EU trader status | Owner confirmed noncommercial | Open-source personal project with no intent to monetize; retain existing non-trader declaration. |
| Physical-device and accessibility pass | Needed | #59, #933 and essential #58 flows. |
| Final signed archives / submission | Needed | Build from validated merged commit, inspect, upload, install and submit. |

## Release readiness: not ready for submission

Both Pincer Chat (iOS/iPadOS) and Pincer Chat for Mac are at 1.0 “Prepare for Submission.” Signed uploads already work, but both records lack required listing and review information. Uploaded binaries are still version 0.1.0. Privacy implementation and final-device validation need work before selecting a release candidate.

## Original audit scope and evidence

Read-only audit of the local clean main checkout e092b25, fetched GitHub main 7aee00b, release workflows, source configuration, website, live App Store Connect records, and TestFlight feedback. The local checkout trails remote main. No code changes, submission, pricing changes, or policy publication were performed. Full test suites, production-archive validation and physical-device certification were not rerun in this audit. “Ready to Submit” in TestFlight means the beta build processed; it is not App Store approval.

## Confirmed release blockers


### 1. Add required-reason API privacy manifests

Status: implemented locally. PrivacyInfo.xcprivacy now ships in the app, extension and relevant package resources; unsigned Mac/iOS Simulator bundles pass inspection. Signed archive privacy reports and Apple validation are still needed. The original audit found no manifests. The project uses UserDefaults, systemUptime, and file modification timestamps. Declare only the approved reasons matching actual behavior; include manifests in every consuming app/extension bundle and SwiftPM resources where needed. Own preferences and shared App Group preferences have different permitted reasons. Generate an archive privacy report, inspect final bundle contents, and pass upload validation. Privacy manifests do not replace App Store privacy answers.
Evidence: project.yml; Sources/PincerKit persistence and TranscriptCache+Segments.swift; Sources/PincerUI transcript timing. Apple required-reason API documentation.

### 2. Publish a complete privacy policy and expose it in the app

Status: policy/support pages and in-app links implemented locally; website and platform builds pass. Deployment and both App Store privacy-policy URLs are still needed. The public security reference loads, but /privacy/ returns 404 and no in-app privacy-policy link was found. Expand the existing security material or add a dedicated stable policy describing the developer, contact, data paths, recipients, purposes, retention, deletion and user choices. Link it from Settings/onboarding and both App Store records.
Cover user-selected gateways and configured model providers; attachments and optional location; Apple Speech network fallback; gateway TTS and direct ElevenLabs voice/preview requests; external image downloads; local transcripts, drafts, outbox and credentials; optional encrypted push relay. Distinguish developer-operated services from user-operated systems accurately.

### 3. Add explicit third-party AI data-sharing consent

Status: confirmed implementation gap in inspected onboarding/send paths. Gateway setup accepts a URL/token, but no explicit AI-sharing consent was found. Before sending personal data to AI services, explain the destination and relevant provider use, and obtain explicit permission. Apply the decision consistently to composer, Share extension, shortcuts/intents, queued messages and other send paths, including applicable TTS. Revisit consent when the destination materially changes. OS microphone/location permission alone does not cover this.
Evidence: Apple review guideline 5.1.2(i); current gateway onboarding and send entry points.

### 4. Complete and publish App Privacy answers for both apps

Status: confirmed empty questionnaires; both pages show “Get Started.” Inventory what leaves each app, who can read it, how long it is retained, purpose, linkage to identity and tracking. Resolve how user-managed gateways/providers fit the actual implementation. Do not choose “Data Not Collected” solely because the developer hosts no backend. Keep answers, policy, manifests, permission prompts and behavior consistent. No advertising/tracking SDK was found in the inspected package setup, but final dependencies and archives still need verification.

### 5. Align App Store version and binary version

Status: project.yml now uses 1.0 to match both App Store version records. Uploaded TestFlight trains still use 0.1.0. Choose the launch version, update the release configuration consistently, use increasing build numbers, archive and upload both platforms, then attach matching processed binaries to the correct records. Neither version currently has a build attached.

### 6. Restore trustworthy test completion before freezing a candidate

Status: confirmed open reliability issue. PR #938 fixes a Tab-navigation test that can end swift test early with a successful exit and adds a test-completion guard. At the audit snapshot it is open with Swift/iOS checks pending. Require the fix to merge with green checks, then validate the exact release commit with complete test-run summaries. Existing green runs affected by premature completion are insufficient evidence. This branch adds a TestFlight gate requiring a completed successful Tests push run on main for the exact uploaded commit. Five gate regressions pass locally; CI and merging remain needed.

### 7. Triage TestFlight crashes and verify fixes

Status: confirmed crash evidence; resolution unverified. iOS build 48.1 shows six crashes and two feedback entries. The feedback includes “Test,” which does not establish that the crashes were harmless or resolved. Obtain and symbolicate crash reports, tie root causes to fixes, and retest reproduction paths on the final candidate. iOS 50.1 has processed but no usage evidence at this snapshot; macOS 49.1 has processed and the latest Mac upload is still running.

## Complete the two App Store listings


### 8. Required metadata and product presentation

Status: confirmed missing on both platforms. Fill description, keywords, support URL and copyright. Choose primary category, answer content-rights questions and complete age-rating questionnaires based on actual unrestricted AI/chat behavior. Names are already set. Subtitle, promotional text, marketing URL and app-preview videos are optional; useful copy can wait until required fields are complete.
The support URL should give users a working contact method and help for setup/troubleshooting. Clearly state that users need an OpenClaw Gateway for live operation and explain any external service costs. Verify icons, display names and screenshots match the release binary. Keep public feature claims within tested behavior.

### 9. Supply iPhone, iPad and Mac screenshots

October 8 inventory: 29 full-size iPhone website captures at 1206×2622, plus cropped variants; no iPad screenshots found. Existing Mac images have varied website dimensions and need release-specific captures. Target five demo scenes per platform: conversation, rich content/tool results, agents/sidebar, search/bookmarks and approvals. Capture a 13-inch iPad at 2064×2752 (or landscape 2752×2064); verify each final file and upload before marking complete. Screenshots must reflect the final candidate. No reviewer credentials or live gateway data are needed.

Status: confirmed zero screenshots in all inspected device families. Capture the final UI with realistic synthetic/demo data, correct privacy-safe content and Apple’s current accepted dimensions. iPad screenshots are required because the app supports iPad. Use App Store Connect Media Manager and the current screenshot specification to resolve required slots; capture Mac images separately. App-preview videos are optional. Do not use live private conversations or credentials.

### 10. Provide a complete App Review access package

Status: demo review route confirmed by the owner. **No reviewer credentials or developer-provided backend are required.** Reviewers use **Try the Demo** on the first welcome screen. “Sign-in required” is now No on both App Store records, username/password are empty, and demo review notes are saved. Reviewer contact name, phone and email are still required for Apple to contact the developer.
The prepared steps are in [APP_STORE_SUBMISSION.md](APP_STORE_SUBMISSION.md). They distinguish local simulation from optional user-configured live services, and explain the operator-client architecture, permissions and sandbox. Validate those demo steps on the final TestFlight builds. Do not provision a reviewer gateway.

### 11. Set pricing and territorial availability

Status: free price schedules are saved and verified on both platforms. The owner confirmed both apps are completely free. Countries/regions still need a decision. Business shows the Paid Apps Agreement and Free Apps Agreement as Active; banking and tax entries also show Active. These are not currently identified blockers. Recheck for new agreements at submission time and confirm program membership stays current. Confirm export-compliance answers for the actual binary: the project currently declares no non-exempt encryption and uses Apple CryptoKit for push decryption; that declaration should be reviewed against all release dependencies.

## Launch decisions to settle


### 12. Confirm the supported distribution matrix

There are separate iOS and macOS app records and bundle identifiers. Decide whether separate listings are intentional and whether free distribution or separate paid purchases is intended. On the iOS record, “iPhone and iPad Apps on Apple Silicon Mac” and Apple Vision Pro availability are currently enabled. Keep them only if you intend and test those experiences; the dedicated Mac app otherwise creates a second Mac offering. Native macOS minimum is 15; iOS/iPadOS minimum is 18.

### 13. Confirm legal/commercial declarations and release timing

Both app records identify the developer as a non-trader under the EU Digital Services Act. Confirm that this matches the actual planned commercial activity and territories; complete trader verification if applicable. Apple’s standard EULA is already selected, so a custom EULA is not inherently required. Confirm rights for app assets, third-party content and upstream marks. Choose manual, automatic or scheduled release; both records currently default to automatic release after approval. Manual release can coordinate the separate iOS and Mac launches.

## Release-candidate validation still needed


### 14. Run the open physical-device and real-gateway checklist

Evidence: issue #59 remains the canonical real-device/real-gateway checklist. Validate fresh install and returning user migration; demo entry; gateway onboarding and unreachable/invalid credentials; permissions allowed and denied; history for multiple agents; reconnect after background/foreground and network changes; cellular/Tailscale connectivity; notification authorization, encrypted push and deep-link routing; refresh catch-up; long conversations and attachment handling.
On a real iPhone and iPad, check keyboard/composer sizing, rotation, large text, image/photo preparation, scrolling while streaming, share extension, intents/shortcuts, dictation and audio interruptions. On a real Mac, check sandbox file import/export, clipboard, shortcuts, menus, Settings, VoiceOver and stable credential access. Confirm no prompt loop after production-signed updates. Verify IPv6-compatible networking and background modes only perform their intended work.

### 15. Close the recent chat-switching and accessibility verification gaps

Issue #933 lists manual checks still needed after host reuse: instant chat switching without stale content/chrome animation, Find/Export targeting the active conversation, search/deep-link jumps, Read Aloud layout, draft/Handoff isolation, isolation when gateways reuse session keys, and VoiceOver behavior. Issue #58 tracks accessibility gaps, with targeted follow-ups including rotors and larger Dynamic Type. Prioritize broken navigation or inaccessible essential flows; not every cosmetic backlog item needs to block launch.

### 16. Validate the actual archived binaries

Run the repository’s relevant unit tests, PincerChecks, demo/live modes against fresh mocks, perf budgets and iOS simulator suite on the exact release commit. Inspect both distribution archives for icons, version/build, privacy manifests, entitlements, extension identifiers, production APNs environment, resources, permissions and embedded signing. Verify exported archives upload and process without unresolved warnings; install those same builds through TestFlight and perform the device pass. Debug builds or upload success alone do not certify production behavior.

## First implementation batch — validation evidence

- Source and omission regressions: `python3 scripts/test_release_privacy.py` — 5 passed. The source checker fails against the original checkout because its app manifest is missing.
- Release gate regressions: `python3 scripts/test_release_ci.py` — 5 passed, including wrong SHA, PR-only, pending, failed, cancelled and stale successful runs.
- XcodeGen: all five app/extension targets contain exactly one root manifest in Copy Bundle Resources.
- Targeted Swift tests: 83 passed across five suites (privacy resources and first-run flows).
- Settings window height: all 6 passed on recheck. One initial display-change expectation failed; the unchanged-source control and restored-change rerun both passed. This transient is recorded rather than treated as a diagnosed fix.
- PincerChecks offline (`--skip-intent-checks`): 2,772 passed, 0 failed, including both new release harnesses.
- PincerChecks demo (`--demo-core`): 702 passed, 0 failed.
- `scripts/sync-strings.sh`: completed macOS/iOS extraction and synchronized the catalog.
- Unsigned macOS app and iOS Simulator app builds: passed. Actual root app, Share, notification and package resource manifests inspected successfully.
- Website: 56 pages built, including privacy/support; screenshot-caption and reduced-motion checks passed.
- App Store Connect: both no-sign-in settings and demo notes saved; both current price schedules verified at $0.00. App availability is still unset. Nothing submitted for review.

## Ready-to-submit exit criteria

Privacy implementation and published answers are consistent; the version mismatch is resolved; a candidate built from a fully validated commit is attached to each record; crash reproduction paths and essential real-device flows pass; required screenshots and listing fields are complete; the built-in demo works without credentials or a gateway; price, territories, declarations and release timing are chosen; submission validation presents no unresolved required fields.

## Already in place

Separate App Store records and bundle IDs; native iPhone/iPad/Mac targets; built-in demo; distribution signing and five-target profiles; archive/export/upload automation; TestFlight processing; Mac sandbox and user-facing permission descriptions; extensive automated checks. Current Xcode/SDK configuration is not an identified minimum-SDK blocker. The broader roadmap, Android/Windows support, app-preview videos and new feature expansion are not prerequisites for this launch.

## Sources and operating references

- [iOS submission record](https://appstoreconnect.apple.com/apps/6816199858/distribution/ios/version/inflight)
- [Mac submission record](https://appstoreconnect.apple.com/apps/6816200065/distribution/macos/version/inflight)
- [iOS App Privacy](https://appstoreconnect.apple.com/apps/6816199858/distribution/privacy)
- [Mac App Privacy](https://appstoreconnect.apple.com/apps/6816200065/distribution/privacy)
- [PR #938 — test completion fix](https://github.com/hartra344/pincer/pull/938)
- [Issue #59 — real-device checks](https://github.com/hartra344/pincer/issues/59)
- [Issue #933 — chat-switch manual checks](https://github.com/hartra344/pincer/issues/933)
- [Issue #58 — accessibility](https://github.com/hartra344/pincer/issues/58)
- [Latest TestFlight workflow](https://github.com/hartra344/pincer/actions/runs/37703282005)
- [Public security reference](https://www.pincerchat.dev/reference/security/)
- [Apple review guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple required-reason API documentation](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Apple App Privacy definitions](https://developer.apple.com/app-store/app-privacy-details/)
- [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
- [Apple DSA trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements)
- [Apple upcoming SDK requirements](https://developer.apple.com/news/upcoming-requirements/)

## October 8 continuation

All six PR #947 checks passed on commit 66d18ea. PR #938 remains open; final merged-candidate validation is still required. App Store Connect signed out during continuation and is awaiting owner passkey/security-key authentication. No submission or release occurred.
