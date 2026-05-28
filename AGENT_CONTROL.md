# PromptStudio Agent Control

PromptStudio exposes a local command-line control surface for coding agents such as Codex, Claude Code, and OpenClaw. The CLI reads and writes the same local SQLite library used by the native macOS app.

## Build

```bash
swift build
```

The executable is available at:

```bash
.build/debug/promptstudioctl
```

By default it uses:

```text
~/Documents/PromptStudio Library
```

Use `--library PATH` to target another library.

## Commands

```bash
promptstudioctl list --query "fashion"
promptstudioctl get ITEM_ID
promptstudioctl folders
promptstudioctl create-folder --name "参考图"
promptstudioctl create-prompt --title "Lookbook" --prompt "white linen dress" --tags "服装,写实"
promptstudioctl update-prompt ITEM_ID --prompt "updated prompt" --negative "watermark"
promptstudioctl add-tags ITEM_ID --tags "人物,摄影设计"
promptstudioctl favorite ITEM_ID --on
promptstudioctl move ITEM_ID --folder-id FOLDER_ID
promptstudioctl delete ITEM_ID
promptstudioctl restore ITEM_ID
promptstudioctl import ~/Desktop/prompt.md ~/Desktop/reference.png --folder-id FOLDER_ID
```

All data commands return JSON, so agents can parse IDs and chain actions.

## Import Behavior

Imported files are copied into the PromptStudio library. Supported asset kinds include image, video, audio, Markdown, JSON, text, document, data, and unknown files. Markdown, JSON, TXT, and CSV files are parsed locally when possible to extract Prompt, negative Prompt, tags, and parameters.

## MCP Path

The CLI is the stable base layer. A future MCP stdio server should wrap the same `PromptStudioAutomationService` methods instead of duplicating database logic.
