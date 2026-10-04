# Secure form question card spec

> **Historical.** This spec was written while this environment had only Command Line
> Tools (no Xcode.app), so the SwiftUI card couldn't be built here yet. It's since been
> implemented in `SecureFormCardView.swift` following this spec closely; kept here as
> design-rationale documentation, not as a to-do.

Scope: the SwiftUI card for `QuestionPrompt.kind == .secureForm`.

## Placement and visual pattern

- Reuse the existing question-card presentation in `ChatView`: same container, spacing, typography, inline placement in the transcript, and the same **Submit** / **Skip** action row used for `ask_user`.
- Treat every field as sensitive UI: values are masked while typing, copied nowhere else in the transcript, and never mirrored into any tool/result text.

## Content

Top-to-bottom:

1. **Header chip / title:** `Secure sign-in`
2. **Origin line:** show the gateway-verified `origin` exactly as provided, for example `mail.google.com`
3. **Supporting copy:** `Pincer will send these values only to the Gateway's verified sign-in form. The agent never sees them.`
4. **One secure field per entry in `fields`**, in order:
   - `username` → label `Username`
   - `password` → label `Password`
   - `otp` → label `One-time code`
   - `email` → label `Email`
   - unknown role → label from `fieldId`
5. **Expiry notice** when `expiresAt` is near or past, matching the app's existing expiring-question treatment.

## Interaction

- Submit stays disabled until every field is non-empty.
- Skip resolves the prompt with cancel/decline and leaves the page untouched.
- Submitting sends only `{requestId, answers:{fieldId:value}}`.
- After submit/skip/expiry, the card becomes non-editable and shows the terminal state.
- No auto-submit of the browser form in phase 1; the success state should say the fields were filled and the operator should review the page before submitting there.

## Platform/security notes

- Apply the same lock-screen / protected-entry behavior the current secret-answer card uses.
- Do not derive trust decisions from the displayed `origin`; it is for operator display only.
- Never prefill from stored credentials in phase 1.
