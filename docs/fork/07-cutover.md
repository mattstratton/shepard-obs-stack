# Spec 07 — Cutover: Point the Live Stack at This Fork

**Phase 7 (last).** Matt's running stack lives at
`/Users/mattstratton/src/github.com/shepard-system/shepard-obs-stack` — a clone of upstream,
currently at commit `f3787cd`, which is a **clean ancestor** (6 commits behind, verified
2026-07-17) of this fork's main. So cutover is an **in-place remote switch + fast-forward**, NOT
a re-clone: Docker volume names derive from the compose project (directory) name, so staying in
that directory preserves all Prometheus/Loki/Tempo data.

The hooks in `~/.claude/settings.json` reference that directory by **absolute path**
(`/Users/mattstratton/src/github.com/shepard-system/shepard-obs-stack/hooks/claude/*.sh`), so no
hook reinstall is needed either.

## Pre-flight checks (in the live directory)

```bash
cd /Users/mattstratton/src/github.com/shepard-system/shepard-obs-stack

# 1. No Rust accelerator — CRITICAL. If either check finds one, remove it:
#    the accelerator fully replaces the bash hooks (stop.sh:17-21) and would
#    silently bypass every fork change.
ls hooks/bin/shepard-hook 2>/dev/null && echo "REMOVE THIS"
command -v shepard-hook && echo "REMOVE FROM PATH"

# 2. Local state. As of 2026-07-17 the only local edit was docker-compose.yaml
#    mapping Grafana to host port 9000 — that change is now COMMITTED in the fork,
#    so the local edit becomes redundant. Anything else uncommitted: inspect before discarding.
git status --short
git diff
```

## Switch

```bash
git remote add fork git@github.com:mattstratton/shepard-obs-stack.git
git fetch fork
git checkout -- docker-compose.yaml       # drop the now-redundant local port edit (ONLY if git diff showed nothing else)
git checkout -B main fork/main            # fast-forward onto the fork
```

If `git status` showed other local changes, stash them first and re-apply/inspect after.

## Apply

```bash
bash tests/run-all.sh                                  # must be green before touching services
docker compose up -d                                   # picks up the compose port change (grafana container recreates)
curl -X POST http://localhost:9090/-/reload            # load new rule files (or: docker compose restart prometheus)
docker compose restart grafana                         # provision new/changed dashboards
docker compose restart alertmanager                    # if spec 05 applied
# OTel Collector config is unchanged by this fork — no restart needed.
```

## Verify end-to-end

1. Services healthy: `curl -s http://localhost:9000/api/health | jq .database` → `"ok"`
   (note **port 9000** now), `curl -s http://localhost:9090/-/healthy`.
2. Rules loaded:
   `curl -s http://localhost:9090/api/v1/rules | jq '[.data.groups[].name]'` includes
   `shepherd_model_prices` and `shepherd_computed_cost`.
3. Run one real Claude Code session in any repo (a couple of tool calls + one skill), then:
   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=shepherd_session_tokens_total' \
     | jq '.data.result[].metric' | head
   # expect git_repo, model, type labels
   curl -s 'http://localhost:9090/api/v1/query?query=shepherd_skill_invocations_total' | jq '.data.result[].metric'
   curl -s 'http://localhost:9090/api/v1/query?query=shepherd:claude:unpriced_models' | jq '.data.result'
   # expect [] — if not, add the listed model IDs to configs/pricing/model-prices.json
   ```
4. Open http://localhost:9000/d/shepherd-cost — computed Total Cost within ~±20% of the
   Native Estimate sanity panel (drift beyond that: wrong rate, wrong model ID, or the
   unverified cache-rate assumptions — see spec 03).
5. Open http://localhost:9000/d/shepherd-projects — per-repo and skill panels populate.

## Post-cutover housekeeping

- The development checkout at `/Users/mattstratton/src/github.com/mattstratton/shepard-obs-stack`
  remains the place where changes are authored and committed; the live directory just
  fast-forwards from the fork remote (`git fetch fork && git merge --ff-only fork/main`).
- Optional later: repoint `~/.claude/settings.json` hook paths at one canonical directory and
  retire the other. Not required.
- To pull future upstream changes: in the dev checkout,
  `git fetch upstream && git merge upstream/main` (remotes already configured there), resolve
  (expect conflicts concentrated in session-parser.sh / stop.sh — see README merge policy),
  run tests, push, then fast-forward the live directory.

## Definition of done

- Live stack runs fork main with all historical dashboard data intact.
- Grafana answers on :9000; old :3000 bookmark dead.
- New metrics flow from a real session; computed cost sane; no accelerator present.
