# Provider Compatibility Audit

Updated 2026-08-20. This is the implementation record for remote BYOK providers, live model discovery, and provider/tool interoperability.

## Fixed in this pass

| Area | Finding | Resolution |
| --- | --- | --- |
| LongCat endpoint | The app used the retired `api.longcat.ai` host and placeholder model IDs. | Uses `https://api.longcat.chat/openai/v1` and `LongCat-2.0`. |
| Gemini model discovery | The list loader filtered model names by the literal word `gemini`, which discarded valid aliases and future model names. | Uses `supportedGenerationMethods == generateContent`, pagination, deduplication, and actionable errors. |
| Model-list failures | Fetch failures were converted to an empty list and displayed as a failed connection test. | Errors remain visible beside the model picker; the Test action has its own status. |
| Saved model UX | A manually saved model could disappear from the picker when live models were present. | The selected model is always preserved in a Selected section. |
| Gemini tools | Gemini was routed through native generation but never received the registered tool declarations or function-call responses. | Registered tools are sent as Gemini `functionDeclarations`; returned `functionCall` parts are translated into the existing tool protocol. |
| Custom endpoints | Arbitrary custom URL strings could be accepted without a usable HTTP(S) host. | Custom endpoints now require an HTTP(S) scheme and host before being used. |

## Current provider matrix

| Provider family | Transport | Model discovery | Native tool envelope |
| --- | --- | --- | --- |
| OpenAI, DeepSeek, Alibaba, OpenRouter, LongCat, Custom | OpenAI-compatible `/chat/completions` | `/models` when supported | OpenAI `tools` |
| Gemini | Native `generateContent` / `streamGenerateContent` | Paginated `/models` with generation-capability filtering | Gemini `functionDeclarations` / `functionCall` |
| Anthropic | Native Messages API | `/models` | Anthropic `tools` / `tool_use` |

The app still keeps a text tool protocol as the canonical agent-loop format. Native provider calls are adapters around that protocol, so permissions, hooks, checkpoints, tool-result rendering, and verification remain shared across local and remote models.

## Comparison findings

The comparison was informed by OpenCode, Continue, and Aider patterns:

- OpenCode's provider abstraction makes endpoint, headers, model metadata, context limits, and output limits explicit. BeetCode has provider routing and real local context sizing, but remote model capability metadata is still mostly implicit.
- Continue exposes an explicit OpenAI-compatible `apiBase` and model capabilities such as tool use and image input. BeetCode supports custom OpenAI-compatible URLs and vision flags, but does not yet let users override capabilities per remote model.
- Aider makes advanced model metadata configurable, including context/output limits, streaming, temperature, and reasoning behavior. BeetCode has model-family heuristics and usage telemetry, but not a user-editable per-model override table.

## Highest-value remaining gaps

1. Add a remote-model metadata layer: context window, output limit, vision, tool calling, reasoning, and temperature support, with user overrides for unusual gateways.
2. Add per-agent model routing so exploration, implementation, verification, and subagents can use different local/remote models.
3. Add a first-class share/import format or encrypted share link; local Markdown/JSON export exists, but collaboration is still file-based.
4. Add declarative project configuration for provider/model/tool policy, while keeping Keychain secrets out of project files.
5. Add provider contract tests with recorded fixtures for `/models`, streaming SSE, tool calls, rate limits, and malformed payloads.

## Upstream references

- [LongCat API overview](https://longcat.chat/platform/docs/APIDocs.html)
- [LongCat OpenCode integration](https://longcat.chat/platform/docs/OpenCode.html)
- [Gemini generateContent API](https://ai.google.dev/api/generate-content?hl=en)
- [Gemini function calling](https://ai.google.dev/gemini-api/docs/function-calling)
- [OpenCode](https://github.com/opencode-ai/opencode)
- [OpenCode provider configuration](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/providers.mdx)
- [Continue OpenAI-compatible providers](https://github.com/continuedev/continue/blob/main/docs/customize/model-providers/top-level/openai.mdx)
- [Aider advanced model settings](https://github.com/Aider-AI/aider/blob/main/aider/website/docs/config/adv-model-settings.md)

## Verification

The full macOS Xcode test suite passes after the provider fixes and native Gemini tool adapter changes. The suite includes provider route/default checks, Gemini capability filtering, OpenAI/Anthropic/Gemini tool extraction, build diagnostics, and app scaffold checks.
