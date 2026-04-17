# Changelog

All notable changes to directive-guardian.

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
