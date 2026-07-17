# Spec 04 — Dashboard Changes

**Phase 4. Depends on spec 03 (rules) and spec 02 (data).** Rework the Cost dashboard around
computed cost, add a new "Projects & Skills" dashboard, and switch the remaining native-cost
panels. Conventions: PromQL for all numeric panels; `round(sum(increase(metric[$__range])))` for
stat/table totals; dashboard JSON is provisioned from `configs/grafana/dashboards/` and requires
`docker compose restart grafana` to pick up edits (UI edits are lost on restart).

Grafana in this fork is at **http://localhost:9000** (admin / shepherd).

## Files touched

- `configs/grafana/dashboards/01-cost.json` (title "04 Cost", uid `shepherd-cost`)
- `configs/grafana/dashboards/10-claude-deep-dive.json` (uid `shepherd-claude-deep-dive`)
- `configs/grafana/dashboards/04-quality.json` (uid `shepherd-quality`)
- NEW `configs/grafana/dashboards/15-projects.json` (title "10 Projects & Skills", uid `shepherd-projects`)
- `CLAUDE.md` — Dashboards table (now 10 dashboards) + Hook Metrics table (new metrics from spec 02)
- `README.md` — dashboard count/list if mentioned

## 01-cost.json

1. **Add the `git_repo` variable** — copy this templating block verbatim from `02-tools.json`:

```json
{
  "current": {"selected": false, "text": ".*", "value": ".*"},
  "name": "git_repo",
  "label": "Git Repo",
  "type": "textbox",
  "query": ".*",
  "description": "Filter by git repo name (regex). Use .* for all."
}
```

2. **Switch primary cost panels to computed cost.** Current exprs use
`shepherd_claude_code_cost_usage_USD_total` (Total Cost stat at ~line 45; "Cost Over Time" and
"Cost by Model" at ~lines 430/492 — locate by panel title, not line number). New exprs:

- Total Cost (stat): `sum(increase(shepherd:claude:computed_cost_usd{git_repo=~"$git_repo"}[$__range]))`
- Cost Over Time (timeseries): `sum by (model) (increase(shepherd:claude:computed_cost_usd{git_repo=~"$git_repo"}[5m]))`
- Cost by Model (pie/bar): `sum by (model) (increase(shepherd:claude:computed_cost_usd{git_repo=~"$git_repo"}[$__range]))`

Update panel descriptions: cost is computed from `configs/pricing/model-prices.json` rates;
the dashboard note at the top of the JSON ("Claude Code only — other providers don't emit cost
metrics") stays true and stays.

3. **New panels:**

- **"Native Estimate (sanity)"** (stat, small): keep the OLD expr
  `sum(max_over_time(shepherd_claude_code_cost_usage_USD_total[$__range]))`.
  Description: "Claude Code's own client-side estimate at public list prices. Cannot filter by
  repo. If this drifts >±20% from Total Cost (all repos), check pricing table rates/model IDs."
- **"Cache Savings ($)"** (stat + optional timeseries):
  `sum(increase(shepherd:claude:cache_savings_usd{git_repo=~"$git_repo"}[$__range]))`
  Description: "What prompt caching saved vs. billing cache reads at the full input rate.
  Cache rates in the pricing file are assumptions until verified."
- **"Model Mix Over Time"** (timeseries, stacked percent):
  `sum by (model) (increase(shepherd_session_tokens_total{git_repo=~"$git_repo"}[$__interval]))`
  Description: "Share of total token volume by model — spots premium-model burn on grunt work."
- **"Unpriced Models"** (stat): `count(shepherd:claude:unpriced_models) or vector(0)` —
  thresholds: green at 0, red > 0. Description: "Models emitting tokens with no pricing entry —
  their cost is silently $0. Fix configs/pricing/model-prices.json."

## NEW 15-projects.json — "10 Projects & Skills"

uid `shepherd-projects`, tags like the other shepherd dashboards, default time range 24h
(skills/session metrics are sparse at 1h), `$git_repo` textbox variable (same block as above).
Copy JSON scaffolding (schemaVersion, datasource refs) from `01-cost.json`; datasource is
Prometheus only.

Rows/panels (all filtered `git_repo=~"$git_repo"` where the metric has the label):

**Row: Projects**
- "Cost by Repo" (table or bar gauge): `sum by (git_repo) (increase(shepherd:claude:computed_cost_usd{git_repo=~"$git_repo"}[$__range]))`, sorted desc, unit currencyUSD.
- "Cost Over Time by Repo" (timeseries): `sum by (git_repo) (increase(shepherd:claude:computed_cost_usd{git_repo=~"$git_repo"}[5m]))`
- "Tokens by Repo & Type" (stacked bar/timeseries): `sum by (git_repo, type) (increase(shepherd_session_tokens_total{git_repo=~"$git_repo"}[$__range]))`

**Row: Skills**
- "Top Skills / Commands" (bar gauge): `topk(20, sum by (skill_name, skill_type) (increase(shepherd_skill_invocations_total{git_repo=~"$git_repo"}[$__range])))`
- "Skill Cost" (table): `sum by (skill_name, skill_type) (increase(shepherd:claude:skill_cost_usd{git_repo=~"$git_repo"}[$__range]))`, unit currencyUSD, description:
  "Turn-window attribution: tokens from a skill's invocation to the end of that user turn,
  split evenly when several skills fire in one turn. An approximation, not billing truth."
- "Skill Invocations Over Time" (timeseries): `sum by (skill_name) (increase(shepherd_skill_invocations_total{git_repo=~"$git_repo"}[$__interval]))`

**Row: Subagents**
- "Subagent Launches" (bar gauge/table): `sum by (subagent_type) (increase(shepherd_subagent_invocations_total{git_repo=~"$git_repo"}[$__range]))`

**Row: MCP**
- "MCP Calls by Server/Tool" (table): `sum by (mcp_server, mcp_tool) (increase(shepherd_mcp_calls_total{git_repo=~"$git_repo"}[$__range]))`
- "MCP Calls Over Time by Server" (timeseries): `sum by (mcp_server) (increase(shepherd_mcp_calls_total{git_repo=~"$git_repo"}[$__interval]))`

## 10-claude-deep-dive.json (lower priority, same phase)

Three stat panels currently on `shepherd_claude_code_cost_usage_USD_total` (locate by title
around former lines ~108/921/1703) → computed-cost equivalents (`shepherd:claude:computed_cost_usd`;
respect the existing `$model` variable: `sum(increase(shepherd:claude:computed_cost_usd{model=~"$model"}[$__range]))`).
Optionally add a compact "Top Skills" bar panel to the existing layout.

## 04-quality.json (lower priority, same phase)

"Cost per 1K output tokens" (~line 289) numerator → `sum(increase(shepherd:claude:computed_cost_usd[$__range]))`.

## Verification

```bash
for f in configs/grafana/dashboards/*.json; do jq empty "$f" || echo "INVALID $f"; done
bash tests/run-all.sh                       # config-validate picks up 15-projects.json via glob
docker compose restart grafana
curl -s -u admin:shepherd http://localhost:9000/api/dashboards/uid/shepherd-projects | jq '.dashboard.title'
curl -s -u admin:shepherd http://localhost:9000/api/dashboards/uid/shepherd-cost | jq '.dashboard.panels | length'
```

Then open http://localhost:9000/d/shepherd-projects and http://localhost:9000/d/shepherd-cost,
range "Last 24 hours", after at least one real Claude session: every panel renders data or an
honest zero; changing `$git_repo` to a real repo name filters everything except the Native
Estimate panel.

## Definition of done

- All dashboard JSONs valid; Grafana provisions 10 dashboards with correct sort-order titles.
- Cost dashboard primary numbers come from computed cost and respond to `$git_repo`.
- Sanity panel shows the native estimate alongside; drift within expectations.
- Projects & Skills dashboard shows per-repo cost, top skills with cost, subagents, MCP.
- CLAUDE.md tables updated (10 dashboards; new hook metrics rows).
