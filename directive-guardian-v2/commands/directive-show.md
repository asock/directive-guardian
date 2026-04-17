---
description: Show one directive's full text (priority, category, body, verify)
argument-hint: "<DIRECTIVE-NNN>"
allowed-tools: Bash
---

Print the full block for the requested directive. If the user's argument isn't
in `DIRECTIVE-NNN` form but matches a title, first `list` to find the ID.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/directive-ctl.sh" show $ARGUMENTS
```
