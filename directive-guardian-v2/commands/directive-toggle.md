---
description: Enable or disable a directive without deleting it
argument-hint: "<DIRECTIVE-NNN>"
allowed-tools: Bash
---

Flip `enabled` on directive **$ARGUMENTS**. First check its current state via
`show`, then issue the opposite command.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/directive-ctl.sh" show $ARGUMENTS
```

If the output shows `enabled: true`, run `disable`; otherwise run `enable`:

```bash
# disable
"${CLAUDE_PLUGIN_ROOT}/scripts/directive-ctl.sh" disable $ARGUMENTS
# OR enable
"${CLAUDE_PLUGIN_ROOT}/scripts/directive-ctl.sh" enable $ARGUMENTS
```

Disabled directives stay in the registry but are skipped by the SessionStart
hook — useful for A/B testing behaviour without losing the text.
