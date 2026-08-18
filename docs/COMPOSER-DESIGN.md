# Composer Design — Audit & Hybrid Master (v0.4)

## Audit of leading composers

| App | Input style | Attachments | Expansion | Context & actions |
| --- | --- | --- | --- | --- |
| Cursor | Full-width bottom bar, rounded, thin border + shadow | Paperclip; @-mention files; context chips (files/symbols) | Auto-grows to ~200px then scrolls | Model picker right; send appears with text; stop while running; agent mode toggle |
| ChatGPT | Rounded-2xl bar, centered column | Paperclip + camera; tools row (search/think/vision) as chips | Auto-grows; char counter near limit | Submit morphs to stop; web-search chip; suggestions above |
| Claude | Minimal rounded bar | Paperclip; plan-mode toggle | Grows | Model + style pickers; arrow send |
| GitHub Copilot | Dockable panel input | Context chips (files, selections) | Grows | Preview toggle; slash commands |
| Linear / Warp | Keyboard-first, minimal | None | Grows | Cmd+Enter to send; focus-first |

## What each does best (the hybrid picks)

1. **Cursor**: full-width expanding textarea with a real focus ring, context
   chips, contextual send/stop, model picker. The strongest 'work surface'
   pattern.
2. **ChatGPT**: tool/attachment chips that are *visible affordances* (not
   hidden), submit↔stop morphing, auto-grow with a sensible max.
3. **Claude**: plan-mode as a first-class toggle next to the input — perfect
   for our plan mode.
4. **Linear/Warp**: keyboard discipline — Enter sends, Shift+Enter newline,
   Esc stops, ⌘V pastes images.

## Hybrid Master Composer (implemented)

Layout (bottom-up):

```
┌────────────────────────────────────────────────────────┐
│ [📎 Attach]  [chip: file.swift ✕] [chip: shot.png ✕]    │ ← attachment chips
│                                                         │
│  Describe a coding task…                     [⏹/➤]     │ ← auto-growing textarea
│                                                         │     1→8 lines, scroll after
│ [🌊 flow] [🧠 model] [📋 plan] [🤔 reasoning]  [➤ send]  │ ← accessory row
└────────────────────────────────────────────────────────┘
   ← animated gradient border (ComposerFlow), brightens on focus/streaming
```

- **Auto-expanding textarea**: 1 line → up to 8, then scrolls. Cursor-style.
- **Attachment button (paperclip)**: NSOpenPanel, files + images. Attachments
  appear as removable chips above the input. Files are read (bounded) into
  the user message as quoted blocks at send time; images go through the
  vision pipeline (describe_image via the active vision-capable provider)
  and their descriptions are attached to the message. ⌘V pastes a
  screenshot/image directly.
- **Accessory row**: composer flow picker (existing presets), active
  model/engine indicator, plan-mode + reasoning toggles inline (Claude-style
  first-class controls), and the send/stop button.
- **Send/stop morphing**: arrow appears when there is text; becomes a stop
  square while the agent runs (ChatGPT-style).
- **Keyboard**: Enter send, Shift+Enter newline, Esc stop, ⌘V paste image.
- **Focus/stream states**: the animated border brightens on focus and pulses
  while streaming; turns orange while an approval is pending.

## Files

- `App/ChatView.swift` — composer layout + attachment chips (this doc's
  design).
- `App/AgentSessionController.swift` — attachment → message expansion.
- `Core/Tools/VisionTool.swift` — image attachment descriptions.