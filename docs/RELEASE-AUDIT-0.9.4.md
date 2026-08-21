# Beet Code — Release Audit (v0.9.4 / build 17)

Generated 2026-08-21. This audit covers the native UX simplification,
composer and history polish, coding-tool interoperability, Apple app delivery,
first-run readiness, regression testing, and packaged release artifacts.

## Verdict

The full deterministic suite, Release build, arm64 architecture check,
signature verification, installed-app metadata, and ZIP/DMG integrity checks
passed. The release is suitable for Apple Silicon Macs running macOS 15 or
later.

The app is signed with a valid Apple Development identity. It is **not**
Developer ID-notarized, so a Gatekeeper warning remains expected for public
downloads until a valid Developer ID Application certificate is available.

Release source branch: `release/v0.9.4`.
Published tag: `v0.9.4`.

## 1. Release identity

| Field | v0.9.4 |
| --- | --- |
| Bundle ID | `com.beetcode.app` |
| Display name | Beet Code |
| Version / build | **0.9.4 / 17** |
| Deployment target | macOS 15.0 |
| Architecture | arm64 only |
| Swift | 6.0 |

## 2. Product outcomes

- A compact first-run readiness assistant connects a project and model, then
  reports Xcode, signing identity, and physical-device status.
- The composer, model selection, remote access, empty states, and high-traffic
  actions share a quieter native capsule-button language.
- Chat history separates native and imported tasks, groups imported history by
  project, and supports current Claude, Codex, and Cursor data layouts.
- Skills and declarative plugins are discovered from Claude Code, Codex,
  Cursor, Copilot, Windsurf, OpenCode, Agent Skills, or a connected IDE folder.
- Ship Center can verify, archive, sign, package, hash, install to a connected
  iPhone or iPad, and optionally hand an archive to Xcode for App Store Connect
  upload.
- Changed-file review and isolated worktrees make agent edits easier to inspect,
  reject, and recover.

## 3. Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Full deterministic suite | PASS | 710 tests executed, 1 skipped, 0 failures |
| Release build | PASS | `BUILD SUCCEEDED` for v0.9.4 build 17 |
| Architecture | PASS | Installed executable is Mach-O 64-bit arm64 |
| Bundle metadata | PASS | `/Applications/BeetCode.app` reports 0.9.4 / 17 |
| Signature verification | PASS | `codesign --verify --deep --strict` |
| ZIP integrity | PASS | `unzip -tq` reports no errors |
| DMG integrity | PASS | `hdiutil verify` reports a valid checksum |
| Source hygiene | PASS | `git diff --check` |
| Public link sources | PASS | README and Pages target `BeetCode-0.9.4.zip` |

### Packaged artifacts

| Artifact | SHA-256 |
| --- | --- |
| `BeetCode-0.9.4.zip` | `5f2dd3a8682d6130519faa9cd78a92969f62a8eeb43ef87867cebf23eee42051` |
| `BeetCode-0.9.4.dmg` | `a875a1d400a193d55e546617a71989fb12961edd84ff25d56918a17ab29cfcfe` |

## 4. Public release

- GitHub release: https://github.com/Mesutcydev/beet-code/releases/tag/v0.9.4
- Latest ZIP: https://github.com/Mesutcydev/beet-code/releases/latest/download/BeetCode-0.9.4.zip
- GitHub Pages: https://mesutcydev.github.io/beet-code/

## 5. Distribution boundary

Developer ID Application signing, hardened-runtime validation, notarization,
and a clean Gatekeeper download path remain blocked by the absence of a valid
Developer ID identity. App Store Connect upload and physical-device install
are implemented and regression-tested at the command/configuration layer; a
live upload and live device install still require the user's Apple account,
provisioning profile, app project, and connected device.
