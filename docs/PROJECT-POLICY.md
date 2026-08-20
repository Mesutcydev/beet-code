# Project policy

Beet Code can load a non-secret project policy from the workspace root:

- `.beetcode.json`
- `.beetcode.jsonc` (comments and trailing commas are accepted)

The normal `.json` file wins when both exist. Credentials are never read from
this file; provider keys stay in the macOS Keychain.

## Example

```jsonc
{
  "version": 1,
  "agent": "build",
  "model": "deepseek-chat",
  "plan": true,
  "goal": false,
  "verifyAfterEdits": true,
  "outputStyle": "concise",
  "contextPaths": ["Sources", "Tests"],
  "allowedTools": ["read_*", "search", "list_directory", "apply_patch", "build_diagnostics"],
  "deniedTools": ["computer_*"],
  "permissions": [
    { "action": "shell", "resource": "rm *", "effect": "deny" }
  ]
}
```

`allowedTools` is an allow-list when present; `deniedTools` wins if a tool
matches both. Permission rules are merged with the imported OpenCode rules and
still pass through Beet Code’s normal approval gate. The `agent` field accepts
native `build`/`plan` profiles plus OpenCode-compatible aliases such as
`reviewer` and `tester` for delegated work.

The `model` value is a project hint and is shown to the active agent. Selecting
the actual local or API engine remains an explicit user action in the model
picker, so opening a repository cannot silently load a model or contact a
provider.
