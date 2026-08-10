#!/usr/bin/env bash
# Behavior tests for GitHub Copilot CLI detection and native hook translation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)
HOOK="$ROOT/bin/fm-copilot-hook.sh"

test_repository_hook_has_native_windows_dispatch() {
  if ! node - "$ROOT/.github/hooks/firstmate.json" <<'NODE'
const fs = require("fs");
const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const expected = {
  sessionStart: ["session-start"],
  preToolUse: ["pre-arm", "pre-cd", "pre-subagent"],
  agentStop: ["agent-stop"],
};
if (config.version !== 1 || typeof config.hooks !== "object") process.exit(1);
for (const [event, modes] of Object.entries(expected)) {
  const entries = config.hooks[event];
  if (!Array.isArray(entries) || entries.length !== modes.length) process.exit(1);
  entries.forEach((entry, index) => {
    if (entry.type !== "command" || entry.cwd !== ".") process.exit(1);
    if (entry.bash !== `bin/fm-copilot-hook.sh ${modes[index]}`) process.exit(1);
    if (typeof entry.powershell !== "string") process.exit(1);
    if (!entry.powershell.includes("Get-Command bash.exe -All -CommandType Application")) process.exit(1);
    if (!entry.powershell.includes("git.exe")) process.exit(1);
    if (!entry.powershell.endsWith(`-lc 'bin/fm-copilot-hook.sh ${modes[index]}'`)) process.exit(1);
    if (event === "preToolUse" && (modes[index] === "pre-arm" || modes[index] === "pre-cd")) {
      if (typeof entry.matcher !== "string") process.exit(1);
      const matcher = new RegExp(entry.matcher);
      if (!matcher.test("bash") || !matcher.test("powershell") || matcher.test("task")) process.exit(1);
    }
  });
}
NODE
  then
    fail "repository Copilot hook lacks equivalent Git Bash PowerShell dispatch"
  fi
  pass "repository Copilot hooks dispatch through Git Bash on Windows"
}

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

test_cloud_agent_leaves_repository_hooks_inert() {
  local dir mode out status
  dir="$TMP_ROOT/cloud-agent"
  make_hook_fixture "$dir"
  for mode in fm-sessionstart-run fm-turnend-guard fm-arm-pretool-check \
              fm-cd-pretool-check fm-subagent-pretool-check; do
    cat > "$dir/bin/$mode.sh" <<'SH'
#!/usr/bin/env bash
printf 'repository hook ran in Copilot cloud agent\n'
exit 2
SH
    chmod +x "$dir/bin/$mode.sh"
  done

  for mode in session-start agent-stop pre-arm pre-cd pre-subagent; do
    status=0
    out=$(printf '{"sessionId":"cloud","stop_hook_active":false,"toolName":"task","toolArgs":{"command":"bin/fm-watch-arm.sh &"}}' \
      | GITHUB_ACTIONS='' COPILOT_AGENT_PROMPT='cloud task' \
        "$dir/bin/fm-copilot-hook.sh" "$mode" 2>&1) || status=$?
    expect_code 0 "$status" "Copilot cloud-agent $mode hook"
    [ -z "$out" ] || fail "Copilot cloud-agent $mode hook was not inert: $out"
  done
  pass "Copilot cloud-agent identity bypasses sessionStart, preToolUse, and agentStop guards"
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
    | env -u COPILOT_AGENT_PROMPT GITHUB_ACTIONS='' FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
      "$dir/bin/fm-copilot-hook.sh" pre-subagent) || status=$?
  expect_code 2 "$status" "local Copilot primary task denial"
  printf '%s' "$out" | node -e \
    'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => { const d=JSON.parse(s); if (d.permissionDecision !== "deny" || !d.permissionDecisionReason.includes("blocked tool: task")) process.exit(1); });' \
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
    out=$(printf '{not-json' | env -u COPILOT_AGENT_PROMPT GITHUB_ACTIONS='' \
      "$dir/bin/fm-copilot-hook.sh" "$mode" 2>&1) || status=$?
    expect_code 0 "$status" "malformed Copilot $mode payload"
    [ -z "$out" ] || fail "malformed Copilot $mode payload reached shared behavior: $out"
  done

  while IFS='|' read -r mode payload; do
    status=0
    out=$(printf '%s' "$payload" | env -u COPILOT_AGENT_PROMPT GITHUB_ACTIONS='' \
      "$dir/bin/fm-copilot-hook.sh" "$mode" 2>&1) || status=$?
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
    | env -u COPILOT_AGENT_PROMPT PATH="$node_path" GITHUB_ACTIONS='' \
      "$dir/bin/fm-copilot-hook.sh" session-start)
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
    | env -u COPILOT_AGENT_PROMPT PATH="$node_path" GITHUB_ACTIONS='' \
      "$dir/bin/fm-copilot-hook.sh" agent-stop)
  decision=$(printf '%s' "$out" | node -e \
    'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => process.stdout.write(JSON.parse(s).decision));')
  reason=$(printf '%s' "$out" | node -e \
    'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => process.stdout.write(JSON.parse(s).reason));')
  [ "$decision" = block ] || fail "agentStop decision was '$decision', expected block"
  assert_contains "$reason" "restore Firstmate supervision" "agentStop lost the shared guard reason"
  pass "copilot agentStop converts the shared exit-2 guard without python3"
}

test_pretool_denials_use_native_output_without_python() {
  local dir node_path mode payload out_file err_file out status
  dir="$TMP_ROOT/pretool"
  node_path="$dir/node-only-bin"
  make_hook_fixture "$dir"
  make_node_only_path "$node_path"
  cat > "$dir/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = --command ] || exit 9
[ "$2" = 'bin/fm-watch-arm.sh &' ] || exit 8
[ "$3" = --claude ] || exit 7
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"arm denied by shared policy"}\n' >&2
exit 2
SH
  cat > "$dir/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = --command ] || exit 9
[ "$2" = 'cd projects/demo' ] || exit 8
[ "$3" = --claude ] || exit 7
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"cd denied by shared policy"}\n' >&2
exit 2
SH
  cat > "$dir/bin/fm-subagent-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = --tool ] || exit 9
[ "$2" = task ] || exit 8
[ "$3" = --claude ] || exit 7
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"subagent denied by shared policy"}\n' >&2
exit 2
SH
  chmod +x "$dir/bin/fm-arm-pretool-check.sh" "$dir/bin/fm-cd-pretool-check.sh" \
    "$dir/bin/fm-subagent-pretool-check.sh"

  while IFS='|' read -r mode payload; do
    out_file="$dir/$mode.out"
    err_file="$dir/$mode.err"
    status=0
    printf '%s' "$payload" \
      | env -u COPILOT_AGENT_PROMPT PATH="$node_path" GITHUB_ACTIONS='' \
        "$dir/bin/fm-copilot-hook.sh" "$mode" \
        >"$out_file" 2>"$err_file" || status=$?
    expect_code 2 "$status" "Copilot $mode denial"
    [ ! -s "$err_file" ] || fail "Copilot $mode denial leaked non-native stderr: $(cat "$err_file")"
    out=$(cat "$out_file")
    printf '%s' "$out" | node -e \
      'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => { const d=JSON.parse(s); if (d.permissionDecision !== "deny" || !d.permissionDecisionReason.includes("denied by shared policy")) process.exit(1); });' \
      || fail "Copilot $mode denial lost its native decision: $out"
  done <<'EOF'
pre-arm|{"toolName":"bash","toolArgs":{"command":"bin/fm-watch-arm.sh &"}}
pre-cd|{"toolName":"bash","toolArgs":{"command":"cd projects/demo"}}
pre-subagent|{"toolName":"task"}
EOF
  pass "copilot preToolUse denials use native stdout decisions without python3"
}

test_powershell_calls_reach_shell_policies() {
  local dir mode command out status
  dir="$TMP_ROOT/powershell-policy"
  make_hook_fixture "$dir"
  cp "$ROOT/bin/fm-arm-pretool-check.sh" "$ROOT/bin/fm-arm-command-policy.mjs" \
    "$ROOT/bin/fm-cd-pretool-check.sh" "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/"
  chmod +x "$dir/bin/fm-arm-pretool-check.sh" "$dir/bin/fm-cd-pretool-check.sh"
  printf '# fixture\n' > "$dir/AGENTS.md"
  git -C "$dir" init -q

  while IFS='|' read -r mode command; do
    status=0
    out=$(node -e 'process.stdout.write(JSON.stringify({toolName:"powershell",toolArgs:{command:process.argv[1]}}))' "$command" \
      | env -u COPILOT_AGENT_PROMPT GITHUB_ACTIONS='' FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" \
        "$dir/bin/fm-copilot-hook.sh" "$mode") || status=$?
    expect_code 2 "$status" "PowerShell $mode denial"
    printf '%s' "$out" | node -e \
      'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => { const d=JSON.parse(s); if (d.permissionDecision !== "deny" || !d.permissionDecisionReason) process.exit(1); });' \
      || fail "PowerShell $mode denial lost its native decision: $out"
  done <<'EOF'
pre-arm|bin/fm-watch-arm.sh &
pre-cd|cd projects/demo
EOF

  for mode in pre-arm pre-cd; do
    status=0
    out=$(printf '{"toolName":"powershell","toolArgs":{"command":"Write-Output safe"}}' \
      | env -u COPILOT_AGENT_PROMPT GITHUB_ACTIONS='' FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" \
        "$dir/bin/fm-copilot-hook.sh" "$mode") || status=$?
    expect_code 0 "$status" "PowerShell $mode allow"
    [ -z "$out" ] || fail "PowerShell $mode allow emitted a decision: $out"
  done
  pass "PowerShell shell calls reach command policies and preserve deny and allow decisions"
}

test_repository_hook_has_native_windows_dispatch
test_live_process_shape_detects_copilot
test_github_actions_leaves_repository_hooks_inert
test_cloud_agent_leaves_repository_hooks_inert
test_local_primary_denies_task_tool
test_malformed_payloads_stay_inert
test_session_start_becomes_additional_context_without_python
test_agent_stop_translates_block_decision_without_python
test_pretool_denials_use_native_output_without_python
test_powershell_calls_reach_shell_policies

echo "# all fm-copilot-harness tests passed"
