# Beet Code — Release Audit (v0.7.0)

Generated 2026-08-19 against the current tree. All numbers below are from real
runs in this session, not claims. Supersedes the v0.6.0 audit.

**Tree audited:** v0.7.0 (build 4) — multi-model residency, parallel chunk
downloads, composer rewrite (Intent architecture), reasoning-pipeline fixes,
MCP config transport defaults, test-suite hermeticity.

## Verdict

**Shippable today as a personal/insider build on your own Macs.**
Not shippable to strangers: Developer ID signing + notarization remain
blocked — certificates revoked (see §4.1).

## 1. Build & test evidence (this session)

| Check | Result |
| --- | --- |
| Debug build (app) | ✅ BUILD SUCCEEDED |
| Test suite | ✅ **304/304, 0 failures**, ~102 s (`TEST SUCCEEDED`) |
| Code signing | ⚠️ ad-hoc (`flags=0x2(adhoc)`), TeamIdentifier unset |
| Gatekeeper | ❌ rejects ad-hoc — expected; requires Developer ID + notarization |
| App Sandbox | OFF (`ENABLE_APP_SANDBOX: NO`) — deliberate and required: the agent needs shell/git/workspace access. Must stay documented. |

Test count growth: 265 (v0.6.0) → 304 (v0.7.0, +39: stream display filter,
GGUF planner, MCP transport decode, intent/composer store, downloader suites).

## 2. What shipped since the v0.6.0 audit

- **Multi-model residency + parallel chunk downloads**: large weight files
  fetch fixed byte ranges in parallel (resumable, aggregating progress);
  small files stream sequentially; both paths verify sha256 and survive
  relaunch via manifests with auto-resume opt-in.
- **Composer rewrite (Intent architecture)**: chips-first composer, intent
  composers/resolvers/presets, deterministic focus ordering, draft-only
  suffix, structural role dedup, plain-chars-over-4 token estimates.
- **Reasoning pipeline**: raw reasoning streams arrive in Qwen3-style
  ` thinking`/` response` XML segments (5-letter tags, verified at byte
  level); `strippingThinking`/`extractingThinking` and the stream display
  filter now match that exact format — complete blocks hidden, open blocks
  show reasoning state, repetition filler collapsed.
- **GGUF selection**: `selectGGUF` picks the largest candidate (ties broken
  by quantization level `-q<digits>`); free loopback port + health detection
  tests added.
- **MCP config transport**: `MCPServerConfig` explicitly decodes
  `command`/`args`/`env`/`url`/`headers`/`oauth` with defaults honored;
  command wins when both transports are present; entries with neither are
  rejected at load.
- **Test-suite hermeticity fixes**:
  - `AppState` launch restore refuses to auto-resume real downloads under an
    XCTest host (`XCTestConfigurationFilePath` present) — previously every
    test-host launch resumed the developer's genuine Qwen3-4B download over
    the network mid-suite, stalling fixture downloads (30+ min runs → ~102 s).
  - E2E/ComposerStore suites pin `planMode`/`autoApprove*` UserDefaults keys
    per-test (save/restore in setUp/tearDown) so a developer's real
    preferences can't leak into the test process.
  - Checkpoint-undo suite re-enables manual approvals locally, exercising the
    real approval path.

## 3. Live verification carried over (v0.6.0 audit, still valid)

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
2. **Versioning**: 0.7.0 / build 4 in `project.yml` + `App/Info.plist`.
3. **Entitlements file**: still absent. Create for Developer ID + hardened
   runtime (MLX/Metal needs no JIT entitlement).

### 4.2 Should fix before 1.0
4. **Distribution format**: no DMG/zip packaging script, no Sparkle
   auto-update, no crash reporting. (`hdiutil create` one-liner below works
   today for ad-hoc DMGs.)
5. **Local API server**: no Anthropic-format *streaming* parity for
   `tool_use` blocks (text-only), no per-request rate limiting.
6. **Info.plist minimal**: no `NSHumanReadableCopyright`, no URL schemes.
7. **MCP**: stdio + HTTP transports now configurable, but no OAuth flow
   execution yet.

### 4.3 Explicitly fine as-is
- Ad-hoc signing for self-use ✅
- Sandbox OFF (documented requirement for shell tools) ✅
- arm64-only (product decision: Apple Silicon only) ✅
- Secrets: Keychain-only, sessions AES-GCM encrypted, redaction on —
  no hardcoded keys (scanned before push) ✅
- Loopback-only server binding (127.0.0.1) ✅
- Repo public at https://github.com/Mesutcydev/beet-code ✅

## 5. Test coverage snapshot (what the 304 tests protect)

AgentLoop + hooks (deny/rewrite + gate non-bypass) · tools/policy/git/
workspace · BYOK providers + registry · tool parser · diagnostics parser ·
diff engine · memory · persistence · repo index · smart downloader · parallel
chunk planner · GGUF planner · memory advisor · end-to-end (incl.
download-finalize-activate, paused-manifest-relaunch, checkpoint-undo) ·
reasoning folding + stream display filter · intent/composer store pipeline ·
local API server · MCP (config transport decode, tools, spawn failure) ·
slash commands + AGENTS.md · legacy migration · browser tool registration.

Known gaps to add before 1.0: idle-TTL unload timing test (needs clock
control), MCP timeout path under a hanging server, DMG/signing automation,
live-browser e2e (needs a UI-test harness).

## 6. Release procedure (repeatable, v0.7)

```sh
cd "new project/BeetCode"
rm -rf .derived                          # avoid stale-path warnings
xcodegen generate                        # after any file add/remove
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .derived build
# 1) Bump version in project.yml (info: properties) — currently 0.7.0 / 4
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