# Spec 06 — Test Plan (Master Checklist)

Apply these incrementally with each phase — do not batch them at the end. Every phase must end
green on `bash tests/run-all.sh`. Baseline before any changes: 4 suites, all green
(shell-syntax, config-validate, hooks, parsers).

## tests/test-parsers.sh (with spec 01)

**Ripple on existing tests:**
- The main Claude fixture's span-count assertion (lines ~26–31: "span count = 5") — the parser
  now outputs 6 lines; either assert `span_count == 5` after filtering
  (`jq -c 'select(.metrics == null)'`) or assert total lines = 6 and spans = 5. Prefer filtering:
  it documents the consumer contract. Audit every `wc -l` / `jq -s length` on parser output.
- Codex/Gemini parser tests must remain untouched and green (their parsers gain no sidecar).

**New tests against `tests/fixtures/claude-session-skills.jsonl`** (expected values derive from
the fixture's chosen token numbers — document them in a comment block at the top of the section):

1. Sidecar exists, is the LAST line, and is the only line with `.metrics`.
2. Sidecar `git_repo` and `session_id` match the fixture.
3. `tokens` array: one entry per model; each of input/output/cacheRead/cacheCreation equals the
   fixture's per-model sums (dedup rule: streaming duplicates by `message.id` counted once).
4. Skill attribution — even split: fixture turn 1 has two invocations (`/obs-cost` slash command
   + `superpowers:brainstorming` Skill call); each gets `floor(window_tokens / 2)` per model and
   type; `count == 1` each.
5. Slash-command name extraction: `obs-cost` (leading `/` stripped, no args).
6. `subagents`: `[{"subagent_type": "code-reviewer", "count": 1}]`.
7. `mcp`: server/tool/count match the fixture's `mcp_progress` entry.
8. Tool span for the Skill call carries attribute `skill.name == "superpowers:brainstorming"`;
   the Task tool span carries `agent.type == "code-reviewer"`.
9. Sidecar `context` chars equal the fixture's computable char counts; `compaction_count == 0`.
10. With `SHEPARD_DETAILED_TRACES=1`: `claude.turn` spans still emitted and sidecar still last.

## tests/test-hooks.sh (with spec 02)

Runs with `SHEPARD_TEST_MODE=1` (bypasses Rust accelerator) and mock curl/git. Add near the
existing Claude stop-hook tests:

**Setup:** `export SHEPARD_STATE_DIR="$TEST_HOME/state"` for isolation; point the hook at a
session JSONL fixture via the documented `~/.claude/projects/<slug>/<session_id>.jsonl` layout
under `$TEST_HOME` (see how existing stop.sh tests fabricate `transcript_path`/`cwd`).

**Async gotcha:** the new emissions happen inside the fully-detached subshell. Assertions on the
mock-curl capture file need a bounded wait:

```bash
for i in $(seq 1 40); do grep -q session_tokens "$CURL_CAPTURE" && break; sleep 0.25; done
```

The existing `compaction_events` assertions were synchronous (emitted in the hook's main path);
they move into the async delta path — convert those assertions to the same polling pattern.

**New tests:**
1. First stop on a fresh session → `session_tokens` emitted with `git_repo`, `model`, `type`
   labels; state file created and parses as JSON.
2. Immediate second stop, unchanged JSONL → NO new `session_tokens`/`skill_*` datapoints
   (compare capture-file counts before/after, with a settle wait).
3. Append one assistant turn to the JSONL, stop again → emitted values equal only the delta.
4. Corrupt state file (`echo garbage > state`) → hook does not crash; full totals re-emitted
   once; state file repaired.
5. Pre-existing lock dir → hook skips emission cleanly (no new datapoints, no hang); state file
   unchanged.
6. Old state files (> 7 days, use `touch -t`) are cleaned up after a run.
7. Skills fixture session → `skill_invocations`, `skill_tokens`, `subagent_invocations`,
   `mcp_calls` all present in capture with correct label sets.

## tests/test-config-validate.sh (with specs 03–05)

1. Pricing file: `jq -e . configs/pricing/model-prices.json` and assert every price entry has
   the 4 numeric rate fields.
2. Generator sync: `diff <(bash scripts/generate-pricing-rules.sh) configs/prometheus/rules/pricing-generated.yaml`.
3. Extend the promtool section (if promtool installed) to also check
   `configs/prometheus/rules/*.yaml`.
4. Alert count: line ~120 `assert_alert_count "$ALERTS_DIR/services.yaml" 5` → `8`.
5. Expression guard: `HighSessionCost` expr contains `computed_cost_usd` (existing guard pattern).
6. Dashboard validation loop is glob-based — confirm `15-projects.json` is picked up
   automatically; if any test asserts a dashboard COUNT (9), bump to 10.

## tests/test-shell-syntax.sh

Glob-based over scripts; `scripts/generate-pricing-rules.sh` should be picked up automatically —
confirm, and bump any hardcoded script count (README claims "23 scripts").

## Doc ripple

After all suites pass, update the test-count claims in `CLAUDE.md` (currently "127 unit tests",
suite breakdowns) and `README.md` to the new real numbers. Run `bash tests/run-all.sh` and copy
the printed totals — do not hand-count.

## E2E (optional but recommended once per phase 2+)

`bash tests/run-all.sh --e2e` — starts the Docker stack and runs `scripts/test-signal.sh`
(11 checks). New metrics are NOT covered by test-signal.sh; extending it is optional — if
extended, add a synthetic `session_tokens` emission + Prometheus query check following its
existing check pattern.

## Definition of done

- All 4 suites green locally and in CI (`.github/workflows/test.yml` runs them on push).
- No test asserts stale counts (spans, alerts, dashboards, scripts, total tests).
- CLAUDE.md/README test numbers match `tests/run-all.sh` output.
