# directive-guardian

**Persistent directive memory for Claude Code.**

A Claude Code plugin that stops the AI from forgetting. Every `SessionStart`
(startup, resume, `/clear`, `/compact`), a hook re-injects your canonical
directive registry — priority-ordered, integrity-checked — back into
context before the session even begins.

## Why

`CLAUDE.md` is flat. It has no priorities, no enable/disable toggle, no
backups, no integrity check, no audit log, no way to sync between machines
without copying the whole file. Directive Guardian is CLAUDE.md with a
spine: structured records, a SHA-256 tamper guard that refuses to
self-heal, a full CLI, and a SessionStart hook that actually wires the
registry into Claude's context — which is the part that makes it work.

## Features

- **SessionStart injection** — priority-ordered markdown brief added to every new session via Claude Code's hook envelope.
- **Enable/disable toggle** — test a session without a directive without deleting it.
- **SHA-256 integrity, no self-heal** — tamper mismatch persists across boots until you explicitly `acknowledge`.
- **Advisory file locking** — `flock` on every write.
- **Auto-rotating audit log** — capped at 500 lines from both the guardian and the CLI paths.
- **Atomic backups** — rolling `.bak` plus timestamped copies, with a `prune-backups` command.
- **Duplicate-ID detection** — `validate` and `audit` catch hand-edit collisions.
- **Export / import with conflict modes** — `append` (default) or `skip` duplicates by title.
- **`show`, `audit`, `acknowledge` commands** — one-stop health check and tamper workflow.
- **POSIX portable** — macOS and Linux, no GNU-only features.

## Install as a Claude Code plugin

Put the repo wherever your plugins live and point Claude Code at the root:

```bash
# one-time
cp -r directive-guardian-v2 ~/.claude/plugins/directive-guardian

# ...then enable the plugin in your Claude Code settings
# (the .claude-plugin/plugin.json at the plugin root registers the SessionStart hook).
```

The hook runs automatically on every new session. No prompt engineering
required — your directives are already in context when the model wakes up.

## Quick start (CLI)

```bash
# Bootstrap (creates registry if missing)
~/.claude/plugins/directive-guardian/scripts/guardian.sh

CTL=~/.claude/plugins/directive-guardian/scripts/directive-ctl.sh

$CTL add "Core Persona" critical identity "Be direct and technical."
$CTL add "Tool Prefs"   high     tooling  "Prefer ripgrep. Use Docker for isolation."

$CTL list
$CTL list --priority critical
$CTL list --category tooling

$CTL show     DIRECTIVE-001
$CTL disable  DIRECTIVE-002
$CTL enable   DIRECTIVE-002
$CTL edit     DIRECTIVE-001 --directive "Updated persona text"

$CTL search   "docker"
$CTL status           # counters + integrity + last 15 log lines
$CTL validate         # schema + duplicate-ID detection
$CTL audit            # validate + duplicates + integrity + backup count

$CTL backup
$CTL prune-backups 5
$CTL restore

$CTL export directives.json
$CTL import directives.json skip   # skip duplicates by title
```

## Integrity (no self-heal)

If `directives.md` is modified outside the guardian (an editor, a sync
conflict, something malicious), the next run logs
`INTEGRITY_WARNING` — and **keeps logging it every boot** until you
explicitly accept the new state:

```bash
$CTL audit          # see the mismatch
$CTL acknowledge    # queues an ack
# next SessionStart / guardian.sh run: checksum refreshed to current state.
```

This is the opposite of v1/v2.0 behaviour, which quietly overwrote the
stored hash after a single warning and made tampering undetectable
thereafter.

## Registry format

Directives live in `~/.claude/directive-guardian/directives.md`:

```markdown
## [DIRECTIVE-001] Core Persona
- **priority**: critical
- **category**: identity
- **enabled**: true
- **directive**: Be direct and technical.
- **verify**: Check that persona definition is loaded in system context.
```

| Field      | Required | Values                                 |
|------------|----------|----------------------------------------|
| priority   | yes      | `critical` / `high` / `medium` / `low` |
| category   | yes      | Any grouping tag                       |
| enabled    | yes      | `true` / `false`                       |
| directive  | yes      | The instruction to reinject            |
| verify     | no       | Hint for how to confirm it's active    |

## Agent trigger phrases

Handled by the skill definition (`SKILL.md`) so Claude invokes the guardian naturally:

| Phrase                    | Action                                |
|---------------------------|---------------------------------------|
| `check directives`        | Report status of all directives       |
| `reapply memory`          | Force re-run of the SessionStart brief|
| `directive status`        | Full status table + integrity         |
| `add directive <text>`    | Append new directive                  |
| `did you forget anything` | Run `audit`                           |

## Architecture

```
directive-guardian-v2/
├── .claude-plugin/
│   └── plugin.json           ← registers the SessionStart hook
├── hooks/
│   └── session-start.sh      ← calls guardian.sh, emits additionalContext
├── scripts/
│   ├── guardian.sh           ← boot parser (JSON or markdown)
│   └── directive-ctl.sh      ← CRUD + audit CLI
├── templates/
│   └── directives-sample.md
├── tests/
│   └── test_guardian.sh      ← 50+ assertions (CRUD, regressions, tamper)
└── SKILL.md / AUDIT.md / README.md
```

Runtime artifacts (not tracked in git):

```
~/.claude/directive-guardian/
├── directives.md
├── directives.md.bak
├── directives.<ts>.md.bak
├── directives.sha256
├── .integrity-ack
└── directive-guardian.log
```

## Running tests

```bash
bash tests/test_guardian.sh
```

Covers bootstrap, full CRUD, filtering, parsing, enable/disable, edit,
search, remove (including block-orphan regression), validation,
duplicate-ID detection, input sanitisation, backup/restore/prune,
JSON escape regression, checksum persistence across tamper, export,
import with conflict modes, status dashboard, `show`, `audit`, and
the SessionStart hook envelope.

## Environment

| Variable                | Default                           | Description             |
|-------------------------|-----------------------------------|-------------------------|
| `DIRECTIVE_MEMORY_DIR`  | —                                 | Primary override        |
| `CLAUDE_MEMORY_DIR`     | —                                 | Secondary override      |
| `OPENCLAW_MEMORY_DIR`   | —                                 | Legacy (v1 compat)      |
| _(none set)_            | `~/.claude/directive-guardian`    | Default location        |
| `GUARDIAN_DRY_RUN`      | `false`                           | Skip checksum updates   |

## Optional dependencies

| Tool    | Required | Used for                              |
|---------|----------|---------------------------------------|
| `jq`    | no       | Priority sort, markdown brief, import |
| `flock` | no       | Advisory file locking (Linux)         |

Both degrade gracefully — sorting falls back to parse order, locking is
skipped on macOS without `flock`.

## License

MIT — see [LICENSE](LICENSE).
