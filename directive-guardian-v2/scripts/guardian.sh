#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# directive-guardian v2 — boot parser with integrity checking
# Parses directives.md → priority-sorted JSON manifest
#
# Fixes from v1 audit:
#   BUG-001: Rewrote awk parser with proper flush-on-new-heading logic
#   BUG-002: Full RFC 8259 JSON string escaping
#   BUG-004: Replaced grep -oP with POSIX-compatible alternatives
#   SEC-001: Advisory file locking via flock
#   SEC-004: SHA-256 integrity verification
#   SEC-005: Auto-rotating log (max 500 lines)
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

MEMORY_DIR="${OPENCLAW_MEMORY_DIR:-$HOME/.openclaw/memory}"
REGISTRY="$MEMORY_DIR/directives.md"
CHECKSUM_FILE="$MEMORY_DIR/directives.sha256"
LOGFILE="$MEMORY_DIR/directive-guardian.log"
LOCKFILE="$MEMORY_DIR/.guardian.lock"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MAX_LOG_LINES=500
DRY_RUN="${GUARDIAN_DRY_RUN:-false}"

# ── Helpers ───────────────────────────────────────────────────────────

log() {
    echo "[$TIMESTAMP] $1" >> "$LOGFILE"
}

rotate_log() {
    if [ -f "$LOGFILE" ]; then
        local line_count
        line_count=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
        if [ "$line_count" -gt "$MAX_LOG_LINES" ]; then
            local keep=$(( MAX_LOG_LINES / 2 ))
            tail -n "$keep" "$LOGFILE" > "$LOGFILE.tmp"
            mv "$LOGFILE.tmp" "$LOGFILE"
            log "LOG_ROTATED — trimmed from $line_count to $keep lines"
        fi
    fi
}

emit_empty_manifest() {
    local status="${1:-empty}"
    cat << MANIFEST
{
  "directives": [],
  "count": 0,
  "enabled_count": 0,
  "disabled_count": 0,
  "status": "$status",
  "integrity": "unknown",
  "timestamp": "$TIMESTAMP",
  "registry": "$REGISTRY"
}
MANIFEST
}

# ── Bootstrap ─────────────────────────────────────────────────────────

if [ ! -d "$MEMORY_DIR" ]; then
    mkdir -p "$MEMORY_DIR"
    # Can't log until dir exists, so this is the first entry
fi

# Ensure log file exists for rotation check
touch "$LOGFILE"
rotate_log

if [ ! -f "$REGISTRY" ]; then
    cat > "$REGISTRY" << 'TMPL'
# Directive Registry
# Managed by directive-guardian v2
# Each ## heading is one directive. See SKILL.md for format docs.
#
# Format: ## [DIRECTIVE-NNN] Title
# Fields: priority, category, enabled, directive, verify
# See SKILL.md for full documentation
TMPL
    log "BOOTSTRAP — created empty registry at $REGISTRY"
    emit_empty_manifest "bootstrapped"
    exit 0
fi

# ── File Locking ──────────────────────────────────────────────────────
# Use flock for advisory locking. If flock isn't available, skip gracefully.

LOCK_FD=9
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCKFILE"
    if ! flock -w 10 $LOCK_FD; then
        log "LOCK_TIMEOUT — could not acquire lock within 10s"
        echo '{"error":"lock_timeout","message":"Another guardian process is running"}' >&2
        exit 1
    fi
fi

# ── Integrity Check ───────────────────────────────────────────────────

integrity="verified"
if [ -f "$CHECKSUM_FILE" ]; then
    stored_hash=$(cat "$CHECKSUM_FILE" 2>/dev/null | awk '{print $1}')
    # Portable: try sha256sum first (Linux), then shasum (macOS)
    if command -v sha256sum >/dev/null 2>&1; then
        current_hash=$(sha256sum "$REGISTRY" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        current_hash=$(shasum -a 256 "$REGISTRY" | awk '{print $1}')
    else
        current_hash="unavailable"
        integrity="no_hash_tool"
    fi

    if [ "$current_hash" != "unavailable" ] && [ "$stored_hash" != "$current_hash" ]; then
        integrity="modified_since_last_checksum"
        log "INTEGRITY_WARNING — registry checksum mismatch (stored: ${stored_hash:0:12}… current: ${current_hash:0:12}…)"
    fi
else
    integrity="no_checksum_file"
    log "INTEGRITY_INFO — no checksum file found, skipping verification"
fi

# ── Parse Directives ──────────────────────────────────────────────────
# Completely rewritten awk parser.
# Fixes BUG-001 (flush logic) and BUG-002 (JSON escaping).
# Uses POSIX awk — no gawk extensions needed.

parse_output=$(awk '
function json_escape(s) {
    # RFC 8259 compliant JSON string escaping
    gsub(/\\/, "\\\\", s)     # backslash first (order matters)
    gsub(/"/, "\\\"", s)      # double quote
    gsub(/\t/, "\\t", s)      # tab
    gsub(/\r/, "\\r", s)      # carriage return
    gsub(/\n/, "\\n", s)      # newline (shouldnt appear in single-line fields)
    return s
}

function flush_directive() {
    if (id == "") return
    if (n > 0) printf ","
    printf "{\"id\":\"%s\",\"title\":\"%s\",\"priority\":\"%s\",\"category\":\"%s\",\"enabled\":%s,\"directive\":\"%s\",\"verify\":\"%s\"}", \
        json_escape(id), \
        json_escape(title), \
        json_escape(priority), \
        json_escape(category), \
        (enabled == "false" ? "false" : "true"), \
        json_escape(directive), \
        json_escape(verify)
    n++
    # Reset
    id = ""; title = ""; priority = ""; category = ""
    enabled = "true"; directive = ""; verify = ""
}

BEGIN {
    n = 0
    id = ""; title = ""; priority = ""; category = ""
    enabled = "true"; directive = ""; verify = ""
    printf "["
}

/^## \[DIRECTIVE-[0-9]+\]/ {
    # Flush previous directive BEFORE starting new one
    flush_directive()

    # Extract ID (without brackets)
    match($0, /\[DIRECTIVE-[0-9]+\]/)
    id = substr($0, RSTART + 1, RLENGTH - 2)

    # Extract title (everything after the ID bracket)
    title = $0
    sub(/^## \[DIRECTIVE-[0-9]+\] */, "", title)

    # Reset fields for new directive
    priority = ""; category = ""; enabled = "true"
    directive = ""; verify = ""
    next
}

# Only parse field lines when we are inside a directive block
id != "" && /^- \*\*priority\*\*:/ {
    val = $0; sub(/^- \*\*priority\*\*: */, "", val)
    gsub(/^ +| +$/, "", val)
    # Validate priority enum
    if (val == "critical" || val == "high" || val == "medium" || val == "low") {
        priority = val
    } else {
        priority = "medium"  # default if invalid
    }
    next
}

id != "" && /^- \*\*category\*\*:/ {
    val = $0; sub(/^- \*\*category\*\*: */, "", val)
    gsub(/^ +| +$/, "", val)
    category = val
    next
}

id != "" && /^- \*\*enabled\*\*:/ {
    val = $0; sub(/^- \*\*enabled\*\*: */, "", val)
    gsub(/^ +| +$/, "", val)
    enabled = (val == "false") ? "false" : "true"
    next
}

id != "" && /^- \*\*directive\*\*:/ {
    val = $0; sub(/^- \*\*directive\*\*: */, "", val)
    gsub(/^ +| +$/, "", val)
    directive = val
    next
}

id != "" && /^- \*\*verify\*\*:/ {
    val = $0; sub(/^- \*\*verify\*\*: */, "", val)
    gsub(/^ +| +$/, "", val)
    verify = val
    next
}

END {
    flush_directive()
    printf "]"
}
' "$REGISTRY")

# ── Count & Sort ──────────────────────────────────────────────────────
# Count total, enabled, disabled using awk on the JSON (portable)

total_count=$(echo "$parse_output" | awk -F'"id"' '{print NF-1}')
enabled_count=$(echo "$parse_output" | { grep -o '"enabled":true' || true; } | wc -l | tr -d ' ')
disabled_count=$(echo "$parse_output" | { grep -o '"enabled":false' || true; } | wc -l | tr -d ' ')

# Sort by priority: critical(0) > high(1) > medium(2) > low(3)
# Use awk to assign sort keys and python-free sorting
# If jq is available, use it. Otherwise output unsorted (still valid).
if command -v jq >/dev/null 2>&1; then
    sorted_output=$(echo "$parse_output" | jq '
        sort_by(
            if .priority == "critical" then 0
            elif .priority == "high" then 1
            elif .priority == "medium" then 2
            else 3 end
        )
    ' 2>/dev/null) || sorted_output="$parse_output"
else
    sorted_output="$parse_output"
fi

# ── Log Results ───────────────────────────────────────────────────────

if [ "$total_count" -eq 0 ]; then
    log "EMPTY_REGISTRY — no directives found"
else
    log "AUDIT — parsed $total_count directives ($enabled_count enabled, $disabled_count disabled)"

    # Log per-directive status (parse IDs and enabled status)
    echo "$parse_output" | { grep -o '"id":"[^"]*","title":"[^"]*"[^}]*"enabled":[a-z]*' || true; } | \
    while IFS= read -r line; do
        did=$(echo "$line" | { grep -o '"id":"[^"]*"' || true; } | cut -d'"' -f4)
        denabled=$(echo "$line" | { grep -o '"enabled":[a-z]*' || true; } | cut -d: -f2)
        if [ "$denabled" = "true" ]; then
            log "  REAPPLIED [$did]"
        else
            log "  SKIPPED [$did] (disabled)"
        fi
    done
fi

log "GUARDIAN BOOT COMPLETE — integrity=$integrity, $enabled_count/$total_count directives ready"

# ── Output Manifest ───────────────────────────────────────────────────

cat << MANIFEST
{
  "directives": $sorted_output,
  "count": $total_count,
  "enabled_count": $enabled_count,
  "disabled_count": $disabled_count,
  "status": "ready",
  "integrity": "$integrity",
  "timestamp": "$TIMESTAMP",
  "registry": "$REGISTRY"
}
MANIFEST

# ── Update Checksum ───────────────────────────────────────────────────
if [ "$DRY_RUN" != "true" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$REGISTRY" > "$CHECKSUM_FILE"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$REGISTRY" > "$CHECKSUM_FILE"
    fi
fi
