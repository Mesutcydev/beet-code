# Beet Code — Release Audit (v0.6.0)

Generated 2026-08-18 against the current tree. All numbers below are from real
runs in this session, not claims. Supersedes the v0.5.0 audit.

**Tree audited:** v0.6.0 (build 3) — provider hardening (13 audit fixes),
Anthropic-native + custom providers, agent-controlled in-app browser, Intent
Lattice full repair, Beet Red theme + palette picker, API settings redesign,
Cursor/ChatGPT-style transcript.

## Verdict

**Shippable today as a personal/insider build on your own Macs.**
Not shippable to strangers: Developer ID signing + notarization remain
blocked — certificates revoked (see §4.1).

## 1. Build & test evidence (this session)

| Check | Result |
| --- | --- |
| Debug build (app) | ✅ BUILD SUCCEEDED |
| Test suite | ✅ **265/265, 0 failures**, ~96 s (`TEST SUCCEEDED`, RUN7/RUN8/RUN9 lineage) |
| Code signing | ⚠️ ad-hoc (`flags=0x2(adhoc)`), TeamIdentifier unset |
| Gatekeeper | ❌ rejects ad-hoc — expected; requires Developer ID + notarization |
| App Sandbox | OFF (`ENABLE_APP_SANDBOX: NO`) — deliberate and required: the agent needs shell/git/workspace access. Must stay documented. |

Test count growth this session: 203 → 221 (hooks) → 225 (rename + legacy
migration) → 265 (lattice logic + store: 36 new tests).

## 2. What shipped since the v0.5.0 audit

- **Provider hardening P1–P13**: UTF-8-safe SSE parsing, provider-safe tool
  role mapping (OpenAI/Gemini), no forced `temperature: 0` probe, custom
  base-URL provider (keyless-capable for local servers), Anthropic-native
  provider, stream watchdog + bounded retry, Gemini `systemInstruction` +
  adjacent-role merge, `max_completion_tokens` for o-series, real usage
  stats decoding, live `/v1/models` fetch (auto-refreshed on key save),
  Gemini `x-goog-api-key` header auth, `User-Agent: BeetCode/0.6`, test
  fixture redaction cleanup.
- **Agent-controlled in-app browser**: shared `WKWebView` controller,
  `browser_*` tools (read-only extraction lower risk; navigation/mutation
  routed through PermissionGate), docked panel next to the transcript.
- **Intent Lattice full repair**: chips-first composer, single-source-of-truth
  store, robust Combine phase sync (sticky cancel, idempotent terminal),
  20 logic + 16 store tests.
- **Beet Red #7A1F3D (Pantone 19-2030 TCX)** as identity accent; palette
  system with live switching (5 palettes) + swatch picker in Settings.
- **API settings redesign**: window 940×720, larger rows, ProviderCard
  auto-fetches the provider's live model list on key save, current-generation
  static fallback lists.
- **Rename LocalForge → Beet Code**: one-time `LegacyMigration` copies
  Keychain items (`com.localforge.*` → `com.beetcode.*`) and moves
  Application Support; legacy items retained as rollback.
- **UI polish (Cursor/ChatGPT-style)**: centered 760pt transcript column,
  avatar-led assistant messages with inline markdown, grouped collapsible
  tool-step cards, blinking streaming caret, ChatGPT-style suggestion chips,
  hover-lift affordances, U9 light-mode inset contrast.

## 3. Live verification carried over (v0.5.0 audit, still valid)

- **Local API server E2E with a real model**: Qwen3 1.7B 4-bit (968 MB)
  served via `lf serve --model`; `/v1/models`, non-streaming + SSE
  completions all returned real generated output.
- **`lf serve` CLI**: banner, model load, SIGINT teardown clean.
- Live model lists depend on valid provider keys — not fully verifiable for
  every provider without them.

## 4. Release-readiness checklist

### 4.1 Must fix before any public distribution
1. **Developer ID signing + notarization — BLOCKED ON CERTIFICATE.**
   Both `Developer ID Application` certificates in the login keychain are
   **revoked** (`CSSMERR_TP_CERT_REVOKED`). Action required: create a new
   Developer ID Application certificate at developer.apple.com. Then:
   hardened-runtime + timestamp codesign → `ditto` zip →
   `xcrun notarytool submit … --wait`.
2. **Versioning**: 0.6.0 / build 3 in `project.yml` + `App/Info.plist`.
3. **Entitlements file**: still absent. Create for Developer ID + hardened
   runtime (MLX/Metal needs no JIT entitlement).

### 4.2 Should fix before 1.0
4. **Distribution format**: no DMG/zip packaging script, no Sparkle
   auto-update, no crash reporting. (`hdiutil create` one-liner below works
   today for ad-hoc DMGs.)
5. **Local API server**: no Anthropic-format *streaming* parity for
   `tool_use` blocks (text-only), no per-request rate limiting.
6. **Info.plist minimal**: no `NSHumanReadableCopyright`, no URL schemes.
7. **MCP**: stdio transport only; no SSE/HTTP transport, no OAuth.

### 4.3 Explicitly fine as-is
- Ad-hoc signing for self-use ✅
- Sandbox OFF (documented requirement for shell tools) ✅
- arm64-only (product decision: Apple Silicon only) ✅
- Secrets: Keychain-only, sessions AES-GCM encrypted, redaction on —
  no hardcoded keys (scanned before push) ✅
- Loopback-only server binding (127.0.0.1) ✅
- Repo public at https://github.com/Mesutcydev/beet-code ✅

## 5. Test coverage snapshot (what the 265 tests protect)

AgentLoop + hooks (deny/rewrite + gate non-bypass) · tools/policy/git/
workspace · BYOK providers + registry · tool parser · diagnostics parser ·
diff engine · memory · persistence · repo index · smart downloader · memory
advisor · end-to-end · reasoning folding · lattice engine · **Intent Lattice
logic + store (36: availability, presets, validation, drafts, runs, cancel
phase transitions)** · local API server (19) · MCP (8) · slash commands +
AGENTS.md (12) · legacy migration · browser tool registration.

Known gaps to add before 1.0: idle-TTL unload timing test (needs clock
control), MCP timeout path under a hanging server, DMG/signing automation,
live-browser e2e (needs a UI-test harness).

## 6. Release procedure (repeatable, v0.6)

```sh
cd "new project/BeetCode"
rm -rf .derived                          # avoid stale-path warnings
xcodegen generate                        # after any file add/remove
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .derived build
# 1) Bump version in project.yml (info: properties) — currently 0.6.0 / 3
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
