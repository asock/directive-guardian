---
description: Remove a directive from the registry (with backup)
argument-hint: "<DIRECTIVE-NNN>"
allowed-tools: Bash
---

The user wants to delete directive **$ARGUMENTS**. Confirm by showing it
first, then remove. A backup is created automatically.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/directive-ctl.sh" show $ARGUMENTS
"${CLAUDE_PLUGIN_ROOT}/scripts/directive-ctl.sh" remove $ARGUMENTS
```

Remind the user the backup is at `directives.md.bak` + a timestamped copy,
and that `/directive-audit` will tell them the current backup count.
