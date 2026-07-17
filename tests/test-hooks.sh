#!/usr/bin/env bash
# tests/test-hooks.sh — behavioral tests for hook scripts
#
# Tests exit codes, stdout output, and metric emission (via mock curl).
# Requires: jq, bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0

pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; }

# --- Setup mocks ---
MOCK_DIR=$(mktemp -d)
CAPTURE_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR" "$CAPTURE_DIR"' EXIT

# Mock curl: capture -d payload
cat > "$MOCK_DIR/curl" << 'MOCK'
#!/usr/bin/env bash
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-d" ]]; then
    echo "$arg" >> "$SHEPARD_TEST_CAPTURE/curl_payloads.log"
  fi
  prev="$arg"
done
MOCK
chmod +x "$MOCK_DIR/curl"

# Mock git: return known values
cat > "$MOCK_DIR/git" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *rev-parse*--abbrev-ref*) echo "test-branch";;
  *remote*get-url*) echo "https://github.com/test/test-repo.git";;
  *) ;;
esac
MOCK
chmod +x "$MOCK_DIR/git"

export PATH="$MOCK_DIR:$PATH"
export SHEPARD_TEST_MODE=1
export SHEPARD_TEST_CAPTURE="$CAPTURE_DIR"

reset_capture() { rm -f "$CAPTURE_DIR/curl_payloads.log"; }

run_hook() {
  local hook="$1"
  shift
  local rc=0
  bash "$REPO_ROOT/$hook" "$@" || rc=$?
  sleep 0.5  # let background mock curl finish (disowned processes)
  return $rc
}

payload_count() {
  [[ -f "$CAPTURE_DIR/curl_payloads.log" ]] && wc -l < "$CAPTURE_DIR/curl_payloads.log" | tr -d ' ' || echo "0"
}

payload_has() {
  [[ -f "$CAPTURE_DIR/curl_payloads.log" ]] && grep -q "$1" "$CAPTURE_DIR/curl_payloads.log" 2>/dev/null
}

# Poll for an async (detached-subshell) datapoint instead of a fixed sleep.
wait_for_payload() {
  local pattern="$1" tries="${2:-60}" i
  for ((i = 0; i < tries; i++)); do
    payload_has "$pattern" && return 0
    sleep 0.25
  done
  return 1
}

# Poll until a state file exists and parses as JSON. This is the LAST thing the Stop hook's
# async delta path does (after emitting metrics), so it's a more reliable "async work is fully
# done" signal than waiting for the first metric payload to appear — under load, metric
# emission (a curl call) can be observed while the rest of the emit loop + state write are
# still in flight, which used to race with immediate follow-up assertions.
wait_for_state_file() {
  local file="$1" tries="${2:-60}" i
  for ((i = 0; i < tries; i++)); do
    [[ -f "$file" ]] && jq -e . "$file" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

# Poll until a file's mtime changes from a captured baseline — used to confirm a state file
# was rewritten (even when its content is unchanged, e.g. a zero-delta re-firing still
# rewrites the file every successful lock acquisition).
file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}
wait_for_mtime_change() {
  local file="$1" before="$2" tries="${3:-60}" i cur
  for ((i = 0; i < tries; i++)); do
    if [[ -f "$file" ]]; then
      cur=$(file_mtime "$file")
      [[ -n "$cur" && "$cur" != "$before" ]] && return 0
    fi
    sleep 0.25
  done
  return 1
}

# ========================================================
echo "PreToolUse (Claude) — sensitive file guard"
# ========================================================

# Should block .env
reset_capture
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/app/.env"}}' | run_hook hooks/claude/pre-tool-use.sh || rc=$?
if [[ $rc -eq 2 ]]; then pass "blocks .env (exit 2)"; else fail "blocks .env" "got exit $rc"; fi

# Should block .pem
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/etc/ssl/server.pem"}}' | run_hook hooks/claude/pre-tool-use.sh || rc=$?
if [[ $rc -eq 2 ]]; then pass "blocks .pem (exit 2)"; else fail "blocks .pem" "got exit $rc"; fi

# Should block id_rsa
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/home/user/.ssh/id_rsa"}}' | run_hook hooks/claude/pre-tool-use.sh || rc=$?
if [[ $rc -eq 2 ]]; then pass "blocks id_rsa (exit 2)"; else fail "blocks id_rsa" "got exit $rc"; fi

# Should block .aws/
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/home/user/.aws/credentials"}}' | run_hook hooks/claude/pre-tool-use.sh || rc=$?
if [[ $rc -eq 2 ]]; then pass "blocks .aws/ (exit 2)"; else fail "blocks .aws/" "got exit $rc"; fi

# Should allow normal files
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/app/src/main.py"}}' | run_hook hooks/claude/pre-tool-use.sh || rc=$?
if [[ $rc -eq 0 ]]; then pass "allows normal file (exit 0)"; else fail "allows normal file" "got exit $rc"; fi

# Should allow empty input
rc=0
echo '{}' | run_hook hooks/claude/pre-tool-use.sh || rc=$?
if [[ $rc -eq 0 ]]; then pass "allows empty input (exit 0)"; else fail "allows empty input" "got exit $rc"; fi

# ========================================================
echo ""
echo "PostToolUse (Claude) — metric emission"
# ========================================================

# Normal tool call → exit 0, emits tool_calls + events (2 payloads)
reset_capture
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/app/main.py"},"tool_response":"file contents","cwd":"/tmp/project"}' \
  | run_hook hooks/claude/post-tool-use.sh || rc=$?
if [[ $rc -eq 0 ]]; then pass "normal tool → exit 0"; else fail "normal tool → exit 0" "got exit $rc"; fi
count=$(payload_count)
if [[ "$count" -ge 2 ]]; then pass "emits ≥2 metrics (tool_calls + events)"; else fail "emits ≥2 metrics" "got $count"; fi

# Error response → tool_status="error"
reset_capture
echo '{"tool_name":"Bash","tool_input":{},"tool_response":"FAILED: exit code 1","cwd":"/tmp/project"}' \
  | run_hook hooks/claude/post-tool-use.sh || true
if payload_has '"error"'; then pass "error response → tool_status=error"; else fail "error response → tool_status=error"; fi

# Sensitive file → emits sensitive_file_access (3 payloads)
reset_capture
echo '{"tool_name":"Read","tool_input":{"file_path":"/app/.env.local"},"tool_response":"ok","cwd":"/tmp/project"}' \
  | run_hook hooks/claude/post-tool-use.sh || true
count=$(payload_count)
if [[ "$count" -ge 3 ]]; then
  pass "sensitive file → emits sensitive_file_access (3 metrics)"
else
  fail "sensitive file → emits sensitive_file_access" "got $count payloads"
fi

# ========================================================
echo ""
echo "Stop hook (Claude) — session end + compaction"
# ========================================================

# Setup temp HOME for session file lookup + isolated state dir for the async delta path
TEST_HOME=$(mktemp -d)
STATE_HOME=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR" "$CAPTURE_DIR" "$TEST_HOME" "$STATE_HOME"' EXIT
slug=$(echo "/tmp/test-project" | sed 's|/|-|g')
mkdir -p "$TEST_HOME/.claude/projects/${slug}/"

# stop_hook_active=true → early exit, no emission
reset_capture
export SHEPARD_STATE_DIR="$STATE_HOME/active-true"
rc=0
echo '{"session_id":"test","cwd":"/tmp/project","stop_hook_active":true}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || rc=$?
if [[ $rc -eq 0 ]]; then pass "stop_hook_active=true → exit 0 (early)"; else fail "stop_hook_active" "got exit $rc"; fi
count=$(payload_count)
if [[ "$count" -eq 0 ]]; then pass "stop_hook_active → no metrics emitted"; else fail "stop_hook_active → no metrics" "got $count"; fi

# Normal session end → emits events(session_end)
reset_capture
export SHEPARD_STATE_DIR="$STATE_HOME/normal"
rc=0
echo '{"session_id":"test-sess","cwd":"/tmp/project","stop_hook_active":false}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || rc=$?
if [[ $rc -eq 0 ]]; then pass "normal stop → exit 0"; else fail "normal stop" "got exit $rc"; fi
if payload_has '"session_end"'; then pass "emits session_end event"; else fail "emits session_end event"; fi

# Degenerate session (no assistants/tools/compactions) → async delta path doesn't crash
reset_capture
export SHEPARD_STATE_DIR="$STATE_HOME/zero-comp"
echo '{"type":"user","sessionId":"zero-comp"}' > "$TEST_HOME/.claude/projects/${slug}/zero-comp.jsonl"
rc=0
echo '{"session_id":"zero-comp","cwd":"/tmp/test-project","stop_hook_active":false}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || rc=$?
if [[ $rc -eq 0 ]]; then
  pass "degenerate session (no data) → exit 0, no crash"
else
  fail "degenerate session → crash!" "got exit $rc"
fi

# Session with compactions → emits compaction_events via the async delta path (first firing,
# prev={}, so the full compaction_count comes through as the delta)
reset_capture
export SHEPARD_STATE_DIR="$STATE_HOME/with-comp"
echo '{"type":"user","sessionId":"with-comp"}
{"type":"system","subtype":"compact_boundary"}
{"type":"system","subtype":"compact_boundary"}' > "$TEST_HOME/.claude/projects/${slug}/with-comp.jsonl"
echo '{"session_id":"with-comp","cwd":"/tmp/test-project","stop_hook_active":false}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || true
if wait_for_payload '"compaction_events"'; then
  pass "session with compactions → emits compaction_events"
else
  fail "session with compactions → emits compaction_events"
fi

# Regression: session file lookup must not depend on reconstructing the project-slug from
# $cwd. Real Claude Code project directories replace BOTH "/" and "." with "-" (e.g. a path
# segment like "github.com" becomes "github-com"), but a naive `sed 's|/|-|g'` only converts
# slashes — so for any cwd containing a dot, the old slug-reconstruction approach computed a
# directory that never matched the real one, and silently never found the session file at
# all (this was a real, long-standing bug: it affected this repo's own dev directory, whose
# path includes "src/github.com/..."). Simulate that exact mismatch here: place the fixture
# under the dot-converted (real) slug while cwd still contains the literal dot.
reset_capture
export SHEPARD_STATE_DIR="$STATE_HOME/dot-lookup"
dotted_cwd="/tmp/test.dotted.project"
real_slug="-tmp-test-dotted-project"   # what Claude Code actually creates (dot -> dash)
mkdir -p "$TEST_HOME/.claude/projects/${real_slug}/"
cat > "$TEST_HOME/.claude/projects/${real_slug}/dot-lookup-test.jsonl" <<'JSONL'
{"type":"user","sessionId":"dot-lookup-test","timestamp":"2026-03-06T12:00:00.000Z","message":{"role":"user","content":"hello"}}
{"type":"assistant","sessionId":"dot-lookup-test","timestamp":"2026-03-06T12:00:01.000Z","uuid":"msg-301","message":{"id":"msg-301","role":"assistant","model":"claude-opus-4-8","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":5,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"stop_reason":"end_turn"}}
JSONL
echo "{\"session_id\":\"dot-lookup-test\",\"cwd\":\"$dotted_cwd\",\"stop_hook_active\":false}" \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || true
if wait_for_payload '"session_tokens"'; then
  pass "session file found by session_id even when cwd contains a dot (slug-mismatch regression)"
else
  fail "dot-in-cwd session lookup" "session_tokens never emitted — session file lookup regressed"
fi

# ========================================================
echo ""
echo "Stop hook (Claude) — metrics sidecar state & deltas"
# ========================================================
# Uses tests/fixtures/claude-session-skills.jsonl (same fixture as the parser tests): turn 1 has
# a /obs-cost slash command + a superpowers:brainstorming Skill call sharing one token window
# (model claude-opus-4-8: input 200, output 1000, cacheRead 40000, cacheCreation 600); turn 2 has
# a Task(code-reviewer) call on model claude-haiku-4-5-20251001 (input 300, output 800, cacheRead
# 5000, cacheCreation 200); one mcp_progress entry (tiger/db_execute_query).

export SHEPARD_STATE_DIR="$STATE_HOME/skills"
skills_session_file="$TEST_HOME/.claude/projects/${slug}/skills-fresh.jsonl"
cp "$REPO_ROOT/tests/fixtures/claude-session-skills.jsonl" "$skills_session_file"
state_file="$SHEPARD_STATE_DIR/claude/skills-fresh.json"

# 1. Fresh session → full totals + state file created and valid
reset_capture
echo '{"session_id":"skills-fresh","cwd":"/tmp/test-project","stop_hook_active":false}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || true
# Wait for the state file, not just the first metric: it's written last in the async
# pipeline, so its presence proves emission has already finished too (no race).
if wait_for_state_file "$state_file"; then
  pass "state file created and parses as JSON"
else
  fail "state file" "missing or invalid: $state_file"
fi
if payload_has '"session_tokens"'; then pass "fresh session emits session_tokens"; else fail "fresh session session_tokens" "not seen"; fi
if payload_has '"skill_invocations"' && payload_has '"skill_tokens"' && \
   payload_has '"subagent_invocations"' && payload_has '"mcp_calls"'; then
  pass "skills fixture emits skill_invocations/skill_tokens/subagent_invocations/mcp_calls"
else
  fail "skills fixture metrics" "one or more of skill_invocations/skill_tokens/subagent_invocations/mcp_calls missing"
fi

# 2. Immediate second stop, unchanged JSONL → no NEW datapoints (session_end + trace excepted)
before_mtime=$(file_mtime "$state_file")
sleep 1.1  # stat's mtime has 1s resolution; force the next write into a distinguishable second
reset_capture
echo '{"session_id":"skills-fresh","cwd":"/tmp/test-project","stop_hook_active":false}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || true
# The state file is rewritten every successful firing (even with an all-zero delta), so
# waiting for its mtime to change is a reliable "this firing is fully done" signal.
wait_for_mtime_change "$state_file" "$before_mtime" || true
new_metric_count=$(grep -cE 'session_tokens|skill_invocations|skill_tokens|subagent_invocations|mcp_calls|context_chars|compaction_events' "$CAPTURE_DIR/curl_payloads.log" 2>/dev/null || true)
new_metric_count=${new_metric_count:-0}
if [[ "$new_metric_count" -eq 0 ]]; then
  pass "second identical stop emits no new datapoints"
else
  fail "second identical stop" "expected 0 new datapoints, got $new_metric_count"
fi

# 3. Append one assistant turn, stop again → emitted values equal only the delta
before_mtime=$(file_mtime "$state_file")
sleep 1.1  # stat's mtime has 1s resolution; force the next write into a distinguishable second
reset_capture
cat >> "$skills_session_file" <<'JSONL'
{"type":"assistant","sessionId":"skills-fresh","timestamp":"2026-03-06T11:00:07.000Z","uuid":"msg-201","message":{"id":"msg-201","role":"assistant","model":"claude-opus-4-8","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"stop_reason":"end_turn"}}
JSONL
echo '{"session_id":"skills-fresh","cwd":"/tmp/test-project","stop_hook_active":false}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || true
if wait_for_mtime_change "$state_file" "$before_mtime"; then pass "appended turn emits a new session_tokens delta"; else fail "appended turn delta" "not seen"; fi
delta_line=$(grep '"session_tokens"' "$CAPTURE_DIR/curl_payloads.log" | grep '"claude-opus-4-8"' | grep '"input"' || true)
delta_val=$(echo "$delta_line" | jq -r '.resourceMetrics[0].scopeMetrics[0].metrics[0].sum.dataPoints[0].asDouble' 2>/dev/null)
if [[ "$delta_val" == "10" ]]; then pass "delta value = 10 (only the new turn's input tokens, not the full total)"; else fail "delta value" "got $delta_val"; fi
if payload_has '"skill_invocations"' || payload_has '"subagent_invocations"' || payload_has '"mcp_calls"'; then
  fail "appended turn" "unexpectedly re-emitted skill/subagent/mcp invocations (should be unchanged, delta=0)"
else
  pass "appended turn does not re-emit unchanged skill/subagent/mcp invocation counts"
fi

# 4. Corrupt state file → hook doesn't crash, full totals re-emitted once, state repaired
reset_capture
export SHEPARD_STATE_DIR="$STATE_HOME/corrupt"
mkdir -p "$SHEPARD_STATE_DIR/claude"
echo "not valid json" > "$SHEPARD_STATE_DIR/claude/skills-fresh.json"
rc=0
echo '{"session_id":"skills-fresh","cwd":"/tmp/test-project","stop_hook_active":false}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || rc=$?
if [[ $rc -eq 0 ]]; then pass "corrupt state file → exit 0, no crash"; else fail "corrupt state file crash" "got exit $rc"; fi
# wait_for_state_file requires valid JSON, so it also proves the repair happened.
if wait_for_state_file "$SHEPARD_STATE_DIR/claude/skills-fresh.json"; then
  pass "corrupt state file → repaired to valid JSON"
else
  fail "corrupt state file repair" "state file still invalid"
fi
if payload_has '"session_tokens"'; then pass "corrupt state file → full totals re-emitted"; else fail "corrupt state file re-emit" "not seen"; fi

# 5. Pre-existing lock dir → hook skips emission cleanly, state file unchanged, no hang
# (No async work happens here at all — mkdir on the lock fails immediately and the hook
# bails out before touching the parser/state, so this path is fast regardless of system
# load; a short fixed wait is fine, unlike the full-pipeline cases above.)
reset_capture
export SHEPARD_STATE_DIR="$STATE_HOME/lock-contend"
mkdir -p "$SHEPARD_STATE_DIR/claude"
echo '{"marker":"untouched"}' > "$SHEPARD_STATE_DIR/claude/skills-fresh.json"
mkdir -p "$SHEPARD_STATE_DIR/claude/skills-fresh.json.lock"
rc=0
echo '{"session_id":"skills-fresh","cwd":"/tmp/test-project","stop_hook_active":false}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || rc=$?
sleep 2
if [[ $rc -eq 0 ]]; then pass "pre-existing lock dir → exit 0, no hang"; else fail "lock contention hang/crash" "got exit $rc"; fi
locked_metric_count=$(grep -cE 'session_tokens|skill_invocations|subagent_invocations|mcp_calls' "$CAPTURE_DIR/curl_payloads.log" 2>/dev/null || true)
locked_metric_count=${locked_metric_count:-0}
if [[ "$locked_metric_count" -eq 0 ]]; then pass "pre-existing lock dir → no new datapoints"; else fail "pre-existing lock dir metrics" "expected 0, got $locked_metric_count"; fi
if [[ "$(cat "$SHEPARD_STATE_DIR/claude/skills-fresh.json")" == '{"marker":"untouched"}' ]]; then
  pass "pre-existing lock dir → state file unchanged"
else
  fail "pre-existing lock dir state" "state file was modified while locked"
fi

# 6. Old state files (>7 days) cleaned up after a run
export SHEPARD_STATE_DIR="$STATE_HOME/cleanup"
mkdir -p "$SHEPARD_STATE_DIR/claude"
echo '{}' > "$SHEPARD_STATE_DIR/claude/old-session.json"
old_ts=$(date -v-10d +%Y%m%d%H%M 2>/dev/null || date -d '-10 days' +%Y%m%d%H%M)
touch -t "$old_ts" "$SHEPARD_STATE_DIR/claude/old-session.json"
reset_capture
echo '{"session_id":"skills-fresh","cwd":"/tmp/test-project","stop_hook_active":false}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || true
# Cleanup runs right after the state write, so waiting for THIS session's state file is the
# right completion signal before checking that the unrelated old file got pruned.
wait_for_state_file "$SHEPARD_STATE_DIR/claude/skills-fresh.json" || true
if [[ ! -f "$SHEPARD_STATE_DIR/claude/old-session.json" ]]; then
  pass "old (>7d) state file cleaned up after a run"
else
  fail "old state file cleanup" "old-session.json still present"
fi

# ========================================================
echo ""
echo "SessionStart (Claude) — post-compaction context"
# ========================================================

output=$(echo '{}' | run_hook hooks/claude/session-start.sh)
if echo "$output" | grep -q 'shepherd_'; then
  pass "outputs conventions text (contains shepherd_)"
else
  fail "outputs conventions text" "missing shepherd_ in output"
fi

# ========================================================
echo ""
echo "AfterTool (Gemini) — JSON stdout"
# ========================================================

reset_capture
output=$(echo '{"tool_name":"read_file","tool_input":{},"tool_response":"ok","cwd":"/tmp/project"}' \
  | GEMINI_CWD="/tmp/project" run_hook hooks/gemini/after-tool.sh)
if [[ "$output" == *"{}"* ]]; then
  pass "outputs {} on stdout"
else
  fail "outputs {} on stdout" "got: $output"
fi

# ========================================================
echo ""
echo "AfterAgent (Gemini) — turn end event"
# ========================================================

reset_capture
output=$(echo '{"cwd":"/tmp/project"}' \
  | GEMINI_CWD="/tmp/project" run_hook hooks/gemini/after-agent.sh)
if [[ "$output" == *"{}"* ]]; then pass "outputs {} on stdout"; else fail "outputs {}" "got: $output"; fi
if payload_has '"turn_end"'; then pass "emits events(turn_end)"; else fail "emits events(turn_end)"; fi

# ========================================================
echo ""
echo "AfterModel (Gemini) — finishReason filtering"
# ========================================================

# Without finishReason → no metric
reset_capture
output=$(echo '{"llm_response":{"candidates":[{}]},"cwd":"/tmp/project"}' \
  | run_hook hooks/gemini/after-model.sh)
if [[ "$output" == *"{}"* ]]; then pass "no finishReason → outputs {} (early exit)"; else fail "no finishReason → outputs {}" "got: $output"; fi
count=$(payload_count)
if [[ "$count" -eq 0 ]]; then pass "no finishReason → no metrics"; else fail "no finishReason → no metrics" "got $count"; fi

# With finishReason → emits model_call
reset_capture
output=$(echo '{"llm_response":{"candidates":[{"finishReason":"STOP"}]},"cwd":"/tmp/project"}' \
  | GEMINI_CWD="/tmp/project" run_hook hooks/gemini/after-model.sh)
if payload_has '"model_call"'; then pass "finishReason=STOP → emits events(model_call)"; else fail "emits events(model_call)"; fi

# ========================================================
echo ""
echo "SessionEnd (Gemini) — session end event"
# ========================================================

reset_capture
output=$(echo '{"session_id":"gem-sess","cwd":"/tmp/project"}' \
  | GEMINI_CWD="/tmp/project" HOME="$TEST_HOME" run_hook hooks/gemini/session-end.sh)
if [[ "$output" == *"{}"* ]]; then pass "outputs {} on stdout"; else fail "outputs {}" "got: $output"; fi
if payload_has '"session_end"'; then pass "emits events(session_end)"; else fail "emits events(session_end)"; fi

# ========================================================
echo ""
echo "Notify (Codex) — event filtering"
# ========================================================

# Valid event → exit 0
reset_capture
rc=0
run_hook hooks/codex/notify.sh '{"type":"agent-turn-complete","thread-id":"t1","cwd":"/tmp/project"}' || rc=$?
if [[ $rc -eq 0 ]]; then pass "agent-turn-complete → exit 0"; else fail "agent-turn-complete" "got exit $rc"; fi

# Non-matching type → exit 0, no emission
reset_capture
rc=0
run_hook hooks/codex/notify.sh '{"type":"other","cwd":"/tmp/project"}' || rc=$?
if [[ $rc -eq 0 ]]; then pass "non-matching type → exit 0"; else fail "non-matching type" "got exit $rc"; fi
count=$(payload_count)
if [[ "$count" -eq 0 ]]; then pass "non-matching type → no metrics"; else fail "non-matching type → no metrics" "got $count"; fi

# ========================================================
echo ""
echo "Install / Uninstall — config injection + cleanup"
# ========================================================

INSTALL_HOME=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR" "$CAPTURE_DIR" "$TEST_HOME" "$INSTALL_HOME"' EXIT

# Create mock CLI binaries so install.sh detects them
for cli in claude codex gemini; do
  echo '#!/bin/bash' > "$MOCK_DIR/$cli"
  chmod +x "$MOCK_DIR/$cli"
done

# Run install
HOME="$INSTALL_HOME" bash "$REPO_ROOT/hooks/install.sh" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then pass "install.sh exits 0"; else fail "install.sh" "got exit $rc"; fi

# Claude: hooks + env injected
if jq -e '.hooks.PreToolUse' "$INSTALL_HOME/.claude/settings.json" &>/dev/null; then
  pass "Claude: PreToolUse hook injected"
else
  fail "Claude: PreToolUse hook missing"
fi
if jq -e '.hooks.Stop' "$INSTALL_HOME/.claude/settings.json" &>/dev/null; then
  pass "Claude: Stop hook injected"
else
  fail "Claude: Stop hook missing"
fi
if jq -e '.env.CLAUDE_CODE_ENABLE_TELEMETRY' "$INSTALL_HOME/.claude/settings.json" &>/dev/null; then
  pass "Claude: native OTel env injected"
else
  fail "Claude: native OTel env missing"
fi

# Codex: notify + otel
if grep -q 'notify' "$INSTALL_HOME/.codex/config.toml" 2>/dev/null; then
  pass "Codex: notify hook injected"
else
  fail "Codex: notify hook missing"
fi
if grep -q '\[otel\]' "$INSTALL_HOME/.codex/config.toml" 2>/dev/null; then
  pass "Codex: [otel] section injected"
else
  fail "Codex: [otel] section missing"
fi

# Gemini: hooks + telemetry
if jq -e '.hooks.AfterTool' "$INSTALL_HOME/.gemini/settings.json" &>/dev/null; then
  pass "Gemini: AfterTool hook injected"
else
  fail "Gemini: AfterTool hook missing"
fi
if jq -e '.telemetry.enabled' "$INSTALL_HOME/.gemini/settings.json" &>/dev/null; then
  pass "Gemini: telemetry config injected"
else
  fail "Gemini: telemetry config missing"
fi

# Run uninstall
HOME="$INSTALL_HOME" bash "$REPO_ROOT/hooks/uninstall.sh" >/dev/null 2>&1

# Claude: hooks + env removed
if ! jq -e '.hooks' "$INSTALL_HOME/.claude/settings.json" &>/dev/null; then
  pass "Claude: hooks removed after uninstall"
else
  fail "Claude: hooks still present after uninstall"
fi
if ! jq -e '.env.CLAUDE_CODE_ENABLE_TELEMETRY' "$INSTALL_HOME/.claude/settings.json" &>/dev/null; then
  pass "Claude: OTel env removed after uninstall"
else
  fail "Claude: OTel env still present after uninstall"
fi

# Codex: notify + otel removed
if ! grep -q 'notify' "$INSTALL_HOME/.codex/config.toml" 2>/dev/null; then
  pass "Codex: notify removed after uninstall"
else
  fail "Codex: notify still present after uninstall"
fi

# Gemini: hooks + telemetry removed
if ! jq -e '.hooks' "$INSTALL_HOME/.gemini/settings.json" &>/dev/null; then
  pass "Gemini: hooks removed after uninstall"
else
  fail "Gemini: hooks still present after uninstall"
fi
if ! jq -e '.telemetry' "$INSTALL_HOME/.gemini/settings.json" &>/dev/null; then
  pass "Gemini: telemetry removed after uninstall"
else
  fail "Gemini: telemetry still present after uninstall"
fi

# ========================================================
echo ""
echo "Install / Uninstall — preserves other tools' hooks (regression)"
# ========================================================
# A plain `. * $hooks` deep-merge in install.sh (and `del(.hooks)` in uninstall.sh) used to
# replace/wipe whole hook-event arrays, silently dropping any other tool's hooks configured
# on the same event (real-world incident: this took out rtk + several moshi-hook entries).
# Pre-populate a settings.json with non-shepherd hooks on the same events shepherd uses, then
# confirm install.sh adds its own entries alongside them (not instead of them), a second
# install.sh doesn't duplicate shepherd's own entries, and uninstall.sh removes only
# shepherd's entries while leaving the others untouched.
OTHER_HOME=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR" "$CAPTURE_DIR" "$TEST_HOME" "$INSTALL_HOME" "$OTHER_HOME"' EXIT
mkdir -p "$OTHER_HOME/.claude"
cat > "$OTHER_HOME/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "rtk hook claude"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "moshi-hook claude-hook", "async": true}]}
    ]
  },
  "env": {"SOME_OTHER_VAR": "keep-me"}
}
EOF

HOME="$OTHER_HOME" bash "$REPO_ROOT/hooks/install.sh" claude >/dev/null 2>&1
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash" and .hooks[0].command == "rtk hook claude")' \
     "$OTHER_HOME/.claude/settings.json" &>/dev/null; then
  pass "install.sh preserves another tool's PreToolUse hook (rtk)"
else
  fail "install.sh dropped rtk's PreToolUse hook"
fi
if jq -e '.hooks.Stop[] | select(.hooks[0].command == "moshi-hook claude-hook")' \
     "$OTHER_HOME/.claude/settings.json" &>/dev/null; then
  pass "install.sh preserves another tool's Stop hook (moshi-hook)"
else
  fail "install.sh dropped moshi-hook's Stop hook"
fi
if jq -e '.env.SOME_OTHER_VAR == "keep-me"' "$OTHER_HOME/.claude/settings.json" &>/dev/null; then
  pass "install.sh preserves unrelated env vars"
else
  fail "install.sh dropped unrelated env vars"
fi
shepherd_pretooluse_count=$(jq '[.hooks.PreToolUse[] | select(([.hooks[]?.command // ""] | any(test("/hooks/claude/pre-tool-use\\.sh$"))))] | length' \
  "$OTHER_HOME/.claude/settings.json")
if [[ "$shepherd_pretooluse_count" -eq 1 ]]; then
  pass "install.sh injects exactly one shepherd PreToolUse entry"
else
  fail "install.sh PreToolUse entry count" "expected 1, got $shepherd_pretooluse_count"
fi

# Re-install: shepherd's own entry must not duplicate, other tools' must still be there
HOME="$OTHER_HOME" bash "$REPO_ROOT/hooks/install.sh" claude >/dev/null 2>&1
shepherd_pretooluse_count=$(jq '[.hooks.PreToolUse[] | select(([.hooks[]?.command // ""] | any(test("/hooks/claude/pre-tool-use\\.sh$"))))] | length' \
  "$OTHER_HOME/.claude/settings.json")
if [[ "$shepherd_pretooluse_count" -eq 1 ]]; then
  pass "re-running install.sh does not duplicate shepherd's own entry"
else
  fail "install.sh re-install duplicate check" "expected 1 shepherd entry, got $shepherd_pretooluse_count"
fi
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash" and .hooks[0].command == "rtk hook claude")' \
     "$OTHER_HOME/.claude/settings.json" &>/dev/null; then
  pass "re-running install.sh still preserves rtk's hook"
else
  fail "re-install dropped rtk's PreToolUse hook"
fi

# Uninstall: shepherd's entries go, rtk/moshi-hook/env stay
HOME="$OTHER_HOME" bash "$REPO_ROOT/hooks/uninstall.sh" claude >/dev/null 2>&1
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash" and .hooks[0].command == "rtk hook claude")' \
     "$OTHER_HOME/.claude/settings.json" &>/dev/null; then
  pass "uninstall.sh preserves another tool's PreToolUse hook (rtk)"
else
  fail "uninstall.sh dropped rtk's PreToolUse hook"
fi
if jq -e '.hooks.Stop[] | select(.hooks[0].command == "moshi-hook claude-hook")' \
     "$OTHER_HOME/.claude/settings.json" &>/dev/null; then
  pass "uninstall.sh preserves another tool's Stop hook (moshi-hook)"
else
  fail "uninstall.sh dropped moshi-hook's Stop hook"
fi
if jq -e '.env.SOME_OTHER_VAR == "keep-me"' "$OTHER_HOME/.claude/settings.json" &>/dev/null; then
  pass "uninstall.sh preserves unrelated env vars"
else
  fail "uninstall.sh dropped unrelated env vars"
fi
shepherd_pretooluse_count=$(jq '[.hooks.PreToolUse[]? | select(([.hooks[]?.command // ""] | any(test("/hooks/claude/pre-tool-use\\.sh$"))))] | length' \
  "$OTHER_HOME/.claude/settings.json")
if [[ "$shepherd_pretooluse_count" -eq 0 ]]; then
  pass "uninstall.sh removes shepherd's own PreToolUse entry"
else
  fail "uninstall.sh left shepherd's entry behind" "count $shepherd_pretooluse_count"
fi

# ========================================================
echo ""
echo "Hook tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
