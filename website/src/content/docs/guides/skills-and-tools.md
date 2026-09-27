---
title: Skills & tools
description: Browse your gateway's skills, install new ones from ClawHub, and see which tools a chat or agent can use before it runs.
---

Skills teach your agents new tricks, and tools are what they call to act. Pincer shows you both: which skills each agent has and why some can't be used yet, and which tools a chat is allowed to call before you send anything.

## Skills

In [Gateway Settings](../gateway-settings/), choose **Skills** in the sidebar. Searching the sidebar for `skills` or `clawhub` also finds it.

Pick an agent at the top. Its skills are grouped by state:

| Section | What it means |
| --- | --- |
| **Ready** | The agent can use the skill. |
| **Needs Setup** | Something the skill needs is missing, such as a program on the gateway host, an environment variable or API key, or a config setting. The row says what. |
| **Blocked** | The gateway's policy, such as a skills allowlist, doesn't let the agent use it. |
| **Disabled** | The skill is turned off. |

Each row shows where the skill comes from (bundled with OpenClaw, the agent's workspace, managed, or ClawHub). Type in the filter field to narrow the list.

### Skill details

Choose a skill for its description, where it's installed, its version when it came from ClawHub, and a checklist of what it needs. Secret values are never shown. An API key or environment variable only says **Set** or **Not set**.

From the details you can:

- turn the skill on or off;
- set its API key;
- run an installer the skill declares, for example to install a missing program on the gateway host. Pincer asks **Run installer "*name*" on the gateway host?** first;
- **Update** a skill that came from ClawHub. If its files were changed on the gateway since it was installed, Pincer asks before replacing them.

### Installing from ClawHub

Choose **Browse ClawHub** and search. Results show each skill's summary, author and version, and whether it's already installed or has an update. Choose one for its details, then **Install**.

Pincer asks **Install "*name*" from ClawHub?** first. The skill is downloaded into the default agent's workspace on the gateway host. Skills can run commands and read files with the agent's permissions, so only install skills you trust.

:::caution[Changes need Full Management]
Anyone connected can browse skills and search ClawHub (`operator.read`). Installing, updating, turning skills on or off and setting API keys need `operator.admin`. Set **Access** to **Full Management** on the **Connection** page, then approve this device on the gateway host. See [Access levels](../../getting-started/connect-a-gateway/#access-levels).

Without it, those controls are turned off and the page says so, with **Open Connection**.
:::

## Effective tools

The tools inspector shows every tool a chat or agent could call, and whether its tool policy allows it. Use it to check what an agent can do before you start a run.

- **For a chat:** open the chat's **⋯** menu and choose **Tools & Policy…**. This works in a new chat before you've sent anything.
- **For an agent:** in Gateway Settings, choose **Agents & Models**, open the agent, and choose **Tools**.

Tools are grouped the way the gateway groups them. Each row shows the tool, where it comes from (core, a plugin, a channel or an MCP server) and **Allowed** or **Denied**, with the reason, such as the tool profile or a `tools.deny` rule. Filter by **All**, **Allowed** or **Denied**, or search by name.

A chat's list is the gateway's preview for that chat's saved settings. If MCP servers haven't connected or listed their tools yet, Pincer says so, and their tools may be missing until they do.

The inspector is read-only and needs only `operator.read`. To change tool policy, use **Tools & Skills** or **Raw Config** in Gateway Settings.

## Older gateways

Pincer only shows what your gateway supports. If it doesn't offer skills (`skills.status`), there's no **Skills** page. Without ClawHub search (`skills.search`), there's no **Browse ClawHub**, and without `skills.install` or `skills.update` those buttons are hidden. Without `tools.effective` or `tools.catalog`, the tools inspector doesn't appear. Update OpenClaw to get them.

## In the demo

The [demo](../../getting-started/try-the-demo/) has sample skills in every state, including one that needs a program, one that needs an API key, a blocked one, a disabled one and a ClawHub skill with an update. ClawHub search returns a few sample results, and installing or updating works without touching a real gateway. The tools inspector shows a sample policy with allowed and denied tools from core, a plugin and an MCP server.
