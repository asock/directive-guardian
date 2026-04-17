---
description: Save a new persistent directive to the guardian registry
argument-hint: "<free-form description of the directive to save>"
allowed-tools: Bash
---

The user wants to persist a directive so it survives `/clear`, `/compact`,
resume, and restart. Their raw description: **$ARGUMENTS**

1. Decide a short title (<=40 chars), a priority (`critical` / `high` /
   `medium` / `low`), and a single-word category. Bias towards `high` unless
   the user's phrasing clearly implies otherwise. If any field is ambiguous,
   ask ONE clarifying question before writing.
2. Invoke the CLI. Quote arguments carefully — the directive text may contain
   spaces and punctuation:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/directive-ctl.sh" add \
  "<title>" <priority> <category> "<directive text>"
```

3. Report the new ID and remind the user it will be re-injected on every
   SessionStart going forward.
