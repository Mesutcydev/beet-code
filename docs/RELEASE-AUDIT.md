# Beet Code — Release Audit (v0.8.0)

Generated 2026-08-19 against the current tree. All numbers below are from real
runs in this session, not claims. Supersedes the v0.7.0 audit.

**Tree audited:** v0.8.0 (build 5) — activity rail, chat import/export,
Pantone-anchored Beet theme, diagnostics panel, KV-aware GGUF context, MTP
speculative decoding, tool-call transcript sanitization, ShellRunner
EXC_GUARD fix; hermetic suite.

## Verdict

**Shippable today as a personal/insider build on your own Macs.**
Not shippable to strangers: Developer ID signing + notarization remain
blocked — certificates revoked (see §4.1).

## 1. Build & test evidence (this session)

| Check | Result |
| --- | --- |
| Debug build (app) | ✅ BUILD SUCCEEDED (after `xcodegen` regen for new files) |
| Test suite | ✅ **370/370, 0 failures**, 97 s, zero runner restarts (`TEST SUCCEEDED`) |
| Targeted re-run (filter + parser) | ✅ 19/19 (StreamDisplayFilterTests, ToolParserTests) |
| Code signing | ⚠️ ad-hoc (`flags=0x2(adhoc)`), TeamIdentifier unset |
| Gatekeeper | ❌ rejects ad-hoc — expected; requires Developer ID + notarization |
| App Sandbox | OFF (`ENABLE_APP_SANDBOX: NO`) — deliberate and required: the agent needs shell/git/workspace access. Must stay documented. |

Test count growth: 304 (v0.7.0) → 370 (v0.8.0, +66: vision agent sessions,
GGUF metadata/context, workspace history, import/export-adjacent suites,
engine pool, diagnostics-adjacent coverage).

**Full-suite flake — root-caused and fixed.** The intermittent
"unexpected exit, crash, or test timeout" mid-suite (host process died inside
`EndToEndTests.testPausedDownloadManifestSurvivesRelaunch`) was an
**EXC_GUARD kill in ShellRunner**: the pipe's read fd was wrapped in a second
`FileHandle(closeOnDealloc: true)`, so one descriptor had two owners and the
last dealloc closed an already-closed *guarded* fd. Fixed by reading through
the pipe's own handle (single owner, no double close) — commits `6d6b4ab`,
`f16cbfa`. Post-fix suite: no runner restarts.

## 2. What shipped since the v0.7.0 audit

- **Activity rail + sidebar redesign**: every panel toggle and action lives
  in the rail (new chat, sessions/imported tabs, browser, simulator,
  diagnostics, export, Model Manager, Settings). Imported chats group under
  collapsible per-project header cards (headline name, accent folder tile,
  count pill, rotating chevron) with **Claude/Codex/Cursor filter pills**.
- **Chat history import/export**: import from `~/.claude`, `~/.codex`, Cursor
  with live parser status and bounded streaming (16 MB/file, 512 KB/message);
  export via rail button (current chat → Markdown) and per-row context menu
  (Markdown/JSON) — wire format sanitized out of exports.
- **Themes**: full-UI Beet mode anchored on the exact Pantone 19-2030 TCX
  Beet Red `#7A1F3D` window background (one hue, four depths; cards lift,
  wells sink; glass falls back to opaque themed surfaces); BeetLogo replaces
  the sparkle avatar and empty-state hammer; brand contract codified in
  `docs/BRAND-KIT.md`.
- **Transcript sanitization**: raw tool-call JSON can no longer leak into the
  transcript — `ToolParser.strippingCalls` cleans live + restored assistant
  messages; `looksLikeToolCallFragment` turns token-ceiling-truncated calls
  into protocol-error re-prompts instead of fake "Task complete" answers;
  streaming display hides in-progress call syntax behind a "Working…"
  indicator.
- **Interactive card redesign**: approval/question/plan cards share one
  silhouette (raised surface, hairline, 3-pt semantic leading bar);
  destructive actions moved to the far trailing edge; streaming caret is a
  brand-gradient pulse bar; composer pills can never wrap mid-label.
- **In-app diagnostics**: docked panel with breadcrumb timeline
  (session/engine/tool/approval/import/system, 500-entry ring buffer,
  metadata-only), category filter pills, system snapshot, plain-text log
  export for bug reports. Spec: `docs/DIAGNOSTICS-SPEC.md`.
- **KV-aware GGUF context**: fixed 32K clamp replaced by RAM-fitted context
  (256K ceiling, 4K floor) sniffed from GGUF header dims;
  `effectiveContextWindow` plumbed engine → pool → router → AppState →
  AgentLoop compaction + composer gauge (fixes llama-server HTTP 400 overflow
  when fitted ctx < catalog window).
- **MTP speculative decoding**: auto-detects nextn tensors (Qwythos),
  launches llama-server with `--spec-type draft-mtp --spec-draft-n-max 2`,
  self-healing fallback on older binaries.
- **Vision**: MLXVLM wired, SmolVLM catalog entries, vision tool covered by
  real agent-session tests; describe_image refusal surfaces as a failed
  observation.
- **Workspace-history digest** in the system prompt (own + imported
  sessions); 思考-delimited reasoning stripping for Qwen finetunes.

## 3. Live verification carried over (still valid)

- **Local API server E2E with a real model**: Qwen3 1.7B 4-bit served via
  `lf serve --model`; `/v1/models`, non-streaming + SSE completions returned
  real generated output (v0.6.0 audit).
- **`lf serve` CLI**: banner, model load, SIGINT teardown clean.
- Live model lists depend on valid provider keys — not fully verifiable for
  every provider without them.
- Attachments (paperclip → quoted files / vision description) exercised in
  unit/E2E suites; not re-verified end-to-end with a live vision model this
  session.

## 4. Release-readiness checklist

### 4.1 Must fix before any public distribution
1. **Developer ID signing + notarization — BLOCKED ON CERTIFICATE.**
   Both `Developer ID Application` certificates in the login keychain are
   **revoked** (`CSSMERR_TP_CERT_REVOKED`). Action required: create a new
   Developer ID Application certificate at developer.apple.com. Then:
   hardened-runtime + timestamp codesign → `ditto` zip →
   `xcrun notarytool submit … --wait`.
2. **Versioning**: 0.8.0 / build 5 in `project.yml` + `App/Info.plist` ✅.
3. **Entitlements file**: still absent. Create for Developer ID + hardened
   runtime (MLX/Metal needs no JIT entitlement).

### 4.2 Should fix before 1.0
4. **Distribution format**: no DMG/zip packaging script, no Sparkle
   auto-update, no crash reporting. (`hdiutil create` one-liner below works
   today for ad-hoc DMGs.)
5. **Local API server**: no Anthropic-format *streaming* parity for
   `tool_use` blocks (text-only), no per-request rate limiting.
6. **Info.plist minimal**: no `NSHumanReadableCopyright`, no URL schemes.
7. **MCP**: stdio + HTTP transports configurable, no OAuth flow execution yet.
8. **Diagnostics persistence**: breadcrumbs are session-only; bounded JSONL
   persistence across launches is specced (DIAGNOSTICS-SPEC §6) but unbuilt.

### 4.3 Explicitly fine as-is
- Ad-hoc signing for self-use ✅
- Sandbox OFF (documented requirement for shell tools) ✅
- arm64-only (product decision: Apple Silicon only) ✅
- Secrets: Keychain-only, sessions AES-GCM encrypted, redaction on —
  no hardcoded keys (scanned before push) ✅
- Loopback-only server binding (127.0.0.1) ✅
- Diagnostics are metadata-only (no message/file contents, no secrets) ✅
- Repo public at https://github.com/Mesutcydev/beet-code ✅

## 5. Test coverage snapshot (what the 370 tests protect)

AgentLoop + hooks (deny/rewrite + gate non-bypass) · tools/policy/git/
workspace · BYOK providers + registry · tool parser (incl. call-stripping +
truncated-fragment detection) · diagnostics parser · diff engine · memory ·
persistence · repo index · smart downloader · parallel chunk planner · GGUF
planner + metadata/context · memory advisor · engine pool residency ·
end-to-end (download-finalize-activate, paused-manifest-relaunch,
checkpoint-undo) · reasoning folding + stream display filter ·
intent/composer store pipeline · vision sessions · workspace history digest ·
local API server · MCP (config transport decode, OAuth planner, tools) ·
slash commands + AGENTS.md · legacy migration · browser tool registration.

Known gaps to add before 1.0: idle-TTL unload timing test (needs clock
control), MCP timeout path under a hanging server, DMG/signing automation,
live-browser e2e (needs a UI-test harness).

## 6. Release procedure (repeatable, v0.8)

```sh
cd "new project/BeetCode"
rm -rf .derived                          # avoid stale-path warnings
xcodegen generate                        # after any file add/remove
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .derived build
# 1) Version is 0.8.0 / 5 in project.yml (info: properties)
# 2) Sign & notarize (BLOCKED until new Developer ID cert, §4.1):
#    codesign --force --options runtime --timestamp \
#      --sign "Developer ID Application: <name>" \
#      .derived/Build/Products/Release/BeetCode.app
#    ditto -c -k --keepParent BeetCode.app BeetCode.zip
#    xcrun notarytool submit BeetCode.zip --apple-id … --wait
# 3) Package DMG:
#    hdiutil create -volname BeetCode -srcfolder BeetCode.app -ov BeetCode.dmg
# 4) Smoke-test the CLI server before tagging a release:
#    BeetCodeCLI serve --port 1234 --model qwen3-1.7b-4bit
#    curl http://127.0.0.1:1234/v1/chat/completions \
#      -H 'Content-Type: application/json' \
#      -d '{"messages":[{"role":"user","content":"ping"}]}'
```
