#!/usr/bin/env bash
# tests/test-parsers.sh — session parser tests with fixtures
#
# Verifies span count, required fields, attribute values, and error status.
# Requires: jq, bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_ROOT/tests/fixtures"
PASS=0 FAIL=0

pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; }

if ! command -v jq &>/dev/null; then
  echo "  ✗ jq not found — cannot run parser tests"
  exit 1
fi

# ========================================================
echo "Claude session parser"
# ========================================================

CLAUDE_OUTPUT=$(bash "$REPO_ROOT/hooks/lib/session-parser.sh" "$FIXTURES/claude-session.jsonl" 2>/dev/null)
# Spans only (the parser's last line is a {"metrics": {...}} sidecar with no span fields)
CLAUDE_SPANS=$(echo "$CLAUDE_OUTPUT" | jq -c 'select(.metrics == null)')

# Span count: root + meta + 2 tools + 1 compaction = 5
span_count=$(echo "$CLAUDE_SPANS" | wc -l | tr -d ' ')
if [[ "$span_count" -eq 5 ]]; then
  pass "span count = 5 (root + meta + 2 tools + compaction)"
else
  fail "span count" "expected 5, got $span_count"
fi

# All spans have required fields
missing=0
while IFS= read -r span; do
  for field in trace_id span_id name start_ns end_ns status attributes; do
    if ! echo "$span" | jq -e "has(\"$field\")" >/dev/null 2>&1; then
      missing=$((missing+1))
    fi
  done
done <<< "$CLAUDE_SPANS"
if [[ $missing -eq 0 ]]; then
  pass "all spans have required fields"
else
  fail "missing fields" "$missing fields missing across spans"
fi

# Root span attributes
root=$(echo "$CLAUDE_OUTPUT" | jq -s '.[0]')
root_name=$(echo "$root" | jq -r '.name')
if [[ "$root_name" == "claude.session" ]]; then pass "root span name = claude.session"; else fail "root span name" "got $root_name"; fi

provider=$(echo "$root" | jq -r '.attributes.provider')
if [[ "$provider" == "claude-code" ]]; then pass "root provider = claude-code"; else fail "root provider" "got $provider"; fi

model=$(echo "$root" | jq -r '.attributes.model')
if [[ "$model" == "claude-sonnet-4-20250514" ]]; then pass "root model correct"; else fail "root model" "got $model"; fi

tool_count=$(echo "$root" | jq -r '.attributes["tool.count"]')
if [[ "$tool_count" == "2" ]]; then pass "root tool.count = 2"; else fail "root tool.count" "got $tool_count"; fi

error_count=$(echo "$root" | jq -r '.attributes["tool.error_count"]')
if [[ "$error_count" == "1" ]]; then pass "root tool.error_count = 1"; else fail "root tool.error_count" "got $error_count"; fi

compaction_count=$(echo "$root" | jq -r '.attributes["compaction.count"]')
if [[ "$compaction_count" == "1" ]]; then pass "root compaction.count = 1"; else fail "root compaction.count" "got $compaction_count"; fi

# Error tool span has status=2
error_tool=$(echo "$CLAUDE_OUTPUT" | jq -s '[.[] | select(.name == "claude.tool.Bash")][0]')
error_status=$(echo "$error_tool" | jq '.status')
if [[ "$error_status" == "2" ]]; then pass "Bash tool span status = 2 (error)"; else fail "Bash tool span status" "got $error_status"; fi

# Compaction span exists
comp_span=$(echo "$CLAUDE_OUTPUT" | jq -s '[.[] | select(.name == "claude.compaction")][0]')
comp_trigger=$(echo "$comp_span" | jq -r '.attributes["compaction.trigger"]')
if [[ "$comp_trigger" == "auto" ]]; then pass "compaction span trigger = auto"; else fail "compaction span" "got trigger=$comp_trigger"; fi

# Trace ID consistency
trace_ids=$(echo "$CLAUDE_SPANS" | jq -r '.trace_id' | sort -u | wc -l | tr -d ' ')
if [[ "$trace_ids" -eq 1 ]]; then pass "all spans share same trace_id"; else fail "trace_id consistency" "$trace_ids unique trace_ids"; fi

# Context breakdown attributes
tool_output_chars=$(echo "$root" | jq -r '.attributes["context.tool_output_chars"]')
if [[ "$tool_output_chars" == "64" ]]; then pass "context.tool_output_chars = 64"; else fail "context.tool_output_chars" "got $tool_output_chars"; fi

tool_output_est=$(echo "$root" | jq -r '.attributes["context.tool_output_tokens_est"]')
if [[ "$tool_output_est" == "16" ]]; then pass "context.tool_output_tokens_est = 16"; else fail "context.tool_output_tokens_est" "got $tool_output_est"; fi

user_prompt_chars=$(echo "$root" | jq -r '.attributes["context.user_prompt_chars"]')
if [[ "$user_prompt_chars" == "38" ]]; then pass "context.user_prompt_chars = 38"; else fail "context.user_prompt_chars" "got $user_prompt_chars"; fi

user_prompt_est=$(echo "$root" | jq -r '.attributes["context.user_prompt_tokens_est"]')
if [[ "$user_prompt_est" == "9" ]]; then pass "context.user_prompt_tokens_est = 9"; else fail "context.user_prompt_tokens_est" "got $user_prompt_est"; fi

compact_summary_chars=$(echo "$root" | jq -r '.attributes["context.compact_summary_chars"]')
if [[ "$compact_summary_chars" == "58" ]]; then pass "context.compact_summary_chars = 58"; else fail "context.compact_summary_chars" "got $compact_summary_chars"; fi

compact_summary_est=$(echo "$root" | jq -r '.attributes["context.compact_summary_tokens_est"]')
if [[ "$compact_summary_est" == "14" ]]; then pass "context.compact_summary_tokens_est = 14"; else fail "context.compact_summary_tokens_est" "got $compact_summary_est"; fi

compaction_pre_tokens=$(echo "$root" | jq -r '.attributes["context.compaction_pre_tokens"]')
if [[ "$compaction_pre_tokens" == "50000" ]]; then pass "context.compaction_pre_tokens = 50000"; else fail "context.compaction_pre_tokens" "got $compaction_pre_tokens"; fi

# Per-turn spans (gated by SHEPARD_DETAILED_TRACES=1)
CLAUDE_DETAILED=$(SHEPARD_DETAILED_TRACES=1 bash "$REPO_ROOT/hooks/lib/session-parser.sh" "$FIXTURES/claude-session.jsonl" 2>/dev/null)
CLAUDE_DETAILED_SPANS=$(echo "$CLAUDE_DETAILED" | jq -c 'select(.metrics == null)')

detail_count=$(echo "$CLAUDE_DETAILED_SPANS" | wc -l | tr -d ' ')
if [[ "$detail_count" -eq 7 ]]; then pass "detailed spans = 7 (5 base + 2 turns)"; else fail "detailed span count" "expected 7, got $detail_count"; fi

turn0=$(echo "$CLAUDE_DETAILED" | jq -s '[.[] | select(.name == "claude.turn" and .attributes["turn.index"] == "0")][0]')
turn0_input=$(echo "$turn0" | jq -r '.attributes["turn.input_tokens"]')
if [[ "$turn0_input" == "450" ]]; then pass "turn 0 input_tokens = 450"; else fail "turn 0 input_tokens" "got $turn0_input"; fi

turn0_tools=$(echo "$turn0" | jq -r '.attributes["turn.tool_count"]')
if [[ "$turn0_tools" == "2" ]]; then pass "turn 0 tool_count = 2"; else fail "turn 0 tool_count" "got $turn0_tools"; fi

turn1=$(echo "$CLAUDE_DETAILED" | jq -s '[.[] | select(.name == "claude.turn" and .attributes["turn.index"] == "1")][0]')
turn1_input=$(echo "$turn1" | jq -r '.attributes["turn.input_tokens"]')
if [[ "$turn1_input" == "50" ]]; then pass "turn 1 input_tokens = 50"; else fail "turn 1 input_tokens" "got $turn1_input"; fi

turn1_tools=$(echo "$turn1" | jq -r '.attributes["turn.tool_count"]')
if [[ "$turn1_tools" == "0" ]]; then pass "turn 1 tool_count = 0"; else fail "turn 1 tool_count" "got $turn1_tools"; fi

turn_parent=$(echo "$turn0" | jq -r '.parent_span_id')
root_sid=$(echo "$CLAUDE_OUTPUT" | jq -s -r '.[0].span_id')
if [[ "$turn_parent" == "$root_sid" ]]; then pass "turn spans parent = root span"; else fail "turn parent" "got $turn_parent, expected $root_sid"; fi

# ========================================================
echo ""
echo "Claude session parser — skills/subagents/MCP sidecar"
# ========================================================
# Fixture: claude-session-skills.jsonl.
# Turn 1: opener has "<command-name>/obs-cost</command-name>" + one assistant (model
#   claude-opus-4-8, usage input:200 output:1000 cacheRead:40000 cacheCreation:600) that calls
#   Skill(superpowers:brainstorming). Two invocations share this turn's token window
#   (/obs-cost slash command + the Skill call) -> split evenly by 2 -> 100/500/20000/300 each.
# Turn 2: plain opener (no command), one assistant (model claude-haiku-4-5-20251001, usage
#   input:300 output:800 cacheRead:5000 cacheCreation:200) that calls Task(subagent_type:
#   code-reviewer). Also calls mcp__tiger__db_execute_query (zero usage, empty tool_result so
#   it doesn't perturb token/char assertions) -> mcp = [{tiger, db_execute_query, count:1}].
#   No skill/slash invocations in this turn -> contributes nothing to skill attribution.
# No compaction entries. context.tool_output_chars = 64 (27 + 37), context.user_prompt_chars =
# 64 (38 + 26) -- verified independently with `wc -c` on the fixture's literal strings.

SKILLS_OUTPUT=$(bash "$REPO_ROOT/hooks/lib/session-parser.sh" "$FIXTURES/claude-session-skills.jsonl" 2>/dev/null)
SKILLS_SPANS=$(echo "$SKILLS_OUTPUT" | jq -c 'select(.metrics == null)')

# 1. Sidecar is the last line and the only line with .metrics
last_line=$(echo "$SKILLS_OUTPUT" | tail -1)
if echo "$last_line" | jq -e '.metrics' >/dev/null 2>&1; then pass "sidecar is last line"; else fail "sidecar last line" "last line has no .metrics"; fi

metrics_lines=$(echo "$SKILLS_OUTPUT" | jq -c 'select(.metrics != null)' | wc -l | tr -d ' ')
if [[ "$metrics_lines" -eq 1 ]]; then pass "exactly one metrics line"; else fail "metrics line count" "expected 1, got $metrics_lines"; fi

metrics=$(echo "$last_line" | jq '.metrics')

# 2. session_id / git_repo
m_session_id=$(echo "$metrics" | jq -r '.session_id')
if [[ "$m_session_id" == "a1b2c3d4-0001-4000-8000-000000000099" ]]; then pass "sidecar session_id matches"; else fail "sidecar session_id" "got $m_session_id"; fi

m_git_repo=$(echo "$metrics" | jq -r '.git_repo')
if [[ "$m_git_repo" == "tiger-den" ]]; then pass "sidecar git_repo matches"; else fail "sidecar git_repo" "got $m_git_repo"; fi

# 3. tokens array: one entry per model, matching fixture usage sums
opus_tok=$(echo "$metrics" | jq '.tokens[] | select(.model == "claude-opus-4-8")')
if [[ "$(echo "$opus_tok" | jq -r '.input')" == "200" && "$(echo "$opus_tok" | jq -r '.output')" == "1000" && \
     "$(echo "$opus_tok" | jq -r '.cacheRead')" == "40000" && "$(echo "$opus_tok" | jq -r '.cacheCreation')" == "600" ]]; then
  pass "tokens[claude-opus-4-8] matches fixture usage"
else
  fail "tokens[claude-opus-4-8]" "got $opus_tok"
fi

haiku_tok=$(echo "$metrics" | jq '.tokens[] | select(.model == "claude-haiku-4-5-20251001")')
if [[ "$(echo "$haiku_tok" | jq -r '.input')" == "300" && "$(echo "$haiku_tok" | jq -r '.output')" == "800" && \
     "$(echo "$haiku_tok" | jq -r '.cacheRead')" == "5000" && "$(echo "$haiku_tok" | jq -r '.cacheCreation')" == "200" ]]; then
  pass "tokens[claude-haiku-4-5-20251001] matches fixture usage"
else
  fail "tokens[claude-haiku-4-5-20251001]" "got $haiku_tok"
fi

tokens_len=$(echo "$metrics" | jq '.tokens | length')
if [[ "$tokens_len" -eq 2 ]]; then pass "tokens array has 2 models"; else fail "tokens array length" "expected 2, got $tokens_len"; fi

# 4-5. skills array: even split across the two turn-1 invocations, count = 1 each
slash_skill=$(echo "$metrics" | jq '.skills[] | select(.skill == "obs-cost")')
if [[ "$(echo "$slash_skill" | jq -r '.kind')" == "slash_command" && "$(echo "$slash_skill" | jq -r '.count')" == "1" ]]; then
  pass "skills[obs-cost] kind=slash_command count=1"
else
  fail "skills[obs-cost] kind/count" "got $slash_skill"
fi
slash_tok=$(echo "$slash_skill" | jq '.tokens[0]')
if [[ "$(echo "$slash_tok" | jq -r '.input')" == "100" && "$(echo "$slash_tok" | jq -r '.output')" == "500" && \
     "$(echo "$slash_tok" | jq -r '.cacheRead')" == "20000" && "$(echo "$slash_tok" | jq -r '.cacheCreation')" == "300" ]]; then
  pass "skills[obs-cost] tokens = even split (100/500/20000/300)"
else
  fail "skills[obs-cost] tokens" "got $slash_tok"
fi

skill_inv=$(echo "$metrics" | jq '.skills[] | select(.skill == "superpowers:brainstorming")')
if [[ "$(echo "$skill_inv" | jq -r '.kind')" == "skill" && "$(echo "$skill_inv" | jq -r '.count')" == "1" ]]; then
  pass "skills[superpowers:brainstorming] kind=skill count=1"
else
  fail "skills[superpowers:brainstorming] kind/count" "got $skill_inv"
fi
skill_tok=$(echo "$skill_inv" | jq '.tokens[0]')
if [[ "$(echo "$skill_tok" | jq -r '.input')" == "100" && "$(echo "$skill_tok" | jq -r '.output')" == "500" && \
     "$(echo "$skill_tok" | jq -r '.cacheRead')" == "20000" && "$(echo "$skill_tok" | jq -r '.cacheCreation')" == "300" ]]; then
  pass "skills[superpowers:brainstorming] tokens = even split (100/500/20000/300)"
else
  fail "skills[superpowers:brainstorming] tokens" "got $skill_tok"
fi

skills_len=$(echo "$metrics" | jq '.skills | length')
if [[ "$skills_len" -eq 2 ]]; then pass "skills array has 2 invocations (turn 2 contributes none)"; else fail "skills array length" "expected 2, got $skills_len"; fi

# 6. subagents
subagents=$(echo "$metrics" | jq -c '.subagents')
if [[ "$subagents" == '[{"subagent_type":"code-reviewer","count":1}]' ]]; then
  pass "subagents = [{code-reviewer, count:1}]"
else
  fail "subagents" "got $subagents"
fi

# 7. mcp
mcp=$(echo "$metrics" | jq -c '.mcp')
if [[ "$mcp" == '[{"server":"tiger","tool":"db_execute_query","count":1}]' ]]; then
  pass "mcp = [{tiger, db_execute_query, count:1}]"
else
  fail "mcp" "got $mcp"
fi

# 8. Tool span attributes: Skill call carries skill.name, Task call carries agent.type
skill_span=$(echo "$SKILLS_SPANS" | jq -s '[.[] | select(.name == "claude.tool.Skill")][0]')
skill_name_attr=$(echo "$skill_span" | jq -r '.attributes["skill.name"]')
if [[ "$skill_name_attr" == "superpowers:brainstorming" ]]; then pass "claude.tool.Skill span has skill.name"; else fail "claude.tool.Skill skill.name" "got $skill_name_attr"; fi

task_span=$(echo "$SKILLS_SPANS" | jq -s '[.[] | select(.name == "claude.tool.Task")][0]')
agent_type_attr=$(echo "$task_span" | jq -r '.attributes["agent.type"]')
if [[ "$agent_type_attr" == "code-reviewer" ]]; then pass "claude.tool.Task span has agent.type"; else fail "claude.tool.Task agent.type" "got $agent_type_attr"; fi

# 9. context chars + compaction_count
m_tool_output_chars=$(echo "$metrics" | jq -r '.context.tool_output_chars')
if [[ "$m_tool_output_chars" == "64" ]]; then pass "sidecar context.tool_output_chars = 64"; else fail "sidecar context.tool_output_chars" "got $m_tool_output_chars"; fi

m_user_prompt_chars=$(echo "$metrics" | jq -r '.context.user_prompt_chars')
if [[ "$m_user_prompt_chars" == "64" ]]; then pass "sidecar context.user_prompt_chars = 64"; else fail "sidecar context.user_prompt_chars" "got $m_user_prompt_chars"; fi

m_compaction_count=$(echo "$metrics" | jq -r '.compaction_count')
if [[ "$m_compaction_count" == "0" ]]; then pass "sidecar compaction_count = 0"; else fail "sidecar compaction_count" "got $m_compaction_count"; fi

# 10. SHEPARD_DETAILED_TRACES=1: claude.turn spans still emitted, sidecar still last
SKILLS_DETAILED=$(SHEPARD_DETAILED_TRACES=1 bash "$REPO_ROOT/hooks/lib/session-parser.sh" "$FIXTURES/claude-session-skills.jsonl" 2>/dev/null)
detailed_turn_count=$(echo "$SKILLS_DETAILED" | jq -c 'select(.name == "claude.turn")' | wc -l | tr -d ' ')
if [[ "$detailed_turn_count" -eq 2 ]]; then pass "detailed skills fixture: 2 claude.turn spans"; else fail "detailed skills claude.turn count" "expected 2, got $detailed_turn_count"; fi

detailed_last=$(echo "$SKILLS_DETAILED" | tail -1)
if echo "$detailed_last" | jq -e '.metrics' >/dev/null 2>&1; then pass "detailed skills fixture: sidecar still last line"; else fail "detailed skills sidecar last" "last line has no .metrics"; fi

# ========================================================
echo ""
echo "Codex session parser"
# ========================================================

CODEX_OUTPUT=$(bash "$REPO_ROOT/hooks/lib/codex-session-parser.sh" "$FIXTURES/codex-session.jsonl" 2>/dev/null)

# Span count: root + meta + 1 tool = 3
span_count=$(echo "$CODEX_OUTPUT" | wc -l | tr -d ' ')
if [[ "$span_count" -eq 3 ]]; then
  pass "span count = 3 (root + meta + 1 tool)"
else
  fail "span count" "expected 3, got $span_count"
fi

# Root span attributes
root=$(echo "$CODEX_OUTPUT" | jq -s '.[0]')
root_name=$(echo "$root" | jq -r '.name')
if [[ "$root_name" == "codex.session" ]]; then pass "root span name = codex.session"; else fail "root span name" "got $root_name"; fi

provider=$(echo "$root" | jq -r '.attributes.provider')
if [[ "$provider" == "codex" ]]; then pass "root provider = codex"; else fail "root provider" "got $provider"; fi

tokens_in=$(echo "$root" | jq -r '.attributes["tokens.input"]')
if [[ "$tokens_in" == "500" ]]; then pass "root tokens.input = 500"; else fail "root tokens.input" "got $tokens_in"; fi

# Tool span name
tool=$(echo "$CODEX_OUTPUT" | jq -s '[.[] | select(.name | startswith("codex.tool"))][0]')
tool_name=$(echo "$tool" | jq -r '.name')
if [[ "$tool_name" == "codex.tool.shell" ]]; then pass "tool span = codex.tool.shell"; else fail "tool span name" "got $tool_name"; fi

# Trace ID consistency
trace_ids=$(echo "$CODEX_OUTPUT" | jq -r '.trace_id' | sort -u | wc -l | tr -d ' ')
if [[ "$trace_ids" -eq 1 ]]; then pass "all spans share same trace_id"; else fail "trace_id consistency" "$trace_ids unique trace_ids"; fi

# ========================================================
echo ""
echo "Gemini session parser"
# ========================================================

GEMINI_OUTPUT=$(bash "$REPO_ROOT/hooks/lib/gemini-session-parser.sh" "$FIXTURES/gemini-session.json" 2>/dev/null)

# Span count: root + meta + 2 tools = 4
span_count=$(echo "$GEMINI_OUTPUT" | wc -l | tr -d ' ')
if [[ "$span_count" -eq 4 ]]; then
  pass "span count = 4 (root + meta + 2 tools)"
else
  fail "span count" "expected 4, got $span_count"
fi

# Root span attributes
root=$(echo "$GEMINI_OUTPUT" | jq -s '.[0]')
root_name=$(echo "$root" | jq -r '.name')
if [[ "$root_name" == "gemini.session" ]]; then pass "root span name = gemini.session"; else fail "root span name" "got $root_name"; fi

provider=$(echo "$root" | jq -r '.attributes.provider')
if [[ "$provider" == "gemini-cli" ]]; then pass "root provider = gemini-cli"; else fail "root provider" "got $provider"; fi

tool_count=$(echo "$root" | jq -r '.attributes["tool.count"]')
if [[ "$tool_count" == "2" ]]; then pass "root tool.count = 2"; else fail "root tool.count" "got $tool_count"; fi

error_count=$(echo "$root" | jq -r '.attributes["tool.error_count"]')
if [[ "$error_count" == "1" ]]; then pass "root tool.error_count = 1 (shell error)"; else fail "root tool.error_count" "got $error_count"; fi

# Error tool span has status=2
error_tool=$(echo "$GEMINI_OUTPUT" | jq -s '[.[] | select(.name == "gemini.tool.shell")][0]')
error_status=$(echo "$error_tool" | jq '.status')
if [[ "$error_status" == "2" ]]; then pass "shell tool span status = 2 (error)"; else fail "shell tool span status" "got $error_status"; fi

# Trace ID consistency
trace_ids=$(echo "$GEMINI_OUTPUT" | jq -r '.trace_id' | sort -u | wc -l | tr -d ' ')
if [[ "$trace_ids" -eq 1 ]]; then pass "all spans share same trace_id"; else fail "trace_id consistency" "$trace_ids unique trace_ids"; fi

# ========================================================
echo ""
echo "Parser tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
