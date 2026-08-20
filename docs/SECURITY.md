# Security Model

BeetCode is local-first: inference runs on-device (MLX) or through your own
API keys (BYOK). Workspace intelligence reads your repository but treats it
as **untrusted data**.

## Boundaries (enforced + tested)

The full boundary catalog with enforcement points lives in
[SECURITY-BOUNDARIES.md](SECURITY-BOUNDARIES.md) (Phase 19). Summary:

- **Workspace confinement** — every file read resolves through realpath
  containment (`PathSafety`, `AgentTool`); `..` traversal and symlink
  escapes are rejected lexically and after resolution.
- **Prompt injection** — repository text is sanitized before it can enter a
  prompt (`PromptInjectionSanitizer`); knowledge proposals containing
  instruction-like content are rejected at the pipeline.
- **Secrets** — secret-shaped content never enters durable stores
  (`SecretScanner`); secret *references* (env var names) are recorded,
  values never are.
- **Git** — invoked as `/usr/bin/git` with fixed arguments and a sanitized
  environment (`GIT_CONFIG_NOSYSTEM=1`, no terminal prompts).
- **Stores** — SQLite in WAL mode under Application Support; corruption
  fails the layer, never the session; everything is re-derivable.
- **Shell policy** — exact safe-command auto-approval; operators,
  substitution, redirection, and outside paths always ask.
- **Project automation** — workspace MCP servers and hooks are disabled by
  default. The user must trust the exact workspace path before local
  configuration is loaded; enabled subprocesses receive a sanitized
  environment and hooks have a hard timeout cap.
- **Local API** — the optional loopback server uses a per-run bearer token,
  bounded connections, serialized engine access, and an explicit CORS
  allowlist. It is not a public network service.

The full release verification, runtime diagrams, and remaining distribution
blockers are in [RELEASE-AUDIT.md](RELEASE-AUDIT.md). The visual architecture
and logic explainer is in [`docs/site`](site/), ready for GitHub Pages.

## Reporting

Open an issue titled `[security] …` or contact the maintainers privately if
the issue is sensitive. Do not attach secrets or personal data.
