# Beet Code — Release Audit

Audit date: **2026-08-20**
Source version: **0.8.0 (build 5)**
Scope: current working tree after the security and concurrency hardening pass.

## Verdict

**Code status: ready for internal release testing.** The app builds and the
full suite passes. **Public distribution is still blocked by signing,
notarization, and packaging credentials**, which cannot be completed from this
checkout alone.

## 1. Verification evidence

| Check | Result | Evidence |
| --- | --- | --- |
| Debug app build | ✅ Passed | `xcodebuild ... build` → `BUILD SUCCEEDED` |
| Release app build | ✅ Passed (local ad-hoc signing) | `xcodebuild -configuration Release ... build` → `BUILD SUCCEEDED` |
| Full test suite | ✅ **545 / 545, 0 failures** | `xcodebuild ... test` → `TEST SUCCEEDED` |
| Architecture | ✅ arm64 | `project.yml` |
| Minimum OS | ✅ macOS 15 | `project.yml` |
| Local API E2E | ✅ Passed | OpenAI, Anthropic, SSE, auth, concurrency tests |
| Workspace trust boundary | ✅ Covered | MCP and hook default-deny regression tests |
| Session encryption failure | ✅ Covered | fail-closed persistence regression test |
| Redirect host validation | ✅ Covered | lookalike-host regression test |

The test runner emitted existing SwiftUI runtime warnings in some UI-hosted
tests. They did not cause failures, but should remain a follow-up for UI
polish. The generated `.derived` directory is ignored build output and is not
part of the release artifact.

## 2. Hardening completed

| Area | Previous risk | Current behavior |
| --- | --- | --- |
| Project MCP | Local config auto-spawned processes and inherited credentials | Local MCP is disabled by default, enabled only for an explicitly trusted workspace, and receives a sanitized environment |
| MCP name collisions | Workspace config could replace a user server | User-global server names win; local collisions are rejected |
| Project hooks | Local hooks ran without an explicit trust decision | Workspace hooks follow the same per-workspace trust switch and run with a sanitized environment and 30-second hard cap |
| Session storage | Encryption failure silently wrote plaintext | Save aborts; no plaintext downgrade occurs |
| Local API state | Concurrent requests could interleave engine history | Reset/replay/generation are serialized through a request gate |
| Local API browser access | Arbitrary origins were reflected in CORS | CORS is opt-in through an origin allowlist; default is no CORS |
| Local API resources | Completed tasks accumulated; slow clients had no read timeout | Connection IDs are removed on completion, active connections are capped, and reads have an idle timeout |
| App API startup | API was open by default when enabled and settings changes could race | The app generates a per-run bearer token and uses generation-based reconciliation |
| Browser navigation | `file://` could be opened | Browser navigation accepts only HTTP(S) |
| Browser screenshots | Paths bypassed workspace resolution and could collide | Paths are workspace-resolved and use UUID filenames |
| Hugging Face redirects | Lookalike hosts could retain `Authorization` | Only `huggingface.co` and its subdomains retain the header |
| Project prompt injection | Project text claimed to override defaults | Project instructions are explicitly treated as untrusted guidance and cannot override safety policy |

## 3. Runtime logic

```text
User opens workspace
        │
        ├── Settings trust switch OFF ──┐
        │                               ├── user MCP only
        │                               └── user hooks only
        │
        └── Settings trust switch ON ───┐
                                        ├── user MCP + local MCP
                                        └── user hooks + local hooks

API request → auth → bounded connection → serialized engine gate
                                      │
                                      ├── reset shared engine
                                      ├── replay complete request history
                                      └── generate / stream → release gate
```

## 4. Public-release blockers

| Blocker | Status | Required action |
| --- | --- | --- |
| Developer ID Application certificate | ❌ External dependency | Create/restore a valid certificate and signing identity |
| Notarization credentials | ❌ External dependency | Configure Apple ID or App Store Connect notary credentials |
| Hardened runtime distribution signing | ⚠️ Not yet exercised | Sign the Release app with `--options runtime` and validate entitlements |
| DMG/ZIP packaging | ⚠️ Not automated | Add a repeatable packaging job after signing is available |
| GitHub Pages publication | ⚠️ Remote configuration | Set the real GitHub remote and enable Pages from GitHub Actions |

The app remains intentionally unsandboxed because the product runs shell,
Git, workspace, simulator, and local-model processes. This must be explained
to users and revisited before a broad public release.

## 5. Test coverage map

| Subsystem | Covered behaviors |
| --- | --- |
| Agent loop | Tool parsing, approvals, hooks, checkpoints, cancellation, memory |
| Workspace boundary | Traversal, symlinks, root replacement, read/write confinement |
| Persistence | AES-GCM round trips, redaction, legacy decode, fail-closed save |
| Local API | OpenAI, Anthropic, streaming, auth, CORS, stateless replay, concurrency |
| MCP | Config validation, trust default, stdio transport, tool approval |
| Downloads | Resumption, ETag changes, checksums, disk preflight, redirect policy |
| Intelligence | Indexing, graph edges, context compilation, MCP inspection |
| UI-adjacent flows | Composer, sessions, vision, diagnostics, model pool, end-to-end workflows |

## 6. Release procedure

```sh
xcodegen generate
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .derived build

# After a valid Developer ID identity is available:
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <team>" \
  .derived/Build/Products/Release/BeetCode.app

ditto -c -k --keepParent \
  .derived/Build/Products/Release/BeetCode.app BeetCode.zip
xcrun notarytool submit BeetCode.zip --apple-id <id> --team-id <team> --wait
hdiutil create -volname BeetCode \
  -srcfolder .derived/Build/Products/Release/BeetCode.app \
  -ov BeetCode.dmg
```

## 7. Follow-ups before 1.0

- Resolve the existing SwiftUI “publishing changes during view updates” warnings.
- Add a controlled idle-clock test for API model unloading.
- Add a hanging-MCP timeout regression test.
- Automate signed Release builds, notarization, and DMG/ZIP generation.
- Decide whether to add persistent diagnostics and a supported update channel.
