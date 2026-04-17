---
description: Full-text search across every directive block
argument-hint: "<keyword>"
allowed-tools: Bash
---

Search the registry for **$ARGUMENTS** (case-insensitive, matches across
all fields). Return matching blocks verbatim.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/directive-ctl.sh" search "$ARGUMENTS"
```

If zero matches, suggest `/directives` to list everything or `/directive-add`
to create one.
