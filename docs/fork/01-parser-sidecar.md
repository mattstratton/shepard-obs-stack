# Spec 01 — Parser Metrics Sidecar

**Phase 1.** Extend `hooks/lib/session-parser.sh` to emit a **metrics sidecar** — one extra JSON
line, always last, containing cumulative session totals for per-repo tokens, skill/slash-command
invocations with turn-window token attribution, subagent launches, MCP calls, and the context
breakdown. Spans are unchanged except for two new attributes. Consumers split on the `metrics`
key.

## Files touched

- `hooks/lib/session-parser.sh` — all changes below
- `tests/fixtures/claude-session-skills.jsonl` — new fixture (spec here, tests in 06)

## Output contract (after this change)

- Lines 1..N: span objects, exactly as today (root span still line 1, `claude.session.meta`
  line 2, etc.).
- Last line: `{"metrics": {...}}` — the ONLY line with a top-level `metrics` key and no
  `trace_id` key.
- Consumers split with:
  - spans: `jq -c 'select(.metrics == null)'`
  - sidecar: `jq -c '.metrics | select(. != null)'`

### Sidecar schema (canonical example)

```json
{"metrics": {
  "session_id": "3f9c2a10-...",
  "git_repo": "tiger-den",
  "tokens": [
    {"model": "claude-opus-4-8", "input": 1200, "output": 5400, "cacheRead": 250000, "cacheCreation": 18000},
    {"model": "claude-haiku-4-5-20251001", "input": 300, "output": 900, "cacheRead": 0, "cacheCreation": 0}
  ],
  "skills": [
    {"skill": "obs-cost", "kind": "slash_command", "count": 1,
     "tokens": [{"model": "claude-opus-4-8", "input": 100, "output": 2000, "cacheRead": 40000, "cacheCreation": 0}]},
    {"skill": "superpowers:brainstorming", "kind": "skill", "count": 2,
     "tokens": [{"model": "claude-opus-4-8", "input": 50, "output": 1500, "cacheRead": 30000, "cacheCreation": 500}]}
  ],
  "subagents": [{"subagent_type": "Explore", "count": 3}],
  "mcp": [{"server": "tiger", "tool": "db_execute_query", "count": 2}],
  "context": {
    "tool_output_chars": 48211, "user_prompt_chars": 1022,
    "compact_summary_chars": 0, "compaction_pre_tokens": 0
  },
  "compaction_count": 0
}}
```

Field notes:
- `tokens[].{input,output,cacheRead,cacheCreation}` — key names MUST be exactly these; they
  become the `type` label and must match the native metric's type values
  (`shepherd_claude_code_token_usage_tokens_total{type=...}`) so one pricing series joins both.
- `skills[].kind` ∈ `skill | slash_command`. `skill` names come verbatim from `.input.skill`
  (keep `plugin:name` prefixes). Slash-command names have the leading `/` stripped and any
  arguments dropped (first whitespace-delimited token).
- `context` + `compaction_count` are included so stop.sh can route the EXISTING
  `context_chars` / `context_compaction_pre_tokens` / `compaction_events` metrics through the
  same delta machinery (spec 02) — this is what fixes the upstream double-count bug.
- All numbers are integers (floor after the even split).

## Changes to session-parser.sh

Current structure (line refs to the pre-change file): helpers at 25–67; `[inputs]` and metadata
71–102; `$tokens` 104–111; context breakdown 133–159; `$tools` 170–178; `$turn_count` 183–189;
`$mcps` 191–196; `$agents` 198–207; span emission 209–354 (per-turn spans gated by
`SHEPARD_DETAILED_TRACES` at 302–354).

### 1. New helper: `slash_cmd` (place near `trunc`, ~line 67)

Extracts the slash-command name from a user entry. Handles both string content and
array-of-text-blocks content:

```jq
# User entry → slash command name (no leading /), or empty
def slash_cmd:
  (.message.content
   | if type == "array" then ([.[] | select(.type == "text") | .text // ""] | join("\n"))
     elif type == "string" then .
     else "" end)
  | if test("<command-name>") then
      (capture("<command-name>\\s*(?<c>[^<]+?)\\s*</command-name>").c
       | ltrimstr("/") | split(" ")[0])
    else empty end;
```

Note: Claude Code writes local-command invocations into the user message as
`<command-name>/foo</command-name>` markers (see any real `~/.claude/projects/*/*.jsonl`).
Skill-backed slash commands ALSO produce a `Skill` tool_use; dedup is NOT attempted — a
`/obs-cost` typed by the user counts once as `slash_command` and, if it triggers the Skill tool,
once as `skill`. The dashboards present the two kinds separately, so this is informative, not
double counting.

### 2. Per-model token totals (immediately after existing `$tokens`, ~line 111)

```jq
# Per-model token totals — sidecar `tokens` array
($assistants
 | map(select(.message.model != null and .message.model != "<synthetic>"))
 | group_by(.message.model)
 | map({model: .[0].message.model,
        input: (map(.message.usage.input_tokens // 0) | add // 0),
        output: (map(.message.usage.output_tokens // 0) | add // 0),
        cacheRead: (map(.message.usage.cache_read_input_tokens // 0) | add // 0),
        cacheCreation: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0)})
) as $tokens_by_model |
```

### 3. Skill/subagent fields on `$tools` (~lines 170–178)

Extend each tool entry:

```jq
[$assistants[] |
  . as $m | ($m.message.content // [] | if type == "array" then .[] else empty end) |
  select(.type == "tool_use") |
  {id: .id, name: .name, ts: $m.timestamp, tok: ($m.message.usage.output_tokens // 0),
   file_path: (.input.file_path // .input.notebook_path // ""),
   command: ((.input.command // "")[:200]),
   pattern: (.input.pattern // .input.query // ""),
   skill: (if .name == "Skill" then (.input.skill // "unknown")
           elif .name == "SlashCommand" then ((.input.command // "unknown") | ltrimstr("/") | split(" ")[0])
           else "" end),
   subagent: (if .name == "Task" or .name == "Agent" then (.input.subagent_type // "unknown") else "" end)}
] as $tools |
```

(`Task` is the JSONL tool name for subagent launches in current Claude Code; accept `Agent` too —
check the fixture source of truth against a real session log and keep whichever names actually
appear, defaulting to matching both.)

### 4. Hoist turn segmentation out of the detailed-traces gate (~lines 302–320)

Move the existing `reduce`-based `$turns` computation from inside the
`if ($ENV.SHEPARD_DETAILED_TRACES // "") == "1"` block to top-level bindings (after `$agents`,
before span emission), UNCHANGED in logic. The per-turn *span emission* (section 6 of the emit)
stays gated; it now just references the hoisted `$turns`.

The existing boundary rule is kept as-is: a turn starts at a user entry with string content that
is not a compact summary. Entries before the first such user message belong to no turn (upstream
behavior; acceptable).

CAVEAT for the implementer: with the array-content user-message shape (gotcha 12 in README),
real human prompts may arrive as arrays and would NOT start a turn under the existing rule.
Do not fix this silently — it changes upstream span behavior. Keep parity with the existing
per-turn span logic; note it as a known limitation in the doc comment above the reduce.

### 5. Turn-window skill attribution (new, after the hoisted `$turns`)

Semantics (locked decision): all tokens from the FIRST skill/slash-command invocation in a turn
window through the END of that window attribute to that window's invocations, split evenly when
there are several. Follow-up turns after the user replies again are not counted.

```jq
# --- Skill/slash-command turn-window attribution ---
($turns | map(
  . as $turn |
  # Dedup assistants inside the window (same rule as $assistants)
  ([$turn.entries[] | select(.type == "assistant")]
    | group_by(.message.id // .uuid) | [.[] | .[-1]]) as $wa |
  # Invocations in this window: Skill/SlashCommand tool_uses + the opening slash command
  (([$wa[] | . as $m | (.message.content // [] | if type == "array" then .[] else empty end)
     | select(.type == "tool_use" and (.name == "Skill" or .name == "SlashCommand"))
     | {name: (if .name == "Skill" then (.input.skill // "unknown")
               else ((.input.command // "unknown") | ltrimstr("/") | split(" ")[0]) end),
        kind: (if .name == "Skill" then "skill" else "slash_command" end),
        ts: $m.timestamp}]
   ) + ([$turn.entries[0] | slash_cmd | {name: ., kind: "slash_command", ts: $turn.ts}])
  ) as $inv |
  if ($inv | length) == 0 then empty else
    ([$inv[].ts] | sort | .[0]) as $first_ts |
    # Window tokens from first invocation onward, per model (ISO-8601 string compare is safe)
    ([$wa[] | select(.timestamp >= $first_ts)]
      | group_by(.message.model // "unknown")
      | map({model: (.[0].message.model // "unknown"),
             input: (map(.message.usage.input_tokens // 0) | add // 0),
             output: (map(.message.usage.output_tokens // 0) | add // 0),
             cacheRead: (map(.message.usage.cache_read_input_tokens // 0) | add // 0),
             cacheCreation: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0)})
    ) as $wtok |
    ($inv | length) as $n |
    $inv | map({name, kind,
                tokens: ($wtok | map({model,
                  input: (.input / $n), output: (.output / $n),
                  cacheRead: (.cacheRead / $n), cacheCreation: (.cacheCreation / $n)}))})
  end
) | flatten
  | group_by("\(.name)|\(.kind)")
  | map({skill: .[0].name, kind: .[0].kind, count: length,
         tokens: ([.[].tokens[]] | group_by(.model)
           | map({model: .[0].model,
                  input: (map(.input) | add | floor),
                  output: (map(.output) | add | floor),
                  cacheRead: (map(.cacheRead) | add | floor),
                  cacheCreation: (map(.cacheCreation) | add | floor)}))})
) as $skill_attribution |
```

### 6. Subagent and MCP aggregations (new, adjacent)

```jq
([$tools[] | select(.subagent != "") | .subagent]
 | group_by(.) | map({subagent_type: .[0], count: length})) as $subagent_counts |

($mcps | map({server: (.data.serverName // "unknown"), tool: (.data.toolName // "unknown")})
 | group_by("\(.server)|\(.tool)")
 | map({server: .[0].server, tool: .[0].tool, count: length})) as $mcp_counts |
```

### 7. New span attributes (tool spans, emit section 2, ~lines 250–263)

Inside the tool-span `attributes` construction, append:

```jq
+ (if $t.skill != "" then {"skill.name": $t.skill} else {} end)
+ (if $t.subagent != "" then {"agent.type": $t.subagent} else {} end)
```

Do NOT change any span names. Do not add per-skill spans.

### 8. Emit the sidecar (last emitted value, after the per-turn span block, before final `end`)

```jq
,
{metrics: {
  session_id: $session_id,
  git_repo: $git_repo,
  tokens: $tokens_by_model,
  skills: $skill_attribution,
  subagents: $subagent_counts,
  mcp: $mcp_counts,
  context: {tool_output_chars: $tool_output_chars,
            user_prompt_chars: $user_prompt_chars,
            compact_summary_chars: $compact_summary_chars,
            compaction_pre_tokens: $compaction_pre_tokens},
  compaction_count: ($compactions | length)
}}
```

## New fixture: `tests/fixtures/claude-session-skills.jsonl`

Model it on the existing Claude fixture (same envelope fields: `type`, `sessionId`, `timestamp`,
`gitBranch`, `gitRepo`, `message`, etc.). Required contents:

1. A user entry whose string content contains
   `<command-name>/obs-cost</command-name>` markers (turn 1 opener).
2. In turn 1: one assistant entry with `tool_use` `{name: "Skill", input: {skill: "superpowers:brainstorming"}}`
   → **two invocations in one window** (the slash command + the Skill call) → tests the even split.
3. A second turn (new user entry, plain string content, no command) containing a `tool_use`
   `{name: "Task", input: {subagent_type: "code-reviewer", prompt: "..."}}`.
4. One `progress` entry with `data.type == "mcp_progress"`, `data.status == "completed"`,
   `data.serverName`/`data.toolName`/`data.elapsedTimeMs` set.
5. Assistant entries across **two distinct models** with non-zero `usage` fields (input, output,
   cache_read_input_tokens, cache_creation_input_tokens) so per-model splits are testable.
6. Matching `tool_result` user entries for each `tool_use` (join by `tool_use_id`).
7. Choose round token numbers so expected attribution values are exact after `/2` and `floor`
   (e.g. window totals of 200/1000/40000/600).

Document the expected sidecar values in a comment block at the top of `tests/test-parsers.sh`'s
new section (fixtures are data-only JSONL; no comments in the fixture itself).

## Verification

```bash
bash -n hooks/lib/session-parser.sh
bash hooks/lib/session-parser.sh tests/fixtures/claude-session-skills.jsonl | tail -1 | jq .metrics
bash hooks/lib/session-parser.sh tests/fixtures/<existing-claude-fixture>.jsonl | jq -c 'select(.metrics == null)' | wc -l   # unchanged span count
bash tests/run-all.sh   # after updating tests per spec 06
```

Also run the parser against a real session log
(`ls -t ~/.claude/projects/*/*.jsonl | head -1`) and eyeball `.metrics`.

## Definition of done

- Sidecar is always the last line, exactly one per parse, schema above.
- Existing spans byte-identical except the two new optional attributes.
- Existing Codex/Gemini parsers untouched; their fixtures still pass.
- SHEPARD_DETAILED_TRACES=0 and =1 both produce the sidecar; =1 still produces `claude.turn`
  spans identical to before.
- `tests/test-parsers.sh` green with the new assertions (spec 06).
