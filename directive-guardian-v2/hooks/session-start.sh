#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# directive-guardian — Claude Code SessionStart hook
#
# Reads stdin as the hook event JSON (ignored here), runs guardian.sh in
# markdown mode, and emits the JSON envelope Claude Code uses to inject
# additional context for the session. Failures are non-fatal — we never
# want a memory tool to block a session from starting.
#
# Install: referenced by .claude-plugin/plugin.json at the repo root.
# Env:     $DIRECTIVE_MEMORY_DIR / $CLAUDE_MEMORY_DIR override the location.
# ═══════════════════════════════════════════════════════════════════════

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARDIAN="$HOOK_DIR/../scripts/guardian.sh"

# Drain hook event JSON on stdin so the parent doesn't stall waiting on us.
if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi

if [ ! -x "$GUARDIAN" ]; then
    # Emit an empty-but-well-formed envelope so a broken install is obvious
    # in the hook logs without crashing the session.
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"directive-guardian: guardian.sh not found at %s"}}\n' "$GUARDIAN"
    exit 0
fi

brief=$("$GUARDIAN" --format markdown 2>/dev/null || true)
if [ -z "$brief" ]; then
    brief="directive-guardian: no directives loaded."
fi

# JSON-escape the markdown body. Prefer jq for RFC 8259 correctness; fall back
# to sed for the handful of characters that actually matter inside a JSON string.
if command -v jq >/dev/null 2>&1; then
    payload=$(printf '%s' "$brief" | jq -Rs .)
else
    esc=$(printf '%s' "$brief" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | awk 'BEGIN{ORS=""} {gsub(/\r/,"\\r"); gsub(/\t/,"\\t"); print; printf "\\n"}')
    payload="\"$esc\""
fi

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$payload"
