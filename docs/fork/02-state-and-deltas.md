# Spec 02 — Per-Session State & Delta Emission in stop.sh

**Phase 2. Depends on spec 01.** The Claude Code Stop hook fires at the end of **every assistant
turn**. The sidecar (spec 01) contains **cumulative** session totals, so stop.sh must emit only
the **delta** since the previous firing, tracked in a per-session state file. This also fixes an
existing upstream bug.

## The existing bug (context for the implementer)

Upstream `hooks/claude/stop.sh` re-emits, on EVERY Stop firing:

- `stop.sh:51-56` — the full-file compaction count → `shepherd_compaction_events_total`
- `stop.sh:73-87` — full-session context char totals → `shepherd_context_chars_total`,
  `shepherd_context_compaction_pre_tokens_total`

Because these are OTLP **delta** sums (accumulated by `deltatocumulative`), every firing ADDS the
whole session's totals again: metrics are inflated ~×(turn count). Traces don't have this problem
(deterministic IDs; re-sent spans overwrite). This spec routes those metrics through the delta
path, so their post-fix magnitudes will drop — that's the fix (CHANGELOG has the note).

## Files touched

- `hooks/claude/stop.sh` — replace the detached-subshell body (lines 49–93)
- `hooks/lib/metrics.sh` — no changes (reuse `emit_counter`)
- `tests/test-hooks.sh` — spec 06

## New metrics

All emitted via `emit_counter(name, value, labels_json)`; Prometheus names get `shepherd_` prefix
and `_total` suffix.

| emit name | Prometheus name | labels |
|---|---|---|
| `session_tokens` | `shepherd_session_tokens_total` | `source="claude-code"`, `git_repo`, `model`, `type` (`input\|output\|cacheRead\|cacheCreation`) |
| `skill_invocations` | `shepherd_skill_invocations_total` | `source`, `git_repo`, `skill_name`, `skill_type` (`skill\|slash_command`) |
| `skill_tokens` | `shepherd_skill_tokens_total` | `source`, `git_repo`, `skill_name`, `skill_type`, `model`, `type` |
| `subagent_invocations` | `shepherd_subagent_invocations_total` | `source`, `git_repo`, `subagent_type` |
| `mcp_calls` | `shepherd_mcp_calls_total` | `source`, `git_repo`, `mcp_server`, `mcp_tool` |

Existing metrics **moved into the delta path** (same names/labels as today):
`context_chars` (`type` ∈ tool_output|user_prompt|compact_summary), `context_compaction_pre_tokens`,
`compaction_events`. Delete the standalone grep-based compaction emission at `stop.sh:50-56` and
the context emission at `stop.sh:63-87`.

`events_total{event_type="session_end"}` (stop.sh:38-41) stays exactly as-is for upstream
compatibility; note in code comment that it counts *completed responses*, not sessions.

**Label rules (hard):** never label with session_id, prompts, args, or any free text. Skill names
verbatim (including `plugin:` prefix). Cardinality budget at 30 repos × 6 models × ~50 skills is
realistically low-thousands of series — fine for local Prometheus.

## State design

- Directory: `${SHEPARD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/shepard-obs}/claude/`
  (mkdir -p on use). `SHEPARD_STATE_DIR` env override exists for test isolation.
- File per session: `<session_id>.json` — the **previous sidecar `metrics` object verbatim**.
- Lock per session: `<session_id>.json.lock` (a directory).

### Flow (inside the existing detached subshell in stop.sh)

```
parser_output=$(bash session-parser.sh "$session_file")      # unchanged
spans=$(jq -c 'select(.metrics == null)' <<<"$parser_output")
cur=$(jq -c '.metrics | select(. != null)' <<<"$parser_output")

echo "$spans" | emit_spans "claude-code-session"              # traces first, unchanged semantics

if [[ -n "$cur" ]]; then
  mkdir -p "$STATE_DIR"
  if mkdir "${state_file}.lock" 2>/dev/null; then             # atomic, portable; no flock on macOS
    trap 'rmdir "${state_file}.lock" 2>/dev/null' EXIT
    prev=$(cat "$state_file" 2>/dev/null || echo '{}')
    jq -e . >/dev/null 2>&1 <<<"$prev" || prev='{}'           # corrupt state → full re-emit once, never crash
    deltas=$(jq -n -c --argjson cur "$cur" --argjson prev "$prev" '<DELTA PROGRAM below>')
    <emit loop over $deltas>                                  # emit_counter per nonzero datapoint
    tmp=$(mktemp "${STATE_DIR}/.tmp.XXXXXX") && printf '%s' "$cur" >"$tmp" && mv "$tmp" "$state_file"
    find "$STATE_DIR" -type f -mtime +7 -delete 2>/dev/null   # matches 7d stack retention
  fi
  # else: another firing holds the lock — skip entirely; next firing catches up
fi
```

Ordering is **emit-then-write**: a crash between emit and state-write re-emits one turn's delta
(small over-count). Write-first would permanently lose tokens on any curl failure — silent
under-reporting of spend is the worse failure for a cost tool.

"Skip if locked" is safe *because* deltas are computed against the stored cumulative baseline:
a skipped firing's delta is included in the next firing's delta automatically.

### Delta program (single jq call)

For each section, compute `cur − prev` per key, **clamped at 0** (clamping guards against JSONL
truncation/rewrites producing negative deltas):

- `tokens`: key = `model`; subtract the 4 token fields pairwise.
- `skills`: key = `"\(.skill)|\(.kind)"`; subtract `count` and the per-model token fields
  (nested: align per-model arrays by `model`, missing prev model → prev 0).
- `subagents`: key = `subagent_type`; subtract `count`.
- `mcp`: key = `"\(.server)|\(.tool)"`; subtract `count`.
- `context`: subtract the 4 scalar fields.
- `compaction_count`: subtract scalar.

Output shape suggestion (flat list the bash loop can iterate with `jq -c '.[]'`):

```json
[{"metric": "session_tokens", "value": 1234,
  "labels": {"source": "claude-code", "git_repo": "tiger-den", "model": "claude-opus-4-8", "type": "output"}},
 {"metric": "skill_invocations", "value": 1,
  "labels": {"source": "claude-code", "git_repo": "tiger-den", "skill_name": "obs-cost", "skill_type": "slash_command"}},
 ...]
```

Build the full flat list inside the one jq program (models × 4 types for `session_tokens`;
skills × models × 4 types for `skill_tokens`; etc.), emitting only entries with `value > 0`.
`git_repo` comes from the sidecar's `git_repo` (fall back to `$GIT_REPO` from `get_git_context`
if empty, matching existing hook convention).

The bash emit loop:

```bash
while IFS= read -r d; do
  [[ -z "$d" ]] && continue
  name=$(jq -r '.metric' <<<"$d")
  val=$(jq -r '.value' <<<"$d")
  labels=$(jq -c '.labels' <<<"$d")
  emit_counter "$name" "$val" "$labels"
done < <(jq -c '.[]' <<<"$deltas")
```

(`emit_counter` is fire-and-forget `curl -s ... & disown`; a burst of ~20 datapoints per turn is
fine. If it ever isn't, batch into one OTLP payload — out of scope now.)

## Shell rules (repeat because they bite)

`set -u` only. No `set -e`, no `pipefail`. Every jq call must tolerate malformed input by
producing empty/`{}` rather than exiting the subshell in a way that skips the state write — but
note the subshell is already fully detached (`</dev/null >/dev/null 2>&1 &`), so failures are
invisible; that's by design (hooks must never block the CLI).

## Verification

```bash
bash -n hooks/claude/stop.sh
bash tests/run-all.sh

# Manual end-to-end (stack running):
export SHEPARD_STATE_DIR=/tmp/shep-state-test
echo '{"session_id":"<real-session-uuid>","transcript_path":"","cwd":"'$PWD'","hook_event_name":"Stop","stop_hook_active":false}' \
  | bash hooks/claude/stop.sh
sleep 2
cat "$SHEPARD_STATE_DIR/claude/<real-session-uuid>.json" | jq .
# Second run must emit nothing new:
curl -s 'http://localhost:9090/api/v1/query?query=shepherd_session_tokens_total' | jq '.data.result[].metric, .data.result[].value'
```

Run the hook twice against the same unchanged session file; the Prometheus counter value must be
identical after the second run (allow one scrape interval).

## Definition of done

- One stop firing on a fresh session emits full totals; an immediate second firing emits nothing.
- Appending turns to the JSONL and re-firing emits only the new turns' deltas.
- Corrupt/missing state file never crashes; lock contention skips cleanly.
- `shepherd_session_tokens_total` visible in Prometheus with `git_repo`, `model`, `type` labels;
  `shepherd_skill_invocations_total`, `shepherd_skill_tokens_total`,
  `shepherd_subagent_invocations_total`, `shepherd_mcp_calls_total` appear after a session that
  used skills/subagents/MCP.
- `shepherd_context_chars_total` growth rate visibly drops (bug fix), values still nonzero.
- test-hooks.sh additions (spec 06) green.
