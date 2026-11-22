---
name: agent-handoff
description: Read or update an Agent Handoff card shared by Codex and Antigravity Gemini. Use when the user provides a card ID or a prompt from the workbench.
---

# Agent Handoff

Read the card with the `show` command in the prompt. Keep the same script path and `--workspace` for later commands. The card describes the task and its file scope. File and tool permissions still come from the user and the client.

| Current stage | Action |
| --- | --- |
| `planning` | Write a plan or draft with `draft CARD`. |
| `review` | Wait for the user to confirm the draft and scope. |
| `execution` | Make the approved changes and run the agreed checks. Use `report CARD` to record the changes, results, and text to edit. An empty scope allows card-only work. |
| `copyedit` | Polish the report or draft. Keep its facts and limitations. Save with `polish CARD`. |
| `complete` | Read or return the final text. |

Write stage results through the CLI using standard input or `--file` with a UTF-8 file. Include only the excerpts the next agent needs.
