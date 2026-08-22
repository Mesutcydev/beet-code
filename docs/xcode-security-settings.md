# Xcode Security Settings

Security build-setting decisions for Beet Code. This document records what
was evaluated so future release audits can build on the decision instead of
silently changing the runtime model.

## Enabled settings

- `ARCHS` to `arm64`: Beet Code is intentionally Apple Silicon only.
- `EXCLUDED_ARCHS` to `x86_64`: Intel binaries are not produced.
- `GCC_WARN_ABOUT_RETURN_TYPE` to `YES_ERROR`: active in the generated Xcode project.
- `GCC_WARN_UNINITIALIZED_AUTOS` to `YES_AGGRESSIVE`: active in the generated Xcode project.
- `GCC_WARN_64_TO_32_BIT_CONVERSION` to `YES`: active in the generated Xcode project.
- `CLANG_WARN_EMPTY_BODY` to `YES`: active in the generated Xcode project.
- `ENABLE_HARDENED_RUNTIME` to `YES`: signed builds opt into hardened runtime
  protections even while public notarization remains unavailable.
- `SWIFT_STRICT_CONCURRENCY` to `complete`: the app and CLI are checked under
  the full Swift concurrency model.

The app, CLI, and tests contain Swift sources only. Clang analyzer settings
for project-owned C, C++, and Objective-C sources are therefore not applicable.
Third-party Swift packages compile from their own upstream settings.

## Disabled settings

- `ENABLE_APP_SANDBOX`: intentionally disabled. A coding agent must launch
  developer tools and read/write the project folders the user explicitly
  selects. Workspace realpath confinement, per-action approval, sanitized
  child environments, and git checkpoints are the compensating controls.

## Deferred

- `ENABLE_ENHANCED_SECURITY`: Requires arm64e pointer authentication plus
  hardened-process v2 entitlements. Beet Code links MLX and other external
  Swift packages and launches signed helper processes, so this needs a
  dedicated compatibility pass and a valid distribution identity before it
  can be enabled safely.
- `ENABLE_POINTER_AUTHENTICATION`: Deferred with Enhanced Security. The
  current product contract is arm64 and every dependency must first be
  confirmed to ship compatible arm64e slices.
- Developer ID signing and notarization: the current public package remains
  Apple Development-signed because no valid Developer ID identity is
  installed. Re-sign, notarize, and Gatekeeper-test when one is available.
- `com.apple.security.hardened-process.checked-allocations`: Hardware memory
  tagging is a later opt-in after Enhanced Security compatibility is proven.
