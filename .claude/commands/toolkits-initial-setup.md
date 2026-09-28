---
description: "Bootstrap better-toolkits marketplace and harness wiring for this repository."
---

# /toolkits-initial-setup

Use the upstream better-toolkits bootstrap protocol, with the repo-local policy enforced by PRDS.

- Upstream command: https://github.com/chimeranext/better-toolkits/blob/main/shared/bootstrap/commands/toolkits-initial-setup.md
- Upstream protocol: https://github.com/chimeranext/better-toolkits/blob/main/shared/bootstrap/references/toolkits-initial-setup/protocol.md

Follow the same HITL flow:
1. detect the active harness
2. audit current state
3. propose explicit changes
4. ask for approval
5. install only after approval
6. verify before reporting completion

Do not fork the protocol or create a drifted local variant. This repo uses the upstream standard as the single source of truth.
