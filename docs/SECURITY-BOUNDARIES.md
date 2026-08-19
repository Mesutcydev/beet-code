# Security Boundaries — Workspace Intelligence

Phase 19 hardening. The intelligence layer reads untrusted repository
content; these are the explicit trust boundaries and where each is enforced.

## Trust model

| Zone | Trust | Rule |
|---|---|---|
| App code (`Core/`, `App/`) | Trusted | Ships signed with the app. |
| Workspace file contents | **Untrusted data** | Never executed, never interpreted as instructions, never leaves the workspace boundary. |
| Knowledge store | Semi-trusted | Only accepts proposals that passed the pipeline (evidence + secret scan + injection scan). |
| Git history | Untrusted data | Read via fixed-argument `/usr/bin/git`; no shell, no config influence (`GIT_CONFIG_NOSYSTEM=1`). |
| Semantic providers (LSP) | Semi-trusted | Can only *upgrade* provenance labels on exact name+line matches; cannot inject symbols. |

## Boundaries and enforcement

1. **Prompt injection from repository text** — `PromptInjectionSanitizer`
   (SecurityCore) redacts instruction-like lines (override phrasing, role
   markers, exfiltration phrasing) from source snippets before they enter a
   `ContextPacket`. The knowledge pipeline *rejects* proposals containing
   such content outright.
2. **Secret persistence** — `SecretScanner` blocks secret-shaped content
   from the knowledge store. Secret *references* (env var names) are
   recorded as entities; secret *values* are never read or stored.
3. **Path traversal / symlink escape** — `PathSafety.resolve` canonicalizes
   with realpath semantics and rejects anything outside the workspace root,
   both lexically (`..`) and after symlink resolution.
4. **Ignored paths** — the scanner honors nested `.gitignore` (Phase 1);
   ignored files are never read.
5. **Oversized files** — files over the 64 MB hash budget are tracked but
   never read into memory (Phase 1).
6. **Binary files** — `BinaryContentDetector` (NUL bytes / invalid UTF-8 in
   the first 8 KB) excludes binaries from parsing and prompting.
7. **Malformed parsers** — parser output is best-effort and total: garbage
   input degrades to partial symbols, never a crash (fuzz-tested).
8. **SQLite corruption** — stores throw typed `StoreError`s on open; a
   corrupt database fails the layer, not the session. All store data is
   derived: delete → re-index.
9. **Poisoned semantic indexes** — LSP upgrades require an exact
   name+position match against syntactic parse output (Phase 5); a hostile
   or broken server cannot fabricate symbols.
10. **Malicious memory proposals** — agent-originated knowledge requires
    verifiable evidence (current file hashes, existing symbols) and passes
    secret + injection scans; unsupported claims are rejected (Phase 9+19).
11. **Unsafe project rule injection** — repository rule files are context
    *data*: they flow through the same sanitizer and are labeled by
    confidence, never granted system-prompt authority.
12. **In-app browser `file://`** — agent `browser_navigate` may only open
    `http(s)` or a `file://` path that `Workspace.resolve` accepts. User
    chrome may open local files they typed. `javascript:` / `data:` rejected.
13. **Computer use** — observation is `.read`; every click/key/scroll is
    `.execute` and cannot be auto-approved (no `command` argument). Logout,
    lock, force-quit, and `cmd+q` are hard-blocked. `AXSecureTextField`
    values are redacted before they enter the model context. Coordinates
    stay in Quartz/AX space (top-left of the main display).

## Failure principle

A failed verification, a corrupt store, or a hostile repository must never
crash the session or fabricate intelligence — the layer degrades to less
context, explicitly labeled.
