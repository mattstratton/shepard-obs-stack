#!/usr/bin/env bash
# hooks/claude/stop.sh — Claude Code Stop hook
#
# Stdin JSON:
#   { "session_id", "transcript_path", "cwd", "hook_event_name",
#     "stop_hook_active", "last_assistant_message" }
#
# Emits: events_total(session_end) counter to Prometheus via OTel Collector.
# Then launches session-parser.sh in background to generate synthetic traces → Tempo.
# All token/cost/session metrics come from Claude's native OTel export.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Rust accelerator: full hook replacement
source "${SCRIPT_DIR}/../lib/accelerator.sh"
if [[ -n "$SHEPARD_HOOK" ]]; then
  "$SHEPARD_HOOK" hook claude stop
  exit $?
fi
source "${SCRIPT_DIR}/../lib/git-context.sh"
source "${SCRIPT_DIR}/../lib/metrics.sh"
source "${SCRIPT_DIR}/../lib/traces.sh"

input="$(cat)"

# Don't re-fire if already in a stop hook loop
stop_active="$(jq -r '.stop_hook_active // false' <<< "$input")"
[[ "$stop_active" == "true" ]] && exit 0

cwd="$(jq -r '.cwd // ""' <<< "$input")"
session_id="$(jq -r '.session_id // ""' <<< "$input")"

# Git context
get_git_context "$cwd"

# Emit session_end event
evt_labels=$(jq -n -c --arg s "claude-code" --arg e "session_end" --arg g "$GIT_REPO" \
  '{source:$s, event_type:$e, git_repo:$g}')
emit_counter "events" "1" "$evt_labels"

# --- Session log parser → synthetic traces to Tempo + metrics sidecar deltas ---
# Locate JSONL session file by session_id (a UUID, so this is exact) rather than
# reconstructing the project-slug directory from $cwd: Claude Code's directory-to-slug
# convention (replace special characters with "-") has varied across versions/paths — some
# sessions on this machine keep dots from a path segment (e.g. "github.com"), others convert
# them to dashes — so a hand-rolled sed can silently compute the wrong path and never find a
# real, existing session file. -print -quit stops at the first match; the projects tree is
# shallow (~/.claude/projects/<slug>/<session_id>.jsonl) so this is cheap.
#
# The Stop hook fires at the end of EVERY assistant turn, but the parser's metrics sidecar
# (hooks/lib/session-parser.sh) is CUMULATIVE for the whole session. So we track the previous
# firing's sidecar per session (state file) and emit only the delta — otherwise every firing
# would re-add the whole session's totals (upstream double-count bug for compaction/context
# metrics; fixed here by routing everything through this same delta path).
if [[ -n "$session_id" && -n "$cwd" ]]; then
  session_file=$(find "${HOME}/.claude/projects" -maxdepth 2 -name "${session_id}.jsonl" -print -quit 2>/dev/null)

  if [[ -n "$session_file" && -f "$session_file" ]]; then
    # Parse session log, emit traces + metric deltas — fully detached
    (
      parser_output=$(bash "${SCRIPT_DIR}/../lib/session-parser.sh" "$session_file")
      [[ -z "$parser_output" ]] && exit 0

      spans=$(echo "$parser_output" | jq -c 'select(.metrics == null)')
      cur=$(echo "$parser_output" | jq -c '.metrics | select(. != null)')

      # Emit traces to Tempo first — unchanged semantics
      echo "$spans" | emit_spans "claude-code-session"

      if [[ -n "$cur" ]]; then
        STATE_DIR="${SHEPARD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/shepard-obs}/claude"
        mkdir -p "$STATE_DIR"
        state_file="${STATE_DIR}/${session_id}.json"

        if mkdir "${state_file}.lock" 2>/dev/null; then
          # Atomic, portable lock (no flock on macOS). If another firing holds it, skip
          # entirely — deltas are computed against the stored cumulative baseline, so a
          # skipped firing's delta is folded into the next firing's delta automatically.
          trap 'rmdir "${state_file}.lock" 2>/dev/null' EXIT

          prev=$(cat "$state_file" 2>/dev/null || echo '{}')
          # Corrupt state file → treat as fresh (full re-emit once), never crash the hook
          jq -e . >/dev/null 2>&1 <<< "$prev" || prev='{}'

          deltas=$(jq -n -c --argjson cur "$cur" --argjson prev "$prev" --arg git_repo_fallback "$GIT_REPO" '
            def clamp0: if . < 0 then 0 else . end;

            def token_diff($c; $p):
              ($c // []) as $ca | ($p // []) as $pa |
              [$ca[] | . as $cm |
                (($pa[] | select(.model == $cm.model)) // {input:0,output:0,cacheRead:0,cacheCreation:0}) as $pm |
                {model: $cm.model,
                 input: (($cm.input // 0) - ($pm.input // 0) | clamp0),
                 output: (($cm.output // 0) - ($pm.output // 0) | clamp0),
                 cacheRead: (($cm.cacheRead // 0) - ($pm.cacheRead // 0) | clamp0),
                 cacheCreation: (($cm.cacheCreation // 0) - ($pm.cacheCreation // 0) | clamp0)}];

            ($cur.git_repo // "") as $sidecar_repo |
            (if $sidecar_repo != "" then $sidecar_repo else $git_repo_fallback end) as $git_repo |

            [
              ( token_diff($cur.tokens; $prev.tokens)[] | . as $td |
                ["input","output","cacheRead","cacheCreation"][] as $type |
                {metric:"session_tokens", value: ($td[$type]),
                 labels:{source:"claude-code", git_repo:$git_repo, model:$td.model, type:$type}}
                | select(.value > 0)
              ),
              ( ($cur.skills // [])[] | . as $cs |
                ((($prev.skills // [])[] | select(.skill == $cs.skill and .kind == $cs.kind)) // {count:0, tokens: []}) as $ps |
                (($cs.count // 0) - ($ps.count // 0) | clamp0) as $inv_d |
                (if $inv_d > 0 then
                  {metric:"skill_invocations", value:$inv_d,
                   labels:{source:"claude-code", git_repo:$git_repo, skill_name:$cs.skill, skill_type:$cs.kind}}
                 else empty end),
                ( token_diff($cs.tokens; $ps.tokens)[] | . as $td |
                  ["input","output","cacheRead","cacheCreation"][] as $type |
                  {metric:"skill_tokens", value: ($td[$type]),
                   labels:{source:"claude-code", git_repo:$git_repo, skill_name:$cs.skill, skill_type:$cs.kind, model:$td.model, type:$type}}
                  | select(.value > 0)
                )
              ),
              ( ($cur.subagents // [])[] | . as $cs |
                ((($prev.subagents // [])[] | select(.subagent_type == $cs.subagent_type)) // {count:0}) as $ps |
                (($cs.count // 0) - ($ps.count // 0) | clamp0) as $d |
                select($d > 0) |
                {metric:"subagent_invocations", value:$d,
                 labels:{source:"claude-code", git_repo:$git_repo, subagent_type:$cs.subagent_type}}
              ),
              ( ($cur.mcp // [])[] | . as $cs |
                ((($prev.mcp // [])[] | select(.server == $cs.server and .tool == $cs.tool)) // {count:0}) as $ps |
                (($cs.count // 0) - ($ps.count // 0) | clamp0) as $d |
                select($d > 0) |
                {metric:"mcp_calls", value:$d,
                 labels:{source:"claude-code", git_repo:$git_repo, mcp_server:$cs.server, mcp_tool:$cs.tool}}
              ),
              ( ($cur.context // {}) as $cc | ($prev.context // {}) as $pc |
                (($cc.tool_output_chars // 0) - ($pc.tool_output_chars // 0) | clamp0) as $d_tool |
                (($cc.user_prompt_chars // 0) - ($pc.user_prompt_chars // 0) | clamp0) as $d_user |
                (($cc.compact_summary_chars // 0) - ($pc.compact_summary_chars // 0) | clamp0) as $d_summary |
                (($cc.compaction_pre_tokens // 0) - ($pc.compaction_pre_tokens // 0) | clamp0) as $d_pre |
                (if $d_tool > 0 then {metric:"context_chars", value:$d_tool, labels:{source:"claude-code", type:"tool_output", git_repo:$git_repo}} else empty end),
                (if $d_user > 0 then {metric:"context_chars", value:$d_user, labels:{source:"claude-code", type:"user_prompt", git_repo:$git_repo}} else empty end),
                (if $d_summary > 0 then {metric:"context_chars", value:$d_summary, labels:{source:"claude-code", type:"compact_summary", git_repo:$git_repo}} else empty end),
                (if $d_pre > 0 then {metric:"context_compaction_pre_tokens", value:$d_pre, labels:{source:"claude-code", git_repo:$git_repo}} else empty end)
              ),
              ( (($cur.compaction_count // 0) - ($prev.compaction_count // 0) | clamp0) as $d_comp |
                (if $d_comp > 0 then {metric:"compaction_events", value:$d_comp, labels:{source:"claude-code", git_repo:$git_repo}} else empty end)
              )
            ]
          ')

          while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            m_name=$(jq -r '.metric' <<< "$d")
            m_val=$(jq -r '.value' <<< "$d")
            m_labels=$(jq -c '.labels' <<< "$d")
            emit_counter "$m_name" "$m_val" "$m_labels"
          done < <(jq -c '.[]' <<< "$deltas")

          # Emit-then-write: a crash between emit and write re-emits one turn's delta (small
          # over-count). Write-first would permanently lose tokens on any curl failure — silent
          # under-reporting of spend is the worse failure for a cost tool.
          tmp=$(mktemp "${STATE_DIR}/.tmp.XXXXXX") && printf '%s' "$cur" > "$tmp" && mv "$tmp" "$state_file"

          # Prune state files older than the stack's 7-day retention
          find "$STATE_DIR" -type f -mtime +7 -delete 2>/dev/null
        fi
      fi
    ) </dev/null >/dev/null 2>&1 &
    disown
  fi
fi

exit 0
