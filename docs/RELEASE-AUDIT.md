# Beet Code — Release Audit (v0.8.2 / build 7)

Generated 2026-08-20 for the v0.8.2 / build 7 release candidate. This audit
describes the current source tree; the tree must be committed and tagged
before the results can be treated as a release record.

## Verdict

**Engineering release candidate: PASS. Public macOS distribution: BLOCKED.**

The application builds in Debug and Release, the CLI target builds, and the
full suite passes. The Release app has a valid Apple Development signature,
but it is not signed for public distribution: it enables `get-task-allow`,
does not enable the hardened runtime, is not notarized, and is rejected by
Gatekeeper. A new, non-revoked Developer ID Application certificate and a
notarization/stapling flow are required before publishing a download.

## 1. Evidence summary

| Check | Result | Evidence |
| --- | --- | --- |
| XcodeGen regeneration | PASS | `xcodegen generate` completed with XcodeGen 2.46.0; the generated `project.pbxproj` SHA-256 was unchanged. |
| Debug app test suite | PASS | `xcodebuild test` completed with **632 passed, 1 skipped, 0 failures (633 total)**. |
| CI-parity unsigned suite | PASS | The GitHub Actions command with `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, and `ONLY_ACTIVE_ARCH=YES` completed with **632 passed, 1 skipped, 0 failures (633 total)**. |
| Release app build | PASS | `xcodebuild ... -configuration Release ... build` returned `BUILD SUCCEEDED`. |
| CLI build | PASS | `xcodebuild ... -scheme BeetCodeCLI ... build` returned `BUILD SUCCEEDED`. |
| Bundle metadata | PASS | `com.beetcode.app`, display name `Beet Code`, version `0.8.2`, build `7`, minimum macOS `15.0`, arm64. |
| Signature integrity | PASS | `codesign --verify --deep --strict` reported the app valid on disk and satisfying its designated requirement. |
| Public distribution signature | BLOCKED | Release settings use `Apple Development`; the Release signature carries `get-task-allow=true`. |
| Hardened runtime | BLOCKED | Release settings report `ENABLE_HARDENED_RUNTIME=NO`. |
| Gatekeeper assessment | BLOCKED | `spctl --assess --type execute` rejected the Release app. |
| DMG packaging script | PARTIAL | `scripts/package-beetcode-dmg.sh` is executable and passes `bash -n`; it creates a UDZO DMG and SHA-256 file but does not sign, notarize, staple, or assess the app. |
| License | PASS | MIT license is present at the repository root. |
| CI coverage | PARTIAL | macOS build/test CI is present; no automated release, signing, notarization, or artifact-publishing workflow exists. |

The first CI-parity attempt stopped before tests because the temporary build
volume ran out of space. After removing only audit-created temporary build
directories, the identical command passed. This was an environment capacity
issue, not a product or test failure.

## 2. Release gates

### P0 — required before public download

1. **Replace development signing with distribution signing.** Obtain a valid
   `Developer ID Application` certificate. The currently listed Developer ID
   identities are revoked. Configure the Release build to use the new
   certificate and a distribution entitlements file.

2. **Enable the hardened runtime and remove development entitlements.** The
   public build must be signed with hardened runtime options and must not carry
   `com.apple.security.get-task-allow`.

3. **Notarize, staple, and verify the exact artifact.** Submit the signed ZIP
   or DMG with `xcrun notarytool`, staple the ticket, then verify with
   `spctl` on a clean machine before publishing.

4. **Create an immutable release source point.** Commit the intended changes,
   regenerate the project, rerun the audit, and tag the exact release tree.
   The current audited tree is dirty, so it is not itself a reproducible
   release reference.

### P1 — required for a dependable release process

5. **Automate release packaging.** The local DMG script is useful, but it only
   wraps an existing app. Add a protected release workflow that builds,
   signs, notarizes, staples, runs Gatekeeper verification, generates
   checksums, and publishes the artifacts.

6. **Add clean-machine smoke coverage.** Install the packaged app from the
   published artifact and exercise launch, model/provider configuration,
   workspace access, session persistence, and the CLI/server entry point.

7. **Publish artifact provenance.** Record the source tag, app version/build,
   architecture, notarization result, and SHA-256 beside each downloadable
   artifact.

### P2 — quality and 1.0 follow-up

- Add `NSHumanReadableCopyright` to the bundle metadata.
- Add persistence coverage for diagnostics across relaunches.
- Add timeout-path coverage for a hanging MCP server.
- Add live-provider, live-browser, and live-vision smoke tests where stable
  credentials and test fixtures are available.
- Keep the arm64-only and App Sandbox-off decisions prominent in release notes;
  both are current product constraints, not accidental omissions.

## 3. Current build and signing configuration

The source-of-truth configuration is `project.yml`:

- Deployment target: macOS 15.0
- Architecture: arm64 only (`x86_64` excluded)
- Swift: 6.0
- App identifier: `com.beetcode.app`
- Version/build: `0.8.2` / `7`
- App Sandbox: disabled, because the agent requires workspace, shell, and git
  access
- Release signing identity: `Apple Development`
- Hardened runtime: disabled

There are no entitlements files in the repository. The current Release app
does have the development `get-task-allow` entitlement, confirming that the
local Release configuration is not a public-distribution configuration.

## 4. Functional coverage verified by the suite

The passing suite covers the current provider and hybrid-surface work,
including streamed reasoning/transcript state, remote-session controller
behavior, provider parsing and tool-call fragments, agent loops and tools,
BYOK/provider flows, persistence and migration, local API/MCP surfaces,
diagnostics, model/context management, import/export, and the macOS app/CLI
targets. The controller-level reasoning regression confirms that an emitted
reasoning event survives into transcript state, and the stop regression
confirms that cancelling an active generation reaches a cancelled terminal
state.

This is automated coverage only. It does not prove that every external model
provider, live browser/simulator integration, notarized download, or clean
machine launch works without the corresponding external credentials and
environment.

## 5. Source and repository hygiene

- `git diff --check`: PASS.
- No credential-bearing artifact extensions (`.p8`, `.pem`, `.key`,
  `.mobileprovision`, `.cer`, or `.env`) were found in the audited tree.
- Token/path-pattern matches were limited to test fixtures, normal system-path
  handling, and diagnostic/tool implementation; no credential value was
  observed.
- The repository has an MIT `LICENSE`.
- The working tree contains substantial uncommitted product changes and new
  files. Those changes were preserved and are intentionally included in this
  audit's scope.

## 6. Repeatable verification commands

Run from the repository root:

```sh
xcodegen generate
git diff --check

xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/beetcode-ci-audit \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=YES test

xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/beetcode-release-audit build

xcodebuild -project BeetCode.xcodeproj -scheme BeetCodeCLI \
  -destination 'platform=macOS' build

codesign --verify --deep --strict --verbose=2 \
  /path/to/BeetCode.app
spctl --assess --type execute --verbose=4 \
  /path/to/BeetCode.app

./scripts/package-beetcode-dmg.sh /path/to/BeetCode.app
```

The final two checks must be repeated after distribution signing,
notarization, and stapling. The packaging script writes to `dist/` and emits
`BeetCode-<version>.dmg` plus its `.sha256` file.

## 7. Release checklist

- [ ] Commit the intended source tree and tag the release.
- [ ] Obtain a non-revoked Developer ID Application certificate.
- [ ] Configure hardened runtime and distribution entitlements.
- [ ] Build the Release app from the tagged tree.
- [ ] Sign all nested code and the app with a timestamp.
- [ ] Package the DMG/ZIP and generate checksums.
- [ ] Submit to Apple notarization and wait for acceptance.
- [ ] Staple the notarization ticket.
- [ ] Verify `codesign`, `spctl`, and installation on a clean Mac.
- [ ] Publish artifacts with version/build, source tag, and SHA-256.

**Final status:** the codebase is ready for continued engineering and
internal testing. It is not ready for a public macOS download until P0 gates
1–4 are closed.
