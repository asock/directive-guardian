---
description: Acknowledge a tamper mismatch so the next boot trusts the current registry
allowed-tools: Bash
---

The user wants to accept the current registry contents after an integrity
mismatch. Confirm once (show what the mismatch is about, or at least a recent
audit line), then queue the acknowledgement:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/directive-ctl.sh" acknowledge
```

Remind them that the next SessionStart (or manual `guardian.sh` run) will
refresh the stored SHA-256 to match the current state and clear the warning.
