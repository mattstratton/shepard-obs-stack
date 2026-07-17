# Fork Roadmap — Matt's shepard-obs-stack

This directory is the **implementation handoff spec** for extending this fork beyond upstream.
It is written to be executed by a Claude session with no prior context: every spec names exact
files, exact changes, verification commands, and a definition of done. Read this README first,
then implement the numbered specs in phase order.

## Why this fork diverges

Upstream treats Claude Code, Codex, and Gemini CLI as equals and trusts Claude Code's built-in
cost estimate. Matt is **Claude Code-only**, pays **real enterprise API rates**, and wants:

1. **Per-project breakdown** — cost/tokens sliced by git repo (tiger-den, timescaledb, …).
2. **Real cost** — computed from token counts × the org's actual per-model rates, not the
   client-side estimate.
3. **Skill/subagent/MCP analytics** — which skills and slash commands run, how often, and what
   they cost.

Native Claude Code OTel metrics carry **no repo dimension** (only `model` + `type`), so per-repo
attribution is built by parsing the session JSONL in the existing Stop hook and emitting our own
labeled counters through the existing hook → OTLP → `deltatocumulative` → Prometheus pipeline.

## Decisions (locked — do not relitigate)

| # | Decision |
|---|----------|
| 1 | Claude Code only. Codex/Gemini pipelines stay **dormant and unextended** but intact (keeps upstream merges painless). |
| 2 | Project = **git repo name**, existing `git_repo` label convention. |
| 3 | Attribution = stop-hook session parser emits token counters `{git_repo, model, type}` from JSONL per-message usage. Not per-repo settings files, not a launcher wrapper. |
| 4 | Cost = computed from tokens × pricing table (`configs/pricing/model-prices.json`, real org rates). Computed cost is primary in all panels; one small panel keeps the native estimate as a drift check. |
| 5 | Skills: invocation counts + **turn-window token attribution** (invocation → next real user message; multiple skills in one window split evenly). Subagents (`subagent_type`) and MCP (server, tool) are first-class dimensions. |
| 6 | Extras: cache-savings-in-$ panel, spend alerts on computed cost, model-mix panel. |
| 7 | These docs live in the fork; cutover doc migrates the live local stack. |
| 8 | Grafana host port is **9000** in this fork (upstream uses 3000). Already applied. |

## Phasing

Each phase must end green on `bash tests/run-all.sh` before starting the next.

| Phase | Spec | Depends on | Delivers |
|-------|------|------------|----------|
| 1 | [01-parser-sidecar.md](01-parser-sidecar.md) | — | Metrics sidecar line from session-parser.sh + new fixture. Pure jq, testable offline. |
| 2 | [02-state-and-deltas.md](02-state-and-deltas.md) | 1 | Delta emission in stop.sh with per-session state files. New Prometheus metrics start flowing. Fixes an existing double-count bug. |
| 3 | [03-pricing-and-cost.md](03-pricing-and-cost.md) | — (verification needs 2) | Pricing file, rule generator, computed-cost recording rules. |
| 4 | [04-dashboards.md](04-dashboards.md) | 3 | Cost dashboard rework + new "Projects & Skills" dashboard. |
| 5 | [05-alerts.md](05-alerts.md) | 3 | Spend alerts on computed cost. |
| 6 | [06-tests.md](06-tests.md) | 1–5 | Applied incrementally with each phase; this spec is the master checklist. |
| 7 | [07-cutover.md](07-cutover.md) | all | Point the live running stack at this fork. |

## Upstream-merge policy

- Never extend Codex/Gemini hooks, parsers, recording rules, dashboards, or tests. Leave their
  files byte-identical to upstream where possible.
- New functionality goes in **new files** when feasible (new dashboard, new rules dir, new
  pricing dir) and in clearly-delimited blocks when touching shared files
  (session-parser.sh, stop.sh, 01-cost.json, services.yaml).
- When merging upstream: conflicts should concentrate in session-parser.sh and stop.sh. The
  sidecar (spec 01) and delta emission (spec 02) blocks are the things to re-apply.

## Risks & gotchas (read before writing any code)

1. **Rust accelerator bypass** — `hooks/claude/stop.sh:17-21` delegates the ENTIRE hook to
   `shepard-hook` when resolvable (project-local `hooks/bin/` or PATH). Every change in these
   specs is bash-side; if the accelerator is installed, none of it runs. It is currently NOT
   installed on Matt's machine. Do not install it; `07-cutover.md` re-checks.
2. **Stop fires every turn** — the Claude Code Stop hook runs at the end of *every assistant
   turn*, not once per session. All new emission must go through the state-file delta path
   (spec 02). Never emit whole-session totals directly.
3. **Existing double-count bug (being fixed)** — upstream stop.sh re-emits the full-file
   compaction count and full-session context_chars on every firing, inflating
   `shepherd_compaction_events_total`, `shepherd_context_chars_total`, and
   `shepherd_context_compaction_pre_tokens_total` by roughly ×(turn count). Spec 02 routes them
   through deltas. Historical magnitudes of these metrics will visibly drop — that is the fix,
   not a regression (noted in CHANGELOG).
4. **Hook shell rules** — hooks use `set -u` ONLY. Never add `set -e` or `set -o pipefail`
   (silent SIGPIPE kills in fire-and-forget pipelines — see CLAUDE.md). jq failures must
   degrade to no-op, never crash the hook.
5. **jq quirks** — reuse the parser's existing `ts_parts` (UTC strptime + fractional-second
   split). Stay jq-1.6 compatible. ISO-8601 string comparison is safe for ordering (fixed-width
   UTC timestamps).
6. **Pricing join is silent** — a `model` label missing from the pricing file contributes $0
   with no error. The `shepherd:claude:unpriced_models` rule + dashboard stat is the guardrail.
   Model IDs are dated (`claude-sonnet-4-5-20250929`) and change with releases.
7. **Recorded cost series are gauge-shaped** — `increase()` still works numerically, but a
   collector restart resets the underlying counters; small misestimates across resets are
   accepted, not solved.
8. **deltatocumulative staleness is 168h** (`configs/otel-collector/config.yaml`, commit
   `a6d4926`). Session-level counters depend on it. Do not lower it.
9. **Cardinality discipline** — skill/agent/MCP names go in labels and span *attributes*, never
   in span *names* (see the fixed `claude.turn` span-name precedent).
10. **Grafana provisioning** — dashboard JSON edits require `docker compose restart grafana`;
    UI edits are lost on restart. Prometheus rule changes need `POST /-/reload` or restart.
11. **Test ripple** — the sidecar changes span-count assertions in `tests/test-parsers.sh`
    (5 → 6 on the main Claude fixture); alert counts in `tests/test-config-validate.sh:120`
    (5 → 8); test-count claims in CLAUDE.md and README.md.
12. **User message content shape** — string OR array of text blocks depending on Claude Code
    version. Slash-command extraction must handle both. Skill invocations may appear as tool
    `Skill` (current) or `SlashCommand` (legacy).
13. **mkdir-lock is load-bearing** — the per-session lock in spec 02 uses `mkdir` (atomic,
    portable). Do not replace with `flock` (absent on macOS). "Skip if locked" is correct
    because deltas are computed from cumulative baselines — the next firing catches up.
