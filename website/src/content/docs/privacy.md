---
title: Privacy Policy
description: What Pincer stores, where information goes, and the choices you control.
---

Effective date: October 7, 2026.

Pincer is a free, open-source app for Mac, iPhone and iPad, maintained by
[hartra344](https://github.com/hartra344/pincer). **There is no developer-provided
backend. Your conversations do not pass through the Pincer developer.** Pincer
does not require a Pincer account and has no advertising, tracking or developer
analytics service.

## Your gateway and AI providers

For live use, you connect Pincer to an OpenClaw Gateway that you choose and control.
Messages, attachments and actions you submit go to that gateway. If you enable
location sharing, location context also goes to it. The gateway may forward
information to the AI models, tools, channels and other services you configure.
Those services may retain information according to their own settings and
policies. Pincer does not select, operate or control them on your behalf.

Review the gateway's configuration and each provider's privacy policy before
sending personal or confidential information. Use a local model if you want model
processing to stay on your own systems. The Pincer developer cannot retrieve or
delete information held by your gateway or its providers.

The built-in **Try the Demo** experience uses a simulation on your device. No
account, credentials, gateway or AI subscription is needed to explore it. Demo
messages are processed locally; opening external links and using optional system
features still follows the behavior described below.

## Information stored on your device

Pincer stores gateway connection settings and preferences locally. Gateway secrets,
device identity keys and push decryption keys are kept in the Apple Keychain.
Its app and extensions share only the App Group and Keychain access group needed
to provide sharing, notifications and Shortcuts.

Cached transcripts and a local message-search index let conversations open and
search quickly. Unsent drafts, queued messages and queued attachments can survive
restarts. Bookmarks, navigation history and optional Spotlight entries also
remain on your device. Some preferences, including chat colors and bookmarks,
can sync through your own gateway. They do not sync through a Pincer service.

Local information remains until you clear it, remove its gateway, or the relevant
cache eviction or system storage cleanup removes it. In Settings, **Clear Cache…**
removes cached transcripts and their search indexes; it does not delete gateway
history. **Clear Outbox…** removes queued messages and their attachments. Removing
a gateway clears its local cached history, drafts, outbox and saved connection
credentials. Discard drafts you no longer want to retain. Data already sent to a
gateway must be managed on that gateway and, where applicable, with its providers.

## Optional features and other recipients

- **Dictation:** Apple Speech converts audio to text. On-device recognition is used
  when available. Unless you enable the on-device-only setting, recognition can
  use Apple's servers when needed. You control microphone and speech permissions
  in system settings. Dictation does not send a message until you choose to send.
- **Read Aloud and voice:** device speech uses Apple's speech facilities. Gateway
  speech sends text to your gateway and its configured speech provider. If you
  configure ElevenLabs voice setup, Pincer can contact ElevenLabs directly to
  retrieve voices and play previews using the key you provide.
- **Web images:** the option to load images linked by agents fetches those images
  directly from their websites. Those sites see ordinary connection information,
  including your IP address. Pincer sends no gateway credentials or cookies with
  those requests. Turn the option off in Settings to prevent these image loads.
- **Location:** only enabled location-sharing features provide location context
  to your gateway. You can disable sharing in Pincer or revoke OS permission.
- **Notifications:** while the app is open, notifications may include previews.
  Optional background push uses a relay you configure and Apple's APNs service.
  The relay routes encrypted payloads; gateway content is encrypted to device
  keys. Connection and delivery metadata still reaches the relevant network
  services. Control previews and permission in system notification settings.
- **Sharing, Shortcuts and Siri:** content you submit is sent to the selected
  gateway. Shortcuts or Siri can also receive prompts and replies. Review saved
  shortcuts and their destinations before running them.
- **Handoff and Spotlight:** Handoff can share gateway/chat navigation information
  with your own Apple devices. Spotlight indexing is optional; indexing message
  content has its own setting. These features use Apple's system services.
- **Help and external links:** opening a website sends an ordinary browser request
  to that website. The documentation host and any linked site may receive IP
  addresses and request metadata under their own policies.

Apple may provide developers with App Store/TestFlight diagnostics and feedback
under your Apple sharing settings. If you submit support information or crash
feedback, that material is used to investigate the reported problem. Do not send
tokens, credentials, private conversations or precise locations in public issues.

## Your choices and contact

You can use the demo, choose your own gateway and providers, disable optional
features, clear local data, revoke system permissions, and disconnect or remove a
gateway. There is no Pincer account to delete. For remote-data deletion, contact
the operator of the gateway or service holding that information.

For questions about this policy or Pincer, use the contact routes on
[Help & Support](../support/). This policy will be updated when data handling
changes. The effective date above identifies the current version.
