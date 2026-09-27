---
title: Subagents & run timeline
description: See every helper run an agent started as a live tree, and follow each run's thinking, tool calls and errors on a timeline.
---

When an agent delegates work, it spawns **helper (subagent) runs**, and those can spawn helpers of their own. Helpers stay out of the sidebar by default, so the **Runs** panel is where you see them: a tree of everything the chat started, with live status, and a timeline of what each run did.

## Opening the Runs panel

Open a chat, then:

- click **Runs** in the chat toolbar, or choose **Show Runs** from the chat's ⋯ menu;
- on macOS, press **⌥⌘R**.

The button only appears when the chat has started a helper run or has run activity of its own. It shows a count, and a spinner while any helper is still working.

- **Mac:** the panel opens as an inspector on the right side of the window. You can resize it, and it stays open when you switch chats.
- **iPad:** it's an inspector in regular width and a sheet in compact width.
- **iPhone:** it's a sheet. Drag it to half or full height.

At the top of the panel, switch between **Tree** and **Timeline**.

## Subagent tree

The tree starts at the current chat. Below it are the helpers it spawned, then their helpers, however deep the tree goes. The tree follows each session's `spawnedBy` / `parentSessionKey`. Children are sorted oldest first, and you can collapse any branch.

Each row shows:

- a **status** symbol and label;
- the run's **title** (its label, or the agent's name if it has none) and its **agent**, in the agent's color;
- the **duration**;
- the **last activity**, like "2m ago". While a helper is running, a caption shows what it's doing right now, for example "Running `web.search`…".

| Status | Symbol | Meaning |
| --- | --- | --- |
| **Running** | spinner | The run is still going. Its duration counts up live. |
| **Done** | green ✓ | The run finished normally. |
| **Error** | red ✕ | The run failed, for example a tool or model error. |
| **Aborted** | gray ■ | The run was stopped before it finished. |
| **Unknown** | gray ? | Pincer is disconnected, so it can't tell whether the run is still going. |

Durations show as `m:ss`, `h:mm:ss` for an hour or longer, and `<1s` for very short runs. **Last activity** is the most recent thing the run streamed: thinking, a reply or a tool call starting or finishing. For a run Pincer hasn't seen stream, it falls back to the session's last update.

### Opening a helper

Click or tap a row to open that helper's chat. On the Mac you can also select a row and press Return. This is the same thing the **Open run** button on a [tool card](../transcript/#tool-cards) does. The helper opens even when the sidebar is set to hide helpers, and the setting doesn't change.

On the Mac, the panel stays open and moves to the helper you opened. Use **↑ Parent** at the top of the panel to go back up the tree.

Control-click or touch and hold a row for **Open**, **Open in New Window** (macOS) and **Copy Session Key**.

## Run timeline

The timeline has one lane per run: the chat's own run, then each helper. All lanes share a time axis running left to right, so you can see which helpers ran in parallel and which one held things up. Each lane is labeled with its run's name and status, and shows its total duration on the right.

A lane is made of:

- **Thinking**: light purple segments.
- **Tool calls**: blue bars labeled with the tool's name. A tool call that failed turns red.
- **Replies**: gray segments where the agent was writing text.
- **Errors**: a red ◆ marker where the run hit an error.
- **Abort**: a gray ■ marker where the run was stopped.

While a run is live, its lane grows and ends in a pulsing "now" edge.

Hover over a segment on the Mac, or tap it on iPhone and iPad, to see its name, when it started, how long it took and, for errors, the first line of the message. Tap a tool call in a helper's lane to open that helper.

The timeline is built from the activity the gateway streams while Pincer is connected. A run that finished before Pincer connected shows **Activity not captured**, with its total duration taken from the session when the gateway provides it.

## When there's nothing to show

- A chat that hasn't delegated anything shows **No helper runs yet**. When the agent spawns a helper, it appears right away.
- If you lose the connection to the gateway, the panel keeps the last state it saw and marks running helpers **Unknown** until you're back online.

## Accessibility

Every status comes with a label as well as a color. VoiceOver reads each tree row as its title, agent, status, duration and last activity, and each timeline segment is its own element.

## Try it in the demo

The [demo gateway](../../getting-started/try-the-demo/) includes a research chat that has already spawned three helpers:

- one finished and started a helper of its own, so the tree is two levels deep;
- one is still running and keeps making tool calls, so you can watch its timer and lane grow;
- one failed on a tool error.

There's also a stopped run, so every status appears, and the chat's own lane has thinking, several tool calls and a spawn for each helper.

## Related

- [Organizing chats](../organizing-chats/#helper-subagent-runs): list helpers in the sidebar instead.
- [Transcript](../transcript/#tool-cards): the **Open run** button on tool cards.
