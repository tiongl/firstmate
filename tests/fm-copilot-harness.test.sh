#!/usr/bin/env bash
# Behavior tests for GitHub Copilot CLI detection and native hook translation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)
HOOK="$ROOT/bin/fm-copilot-hook.sh"

test_live_process_shape_detects_copilot() {
  local fakebin out pid
  fakebin=$(fm_fakebin "$TMP_ROOT/detect")
  ln -s /bin/bash "$fakebin/copilot"
  out=$("$fakebin/copilot" -c "\"$ROOT/bin/fm-harness.sh\"; :")
  [ "$out" = copilot ] || fail "copilot argv[0] process shape detected as '$out'"
  pid=$("$fakebin/copilot" -c ". \"$ROOT/bin/fm-session-lock-lib.sh\"; fm_harness_ancestry_pid")
  case "$pid" in ''|*[!0-9]*) fail "copilot lock ancestry returned '$pid'" ;; esac
  pass "copilot harness and lock detection recognize the markerless MainThread/argv[0] process shape"
}

make_hook_fixture() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$HOOK" "$dir/bin/fm-copilot-hook.sh"
  chmod +x "$dir/bin/fm-copilot-hook.sh"
}

make_node_only_path() {
  local dir=$1 command source
  shift
  mkdir -p "$dir"
  for command in bash cat dirname mktemp node rm "$@"; do
    source=$(command -v "$command") || fail "required test command is unavailable: $command"
    ln -sf "$source" "$dir/$command"
  done
  ! PATH="$dir" command -v python3 >/dev/null 2>&1 \
    || fail "node-only test path unexpectedly contains python3"
}

test_github_actions_leaves_repository_hooks_inert() {
  local dir mode out status
  dir="$TMP_ROOT/github-actions"
  make_hook_fixture "$dir"
  for mode in fm-sessionstart-run fm-turnend-guard fm-arm-pretool-check \
              fm-cd-pretool-check fm-subagent-pretool-check; do
    cat > "$dir/bin/$mode.sh" <<'SH'
#!/usr/bin/env bash
printf 'repository hook ran in GitHub Actions\n'
exit 2
SH
    chmod +x "$dir/bin/$mode.sh"
  done

  for mode in session-start agent-stop pre-arm pre-cd pre-subagent; do
    status=0
    out=$(printf '{"sessionId":"cloud","stop_hook_active":false,"toolName":"task","toolArgs":{"command":"bin/fm-watch-arm.sh &"}}' \
      | GITHUB_ACTIONS=true "$dir/bin/fm-copilot-hook.sh" "$mode" 2>&1) || status=$?
    expect_code 0 "$status" "GitHub Actions $mode hook"
    [ -z "$out" ] || fail "GitHub Actions $mode hook was not inert: $out"
  done
  pass "Copilot repository hooks stay inert and allow task in GitHub Actions"
}

test_local_primary_denies_task_tool() {
  local dir out status=0
  dir="$TMP_ROOT/local-primary"
  make_hook_fixture "$dir"
  cp "$ROOT/bin/fm-subagent-pretool-check.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-subagent-pretool-check.sh"
  mkdir -p "$dir/state"
  printf '# fixture\n' > "$dir/AGENTS.md"
  git -C "$dir" init -q

  out=$(printf '{"toolName":"task"}' \
    | env GITHUB_ACTIONS='' FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
      "$dir/bin/fm-copilot-hook.sh" pre-subagent 2>&1) || status=$?
  expect_code 2 "$status" "local Copilot primary task denial"
  printf '%s' "$out" | node -e \
    'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => { const d=JSON.parse(s); if (d.hookSpecificOutput.permissionDecision !== "deny" || !d.systemMessage.includes("blocked tool: task")) process.exit(1); });' \
    || fail "local Copilot primary task denial lost its native decision: $out"
  pass "local Copilot primary sessions still deny the task tool"
}

test_malformed_payloads_stay_inert() {
  local dir mode out payload status
  dir="$TMP_ROOT/malformed"
  make_hook_fixture "$dir"
  for mode in fm-sessionstart-run fm-turnend-guard fm-arm-pretool-check \
              fm-cd-pretool-check fm-subagent-pretool-check; do
    cat > "$dir/bin/$mode.sh" <<'SH'
#!/usr/bin/env bash
printf 'shared hook reached\n'
exit 2
SH
    chmod +x "$dir/bin/$mode.sh"
  done

  for mode in agent-stop pre-arm pre-cd pre-subagent; do
    status=0
    out=$(printf '{not-json' | GITHUB_ACTIONS='' "$dir/bin/fm-copilot-hook.sh" "$mode" 2>&1) || status=$?
    expect_code 0 "$status" "malformed Copilot $mode payload"
    [ -z "$out" ] || fail "malformed Copilot $mode payload reached shared behavior: $out"
  done

  while IFS='|' read -r mode payload; do
    status=0
    out=$(printf '%s' "$payload" | GITHUB_ACTIONS='' "$dir/bin/fm-copilot-hook.sh" "$mode" 2>&1) || status=$?
    expect_code 0 "$status" "invalid Copilot $mode payload"
    [ -z "$out" ] || fail "invalid Copilot $mode payload reached shared behavior: $out"
  done <<'EOF'
session-start|[]
agent-stop|[]
pre-arm|[]
pre-cd|[]
pre-subagent|[]
agent-stop|{"stop_hook_active":{}}
agent-stop|{"stop_hook_active":false,"sessionId":{}}
agent-stop|{"stop_hook_active":false,"session_id":[]}
pre-arm|{"toolArgs":{"command":{}}}
pre-cd|{"toolArgs":{"command":[]}}
pre-subagent|{"toolName":{"name":"task"}}
EOF
  pass "malformed and mistyped Copilot payloads stay inert"
}

test_session_start_becomes_additional_context_without_python() {
  local dir node_path out value
  dir="$TMP_ROOT/session-start"
  node_path="$dir/node-only-bin"
  make_hook_fixture "$dir"
  make_node_only_path "$node_path"
  cat > "$dir/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'FIRSTMATE COPILOT START\nsecond line\n'
SH
  chmod +x "$dir/bin/fm-sessionstart-run.sh"
  out=$(printf '{"source":"startup"}' \
    | PATH="$node_path" GITHUB_ACTIONS='' "$dir/bin/fm-copilot-hook.sh" session-start)
  value=$(printf '%s' "$out" | node -e \
    'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => process.stdout.write(JSON.parse(s).additionalContext));')
  assert_contains "$value" "FIRSTMATE COPILOT START" "session-start digest was not injected"
  assert_contains "$value" "second line" "session-start multiline context was truncated"
  pass "copilot sessionStart translates the complete digest without python3"
}

test_agent_stop_translates_block_decision_without_python() {
  local dir node_path out decision reason
  dir="$TMP_ROOT/agent-stop"
  node_path="$dir/node-only-bin"
  make_hook_fixture "$dir"
  make_node_only_path "$node_path"
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'restore Firstmate supervision\n' >&2
exit 2
SH
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  out=$(printf '{"sessionId":"copilot-test","stop_hook_active":false}' \
    | PATH="$node_path" GITHUB_ACTIONS='' "$dir/bin/fm-copilot-hook.sh" agent-stop)
  decision=$(printf '%s' "$out" | node -e \
    'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => process.stdout.write(JSON.parse(s).decision));')
  reason=$(printf '%s' "$out" | node -e \
    'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => process.stdout.write(JSON.parse(s).reason));')
  [ "$decision" = block ] || fail "agentStop decision was '$decision', expected block"
  assert_contains "$reason" "restore Firstmate supervision" "agentStop lost the shared guard reason"
  pass "copilot agentStop converts the shared exit-2 guard without python3"
}

test_pretool_payload_reaches_shared_policy_without_python() {
  local dir node_path out status=0
  dir="$TMP_ROOT/pretool"
  node_path="$dir/node-only-bin"
  make_hook_fixture "$dir"
  make_node_only_path "$node_path"
  cat > "$dir/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = --command ] || exit 9
[ "$2" = 'bin/fm-watch-arm.sh &' ] || exit 8
[ "$3" = --claude ] || exit 7
printf 'denied by shared policy\n' >&2
exit 2
SH
  chmod +x "$dir/bin/fm-arm-pretool-check.sh"
  out=$(printf '{"toolName":"bash","toolArgs":{"command":"bin/fm-watch-arm.sh &"}}' \
    | PATH="$node_path" GITHUB_ACTIONS='' "$dir/bin/fm-copilot-hook.sh" pre-arm 2>&1) || status=$?
  expect_code 2 "$status" "Copilot preToolUse denial"
  assert_contains "$out" "denied by shared policy" "preToolUse lost the shared policy denial"
  pass "copilot preToolUse reaches the shared command policy without python3"
}

test_live_process_shape_detects_copilot
test_github_actions_leaves_repository_hooks_inert
test_local_primary_denies_task_tool
test_malformed_payloads_stay_inert
test_session_start_becomes_additional_context_without_python
test_agent_stop_translates_block_decision_without_python
test_pretool_payload_reaches_shared_policy_without_python

echo "# all fm-copilot-harness tests passed"
