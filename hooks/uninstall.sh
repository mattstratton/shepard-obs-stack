#!/usr/bin/env bash
# hooks/uninstall.sh — remove shepherd hooks from AI CLI configs
#
# Usage:
#   ./hooks/uninstall.sh              # uninstall all
#   ./hooks/uninstall.sh claude       # uninstall only Claude Code
#   ./hooks/uninstall.sh codex gemini # uninstall Codex + Gemini
#
# Supported providers: claude, codex, gemini

set -euo pipefail

REMOVED=0

green()  { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red()    { printf '\033[31m%s\033[0m\n' "$1"; }

# ── Claude Code ──────────────────────────────────────────────────────

uninstall_claude() {
  local config_file="$HOME/.claude/settings.json"

  if [[ ! -f "$config_file" ]]; then
    yellow "Claude Code  — no config found, skipping"
    return
  fi

  if ! jq -e '.hooks' "$config_file" &>/dev/null; then
    yellow "Claude Code  — no hooks configured, skipping"
    return
  fi

  # Remove shepherd's own hook entries only (identified by hook script path suffix, same
  # rule install.sh uses), keeping any other tool's hooks on the same event (rtk, personal
  # moshi-hook entries, etc.) intact — a plain `del(.hooks)` wipes ALL of them, not just
  # shepherd's. Drop an event key entirely once it's empty, and drop `.hooks` itself once
  # every event is empty (matches previous behavior when shepherd was the only hook present).
  local tmp
  tmp=$(mktemp)
  jq '
      def is_shepherd($re): ([.hooks[]?.command // ""] | any(test($re)));
      def strip_event($existing; $re): ([($existing // [])[] | select(is_shepherd($re) | not)]);

      .hooks.PreToolUse = strip_event(.hooks.PreToolUse; "/hooks/claude/pre-tool-use\\.sh$") |
      .hooks.PostToolUse = strip_event(.hooks.PostToolUse; "/hooks/claude/post-tool-use\\.sh$") |
      .hooks.SessionStart = strip_event(.hooks.SessionStart; "/hooks/claude/session-start\\.sh$") |
      .hooks.Stop = strip_event(.hooks.Stop; "/hooks/claude/stop\\.sh$") |
      (if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end) |
      (if (.hooks.PostToolUse | length) == 0 then del(.hooks.PostToolUse) else . end) |
      (if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end) |
      (if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end) |
      (if (.hooks // {} | length) == 0 then del(.hooks) else . end) |
      del(.env.CLAUDE_CODE_ENABLE_TELEMETRY,
          .env.OTEL_METRICS_EXPORTER,
          .env.OTEL_LOGS_EXPORTER,
          .env.OTEL_EXPORTER_OTLP_PROTOCOL,
          .env.OTEL_EXPORTER_OTLP_ENDPOINT,
          .env.OTEL_METRIC_EXPORT_INTERVAL,
          .env.OTEL_LOGS_EXPORT_INTERVAL,
          .env.OTEL_LOG_TOOL_DETAILS) |
      if .env == {} then del(.env) else . end' "$config_file" > "$tmp" && mv "$tmp" "$config_file"

  green "Claude Code  — hooks + native OTel removed from $config_file"
  REMOVED=$((REMOVED + 1))
}

# ── Codex CLI ────────────────────────────────────────────────────────

uninstall_codex() {
  local config_file="$HOME/.codex/config.toml"

  if [[ ! -f "$config_file" ]]; then
    yellow "Codex CLI    — no config found, skipping"
    return
  fi

  # Detect shepherd config (markers or legacy patterns)
  local has_markers=false
  local has_legacy_notify=false
  local has_legacy_otel=false

  grep -q '# shepherd-managed:' "$config_file" 2>/dev/null && has_markers=true
  grep -q 'codex/notify\.sh' "$config_file" 2>/dev/null && has_legacy_notify=true
  if grep -q '^\[otel\]' "$config_file" 2>/dev/null && \
     sed -n '/^\[otel\]/,/^\[/p' "$config_file" | grep -q 'localhost:4317'; then
    has_legacy_otel=true
  fi

  if ! $has_markers && ! $has_legacy_notify && ! $has_legacy_otel; then
    yellow "Codex CLI    — no shepherd config found, skipping"
    return
  fi

  # Back up before uninstall
  cp "$config_file" "${config_file}.bak.$(date +%s)"

  # Remove shepherd-managed blocks
  if $has_markers; then
    sed -i.tmp '/^# shepherd-managed:start/,/^# shepherd-managed:end/d' "$config_file"
    rm -f "${config_file}.tmp"
    green "Codex CLI    — shepherd config removed (managed blocks)"
  fi

  # Legacy fallback (for installs before markers were added)
  if ! $has_markers; then
    if $has_legacy_notify; then
      sed -i.tmp '/codex\/notify\.sh/d' "$config_file"
      rm -f "${config_file}.tmp"
    fi

    if $has_legacy_otel; then
      sed -i.tmp '/^\[otel\]/,/^\[/{/^\[otel\]/d;/^\[/!d;}' "$config_file"
      rm -f "${config_file}.tmp"
    fi

    green "Codex CLI    — shepherd hooks removed (legacy format)"
  fi

  # Warn about non-shepherd config that was preserved
  if grep -q '^notify' "$config_file" 2>/dev/null; then
    yellow "Codex CLI    — non-shepherd notify config preserved"
  fi
  if grep -q '^\[otel\]' "$config_file" 2>/dev/null; then
    yellow "Codex CLI    — non-shepherd [otel] config preserved"
  fi

  # Remove empty file if nothing left
  if [[ ! -s "$config_file" ]] || [[ "$(tr -d '[:space:]' < "$config_file")" == "" ]]; then
    rm -f "$config_file"
  fi

  REMOVED=$((REMOVED + 1))
}

# ── Gemini CLI ───────────────────────────────────────────────────────

uninstall_gemini() {
  local config_file="$HOME/.gemini/settings.json"

  if [[ ! -f "$config_file" ]]; then
    yellow "Gemini CLI   — no config found, skipping"
    return
  fi

  if ! jq -e '.hooks' "$config_file" &>/dev/null; then
    yellow "Gemini CLI   — no hooks configured, skipping"
    return
  fi

  # Same shepherd-only removal as uninstall_claude — see its comment for why.
  local tmp
  tmp=$(mktemp)
  jq '
      def is_shepherd($re): ([.hooks[]?.command // ""] | any(test($re)));
      def strip_event($existing; $re): ([($existing // [])[] | select(is_shepherd($re) | not)]);

      .hooks.AfterTool = strip_event(.hooks.AfterTool; "/hooks/gemini/after-tool\\.sh$") |
      .hooks.AfterAgent = strip_event(.hooks.AfterAgent; "/hooks/gemini/after-agent\\.sh$") |
      .hooks.AfterModel = strip_event(.hooks.AfterModel; "/hooks/gemini/after-model\\.sh$") |
      .hooks.SessionEnd = strip_event(.hooks.SessionEnd; "/hooks/gemini/session-end\\.sh$") |
      (if (.hooks.AfterTool | length) == 0 then del(.hooks.AfterTool) else . end) |
      (if (.hooks.AfterAgent | length) == 0 then del(.hooks.AfterAgent) else . end) |
      (if (.hooks.AfterModel | length) == 0 then del(.hooks.AfterModel) else . end) |
      (if (.hooks.SessionEnd | length) == 0 then del(.hooks.SessionEnd) else . end) |
      (if (.hooks // {} | length) == 0 then del(.hooks) else . end) |
      del(.telemetry)' "$config_file" > "$tmp" && mv "$tmp" "$config_file"

  green "Gemini CLI   — hooks + native OTel removed from $config_file"
  REMOVED=$((REMOVED + 1))
}

# ── Main ─────────────────────────────────────────────────────────────

PROVIDERS=("$@")
ALL_PROVIDERS=(claude codex gemini)

# Validate arguments
for p in ${PROVIDERS[@]+"${PROVIDERS[@]}"}; do
  case "$p" in
    claude|codex|gemini) ;;
    -h|--help)
      echo "Usage: $0 [claude] [codex] [gemini]"
      echo ""
      echo "  No args  — uninstall all"
      echo "  With args — uninstall only specified providers"
      exit 0
      ;;
    *)
      red "Unknown provider: $p"
      echo "Supported: claude, codex, gemini"
      exit 1
      ;;
  esac
done

# Default to all if no args
if [[ ${#PROVIDERS[@]} -eq 0 ]]; then
  PROVIDERS=("${ALL_PROVIDERS[@]}")
fi

echo "shepherd-hooks uninstaller"
echo "=========================="
echo ""

for provider in "${PROVIDERS[@]}"; do
  "uninstall_${provider}"
done

# Remove Rust accelerator binary (project-local only)
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "${HOOKS_DIR}/bin/shepard-hook" ]]; then
  rm -f "${HOOKS_DIR}/bin/shepard-hook"
  rmdir "${HOOKS_DIR}/bin" 2>/dev/null || true
  green "shepard-hook — removed from ${HOOKS_DIR}/bin/"
fi

echo ""
if [[ $REMOVED -eq 0 ]]; then
  echo "Nothing to remove."
else
  echo "${REMOVED} CLI(s) cleaned up."
fi
