# Spec 05 — Spend Alerts on Computed Cost

**Phase 5. Depends on spec 03.** Retune the existing cost alert to computed cost and add
daily/weekly spend thresholds plus the unpriced-model guardrail.

## Files touched

- `configs/prometheus/alerts/services.yaml` — 1 changed alert, 3 new (5 → 8 alerts)
- `configs/alertmanager/alertmanager.yaml` — inhibit-rule lists
- `tests/test-config-validate.sh` — alert count + expression guards (see also spec 06)

## services.yaml changes

1. **`HighSessionCost`** (existing) — replace expr:

```yaml
- alert: HighSessionCost
  expr: sum(increase(shepherd:claude:computed_cost_usd[1h])) > 10
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "AI coding cost exceeded $10 in the last hour"
    description: "Computed cost (pricing table × tokens) is {{ $value | printf \"%.2f\" }} USD over 1h."
```

Keep the alert NAME unchanged (inhibit rules and tests reference it).

2. **New alerts** (append to the same group; thresholds are placeholders — Matt tunes):

```yaml
- alert: DailySpendHigh
  expr: sum(increase(shepherd:claude:computed_cost_usd[24h])) > 50
  for: 0m
  labels:
    severity: warning
  annotations:
    summary: "AI coding spend exceeded $50 in 24h"
    description: "24h computed spend: ${{ $value | printf \"%.2f\" }}."

- alert: WeeklySpendHigh
  expr: sum(increase(shepherd:claude:computed_cost_usd[7d])) > 200
  for: 0m
  labels:
    severity: info
  annotations:
    summary: "AI coding spend exceeded $200 in 7d"
    description: "7d computed spend: ${{ $value | printf \"%.2f\" }}. Note: 7d equals Prometheus retention — this window works, but barely; treat as approximate."

- alert: UnpricedModelSeen
  expr: count(shepherd:claude:unpriced_models) > 0
  for: 10m
  labels:
    severity: info
  annotations:
    summary: "Model(s) emitting tokens with no pricing entry"
    description: "Cost for {{ $value }} model(s) is silently $0. Add entries to configs/pricing/model-prices.json and regenerate rules."
```

## alertmanager.yaml

Everywhere the inhibit rules list `HighSessionCost` as a suppressed target (the
`OTelCollectorDown` and `ShepherdServicesDown` source rules), add `DailySpendHigh`,
`WeeklySpendHigh`, and `UnpricedModelSeen` to the same target lists. Grep first:

```bash
grep -n "HighSessionCost" configs/alertmanager/alertmanager.yaml
```

## Test updates (also listed in spec 06)

- `tests/test-config-validate.sh:120`: `assert_alert_count "$ALERTS_DIR/services.yaml" 5` → `8`.
- Add an expression guard asserting `HighSessionCost`'s expr contains `computed_cost_usd`
  (follow the existing expression-guard pattern in that file).

## Verification

```bash
promtool check rules configs/prometheus/alerts/services.yaml   # if installed
bash tests/run-all.sh
docker compose restart prometheus alertmanager                  # or POST /-/reload to prometheus
curl -s http://localhost:9090/api/v1/rules?type=alert | jq '[.data.groups[].rules[].name]'
# expect the 8 services alerts including DailySpendHigh/WeeklySpendHigh/UnpricedModelSeen
curl -s http://localhost:9093/api/v2/status | jq .config.original | grep -c DailySpendHigh
```

Optional live test: temporarily set `DailySpendHigh` threshold to `> 0.01`, reload, wait 1–2m,
confirm it fires in Alertmanager (`curl -s http://localhost:9093/api/v2/alerts | jq '.[].labels.alertname'`),
then restore the threshold and reload.

## Definition of done

- 8 alerts load in Prometheus; no promtool errors; inhibit lists updated; regression tests green.
- `HighSessionCost` fires on computed cost, not the native estimate.
