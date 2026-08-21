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

The app, CLI, and tests contain Swift sources only. Clang analyzer settings
for project-owned C, C++, and Objective-C sources are therefore not applicable.
Third-party Swift packages compile from their own upstream settings.

## Disabled settings

No security setting is explicitly disabled in `project.yml`. Xcode currently
resolves Enhanced Security, pointer authentication, and hardened runtime to
their default `NO` values because the project does not opt in.

## Deferred

- `ENABLE_ENHANCED_SECURITY`: Requires arm64e pointer authentication plus
  hardened-process v2 entitlements. Beet Code links MLX and other external
  Swift packages and launches signed helper processes, so this needs a
  dedicated compatibility pass and a valid distribution identity before it
  can be enabled safely.
- `ENABLE_POINTER_AUTHENTICATION`: Deferred with Enhanced Security. The
  current product contract is arm64 and every dependency must first be
  confirmed to ship compatible arm64e slices.
- `ENABLE_HARDENED_RUNTIME`: The current public package is Apple
  Development-signed because the available Developer ID identities are
  revoked. Enable, sign, notarize, and Gatekeeper-test this together when a
  valid Developer ID Application identity is installed.
- `com.apple.security.hardened-process.checked-allocations`: Hardware memory
  tagging is a later opt-in after Enhanced Security compatibility is proven.
