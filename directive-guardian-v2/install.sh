#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# directive-guardian — one-command install for Claude Code
#
# Copies the plugin to ~/.claude/plugins/directive-guardian (override with
# $CLAUDE_PLUGINS_DIR), runs a dry-run guardian.sh to bootstrap the registry,
# and prints the next steps for enabling the plugin in settings.
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_ROOT="${CLAUDE_PLUGINS_DIR:-$HOME/.claude/plugins}"
DEST_DIR="$DEST_ROOT/directive-guardian"

info()  { printf '  • %s\n' "$1"; }
warn()  { printf '  ! %s\n' "$1" >&2; }
fail()  { printf '  ✗ %s\n' "$1" >&2; exit 1; }
done_() { printf '  ✓ %s\n' "$1"; }

echo "═══ directive-guardian install ═══"

# ── Preflight ─────────────────────────────────────────────────────────

[ -f "$SRC_DIR/.claude-plugin/plugin.json" ] || fail "plugin.json missing — run install.sh from the plugin root"
[ -x "$SRC_DIR/scripts/guardian.sh" ]        || fail "scripts/guardian.sh is not executable"
[ -x "$SRC_DIR/hooks/session-start.sh" ]     || fail "hooks/session-start.sh is not executable"

mkdir -p "$DEST_ROOT"

if [ -e "$DEST_DIR" ] && [ "$SRC_DIR" = "$(cd "$DEST_DIR" && pwd)" ]; then
    info "source and destination are the same path — skipping copy"
else
    if [ -d "$DEST_DIR" ]; then
        info "replacing existing install at $DEST_DIR"
        rm -rf "$DEST_DIR"
    fi
    # Copy the whole tree except runtime artefacts and VCS metadata.
    mkdir -p "$DEST_DIR"
    tar -C "$SRC_DIR" --exclude='.git' --exclude='tests' -cf - . | tar -C "$DEST_DIR" -xf -
    done_ "plugin copied to $DEST_DIR"
fi

chmod +x "$DEST_DIR/scripts/"*.sh "$DEST_DIR/hooks/"*.sh "$DEST_DIR/install.sh" 2>/dev/null || true

# ── Bootstrap registry ────────────────────────────────────────────────

GUARDIAN_DRY_RUN=true "$DEST_DIR/scripts/guardian.sh" >/dev/null 2>&1 || \
    warn "guardian.sh dry-run returned non-zero; inspect your memory dir manually"
done_ "registry bootstrapped"

# ── Next steps ────────────────────────────────────────────────────────

cat <<NEXT

═══ next steps ═══
  1. Enable the plugin in Claude Code (Settings → Plugins → directive-guardian)
     OR add to ~/.claude/settings.json:
       "plugins": { "directive-guardian": { "enabled": true } }

  2. Verify the SessionStart hook is wired:
       $DEST_DIR/hooks/session-start.sh </dev/null | jq .

  3. Add your first directive:
       $DEST_DIR/scripts/directive-ctl.sh add "Persona" critical identity \\
         "Be direct and precise."

  4. Run an audit any time:
       $DEST_DIR/scripts/directive-ctl.sh audit

  Slash commands available after enable:
       /directives, /directive-add, /directive-audit,
       /directive-reapply, /directive-ack
═══════════════════════════
NEXT
