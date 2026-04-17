# Changelog

All notable changes to directive-guardian.

## [1.0.0] — 2026-04-17

First public release. Consolidates the internal 2.0 → 2.3 development
line into a single shipped version. Everything in 2.0–2.3 below is
part of 1.0; the sub-sections are kept for provenance.

- Claude Code plugin (SessionStart hook + 10 slash commands + installer)
- Real integrity guard (no self-heal; `acknowledge` workflow)
- Full CRUD / audit / show / validate / duplicate-ID detection
- Multiline directives (parser) and onboarding from existing CLAUDE.md
- Git mode: auto-commit mutations, multi-device sync via `sync`
- Auto-pruned backups, schema versioning, `--json` output,
  category-grouped markdown brief
- Race-safe under concurrent writes (caught and fixed the
  `DIRECTIVE-008/009` octal bug via a 10-way parallel-add stress test)
- 130 tests green

## [2.3.0] — 2026-04-17

### Added
- **Auto-prune** — backups trimmed to `MAX_BACKUPS` (default 10) after every
  mutation. Gated on `GUARDIAN_AUTO_PRUNE=true` (default). The memory dir no
  longer grows unbounded on busy installs.
- **`directive-ctl sync [both|push|pull]`** — git-backed multi-device sync.
  Snapshots any un-committed local edits first (so manual CLAUDE.md tweaks
  aren't stranded), rebases on pull, pushes on push. No-ops cleanly when
  no `origin` remote is configured.
- **`directive-ctl list --json`** — machine-readable output. Reuses the
  guardian's JSON manifest as the source of truth; `--category` and
  `--priority` filters apply via jq.
- **Markdown brief grouped by category** — the hook-injected context now
  reads as `### <category> (count)` sections rather than a flat list.
  Categories containing a critical directive sort first, then by name.

### Tests
- 118 → 130 green. New coverage: auto-prune cap, `list --json` shape and
  filters, categorical grouping and ordering in the markdown brief, and
  the sync push path against a local bare remote.

## [2.2.0] — 2026-04-17

### Added
- **Git mode**: `directive-ctl git-init` turns the memory dir into a git
  repo; setting `GUARDIAN_GIT_AUTOCOMMIT=true` makes every mutation
  (add / edit / remove / import / from-claude-md) produce a commit.
  Uses a dedicated tool identity (`directive-guardian@localhost`) and
  bypasses signing because these are automated tool snapshots, not
  user-authored commits.
- **Schema version sentinel** — new registries include
  `<!-- directive-guardian schema: 1 -->` as line 1. Guardian logs
  `SCHEMA_WARNING` on mismatch; legacy registries without the sentinel
  still load.
- **Five more slash commands**: `/directive-show`, `/directive-remove`,
  `/directive-toggle`, `/directive-search`, `/directive-export`.

### Fixed
- **`next_id` octal bug** — `$(( 008 + 1 ))` crashed with
  "value too great for base" whenever the last directive was
  `DIRECTIVE-008` or `DIRECTIVE-009`, silently dropping writes under
  concurrency. Fixed by forcing base-10 with `10#` prefix in `next_id`,
  `cmd_import`, and `cmd_from_claude_md`.
- **`cmd_edit` / `cmd_import` subshell propagation** — `set -e` inherited
  into git helper subshells aborted on missing optional files. Pinned
  with explicit `set +e` and trailing `exit 0` inside the subshells.

### Tests
- 101 → 118 green. New coverage: schema sentinel presence/mismatch,
  git auto-commit for add/edit/remove, autocommit gated by env var,
  `git-init` idempotence, and a 10-way concurrent-write stress test
  (which is how the `next_id` octal bug was caught).

## [2.1.0] — 2026-04-17

The "actually a Claude Code plugin" release. Adds the SessionStart
integration that turns a pile of shell scripts into a real persistence
layer, and fixes the tamper-detection bug that made v2.0's integrity
feature cosmetic.

### Added
- **Claude Code plugin manifest** (`.claude-plugin/plugin.json`) with a
  `SessionStart` hook (`hooks/session-start.sh`) that injects every
  enabled directive, priority-ordered, into the model's context on
  startup / resume / `/clear` / `/compact`.
- **Slash commands** (`commands/`): `/directives`, `/directive-add`,
  `/directive-audit`, `/directive-reapply`, `/directive-ack`.
- **One-command installer** (`install.sh`) copies the plugin into
  `~/.claude/plugins/` and bootstraps the registry.
- **`guardian.sh --format markdown`** — renders the manifest as a
  human-readable brief (used by the hook).
- **`guardian.sh --verify-only`** — integrity check that exits 2 on
  mismatch; use it from CI or a cron job.
- **Multiline directive support** — fields can wrap onto indented
  continuation lines (GitHub-rendered markdown list item syntax).
- **New CLI commands**:
  - `show <ID>` — print one directive's full block.
  - `audit` — validate + duplicate-ID check + integrity + backup count
    + last-mutation time, one-stop health report.
  - `acknowledge` — accept the current registry state after a tamper
    mismatch; next boot refreshes the stored checksum.
  - `prune-backups [keep=10]` — trim old timestamped backups.
  - `from-claude-md [file]` — seed an empty registry from an existing
    CLAUDE.md (first-run onboarding).
- **Import conflict modes** — `import <file> [append|skip]` dedupes
  by title in `skip` mode.
- **Dual env-var resolution** — `DIRECTIVE_MEMORY_DIR` (preferred),
  `CLAUDE_MEMORY_DIR`, then `OPENCLAW_MEMORY_DIR` (legacy), defaulting
  to `~/.claude/directive-guardian`. Auto-detects an existing
  `~/.openclaw/memory` dir so v1 users upgrade in place.

### Changed
- **Integrity check no longer self-heals.** On a SHA-256 mismatch the
  stored hash is kept and the warning logs every subsequent boot until
  the user runs `directive-ctl acknowledge`. Previously v2.0 overwrote
  the hash at the end of every run, silently accepting tamper after one
  warning.
- **`cmd_edit`** now strips orphan continuation lines when replacing a
  multiline field, so edits don't leave stray content attached to the
  new value.
- **Log rotation** now fires from the CLI write path as well as from
  `guardian.sh` — heavy CLI use no longer grows the log between boots.
- **Validation** catches duplicate `DIRECTIVE-NNN` IDs (hand-edit or
  merge-conflict hazard).
- **`cmd_import`** computes `next_id` once and increments in-memory
  (was O(N²), now O(N)).

### Fixed
- **`cmd_remove` orphan content** — non-field lines inside a removed
  directive block no longer leak into the following content. The awk
  state machine now skips the whole block until the next `##` heading.
- **Consecutive blank lines** after removal are collapsed.

### Deprecated
- `OPENCLAW_MEMORY_DIR` still works but is a legacy fallback; new
  installs should use `DIRECTIVE_MEMORY_DIR`.

## [2.0.0] — earlier

Initial v2 rewrite. Resolved the 18 findings from the v1 audit:
awk parser flush, full RFC 8259 JSON escaping, POSIX-portable grep,
file locking, SHA-256 integrity (broken — see 2.1 fix), auto-rotating
log, enable/disable toggle, backups, export/import, `edit`, search,
validation, input sanitisation, test harness (45 tests).

## [1.0.0] — original

Prototype. Documented as "Orbital Threat Assessment" in `AUDIT.md`:
silent data loss from the awk parser, JSON injection via unescaped
characters, `sed` destroying trailing content, `grep -oP` breaking on
macOS, plus five security issues and seven missing features.
