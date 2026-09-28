---
title: Local cache
description: What Pincer keeps on your device, how it handles old or damaged cache files, and how to clear it.
---

Pincer keeps a copy of each chat's history on your device, so chats open instantly, scrolling up never waits for the network, and [message search](../search/) works across older history. The cache is only a copy: your gateway always has the real transcript, and anything missing from the cache is fetched again.

## What's cached, and where

Each gateway gets its own folder, with one file per chat:

| Platform | Folder |
|---|---|
| macOS | `~/Library/Caches/Pincer/Transcripts/<gateway>/` (inside the app's sandbox container for the Xcode-built app) |
| iOS and iPadOS | `Library/Caches/Pincer/Transcripts/<gateway>/` in Pincer's app container |

`<gateway>` is the gateway's ID in Pincer, not its name. In that folder:

- **`<chat>.json`**: the chat's transcript, up to the latest 20,000 messages. The file name is a hash of the chat's key, so it doesn't reveal the chat's name.
- **`<chat>.json.meta`**: a small note of whether the history is complete and when the chat was last active, so Pincer can skip chats that haven't changed.
- **`search-index.sqlite`** (plus `-wal` and `-shm`): the [message search](../search/) index, built from the transcripts.
- **`Quarantine/`**: damaged cache files set aside for troubleshooting (see [below](#damaged-cache-files)). Usually absent.

Messages you haven't sent yet aren't part of the cache: the [outbox](../offline-outbox/#where-the-outbox-is-stored) is stored separately, so the system never clears it and **Clear Cache…** leaves it alone.

Files use complete file protection. Removing a gateway deletes its whole folder. Because it's in the system's Caches folder, macOS and iOS may also clear it when storage runs low; Pincer just refetches.

When a session is deleted, rewound, switched to another branch or recovered (from the [Session manager](../sessions/) or anywhere else), Pincer deletes that chat's whole cached transcript, including its tool call details, and an open chat reloads from the gateway.

To turn the cache off, set `PINCER_CACHE_DIR=off`. Nothing is written, and message search is off too (except in the demo, which keeps its index in memory). To use another folder, set it to a path. See [Security & privacy](../../reference/security/#local-cache).

## Updates and old cache files

Every transcript file records the cache format version it was written with. When you open a chat after updating Pincer:

- **Same version:** the cached transcript shows at once, then Pincer fetches only what's new.
- **Older version Pincer can upgrade:** it's converted to the current format in place, once, and shows as usual.
- **Older version Pincer can't upgrade**, or **newer version** (for example after going back to an earlier Pincer build): the file is deleted. The chat shows its usual loading state, then the full history from the gateway, and the cache is written again in the current format.

For example, updating from a build before cache format 6 upgrades every cached chat in place: chats cached before [file diffs](../file-diffs/#chats-cached-by-earlier-versions) arrived keep their history, and their file writes are labelled **Written** instead of guessing **New file**. Nothing is downloaded again, but the search index is rebuilt once.

You don't see an error for any of this. The first launch after an update that changes the format may take a little longer to fill in history while chats reload in the background.

## Damaged cache files

If a cache file is empty, cut short (for example by a crash or a full disk while writing) or otherwise unreadable, Pincer doesn't fail silently or show an empty chat as if it were the real history. It:

1. moves the file into the gateway's `Quarantine/` folder, named `<chat>-<time>.json`, and deletes its `.meta` file;
2. loads the chat from the gateway, as if it had never been cached;
3. writes a fresh cache file.

There's no error banner, since nothing is lost. If you're offline, the chat shows the same state as any chat that hasn't loaded yet, and fills in once you reconnect.

Only the 5 most recent quarantined files are kept per gateway; older ones are deleted automatically. They're kept only so a damaged file can be attached to a bug report, and can be deleted at any time. **Clear Cache** removes them too.

Pincer records each discarded or quarantined file in the system log under subsystem `chat.pincer`, category `TranscriptCache`, without any message content. On macOS you can watch it with:

```sh
log stream --predicate 'subsystem == "chat.pincer" AND category == "TranscriptCache"'
```

## Clearing the cache

To free the space or start fresh, open **Settings** (**General** tab on macOS) and find **Storage**:

- **Cached transcripts** shows how much space the cache uses, for all gateways (or **Off** when `PINCER_CACHE_DIR=off`).
- **Clear Cache…** asks **Clear cached transcripts?** and, when you confirm with **Clear Cache**, deletes every gateway's cached transcripts, search indexes and quarantined files.

Nothing on your gateways is deleted. Chats you have open stay on screen and are saved again right away, and you can search them again as soon as Clear Cache finishes. While you're connected, Pincer downloads the other chats again in the background, and message search fills back in as they're cached, without a relaunch.

## Search index

The search index is derived from the cache, so you never need to manage it yourself:

- After an update that changes the index or the cache format, it's rebuilt from the cached transcripts in the background. Search shows **Indexing chats… n of m** until it's done.
- A damaged index is deleted and rebuilt the same way.
- Chats whose cache file was discarded or quarantined are added back once they reload from the gateway.
- **Clear Cache** deletes the index; it rebuilds as chats are cached again.

See [Search messages](../search/).
