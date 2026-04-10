#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# directive-ctl v2 — Full CLI for managing the directive registry
#
# Fixes from v1 audit:
#   BUG-003: Rewrote remove with awk (no sed range bugs)
#   BUG-004: All grep uses POSIX ERE (no -P flag)
#   SEC-001: flock advisory locking on all write ops
#   SEC-002: Input validation on priority, category, ID format
#   FEAT-001: enable/disable toggle
#   FEAT-002: Auto-backup before destructive ops
#   FEAT-004: edit command
#   FEAT-005: search/filter by category, priority, keyword
#   FEAT-003: export/import as JSON
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

MEMORY_DIR="${OPENCLAW_MEMORY_DIR:-$HOME/.openclaw/memory}"
REGISTRY="$MEMORY_DIR/directives.md"
LOGFILE="$MEMORY_DIR/directive-guardian.log"
LOCKFILE="$MEMORY_DIR/.guardian.lock"
CHECKSUM_FILE="$MEMORY_DIR/directives.sha256"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Helpers ───────────────────────────────────────────────────────────

log() { echo "[$TIMESTAMP] $1" >> "$LOGFILE"; }

die() { echo "✗ $1" >&2; exit 1; }

ensure_registry() {
    if [ ! -d "$MEMORY_DIR" ]; then
        mkdir -p "$MEMORY_DIR"
        log "BOOTSTRAP — created memory directory"
    fi
    touch "$LOGFILE"
    if [ ! -f "$REGISTRY" ]; then
        die "Registry not found at $REGISTRY — run guardian.sh first to bootstrap"
    fi
}

# Portable: acquire flock if available
acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCKFILE"
        if ! flock -w 10 9; then
            die "Could not acquire lock (another process is writing)"
        fi
    fi
}

# Backup before destructive ops (SEC-002, FEAT-002)
backup_registry() {
    cp "$REGISTRY" "$REGISTRY.bak"
    log "BACKUP — created $REGISTRY.bak"
}

# Update checksum after modifications
update_checksum() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$REGISTRY" > "$CHECKSUM_FILE"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$REGISTRY" > "$CHECKSUM_FILE"
    fi
}

# Validate priority is in allowed set
validate_priority() {
    case "$1" in
        critical|high|medium|low) return 0 ;;
        *) die "Invalid priority '$1' — must be: critical, high, medium, low" ;;
    esac
}

# Validate directive ID format
validate_id() {
    echo "$1" | grep -qE '^DIRECTIVE-[0-9]{3,}$' || \
        die "Invalid ID format '$1' — expected DIRECTIVE-NNN"
}

# Find next available ID number (POSIX-safe, no grep -P)
next_id() {
    local last
    # Only match actual heading lines, not comments or examples
    last=$(grep -E '^## \[DIRECTIVE-[0-9]+\]' "$REGISTRY" 2>/dev/null | \
           grep -oE 'DIRECTIVE-[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
    printf "%03d" $(( ${last:-0} + 1 ))
}

# Check if an ID exists in the registry
id_exists() {
    grep -qE "^## \[$1\]" "$REGISTRY"
}

# ── Commands ──────────────────────────────────────────────────────────

cmd_add() {
    local title="${1:?Usage: directive-ctl add TITLE PRIORITY CATEGORY DIRECTIVE [VERIFY]}"
    local priority="${2:?Missing priority (critical/high/medium/low)}"
    local category="${3:?Missing category}"
    local directive="${4:?Missing directive text}"
    local verify="${5:-}"

    validate_priority "$priority"

    # Sanitize: prevent injection of markdown heading patterns
    if echo "$directive" | grep -qE '^## \[DIRECTIVE-'; then
        die "Directive text cannot contain registry heading patterns"
    fi

    ensure_registry
    acquire_lock
    backup_registry

    local nid
    nid=$(next_id)

    {
        echo ""
        echo "## [DIRECTIVE-${nid}] ${title}"
        echo "- **priority**: ${priority}"
        echo "- **category**: ${category}"
        echo "- **enabled**: true"
        echo "- **directive**: ${directive}"
        [ -n "$verify" ] && echo "- **verify**: ${verify}"
    } >> "$REGISTRY"

    update_checksum
    log "ADDED [DIRECTIVE-${nid}] \"${title}\" (priority=$priority, category=$category)"
    echo "✓ Added DIRECTIVE-${nid}: ${title}"
}

cmd_remove() {
    local target="${1:?Usage: directive-ctl remove DIRECTIVE-XXX}"
    validate_id "$target"
    ensure_registry

    if ! id_exists "$target"; then
        die "$target not found in registry"
    fi

    acquire_lock
    backup_registry

    # Use awk for safe block removal — handles last-directive-in-file correctly
    awk -v target="$target" '
    BEGIN { skip = 0 }
    /^## \[DIRECTIVE-[0-9]+\]/ {
        if (index($0, "[" target "]") > 0) {
            skip = 1
            next
        } else {
            skip = 0
        }
    }
    skip && /^- \*\*/ { next }
    skip && /^$/ { skip = 0; next }
    { print }
    ' "$REGISTRY" > "$REGISTRY.tmp"

    mv "$REGISTRY.tmp" "$REGISTRY"
    update_checksum
    log "REMOVED [$target]"
    echo "✓ Removed $target (backup at $REGISTRY.bak)"
}

cmd_edit() {
    local target="${1:?Usage: directive-ctl edit DIRECTIVE-XXX --field value}"
    validate_id "$target"
    ensure_registry

    if ! id_exists "$target"; then
        die "$target not found in registry"
    fi

    shift
    local field="" value=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --directive)  field="directive"; value="${2:?Missing value}"; shift 2 ;;
            --priority)   field="priority";  value="${2:?Missing value}"; shift 2; validate_priority "$value" ;;
            --category)   field="category";  value="${2:?Missing value}"; shift 2 ;;
            --verify)     field="verify";    value="${2:?Missing value}"; shift 2 ;;
            --enabled)    field="enabled";   value="${2:?Missing value}"; shift 2 ;;
            *) die "Unknown flag: $1 (use --directive, --priority, --category, --verify, --enabled)" ;;
        esac

        acquire_lock
        backup_registry

        # Use awk to find the target block and replace the specific field
        awk -v target="$target" -v field="$field" -v value="$value" '
        BEGIN { in_block = 0; found_field = 0 }
        /^## \[DIRECTIVE-[0-9]+\]/ {
            # Flush missing field if we were in target block and didnt find it
            if (in_block && !found_field) {
                print "- **" field "**: " value
            }
            in_block = (index($0, "[" target "]") > 0) ? 1 : 0
            found_field = 0
            print
            next
        }
        in_block && $0 ~ "^- \\*\\*" field "\\*\\*:" {
            print "- **" field "**: " value
            found_field = 1
            next
        }
        END {
            # If last block was target and field wasnt found, append
            if (in_block && !found_field) {
                print "- **" field "**: " value
            }
        }
        { print }
        ' "$REGISTRY" > "$REGISTRY.tmp"

        mv "$REGISTRY.tmp" "$REGISTRY"
        update_checksum
        log "EDITED [$target] set $field=\"$value\""
        echo "✓ Updated $target: $field = $value"
    done
}

cmd_enable() {
    local target="${1:?Usage: directive-ctl enable DIRECTIVE-XXX}"
    cmd_edit "$target" --enabled true
}

cmd_disable() {
    local target="${1:?Usage: directive-ctl disable DIRECTIVE-XXX}"
    cmd_edit "$target" --enabled false
}

cmd_list() {
    ensure_registry
    local filter_cat="" filter_pri=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --category) filter_cat="${2:?Missing category}"; shift 2 ;;
            --priority) filter_pri="${2:?Missing priority}"; shift 2; validate_priority "$filter_pri" ;;
            *) shift ;;
        esac
    done

    echo "═══ Directive Registry ═══"

    awk -v fcat="$filter_cat" -v fpri="$filter_pri" '
    /^## \[DIRECTIVE-[0-9]+\]/ {
        if (id != "") {
            show = 1
            if (fcat != "" && category != fcat) show = 0
            if (fpri != "" && priority != fpri) show = 0
            if (show) {
                status = (enabled == "false") ? " [DISABLED]" : ""
                printf "  [%s] %-30s pri=%-8s cat=%-12s%s\n", id, title, priority, category, status
                count++
            }
        }
        match($0, /\[DIRECTIVE-[0-9]+\]/)
        id = substr($0, RSTART+1, RLENGTH-2)
        title = $0; sub(/^## \[DIRECTIVE-[0-9]+\] */, "", title)
        priority = ""; category = ""; enabled = "true"
    }
    /^- \*\*priority\*\*:/ { val=$0; sub(/.*: */, "", val); gsub(/ /, "", val); priority=val }
    /^- \*\*category\*\*:/ { val=$0; sub(/.*: */, "", val); gsub(/ /, "", val); category=val }
    /^- \*\*enabled\*\*:/ { val=$0; sub(/.*: */, "", val); gsub(/ /, "", val); enabled=val }
    END {
        if (id != "") {
            show = 1
            if (fcat != "" && category != fcat) show = 0
            if (fpri != "" && priority != fpri) show = 0
            if (show) {
                status = (enabled == "false") ? " [DISABLED]" : ""
                printf "  [%s] %-30s pri=%-8s cat=%-12s%s\n", id, title, priority, category, status
                count++
            }
        }
        printf "═══ Showing: %d directives", count+0
        if (fcat != "") printf " (category=%s)", fcat
        if (fpri != "") printf " (priority=%s)", fpri
        printf " ═══\n"
    }
    ' "$REGISTRY"
}

cmd_search() {
    local keyword="${1:?Usage: directive-ctl search KEYWORD}"
    ensure_registry

    echo "═══ Search: \"$keyword\" ═══"
    # Case-insensitive search across full directive blocks
    awk -v kw="$keyword" '
    BEGIN { id = ""; buf = "" }
    function match_ci(s, k) {
        return (index(tolower(s), tolower(k)) > 0)
    }
    /^## \[DIRECTIVE-[0-9]+\]/ {
        if (id != "" && match_ci(buf, kw)) {
            printf "%s\n", buf
            found++
        }
        id = $0; buf = $0 "\n"
        next
    }
    id != "" { buf = buf $0 "\n" }
    END {
        if (id != "" && match_ci(buf, kw)) {
            printf "%s\n", buf
            found++
        }
        printf "═══ Found: %d matches ═══\n", found+0
    }
    ' "$REGISTRY"
}

cmd_status() {
    ensure_registry

    echo "═══ Guardian Status ═══"

    # Directive count
    local total
    total=$(grep -cE '^## \[DIRECTIVE-' "$REGISTRY" 2>/dev/null || echo 0)
    local enabled disabled
    enabled=$(grep -cE '^\- \*\*enabled\*\*: *true' "$REGISTRY" 2>/dev/null || echo 0)
    disabled=$(grep -cE '^\- \*\*enabled\*\*: *false' "$REGISTRY" 2>/dev/null || echo 0)
    echo "  Directives: $total total ($enabled enabled, $disabled disabled)"

    # Integrity
    if [ -f "$CHECKSUM_FILE" ]; then
        local stored current
        stored=$(awk '{print $1}' "$CHECKSUM_FILE")
        if command -v sha256sum >/dev/null 2>&1; then
            current=$(sha256sum "$REGISTRY" | awk '{print $1}')
        elif command -v shasum >/dev/null 2>&1; then
            current=$(shasum -a 256 "$REGISTRY" | awk '{print $1}')
        else
            current="unavailable"
        fi
        if [ "$stored" = "$current" ]; then
            echo "  Integrity:  ✓ verified (SHA-256 match)"
        elif [ "$current" = "unavailable" ]; then
            echo "  Integrity:  ? no hash tool available"
        else
            echo "  Integrity:  ✗ MISMATCH (registry modified outside guardian)"
        fi
    else
        echo "  Integrity:  — no checksum file (run guardian.sh to create)"
    fi

    # Backup
    if [ -f "$REGISTRY.bak" ]; then
        echo "  Backup:     ✓ exists ($REGISTRY.bak)"
    else
        echo "  Backup:     — none"
    fi

    # Recent log
    echo ""
    if [ -f "$LOGFILE" ]; then
        echo "── Last 15 Log Entries ──"
        tail -15 "$LOGFILE"
    else
        echo "  No log file found."
    fi
    echo "═══════════════════════════"
}

cmd_backup() {
    ensure_registry
    local backup_file="$MEMORY_DIR/directives.$(date +%Y%m%d-%H%M%S).md.bak"
    cp "$REGISTRY" "$backup_file"
    log "MANUAL_BACKUP — $backup_file"
    echo "✓ Backed up to $backup_file"
}

cmd_restore() {
    local source="${1:-$REGISTRY.bak}"
    if [ ! -f "$source" ]; then
        die "Backup file not found: $source"
    fi
    acquire_lock
    cp "$REGISTRY" "$REGISTRY.pre-restore.bak"
    cp "$source" "$REGISTRY"
    update_checksum
    log "RESTORED — from $source (pre-restore backup at $REGISTRY.pre-restore.bak)"
    echo "✓ Restored from $source"
}

cmd_export() {
    ensure_registry
    local outfile="${1:-$MEMORY_DIR/directives-export.json}"

    # Reuse guardian parser for export
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    if [ -x "$script_dir/guardian.sh" ]; then
        GUARDIAN_DRY_RUN=true "$script_dir/guardian.sh" > "$outfile"
    else
        die "Cannot find guardian.sh for parsing — expected at $script_dir/guardian.sh"
    fi

    log "EXPORTED — $outfile"
    echo "✓ Exported to $outfile"
}

cmd_import() {
    local infile="${1:?Usage: directive-ctl import <json-file>}"
    if [ ! -f "$infile" ]; then
        die "Import file not found: $infile"
    fi

    ensure_registry
    acquire_lock
    backup_registry

    if ! command -v jq >/dev/null 2>&1; then
        die "jq is required for import — install with: apt install jq / brew install jq"
    fi

    # Parse JSON and append each directive to registry
    local imported=0
    jq -c '.directives[]' "$infile" 2>/dev/null | while IFS= read -r obj; do
        local d_id d_title d_pri d_cat d_en d_dir d_ver
        d_title=$(echo "$obj" | jq -r '.title')
        d_pri=$(echo "$obj" | jq -r '.priority')
        d_cat=$(echo "$obj" | jq -r '.category')
        d_en=$(echo "$obj" | jq -r '.enabled')
        d_dir=$(echo "$obj" | jq -r '.directive')
        d_ver=$(echo "$obj" | jq -r '.verify // ""')

        local nid
        nid=$(next_id)

        {
            echo ""
            echo "## [DIRECTIVE-${nid}] ${d_title}"
            echo "- **priority**: ${d_pri}"
            echo "- **category**: ${d_cat}"
            echo "- **enabled**: ${d_en}"
            echo "- **directive**: ${d_dir}"
            [ -n "$d_ver" ] && [ "$d_ver" != "null" ] && echo "- **verify**: ${d_ver}"
        } >> "$REGISTRY"
        imported=$((imported + 1))
    done

    update_checksum
    log "IMPORTED — from $infile"
    echo "✓ Imported directives from $infile"
}

cmd_checksum() {
    ensure_registry
    update_checksum
    echo "✓ Checksum updated: $(cat "$CHECKSUM_FILE")"
}

cmd_validate() {
    ensure_registry
    echo "═══ Validation Report ═══"

    local errors=0
    awk '
    /^## \[DIRECTIVE-[0-9]+\]/ {
        if (id != "") {
            if (priority == "") { printf "  ⚠ [%s] missing priority\n", id; errors++ }
            if (category == "") { printf "  ⚠ [%s] missing category\n", id; errors++ }
            if (directive == "") { printf "  ⚠ [%s] missing directive text\n", id; errors++ }
            if (enabled == "") { printf "  ⚠ [%s] missing enabled field\n", id; errors++ }
            if (priority != "" && priority != "critical" && priority != "high" && priority != "medium" && priority != "low") {
                printf "  ✗ [%s] invalid priority: %s\n", id, priority; errors++
            }
        }
        match($0, /\[DIRECTIVE-[0-9]+\]/)
        id = substr($0, RSTART+1, RLENGTH-2)
        priority = ""; category = ""; directive = ""; enabled = ""
    }
    /^- \*\*priority\*\*:/ { val=$0; sub(/.*: */, "", val); gsub(/ /, "", val); priority=val }
    /^- \*\*category\*\*:/ { val=$0; sub(/.*: */, "", val); gsub(/ /, "", val); category=val }
    /^- \*\*directive\*\*:/ { val=$0; sub(/.*: */, "", val); directive=val }
    /^- \*\*enabled\*\*:/ { val=$0; sub(/.*: */, "", val); gsub(/ /, "", val); enabled=val }
    END {
        if (id != "") {
            if (priority == "") { printf "  ⚠ [%s] missing priority\n", id; errors++ }
            if (category == "") { printf "  ⚠ [%s] missing category\n", id; errors++ }
            if (directive == "") { printf "  ⚠ [%s] missing directive text\n", id; errors++ }
            if (enabled == "") { printf "  ⚠ [%s] missing enabled field\n", id; errors++ }
        }
        if (errors == 0) {
            print "  ✓ All directives valid"
        }
    }
    ' "$REGISTRY"

    echo "═══════════════════════════"
}

# ── Main Router ───────────────────────────────────────────────────────

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
    add)        cmd_add "$@" ;;
    remove)     cmd_remove "$@" ;;
    edit)       cmd_edit "$@" ;;
    enable)     cmd_enable "$@" ;;
    disable)    cmd_disable "$@" ;;
    list)       cmd_list "$@" ;;
    search)     cmd_search "$@" ;;
    status)     cmd_status ;;
    backup)     cmd_backup ;;
    restore)    cmd_restore "$@" ;;
    export)     cmd_export "$@" ;;
    import)     cmd_import "$@" ;;
    checksum)   cmd_checksum ;;
    validate)   cmd_validate ;;
    help|*)
        cat << 'USAGE'
directive-ctl v2 — Manage the directive guardian registry

  CRUD:
    add <title> <priority> <category> <directive> [verify]
    remove <DIRECTIVE-XXX>
    edit <DIRECTIVE-XXX> --directive "text" [--priority X] [--category Y]
    enable <DIRECTIVE-XXX>
    disable <DIRECTIVE-XXX>

  Query:
    list [--category <tag>] [--priority <level>]
    search <keyword>
    status
    validate

  Data:
    backup                Create timestamped backup
    restore [file]        Restore from backup
    export [file]         Export as JSON
    import <file>         Import from JSON export
    checksum              Update SHA-256 integrity hash

  Priority: critical | high | medium | low
  ID format: DIRECTIVE-NNN (e.g., DIRECTIVE-001)
USAGE
        ;;
esac
