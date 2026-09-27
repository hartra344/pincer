---
title: File edit diffs
description: How Pincer shows the agent's file writes, edits and patches as colour-coded diffs in tool cards.
---

When an agent changes a file, its tool card shows the change as a diff instead of the tool's raw JSON arguments. You see which file changed, how many lines were added and removed, and the lines themselves.

## Which tools get a diff

Pincer recognizes the OpenClaw Gateway's file tools and the usual aliases:

| Tool | Names | What the card shows |
| --- | --- | --- |
| Edit | `edit`, `edit_file`, `multiedit`, `multi_edit`, `notebook_edit` | The replaced text as removed lines and the new text as added lines, with a few lines of context. An edit with several replacements gets one hunk for each. |
| Write | `write`, `write_file`, `create_file` | The whole file as added lines, labelled **New file**. |
| Patch | `apply_patch`, `patch` | Every file in the patch, in order, each with its own header. Files that were added, deleted or moved are labelled. |
| Text editor | `str_replace_editor`, `str_replace_based_edit_tool` | `create` shows as a write, and `str_replace` or `insert` as an edit. |

The file path can come from `path`, `file_path` or `filePath`, and the edit text from `oldText`/`newText` or `old_string`/`new_string`. When the gateway sends back its own diff with the result, Pincer shows that one, since it reflects what was written to disk.

## Reading a diff

- The header shows the file name, with its folder dimmed after it, then the green **+added** and red **−removed** counts. Hover over the name on macOS to see the full path. For a patch that touches more than one file, the header shows how many files changed and the total counts.
- Added lines start with `+` on a green background and removed lines start with `−` on a red one. Unchanged context lines are dimmed, and `⋯` marks lines that were skipped between hunks. The `+` and `−` signs are always there, so you don't need to tell the colours apart.
- The text is monospaced, follows your text size setting (Dynamic Type on iOS and iPadOS), and works in light and dark mode.
- VoiceOver reads the card as, for example, "Edited Config.swift, 3 added, 1 removed".

## Long diffs

A diff with more than 20 lines starts collapsed to its first 12. Choose **Show all N lines** to expand it and **Show less** to fold it again.

Very large changes are cut short so the transcript stays responsive. Pincer diffs up to 600 lines on each side of an edit, 120,000 characters of input and 8 replacements in a single edit, and shows at most 400 lines. Anything past that ends in a **Diff truncated** row that says how many lines were left out.

## Copying

The card's **Copy** button copies the change as a standard unified diff (`--- a/…`, `+++ b/…`, `@@` hunks), which you can paste into a code review or apply with `git apply`. For a new-file write it copies the file's contents.

## While the tool runs, and when it fails

- While the agent is still sending the arguments, the card shows the file name with a spinner, and the diff appears as soon as it can be read.
- If the tool call fails, the card shows the error rather than a diff, because the change may never have been made. The arguments the agent sent are under a disclosure below it.
- If Pincer can't read the arguments as a file change (an unknown shape, or a malformed patch), the card falls back to showing the raw arguments, the same as any other tool.

## Try it in the demo

In the [demo](../../getting-started/try-the-demo/), open **Coder → Main** and set **Thinking Steps → All** in the chat's ⋯ menu. The transcript has an edit, a new-file write and a patch that changes several files, all simulated.
