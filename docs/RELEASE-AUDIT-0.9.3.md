# Beet Code — Release Audit (v0.9.3 / build 16)

Generated 2026-08-21. This audit covers the structured API-answer and
reasoning-rendering fixes, their regression tests, and the v0.9.3 packaged
release artifacts.

## Verdict

The focused parser/reasoning tests, full deterministic test suite, Release
app, signature verification, and packaged artifacts passed the final checks.
The app is signed with the existing Apple Development identity; Developer ID,
hardened runtime, notarization, and Gatekeeper-clean delivery remain out of
scope.

Release source branch: `release/v0.9.3`.
Published tag: `v0.9.3`.

## 1. Release identity

| Field | v0.9.3 |
| --- | --- |
| Bundle ID | `com.beetcode.app` |
| Display name | Beet Code |
| Version / build | **0.9.3 / 16** |
| Deployment target | macOS 15.0 |
| Architecture | arm64 |
| Swift | 6.0 |

## 2. Answer structure behavior

- Adjacent streamed reasoning fragments are reassembled into readable
  paragraphs instead of one word or token per paragraph.
- Tool-call protocol wrappers are removed from visible answers and exports,
  including empty `<tool_call>` tags.
- Assistant Markdown preserves headings, lists, paragraphs, and code blocks
  across local and API-backed models.

## 3. Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Release build | PASS | `xcodebuild -scheme BeetCode -configuration Release ... build` |
| Bundle metadata | PASS | Release app reports `0.9.3` / `16` |
| Signature verification | PASS | `codesign --verify --deep --strict` |
| Focused regressions | PASS | 66 tests, 0 failures: reasoning, tool parser, and provider audit tests |
| Full deterministic suite | PASS | 689 passed, 1 skipped, 0 failures |
| `git diff --check` | PASS | Clean before staging |
| Public link sources | PASS | README and GitHub Pages buttons target `BeetCode-0.9.3.zip` |

### Packaged artifacts

| Artifact | SHA-256 |
| --- | --- |
| `BeetCode-0.9.3.zip` | `2874e4c4d97f6c60205ba6bd729d08139742cd30ec31ea8513b9546a17812005` |
| `BeetCode-0.9.3.dmg` | `b1b9ce64645f45ef7c7228d7e159743bae7ab2a15b1bfcd2929db255a7815bc7` |

## 4. Public release

- GitHub release: https://github.com/Mesutcydev/beet-code/releases/tag/v0.9.3
- Latest ZIP: https://github.com/Mesutcydev/beet-code/releases/latest/download/BeetCode-0.9.3.zip
- GitHub Pages: https://mesutcydev.github.io/beet-code/

## 5. Release gates

1. **PASS** — Commit the answer-structure fixes, regression tests, version
   metadata, README, audit, and Pages links.
2. **PASS** — Push `release/v0.9.3`, fast-forward `main`, and create tag
   `v0.9.3`.
3. **PASS** — Package the signed Release app as ZIP/DMG and write SHA-256
   sidecars.
4. **PASS** — Publish the assets to the GitHub release and verify the Pages
   workflow completes successfully.
