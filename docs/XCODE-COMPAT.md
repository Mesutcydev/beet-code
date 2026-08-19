# Xcode 26 + 27 compatibility

Beet Code is built from one `project.yml`. Verified on this machine:

| Toolchain | Version | macOS SDK | Result |
|---|---|---|---|
| `/Applications/Xcode.app` | 26.6 (17F113) | 26.5 | Release build |
| `/Applications/Xcode-beta.app` | 27.0 (27A5218g) | 27.0 | Release build |

## Rules that keep both working

1. **Project format** — `options.projectFormat: xcode16_0` (objectVersion 77). Opens in Xcode 26 and 27.
2. **Language mode** — `SWIFT_VERSION: 6.0`. Xcode 27 ships Swift 6.3; stay on 6.0 mode so 26 does not need newer syntax.
3. **Deployment** — macOS 15.0. Use `#available(macOS 26.0, *)` for Liquid Glass and `posix_spawn_file_actions_addchdir` (the `_np` variant is the 15.x fallback).
4. **WKWebView** — never construct in a `nonisolated` init. `BrowserController` creates the view on first MainActor access.
5. **MLX** — `MLX.Memory.cacheLimit = …` (not deprecated `MLX.GPU.set(cacheLimit:)`).
6. **GGUF / llama-server** — launch flags `--ctx-size`, `--n-gpu-layers`, `--no-webui`, `--spec-type draft-mtp`, `--spec-draft-n-max` are current llama.cpp. Old `--draft-n` / `--draft-max` were removed; do not resurrect them.

## How to verify

```sh
xcodegen generate

# Xcode 26
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -configuration Release -destination 'platform=macOS' build

# Xcode 27
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -configuration Release -destination 'platform=macOS' build
```
