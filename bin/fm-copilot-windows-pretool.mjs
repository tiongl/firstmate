#!/usr/bin/env node

if (
  process.env.GITHUB_ACTIONS === "true" ||
  Object.hasOwn(process.env, "COPILOT_AGENT_PROMPT")
) {
  process.exit(0);
}

const reason =
  "Firstmate Copilot primary sessions are unsupported on native Windows. Use macOS, Linux, or WSL; Windows Zellij support is a separate experimental backend.";

process.stdout.write(
  `${JSON.stringify({
    permissionDecision: "deny",
    permissionDecisionReason: reason,
  })}\n`,
);
process.exit(2);
