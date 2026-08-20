# Contributing

## Build & test

```sh
xcodegen generate          # requires USER to be set (it is, normally)
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -destination 'platform=macOS' test
```

No model weights or Metal device are needed for the test suite.

Pull requests also run the same generated-project build and macOS test suite
in GitHub Actions. If you change `project.yml`, regenerate the project before
testing; the generated `BeetCode.xcodeproj` is intentionally ignored.

Before opening a PR:

```sh
git diff --check
xcodegen generate
xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Provider fixes should include a sanitized contract fixture or a focused test;
UI changes should include a short before/after note and the interaction that
was manually verified. Never commit API keys, model weights, session exports,
or screenshots containing private workspace data.

## Ground rules for the intelligence layer

1. **Deterministic or it doesn't ship.** Retrieval, ranking, capsules, and
   impact reports must be pure functions of the stores. If a feature needs
   an LLM, it belongs in the agent loop, not in `Core/Intelligence`.
2. **Provenance is mandatory.** Anything derived from a semantic provider
   (LSP/SCIP) upgrades the `intelligenceSource` label — it never blends
   with syntactic facts.
3. **Tests are the contract.** Every module ships with XCTest coverage that
   runs against real temp workspaces / real SQLite / real git. No mocks of
   the layer's own stores.
4. **Degrade, don't crash.** A hostile or corrupt workspace must reduce
   context quality, never session stability.
5. **Don't claim unimplemented support.** Language adapters, framework
   adapters, and embedding providers exist only where code and tests exist.

## Layout

- `App/` — SwiftUI shell (UI depends on Core, never the reverse)
- `Core/Intelligence/` — the workspace intelligence layer (see
  [ARCHITECTURE.md](ARCHITECTURE.md))
- `CLI/` — the `lf` command-line tool (`lf intel …` included)
- `Tests/` — XCTest suites mirroring Core modules

## Pull requests

Keep them scoped. Run the full suite before submitting. If you change the
knowledge schema or the packet format, update `KNOWLEDGE_MODEL.md` /
`CONTEXT_COMPILER.md` in the same PR.
