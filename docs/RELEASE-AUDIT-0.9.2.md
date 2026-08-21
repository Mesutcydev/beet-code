# Beet Code — Release Audit (v0.9.2 / build 15)

Generated 2026-08-21. This audit covers the v0.9.2 release built from the
native Dark-mode default change and the already-verified local-model fixes.

## Verdict

The source, focused settings tests, Release app, installed app, and packaged
artifacts passed the final checks. v0.9.2 is the current public release. The
app is signed with the existing Apple Development identity; Developer ID,
hardened runtime, notarization, and Gatekeeper-clean delivery remain out of
scope.

Release source commit: `e8c5ac1` (`release: BeetCode 0.9.2 native Dark default`).
Published tag: `v0.9.2` (the release-audit commit below the source commit).

## 1. Release identity

| Field | v0.9.2 |
| --- | --- |
| Bundle ID | `com.beetcode.app` |
| Display name | Beet Code |
| Version / build | **0.9.2 / 15** |
| Deployment target | macOS 15.0 |
| Architecture | arm64 |
| Swift | 6.0 |

## 2. Appearance behavior

- Fresh settings stores register native Dark as the default.
- An existing saved `beet` appearance is migrated once to native Dark.
- Beet remains an explicit appearance choice and was selected successfully in
  the installed app, then switched back to Dark.
- Settings copy now identifies Dark as the default and explains all four
  appearance choices.

## 3. Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Release build | PASS | `xcodebuild -scheme BeetCode -configuration Release ... build` |
| Bundle metadata | PASS | Release app reports `0.9.2` / `15` |
| Settings migration tests | PASS | 2 tests, 0 failures: `SettingsStoreTests` |
| Installed app | PASS | `/Applications/BeetCode.app` reports `0.9.2` / `15` |
| Live default appearance | PASS | Installed app opens with native Dark; persisted value is `appearance = dark` |
| Beet compatibility | PASS | Settings picker exposes and activates Beet, then returns to Dark |
| Prior local-model gates | PASS | v0.9.1 audit retained the 30 focused local-model/prompt tests and GGUF smoke checks |
| `git diff --check` | PASS | Clean before staging |
| Public links | PASS | README and GitHub Pages buttons target `BeetCode-0.9.2.zip` |

### Packaged artifacts

| Artifact | SHA-256 |
| --- | --- |
| `BeetCode-0.9.2.zip` | `4fe18b1dda218bc8dfdb4d41be66ec96dc07cba92730333dbdacd19193cd6318` |
| `BeetCode-0.9.2.dmg` | `ceb1b3e73ba104cc6578db89124034c181ffb14428d0f16e5effab0041dc7b2c` |

## 4. Public release

- GitHub release: https://github.com/Mesutcydev/beet-code/releases/tag/v0.9.2
- Latest ZIP: https://github.com/Mesutcydev/beet-code/releases/latest/download/BeetCode-0.9.2.zip
- GitHub Pages: https://mesutcydev.github.io/beet-code/

## 5. Release gates

1. **PASS** — Commit the appearance change, migration tests, version metadata,
   README, and Pages links.
2. **PASS** — Push `release/v0.9.2`, fast-forward `main`, and create tag
   `v0.9.2`.
3. **PASS** — Package the signed Release app as ZIP/DMG and write SHA-256
   sidecars.
4. **PASS** — Publish the assets to the GitHub release and verify the Pages
   workflow completes successfully.
