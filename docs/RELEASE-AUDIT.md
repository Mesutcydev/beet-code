# Beet Code — Release Audit (v0.5.0)

Generated 2026-08-18 against the current tree. This is a **from-scratch
audit** replacing the v0.4-era document. All numbers below are from real
runs in this session, not claims.

**Tree audited:** v0.5.0 (build 2) — local API server, MCP client,
AGENTS.md/CLAUDE.md, slash commands, Keychain deadlock elimination,
layering fixes, F3 weight-guard hardening.

## Verdict

**Shippable today as a personal/insider build on your own Macs.**
Not shippable to strangers: Developer ID signing + notarization remain
blocked — and the blocker is now known exactly (see §4.1).

## 1. Build & test evidence (this session)

| Check | Result |
| --- | --- |
| Debug build (app) | ✅ BUILD SUCCEEDED |
| Debug build (CLI `BeetCodeCLI`) | ✅ BUILD SUCCEEDED (previously did not compile — layering fixes, §3) |
| Release build (clean) | ✅ BUILD SUCCEEDED; 12 warnings (see §5) |
| Test suite | ✅ **203/203, 0 failures**, ~89 s (deterministic: no weights, no Metal, no network) |
| Release app bundle | arm64-only, 50 MB, `CFBundleShortVersionString` 0.5.0 / build 2 |
| Code signing | ⚠️ ad-hoc (`flags=0x2(adhoc)`), TeamIdentifier unset |
| Gatekeeper | ❌ rejects ad-hoc — expected; requires Developer ID + notarization |
| App Sandbox | OFF (`ENABLE_APP_SANDBOX: NO`) — deliberate and required: the agent needs shell/git/workspace access. Must stay documented. |

Test count grew 166 → 203 this session (+37): 10 local-API-server e2e,
4 bearer-auth, 5 Anthropic `/v1/messages`, 12 slash-command/project-instruction,
8 MCP (incl. real-subprocess JSON-RPC against a python fake server).

## 2. What was verified live (not just unit-tested)

- **Local API server E2E with a real model**: downloaded Qwen3 1.7B 4-bit
  (968 MB, LFS-verified) via `lf download`, served via `lf serve --model`,
  and drove it with real HTTP: `/v1/models` reports `loaded:true`,
  `/v1/chat/completions` returned a real generated answer (finish_reason
  stop), and streaming produced role delta → token chunks → `[DONE]`.
- **API server without a model**: clean structured 500
  (`{"error":{"message":"Generation failed: No model is loaded.",...}}`),
  structured 404 on unknown routes, CORS preflight 204.
- **`lf serve` CLI**: banner, model load, SIGINT teardown all clean;
  leaked-continuation warning fixed (sleep-loop park).
- **Release app launch**: process stays alive with a healthy idle runloop
  (window-visibility check remains Accessibility-blocked from the automation
  gateway — verify visually on next manual launch).

## 3. Defects found & fixed during this audit

| ID | Severity | Finding | Fix |
| --- | --- | --- | --- |
| N1 | **Critical** | The CLI target had **never compiled**: `ComposerFlow` (App) and `SimctlRunner` (App) were referenced from Core. Surfaced only when `lf serve` was built. | `ComposerFlow` moved to Core (SwiftUI palette kept as App extension); `SimctlRunner` + plist helper moved to Core; App method delegates. All three targets now build. |
| N2 | High | F3 guard gap: a model directory holding only config/tokenizer files (exactly the state found on disk for qwen2.5-coder-7b — weights deleted, sidecar gone) passed `hasConfiguration` and would crash the loader with `keyNotFound(lm_head.weight)`. | `hasConfiguration` now also requires ≥1 `.safetensors`/`.weight` file. Stale registry entries self-heal to "not downloaded". |
| N3 | Medium | `/memory add` without text parsed as `.memory` (listed facts) instead of falling back to help. | Parser accepts bare `add` → help. Test added. |
| N4 | Low | Two Swift warnings introduced by the `send()` async refactor (unused bindings). | Removed. |

Carried over from the earlier audit, all still in effect: F1 (remote
context loss), F2 (continuation amnesia), F3 (incomplete downloads),
F8 (structured cancel), F9/F9b/F9c (Keychain deadlock chain), U1–U8 UI
polish, R1–R3 (first release audit findings).

## 4. Release-readiness checklist

### 4.1 Must fix before any public distribution
1. **Developer ID signing + notarization — BLOCKED ON CERTIFICATE.**
   Both `Developer ID Application: MESUT CAN YAGCI (PUH4GMFV56)`
   certificates in the login keychain are **revoked**
   (`CSSMERR_TP_CERT_REVOKED`, verified via `security find-identity`).
   Action required from you: create a new Developer ID Application
   certificate at developer.apple.com (renew the membership first if it
   lapsed). Then: hardened-runtime + timestamp codesign → `ditto` zip →
   `xcrun notarytool submit … --wait`. Until then the app is ad-hoc only.
2. **Versioning — DONE this session**: bumped 0.1.0/1 → **0.5.0/2** in
   `project.yml`. Keep bumping per release.
3. **Entitlements file**: still absent. For Developer ID + hardened
   runtime, create one (MLX/Metal needs no JIT entitlement; verify
   notarization passes with plain Metal; Keychain needs nothing unsigned).

### 4.2 Should fix before 1.0
4. **Distribution format**: no DMG/zip packaging script, no Sparkle
   auto-update, no crash reporting. (The `hdiutil create` one-liner below
   works today for ad-hoc DMGs.)
5. **Local API server polish** (shipped v0.5): still no Anthropic-format
   *streaming* parity for `tool_use` blocks (text-only), no per-request
   rate limiting. Documented in COMPETITIVE-ANALYSIS as remaining gaps.
6. **Info.plist minimal**: no `NSHumanReadableCopyright`, no URL schemes.
7. **MCP is new code**: stdio transport only; no SSE/HTTP MCP transport
   yet, no OAuth. Fine for v1 parity (OpenCode proves stdio is enough).

### 4.3 Explicitly fine as-is
- Ad-hoc signing for self-use ✅
- Sandbox OFF (documented requirement for shell tools) ✅
- arm64-only (product decision: Apple Silicon only) ✅
- Secrets: Keychain-only, sessions AES-GCM encrypted, redaction on —
  no hardcoded keys in App/Core/CLI (scanned) ✅
- Loopback-only server binding (127.0.0.1; nothing external can reach it) ✅

## 5. Release warnings inventory (Release build, 12 total)

Pre-existing (not from this session): MLX `set(cacheLimit:)` deprecation,
two "no calls to throwing functions" `try` notes, `HFTokenStore` let-var,
two unused-binding notes in download code, one unused `try?` result.
Fixed this session: the two warnings introduced by the `send()` refactor.
None are functional; sweep is a nice-to-have before 1.0.

## 6. Release procedure (repeatable, updated for v0.5)

```sh
cd BeetCode
rm -rf .derived                          # avoid stale-path warnings
xcodegen generate                        # after any file add/remove
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .derived build
# 1) Bump version in project.yml (info: properties) — currently 0.5.0 / 2
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

## 7. Test coverage snapshot (what the 203 tests protect)

AgentLoop (20) · tools/policy/git/workspace · BYOK providers + registry ·
tool parser · diagnostics parser · diff engine · memory · persistence ·
repo index · smart downloader · memory advisor · end-to-end (AppState →
download → agent) · reasoning folding · lattice engine · **local API
server (19: OpenAI routes, SSE, statelessness, auth, Anthropic format)** ·
**MCP (8: config, real-subprocess connect/call, adapter, registry)** ·
**slash commands + AGENTS.md/CLAUDE.md (12)**.

Known gaps to add before 1.0: idle-TTL unload timing test (needs clock
control), MCP timeout path under a hanging server, DMG/signing automation.
