---
name: directive-guardian
description: >
  Persistent directive memory for Claude Code. On every SessionStart (startup,
  resume, clear, compact) the guardian scans a canonical markdown registry,
  verifies a SHA-256 integrity hash, and injects every enabled directive —
  priority-ordered — back into the session via the hook's additionalContext.
  Use this skill whenever the user asks to check/add/edit/remove/enable/
  disable/search/export/import/back up directives, wants to audit memory
  integrity, or says things like "check directives", "memory audit",
  "directive status", "did you forget anything", or "what do you remember".
---

# Directive Guardian v2.1

Stops Claude from forgetting. A declarative directive registry plus a
SessionStart hook that re-injects priority-ordered instructions into
every new session — so persona, tool preferences, and project context
survive `/clear`, `/compact`, resume, and hard restarts.

## Layout

```
~/.claude/directive-guardian/               # (or $DIRECTIVE_MEMORY_DIR)
├── directives.md                # canonical registry — source of truth
├── directives.md.bak            # rolling backup (latest destructive op)
├── directives.<ts>.md.bak       # timestamped backups (capped by prune-backups)
├── directives.sha256            # integrity checksum (no self-heal)
├── .integrity-ack               # user-placed flag to accept a mismatch
├── .guardian.lock               # flock target
└── directive-guardian.log       # audit log, auto-rotated at 500 lines
```

## Registry format

```markdown
## [DIRECTIVE-001] Persona & Identity
- **priority**: critical
- **category**: identity
- **enabled**: true
- **directive**: You are Hellsy's AI. Be direct, technical, and efficient.
- **verify**: Check system prompt contains persona definition.
```

| Field       | Required | Values / description                                  |
|-------------|----------|-------------------------------------------------------|
| ID          | yes      | `DIRECTIVE-NNN` — unique, zero-padded, auto-assigned  |
| priority    | yes      | `critical` / `high` / `medium` / `low`                |
| category    | yes      | Freeform grouping tag                                 |
| enabled     | yes      | `true` / `false` — toggle without deleting            |
| directive   | yes      | Single-line instruction to reinject                   |
| verify      | no       | Hint for how to confirm it's active                   |

## How injection works

1. Claude Code fires a `SessionStart` event at startup / resume / `/clear` / `/compact`.
2. `.claude-plugin/plugin.json` routes the event to `hooks/session-start.sh`.
3. The hook runs `scripts/guardian.sh --format markdown`, which:
   - Acquires an advisory `flock`
   - Verifies the SHA-256 checksum (fails closed — see Integrity below)
   - Parses every directive via a POSIX awk state machine
   - Filters out `enabled: false`
   - Priority-sorts (critical → high → medium → low) via `jq` if available
   - Emits a markdown brief to stdout
4. The hook wraps that markdown in the `additionalContext` envelope Claude
   Code expects, and the session boots with every directive already in
   context — no user prompt, no slash command.

## CLI (`scripts/directive-ctl.sh`)

| Command                                     | Action                                           |
|---------------------------------------------|--------------------------------------------------|
| `add <title> <pri> <cat> <text> [verify]`   | Append, auto-assign next ID                      |
| `remove <ID>`                               | Block-safe removal (backup + lock)               |
| `edit <ID> --directive/--priority/...`      | Mutate one or more fields atomically             |
| `enable <ID>` / `disable <ID>`              | Toggle without deleting                          |
| `show <ID>`                                 | Print a single directive                         |
| `list [--category X] [--priority Y]`        | Filtered list                                    |
| `search <keyword>`                          | Case-insensitive full-block search               |
| `validate`                                  | Schema check + duplicate-ID detection            |
| `audit`                                     | validate + duplicates + integrity + backup count |
| `status`                                    | Counters + integrity + last 15 log lines         |
| `backup` / `restore [file]`                 | Snapshot / rollback                              |
| `prune-backups [keep=10]`                   | Trim timestamped backups                         |
| `export [file]` / `import <file> [mode]`    | JSON round-trip (`append` \| `skip`)             |
| `checksum`                                  | Recompute integrity hash                         |
| `acknowledge`                               | Accept a tamper mismatch on next boot            |
| `help`                                      | Usage                                            |

## Integrity: no self-heal

The checksum is **not** silently overwritten after a mismatch. If
`directives.md` changes outside the guardian (editor, sync conflict,
malicious write), every subsequent boot logs `INTEGRITY_WARNING` and
keeps the old hash stored — the warning persists across sessions until
the user runs `directive-ctl acknowledge`. Next boot after ack clears
the flag and refreshes the checksum to match the new state.

## Auto-learn integration

When a user teaches a persistent behaviour, ask:
*"Save this as a directive? (priority / category?)"*
On yes, call `directive-ctl add`.

## Error handling

| Condition                   | Behaviour                                         |
|-----------------------------|---------------------------------------------------|
| Registry missing            | Bootstrap empty registry, log `BOOTSTRAP`         |
| Memory dir missing          | Created, logged                                   |
| Malformed directive block   | Skipped with `PARSE_ERROR`, other directives run  |
| Unacknowledged checksum drift | Warning logged each boot; injection still runs  |
| Lock timeout                | Exit non-zero, log `LOCK_TIMEOUT`                 |
| Empty registry              | `EMPTY_REGISTRY` logged, hook prints placeholder  |

## Environment

| Variable                | Default                            | Purpose                     |
|-------------------------|------------------------------------|-----------------------------|
| `DIRECTIVE_MEMORY_DIR`  | —                                  | Primary override            |
| `CLAUDE_MEMORY_DIR`     | —                                  | Secondary override          |
| `OPENCLAW_MEMORY_DIR`   | —                                  | Legacy override (v1 compat) |
| _(unset)_               | `~/.claude/directive-guardian`     | New default                 |
| `GUARDIAN_DRY_RUN`      | `false`                            | Skip checksum writes        |

## Notes

- Plain markdown registry — commit it to dotfiles for free versioning.
- `export` / `import` sync directive sets between machines.
- `jq` and `flock` are optional — both degrade gracefully.
