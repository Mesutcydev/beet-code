# Release Audit — Workspace Intelligence (2026-08-19)

Audit of the BeetCode tree including the new Workspace Intelligence layer
(Phases 0–22), run before creating the public repository.

## Verdict: PASS (with notes)

## Checks

| # | Check | Result |
|---|---|---|
| 1 | Secrets in source (API keys, tokens, private keys) | **Clean** — only false-positive prose in `.derived/` build artifacts (not shipped) |
| 2 | Personal/proprietary identifiers (`DEVELOPMENT_TEAM`, home paths, org names) | **Clean** — none in `project.yml`, plist, or sources |
| 3 | Debug residue (`TODO`/`FIXME`/`HACK`) | **Clean** — zero in `Core/`, `App/` |
| 4 | `print()` in `Core/` | Only CLI/MCP-stdio output paths (intended) |
| 5 | Debug + Release builds | **Both succeed**; zero warnings from `Core/Intelligence/` |
| 6 | Full test suite | **490 tests, 0 failures** |
| 7 | License | Added `LICENSE` (MIT) |
| 8 | Docs | `README.md` (intelligence section added), `ARCHITECTURE.md`, `CONTEXT_COMPILER.md`, `KNOWLEDGE_MODEL.md`, `SDK.md`, `BENCHMARKS.md`, `SECURITY.md`, `SECURITY-BOUNDARIES.md`, `CONTRIBUTING.md` |
| 9 | CLI smoke (real binary, real repo) | `lf intel index/search/impact` on BeetCode itself: 177 files / 1.56 s, correct answers |
| 10 | Data hygiene | No workspace content committed; all intelligence stores live under Application Support; `beetcode-models/` and `.derived/` gitignored |

## Notes (accepted, not blockers)

- **App sandbox is off** (`ENABLE_APP_SANDBOX: NO`) — a deliberate upstream
  design decision: a coding agent needs shell/git/process access.
  Confinement is enforced in code (`AgentTool` realpath containment,
  `PathSafety`) instead of by the kernel sandbox.
- **Pre-existing warnings** in `Core/MCP/MCPOAuth.swift`, `ShellRunner.swift`,
  etc. (concurrency annotations, unused results) — upstream code, outside
  this audit's scope; none are in the intelligence layer.
- **Signing**: `CODE_SIGN_STYLE: Automatic`, ad-hoc identity for local
  builds. Distribution signing is a release-engineering decision left to the
  maintainers.

## Reproduce

```sh
xcodegen generate
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -destination 'platform=macOS' test          # 490 tests
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -configuration Release build                # release build
```
