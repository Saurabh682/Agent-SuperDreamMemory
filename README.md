# Agent Memory Kit

A shared, reviewable "dreaming" memory for any coding agent (Codex, Antigravity, Claude Code, Cursor, anything that reads an instructions file).

**How it works**

1. Every agent reads one shared rules file. When it learns something durable it writes a small note to `.agent-memory/inbox/` in the project. It never edits memory directly.
2. A *different* agent later reviews those notes (the "dream" pass): it checks evidence, rejects weak or one-off claims, and writes a *proposal* to `.agent-memory/proposals/`.
3. You read the proposal, and the kit merges it only if a leak scan is clean and you type `yes`.

Global lessons live in one folder (`~/.agent-memory`), project lessons live in each project. Nothing is merged without you.

## Quick start (Windows)

1. Unzip anywhere and keep the folder.
2. Open `config.json`, set `"enabled": true` for the agents you use (Codex and Antigravity are on by default).
3. Double-click **Setup.cmd**.
4. Menu **1 Install**, once. Then **2 Set up a project** for each project.

Works with PowerShell 5.1 (built into Windows) or PowerShell 7 on Windows, macOS and Linux (`pwsh setup.ps1`).

## The menu

| Choice | What it does |
| --- | --- |
| 1 Install | Creates the shared memory, adds a small marked block to each enabled agent's global instructions file (original saved as `*.agent-memory.bak`). Safe to run again. |
| 2 Set up a project | Creates `.agent-memory/`, detects the stack, writes a never-open list (including sensitive files it finds), updates `.gitignore`. |
| 3 Backfill | Builds a prompt for one agent to mine the project's git history and docs into notes. Copied to your clipboard. |
| 4 Dream | Builds a review prompt for a *different* agent than the one that wrote the notes. |
| 5 Review and merge | Scans the newest proposal for emails/keys, shows what would change, merges only after you type `yes`, archives the processed notes. |
| 6 Status | Which agents are connected, note counts, whether it is time to dream. |
| 7 Uninstall | Removes the blocks from the agents' files. Your memory and notes stay. |

Paste each prompt into a **new thread** in the agent, with that project open (the prompt checks the workspace path).

Everything is also available without the menu, for example `.\setup.ps1 -Action dream -Project D:\code\app -Tool codex`.

## Configure (config.json)

- **memoryHome**: where the shared memory lives.
- **agents**: one entry per agent. To add any agent, copy an entry, set its `name`, and put the path of its global instructions file in `globalFiles`. `createIfMissing: false` means "only edit it if it already exists", which matters for Antigravity's `GEMINI.md` because it outranks `AGENTS.md`.
- **projectPointerFiles**: for agents with no global file (for example Cursor), list project files such as `".cursor/rules/memory.mdc"` or `"AGENTS.md"` to get a short pointer block. `projectPointerPosition: "start"` keeps it above a very large file so it is not cut off.
- **neverOpen / sensitiveFilePatterns / sensitiveFolders**: what agents must not read or copy.
- **profiles**: themes the backfill uses per stack (android, node, python, default). Add your own. A project can override in `.agent-memory/config.json`.
- **backfill / dream**: months of history, items per note, index line limit, whether the dream pass may run tests (default: no), and extra rules.
- **leakPatterns**: what the leak scan blocks on.

## What it will not do

It never edits source code, never deletes your memory folder, never commits or pushes for you, and never merges a proposal without your `yes`. Edits to agent files are limited to one removable block.

## Limits to know

- The rules are instructions. An agent can still forget to write a note or ignore a rule, so check **Status** after real work.
- Reading proposals is your job. The scan catches emails, API keys and private-key headers, not wrong lessons.
- The kit generates prompts and does not launch agents. If an agent has a headless mode you can wrap the prompt file in `~/.agent-memory/dream/` yourself.
- Tested end to end in PowerShell 7 with simulated agent files. It was not run on Windows PowerShell 5.1 or against the real Codex or Antigravity apps.
