---
description: List every directive Claude is supposed to remember
argument-hint: "[--priority critical|high|medium|low] [--category TAG]"
allowed-tools: Bash
---

Run the directive-guardian list command with any filters the user passed, then
summarise the output in a single sentence (total count, and a one-line
highlight of the highest-priority directive).

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/directive-ctl.sh" list $ARGUMENTS
```

If the CLI reports zero directives, suggest `/directive-add` to create one.
