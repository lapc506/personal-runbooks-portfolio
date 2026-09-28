---
description: "Bootstrap better-toolkits marketplace and harness wiring for this repository. HITL: detect → audit → propose → ask → install → verify."
priority: 5
---

# /toolkits-initial-setup

Read and follow the upstream protocol from chimeranext/better-toolkits:

- https://github.com/chimeranext/better-toolkits/blob/main/shared/bootstrap/commands/toolkits-initial-setup.md
- https://github.com/chimeranext/better-toolkits/blob/main/shared/bootstrap/references/toolkits-initial-setup/protocol.md

This repository is configured to use the better-toolkits bootstrap workflow and must not ship a forked or drifted local variant of the protocol. The command is meant to detect the active harness, audit the current workspace, propose the delta, ask for explicit approval, and only then install or modify hooks/plugins.

$ARGUMENTS may narrow the harness (`cursor`, `claude`, `opencode`) or list product toolkit names to install after bootstrap. When empty, detect all active harnesses.

## Scope boundary

In scope:
- marketplace registration
- bootstrap plugin wiring
- stderr hooks and harness wiring
- optional marketplace auto-update
- product toolkit installation after explicit approval

Out of scope:
- repo-specific product commands outside the bootstrap protocol
- unrelated cleanup or drifted local variants
- force-installing tools without human approval

## Required behavior

1. Detect the active harness from the current workspace context.
2. Audit the current state in read-only mode.
3. Propose the exact diff and commands.
4. Stop for explicit human approval.
5. Install only after approval.
6. Verify with the repo's bootstrap checks before reporting success.

No writes outside the active workspace are allowed without explicit human approval.
