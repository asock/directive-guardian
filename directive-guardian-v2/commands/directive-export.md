---
description: Export the directive registry as JSON (for syncing between machines)
argument-hint: "[output-file]"
allowed-tools: Bash
---

Export the registry as a portable JSON file. Defaults to
`directives-export.json` in the memory dir if the user didn't specify a path.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/directive-ctl.sh" export $ARGUMENTS
```

Tell the user where the file was written and mention that the companion
command is `import <file> [append|skip]`.
