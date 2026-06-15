## Karpathy Guidelines

Use the installed `karpathy-guidelines` skill for coding, review, and refactoring tasks.
Source: `/Users/creatigo/.codex/skills/karpathy-guidelines/SKILL.md`

Core behavior:

- Think before coding: state assumptions, surface ambiguity, explain tradeoffs, and ask when the task is genuinely unclear.
- Simplicity first: implement the minimum code that solves the request; avoid speculative abstractions, extra configurability, and unrequested features.
- Surgical changes: touch only files and lines required by the user request; match existing style; mention unrelated dead code instead of deleting it.
- Goal-driven execution: define verifiable success criteria, run the relevant checks, and loop until the requested outcome is verified or a concrete blocker is found.

## PromptStudio Engineering Rules

- Default to analyzing performance, state flow, and reuse boundaries before changing functionality.
- Keep small changes surgical; do not expand the scope when a focused fix is enough.
- For repeated UI, scrolling, waterfall layout, previews, file I/O, thumbnails, and keyboard handling, propose the complete durable approach before implementing.
- If a durable fix requires changing core structure, confirm the tradeoff with the user before editing.
- Avoid temporary patches. Use an emergency workaround only when explicitly labeled as such and when the durable fix is not practical in the current turn.
