# PromptStudio Desktop Pet and Web Capture Design

## Goal

PromptStudio launches a quiet floating ink-creature pet. In Chrome, Edge, or Arc, selecting text reveals a feed button; confirming the feed stores a local text Prompt in a dedicated inbox and animates the selected text into the pet.

## Product behavior

- The pet appears on launch by default, never steals keyboard focus, can be dragged and snapped to a screen edge, and can be hidden for the current app session.
- A 28-point feed button appears 300 milliseconds after a non-empty web selection and disappears on scrolling, clearing the selection, or five seconds of inactivity.
- Feeding asks for confirmation. A successful database write precedes the text-flight and swallow animation. Cancelling or failing never shows success.
- While the pet is hidden, feeding saves silently and posts a local notification.
- The first release is free and excludes growth, costumes, free roaming, AI titles/tags, Safari, Windows, and cloud transport.

## Visual and control model

- The pet is a 72–88 point charcoal blob with white eyes and a muted purple mouth, drawn with SwiftUI Canvas/Path and system animations.
- States are idle, asking, eating, success, cancelled, error, and hidden. Idle motion is limited to breathing and occasional blinking.
- Right-click actions are Hide Pet, Pause Web Capture for 1 Hour, and Open PromptStudio. A menu-bar mouth icon restores the pet.
- Settings cover launch visibility, capture enablement and connection state, default folder, sound (off by default), source clearing, and browser-host removal. Reduced motion follows macOS.

## Architecture

- A Manifest V3 extension renders the page overlay and sends user-approved selections through a long-lived Chrome Native Messaging port.
- A bundled `PromptStudioCaptureHost` validates the exact production/development extension origins, translates Chrome length-framed JSON to a user-only Unix socket, and cold-launches PromptStudio when necessary.
- The app-side capture server presents the pet confirmation, calls a free capture-only creation API, and returns the pet mouth position. The extension converts screen coordinates back to viewport coordinates and animates a text fragment toward that point.
- The extension makes no network requests. Logs contain status, duration, and character count only; never body text or a complete URL.

## Public data and protocol

- `WebCaptureCandidate`: capture ID, selected text, page title, page URL, site name, click screen point, and capture time.
- `CapturedSource`: web source metadata persisted locally with the Prompt.
- `WebCaptureEvent`: presented, cancelled, animate, saved, and failed.
- `createCapturedPrompt(_:)`: free capture-only API with a 50,000-character limit and capture-ID idempotency.
- `PromptItem` gains nullable capture ID/source metadata. SQLite gains `captureId`, `captureSourceJSON`, and a partial unique capture-ID index.
- Captures use top-level folder `folder-capture-inbox` (待整理), model `unspecified_text` (未指定模型), and tags 网页采集 and 待整理. Titles use the first non-empty line, whitespace-normalized and limited to 40 characters.

## Acceptance criteria

- Chrome, Edge, and Arc support warm/cold app capture with correct multi-display placement and no focus theft.
- Empty text, password fields, restricted pages, selections over 50,000 characters, retries, disconnects, unavailable libraries, hidden mode, and reduced motion have explicit outcomes.
- One hundred sequential captures produce no loss or duplicate items.
- Existing libraries migrate without data loss; signing, notarization, update packaging, and existing tests continue to pass.

