# Agent Handoff Cards

[简体中文](../README.md)

**Give Gemini the plan, Codex the implementation, and Gemini the results.** One local card holds the draft, the files you approve, the test results, and the final wording.

[Download source ZIP](https://github.com/Fanmili-5/agent-handoff-cards/releases/download/v0.1.0-alpha.2/agent-handoff-cards-v0.1.0-alpha.2-source.zip) · [Release notes](https://github.com/Fanmili-5/agent-handoff-cards/releases/tag/v0.1.0-alpha.2)

![Example card showing an approved edit to labels.py, two passing tests, and Gemini’s final note.](handoff-example.png)

*Illustration based on a completed handoff. Codex edited `labels.py`, both tests passed, and Gemini wrote back a short user-facing note.*

## Quick start

Requires macOS 13 or later, Python 3.9+, and Xcode Command Line Tools. Unzip the source and run:

```bash
python3 -B workbench.py
```

The first launch builds `dist/Agent Handoff.app`. Select a project that both clients can access. Create a card with the goal and the relative paths Codex may edit. Leave the scope empty for a writing-only task.

1. Copy the planning prompt and send it to Gemini in Antigravity.
2. Review the draft and approve its file scope in the workbench.
3. Send the execution prompt to Codex. It writes its changes and test results back to the card.
4. Send the editing prompt to Gemini and copy the final text from the workbench.

You send each prompt. The clients use their existing sign-ins. The workbench requires no API key or Antigravity Hub patch.

## CLI and Skill

Run from the source directory. Replace `CARD` with the ID returned by `new`.

```bash
python3 -B handoff.py --workspace /path/to/project new \
  --title 'Update release notes' --goal 'Verify setup and update the README' --scope README.md
python3 -B handoff.py --workspace /path/to/project prompt CARD
```

The workbench prompt includes the CLI and Skill paths, so the tool can live outside the task project. To approve in the terminal, review the draft and digest with `show CARD`, then use `approve CARD --digest DIGEST`. The `draft`, `report`, and `polish` commands accept text via stdin or `--file`. [Handoff Skill](../.agents/skills/agent-handoff/SKILL.md)

Cards live in the project's `.agent-handoff/` directory. Exclude it from Git. Each client handles the files it is permitted to read and sends the necessary content to its model service.

Tested on Apple Silicon with macOS 26.5.1. Other macOS versions and Intel Macs are unverified. [MIT license](../LICENSE)
