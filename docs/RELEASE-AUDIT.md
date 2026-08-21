# Beet Code — Release Audit (v0.9.1 / build 14)

Generated 2026-08-21. This audit covers the v0.9.1 release built
from this checkout. The release updates the local-model path, transcript
rendering, model metadata/import handling, and the public download links.

## Verdict

The source and Release app passed the final desktop smoke check and v0.9.1 is
published. The app is signed with the existing Apple Development identity;
Developer ID, hardened runtime, notarization, and Gatekeeper-clean delivery
remain intentionally out of scope for this release.

Release source commit: `9b8f5ba` (`release: BeetCode 0.9.1 local model reliability`).
Published tag commit: `d8f8b74` (`v0.9.1`). The source commit is immutable;
this audit entry records the packaged app artifacts built from it.

## 1. Release identity

| Field | v0.9.1 |
| --- | --- |
| Bundle ID | `com.beetcode.app` |
| Display name | Beet Code |
| Version / build | **0.9.1 / 14** |
| Deployment target | macOS 15.0 |
| Architecture | arm64 |
| Swift | 6.0 |
| App Sandbox | disabled (workspace, shell, and git access) |
| Release signing | Apple Development, team `438VSM6P5L` |

## 2. Local-model compatibility matrix

| Model structure | Dispatch | Compatibility check |
| --- | --- | --- |
| MLX/safetensors language model with root `config.json` | In-process MLX LLM factory | Qwen2.5, Qwen3, and Qwen3.5 text layouts are covered by metadata and engine tests |
| MLX/safetensors multimodal model with nested `text_config` and vision metadata | In-process MLX VLM factory | Qwen3.5 2-bit layout is recognized as multimodal; the real model name is retained when the leaf folder is only `2-bit` |
| Sharded MLX weights (`model-00001-of-…`, index JSON) | In-process MLX LLM/VLM factory | The completeness check accepts the shard files and the loader receives the model directory |
| GGUF file or folder containing a GGUF file | `llama-server` engine | Header metadata supplies architecture/context when available; Qwen2.5, Qwen3, and Llama 3.1 smoke-tested |
| Quantization-only folder names (`2-bit`, `4bit`, `8-bit`) | Same format-specific engine | Import IDs and display names include the parent model identity |
| Incomplete snapshot or config-only folder | Refused before loading | `.incomplete` markers and missing weight files remain non-loadable |

All local engines now share one transcript cleanup path: thinking blocks and
chat-template control tokens are removed from the visible answer, while
Markdown lists, code fences, line breaks, and indentation are preserved.
Explicit short requests such as “Reply with exactly OK.” are normalized only
when no tool call is produced; ordinary prose is left untouched.

## 3. Verification evidence

| Check | Result | Evidence |
| --- | --- | --- |
| Release build | PASS | `xcodebuild -scheme BeetCode -configuration Release ... build` |
| Bundle metadata | PASS | Release app reports `0.9.1` / `14` |
| Code signature | PASS | `codesign --verify --deep --strict` on the Release app |
| Focused local-model/prompt tests | PASS | 30 tests, 0 failures: `MLXModelInspectorTests`, `PromptCapabilityGuidanceTests`, and `ReasoningTests` |
| Llama/Qwen GGUF response smoke | PASS | Fresh v0.9.1 Llama 3.1 smoke returned exactly `OK`; Qwen2.5 and Qwen3 8B also returned clean short answers in the preceding GGUF checks |
| 2-bit model identity | PASS | Picker displays `Qwen3.8 27B Uncensored MLX`; `2-bit` is no longer the human-facing name |
| 16 GB admission | PASS | The 27B 2-bit model is visibly disabled when it cannot fit the current machine |
| `git diff --check` | PASS | Clean before staging |
| Public links | PASS | README, release page, and GitHub Pages buttons target `BeetCode-0.9.1.zip` |
| GitHub release | PASS | [v0.9.1 release](https://github.com/Mesutcydev/beet-code/releases/tag/v0.9.1) is public with ZIP, DMG, and both checksum sidecars |
| GitHub Pages | PASS | [Pages workflow 32470039365](https://github.com/Mesutcydev/beet-code/actions/runs/32470039365) completed successfully from `main` |

### Packaged artifacts

| Artifact | SHA-256 |
| --- | --- |
| `BeetCode-0.9.1.zip` | `5c00b885bef3d388ca4a73bd821a9402ef2e2d48183a9bd0d11780598a1b7489` |
| `BeetCode-0.9.1.dmg` | `cabc10c146a7e2169d43220cedfd51a4501232596a153d1cfb438c4e9f39be7b` |

## 4. Release gates

1. **PASS** — Commit the intended source, tests, and release documentation;
   keep derived build directories out of git.
2. **PASS** — Push `release/v0.9.1`, fast-forward `main`, and create tag
   `v0.9.1`.
3. **PASS** — Package the signed Release app as ZIP/DMG and write SHA-256
   sidecars.
4. **PASS** — Publish the assets to the GitHub release and wait for the Pages
   workflow.
5. **PASS** — Release URL and workflow result recorded above.

## 5. Distribution signing

The public build intentionally remains Apple Development signed. Do not switch
to the revoked Developer ID identity, enable hardened runtime, strip
`get-task-allow`, or add a notarization step in this release. README keeps the
right-click **Open** / `xattr -dr com.apple.quarantine` guidance for this
distribution choice.

## 6. Repeatable verification

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

codesign --verify --deep --strict --verbose=2 /path/to/BeetCode.app
```
