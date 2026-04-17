---
description: Audit directive-guardian — validation, duplicates, integrity, backups
allowed-tools: Bash
---

Run the guardian audit and translate the output into a short status report:
validation pass/fail, duplicate-ID count, integrity state (verified / mismatch
/ acknowledged), backup count, and when the registry was last modified.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/directive-ctl.sh" audit
```

If integrity reports MISMATCH, explain that the registry was modified outside
the guardian and offer to run `/directive-ack` after the user confirms the
current contents are intentional.
