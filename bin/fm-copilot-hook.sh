#!/usr/bin/env bash
# GitHub Copilot CLI hook transport for Firstmate's shared lifecycle scripts.
#
# Usage:
#   fm-copilot-hook.sh session-start
#   fm-copilot-hook.sh agent-stop
#   fm-copilot-hook.sh pre-arm
#   fm-copilot-hook.sh pre-cd
#   fm-copilot-hook.sh pre-subagent
#
# Copilot's repository hooks use camelCase events and JSON decision objects.
# This adapter translates those payloads into the existing harness-neutral
# script interfaces. Every malformed or unavailable transport path stays inert
# except a shared policy script's explicit denial, which preserves its exit 2.
set -u

[ "${GITHUB_ACTIONS:-}" = true ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=${1:-}

json_object_payload() {  # <payload>
  local payload=$1
  command -v node >/dev/null 2>&1 || return 1
  node -e '
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      const data = JSON.parse(input);
      if (data === null || typeof data !== "object" || Array.isArray(data)) {
        process.exit(1);
      }
    });
  ' 2>/dev/null <<<"$payload"
}

json_field() {  # <payload> <field>
  local payload=$1 field=$2
  command -v node >/dev/null 2>&1 || return 1
  FIELD="$field" node -e '
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      const data = JSON.parse(input);
      if (data === null || typeof data !== "object" || Array.isArray(data)) {
        process.exit(1);
      }
      let value;
      switch (process.env.FIELD) {
        case "stop-active":
          value = data.stop_hook_active ?? false;
          if (typeof value !== "boolean") process.exit(1);
          break;
        case "session-id":
          if (data.sessionId !== undefined) {
            value = data.sessionId;
          } else if (data.session_id !== undefined) {
            value = data.session_id;
          } else {
            value = "unknown";
          }
          if (typeof value !== "string") process.exit(1);
          break;
        case "command":
          if (data.toolArgs === undefined) {
            value = "";
          } else {
            if (data.toolArgs === null || typeof data.toolArgs !== "object" ||
                Array.isArray(data.toolArgs)) process.exit(1);
            value = data.toolArgs.command ?? "";
          }
          if (typeof value !== "string") process.exit(1);
          break;
        case "tool":
          value = data.toolName ?? "";
          if (typeof value !== "string") process.exit(1);
          break;
        case "system-message":
          value = data.systemMessage ?? "";
          if (typeof value !== "string") process.exit(1);
          break;
        default:
          process.exit(1);
      }
      process.stdout.write(String(value));
    });
  ' 2>/dev/null <<<"$payload"
}

json_object() {  # <field> <value>
  local field=$1 value=$2
  command -v node >/dev/null 2>&1 || return 1
  FIELD="$field" VALUE="$value" node -e \
    'process.stdout.write(JSON.stringify({[process.env.FIELD]: process.env.VALUE}) + "\n")'
}

json_block_decision() {  # <reason>
  local reason=$1
  command -v node >/dev/null 2>&1 || return 1
  REASON="$reason" node -e \
    'process.stdout.write(JSON.stringify({decision: "block", reason: process.env.REASON}) + "\n")'
}

json_pretool_denial() {  # <reason>
  local reason=$1
  command -v node >/dev/null 2>&1 || return 1
  REASON="$reason" node -e \
    'process.stdout.write(JSON.stringify({permissionDecision: "deny", permissionDecisionReason: process.env.REASON}) + "\n")'
}

run_pretool_guard() {
  local reason_file output status reason
  reason_file=$(mktemp "${TMPDIR:-/tmp}/fm-copilot-pretool.XXXXXX") || return 0
  if "$@" 2>"$reason_file"; then
    status=0
  else
    status=$?
  fi
  output=$(cat "$reason_file" 2>/dev/null || true)
  rm -f "$reason_file"
  [ "$status" -eq 2 ] || return 0
  reason=$(json_field "$output" system-message) || reason=$output
  [ -n "$reason" ] || reason="Firstmate policy denied this tool call."
  json_pretool_denial "$reason" || return 0
  return 2
}

case "$MODE" in
  session-start)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    json_object_payload "$PAYLOAD" || exit 0
    DIGEST=$(printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-sessionstart-run.sh" 2>/dev/null || true)
    [ -n "$DIGEST" ] || exit 0
    json_object additionalContext "$DIGEST" || exit 0
    ;;
  agent-stop)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    STOP_ACTIVE=$(json_field "$PAYLOAD" stop-active) || exit 0
    SESSION_ID=$(json_field "$PAYLOAD" session-id) || exit 0
    case "$STOP_ACTIVE" in
      true|false) ;;
      *) exit 0 ;;
    esac
    REASON_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-copilot-stop.XXXXXX") || exit 0
    trap 'rm -f "$REASON_FILE"' EXIT HUP INT TERM
    if "$SCRIPT_DIR/fm-turnend-guard.sh" \
      --stop-active "$STOP_ACTIVE" --session-id "$SESSION_ID" \
      </dev/null 2>"$REASON_FILE"; then
      exit 0
    else
      STATUS=$?
    fi
    [ "$STATUS" -eq 2 ] || exit 0
    REASON=$(cat "$REASON_FILE" 2>/dev/null || true)
    [ -n "$REASON" ] || exit 0
    json_block_decision "$REASON" || exit 0
    ;;
  pre-arm|pre-cd)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    COMMAND=$(json_field "$PAYLOAD" command) || exit 0
    [ -n "$COMMAND" ] || exit 0
    if [ "$MODE" = pre-arm ]; then
      run_pretool_guard "$SCRIPT_DIR/fm-arm-pretool-check.sh" --command "$COMMAND" --claude
      exit $?
    fi
    run_pretool_guard "$SCRIPT_DIR/fm-cd-pretool-check.sh" --command "$COMMAND" --claude
    exit $?
    ;;
  pre-subagent)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    TOOL=$(json_field "$PAYLOAD" tool) || exit 0
    [ -n "$TOOL" ] || exit 0
    run_pretool_guard "$SCRIPT_DIR/fm-subagent-pretool-check.sh" --tool "$TOOL" --claude
    exit $?
    ;;
  *)
    echo "usage: $(basename "$0") session-start|agent-stop|pre-arm|pre-cd|pre-subagent" >&2
    exit 2
    ;;
esac
