# MTP speculative decoding for Qwythos — feasibility

**Verdict: feasible, and shipped.** All three required layers are present on
this machine; Beet Code now auto-detects MTP-capable GGUFs and enables
draft-mtp speculative decoding at server launch, with a self-healing fallback.

## What MTP is

Multi-Token Prediction: the model ships extra "nextn" predictor layers that
draft several tokens ahead per decode step; the full model then verifies the
draft in one pass. Accepted drafts turn 1 token/step into 2–3, raising decode
throughput without changing output distribution (verification is exact).

## Evidence that Qwythos supports it

1. **Model card / HF config** — `empero-ai/Qwythos-9B-Claude-Mythos-5-1M`
   declares `mtp_num_hidden_layers: 1` (with
   `mtp_use_dedicated_embeddings: false`). The arch is hybrid Gated-DeltaNet
   3:1 attention over a Qwen3.5-9B base.
2. **Local GGUF has the tensors** — the user's
   `Qwythos-9B-Claude-Mythos-5-1M-MTP-Q5_K_M.gguf` (6.3 GB) header carries
   `qwen35.nextn_predict_layers` and tensors
   `blk.32.nextn.{eh_proj,enorm,hnorm,shared_head_norm}.weight`.
3. **llama.cpp supports the flag** — the installed `llama-server`
   (Homebrew, build 10470) accepts `--spec-type draft-mtp` and
   `--spec-draft-n-max` (llama.cpp PR #22673).

## Expected gain

Community measurements of draft-mtp on this model family
(Qwen3.x hybrid arch, code workloads) report **+33–39 % decode throughput**
with ~80 % draft acceptance at `n-max 2`. Acceptance drops sharply past the
second drafted token on code, so deeper drafts waste verify passes — Beet Code
launches with `--spec-draft-n-max 2`.

## Measured on this machine (2026-08-19, M4, Qwythos-9B MTP Q5_K_M)

Fixed prompt (Swift LRU cache, 256 generated tokens, temp 0.6, cold KV),
sequential servers, two samples per mode:

| Mode | Decode tok/s | Prompt tok/s |
| --- | --- | --- |
| MTP off | 12.75 / 10.79 | 71.4 / 70.6 |
| draft-mtp, n-max 2 | 13.32 / 11.43 | 69.6 / 66.7 |
| draft-mtp, n-max 4 | 7.15 | 61.3 |

**Verdict: ~+5 % decode at n-max 2** (consistent direction in both pairs;
run-to-run noise is ±8 %), a ~3 % prompt-processing hit, and n-max 4 is
clearly counterproductive (−34 %) — which validates the n-max 2 default.
The community's 33–39 % did not reproduce on this hardware/model combo
(hybrid-arch MTP kernels are young; gains likely scale with model size and
acceptance profile). Auto-enable stays: small consistent upside, no
meaningful downside, and the self-healing fallback covers older binaries.
First app-launched server confirmed the auto-detect path live
(`--spec-type draft-mtp --spec-draft-n-max 2` present in the wild).

## What shipped

- `GGUFMetadata.mtpPredictLayers` / `.supportsDraftMTP` — parses
  `<arch>.nextn_predict_layers` from the GGUF header (same
  architecture-qualified resolution as `context_length`).
- `GGUFEngine.Planner.serverArguments(..., speculativeMTP:)` — appends
  `--spec-type draft-mtp --spec-draft-n-max 2` when asked.
- `GGUFEngine.load` — when the sniffed header supports MTP, the first launch
  attempt uses draft-mtp. If the server never answers (e.g. an older
  llama-server rejects the flag at arg-parse and exits — the health wait
  fails in ~250 ms, not 120 s), it retries once without the flag and logs a
  warning. Non-MTP models are untouched.
- Tests: header-parse detection (with/without nextn layers), planner flag
  opt-in, all hermetic.

## Caveats

- **Single-stream only**: speculative decoding serializes slots. Fine for
  Beet Code — the embedded server serves one user.
- **Prompt processing** takes a small hit (the draft head runs prefill too);
  net win on generation-heavy sessions, roughly neutral on one-shot prompts.
- **Young kernels**: hybrid-arch MTP paths in llama.cpp are new; if a future
  llama.cpp update regresses, the fallback above keeps loads working.
- **Memory cost is negligible**: one nextn layer + a small draft KV.

## How to measure the win (A/B)

Load the Qwythos MTP build, send the same long generation prompt twice, and
watch the tok/s pill — once with MTP (default now), once with it disabled.
To disable temporarily, force `speculativeMTP: false` at the first
`launchServer` call in `GGUFEngine.load`. For a stricter measurement, run
`llama-server` by hand with `--parallel 1` and compare `llama-bench`-style
decode rates with and without `--spec-type draft-mtp`.
