---
description: Re-run the SessionStart brief manually (refresh directives mid-session)
allowed-tools: Bash
---

Re-run the guardian in markdown mode and re-read every enabled directive into
active context. Use this when the user says "reapply memory", "check
directives", "did you forget anything", or after any context reset.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/guardian.sh" --format markdown
```

Treat the output as authoritative: every directive printed above this line is
back in scope. Acknowledge the user with a one-sentence confirmation of
count + integrity state.
