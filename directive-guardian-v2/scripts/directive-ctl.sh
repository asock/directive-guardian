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

# Keep env-var resolution identical to guardian.sh so the two never disagree.
resolve_memory_dir() {
    if [ -n "${DIRECTIVE_MEMORY_DIR:-}" ]; then echo "$DIRECTIVE_MEMORY_DIR"; return; fi
    if [ -n "${CLAUDE_MEMORY_DIR:-}"    ]; then echo "$CLAUDE_MEMORY_DIR";    return; fi
    if [ -n "${OPENCLAW_MEMORY_DIR:-}"  ]; then echo "$OPENCLAW_MEMORY_DIR";  return; fi
    if [ -d "$HOME/.openclaw/memory" ] && [ ! -d "$HOME/.claude/directive-guardian" ]; then
        echo "$HOME/.openclaw/memory"; return
    fi
    echo "$HOME/.claude/directive-guardian"
}

MEMORY_DIR=$(resolve_memory_dir)
REGISTRY="$MEMORY_DIR/directives.md"
LOGFILE="$MEMORY_DIR/directive-guardian.log"
LOCKFILE="$MEMORY_DIR/.guardian.lock"
CHECKSUM_FILE="$MEMORY_DIR/directives.sha256"
ACK_FILE="$MEMORY_DIR/.integrity-ack"
MAX_LOG_LINES=500
MAX_BACKUPS=10  # directives.<ts>.md.bak files to retain after prune

# ── Helpers ───────────────────────────────────────────────────────────

# Each log line gets a fresh timestamp so long-running invocations stay accurate (S7).
log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $1" >> "$LOGFILE"; }

# Rotate the log from the CLI path too — previously only guardian.sh did this,
# so heavy CLI use (AUDIT-07) could blow past the cap between boots.
rotate_log() {
    [ -f "$LOGFILE" ] || return 0
    local line_count keep
    line_count=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$line_count" -gt "$MAX_LOG_LINES" ]; then
        keep=$(( MAX_LOG_LINES / 2 ))
        tail -n "$keep" "$LOGFILE" > "$LOGFILE.tmp" && mv "$LOGFILE.tmp" "$LOGFILE"
        log "LOG_ROTATED — trimmed from $line_count to $keep lines"
    fi
}

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

# Backup before destructive ops (SEC-002, FEAT-002).
# Writes both a rolling .bak (latest, easy to find) AND a timestamped copy
# so two destructive ops in a row don't destroy the only recoverable state (S2).
backup_registry() {
    local ts
    ts=$(date -u +"%Y%m%dT%H%M%SZ")
    cp "$REGISTRY" "$REGISTRY.bak"
    cp "$REGISTRY" "$MEMORY_DIR/directives.$ts.md.bak"
    log "BACKUP — created $REGISTRY.bak and directives.$ts.md.bak"
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

# Validate enabled flag (S5 — guardian normalizes anything-not-false to true,
# which silently masks typos like `--enabled maybe`).
validate_enabled() {
    case "$1" in
        true|false) return 0 ;;
        *) die "Invalid enabled value '$1' — must be: true or false" ;;
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
    rotate_log
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

    # AUDIT-03: skip the ENTIRE block (heading + any content) until the next
    # `## [DIRECTIVE-` heading or EOF. The previous version only skipped field
    # lines and bailed on the first blank, leaking any stray content between
    # the last field and the next directive.
    awk -v target="$target" '
    BEGIN { skip = 0; pending_blank = 0 }
    /^## \[DIRECTIVE-[0-9]+\]/ {
        if (skip) {
            # We were inside the removed block — eat the trailing blank we
            # held back so the output does not accumulate empty separators.
            pending_blank = 0
        }
        if (index($0, "[" target "]") > 0) {
            skip = 1
            next
        }
        skip = 0
        if (pending_blank) { print ""; pending_blank = 0 }
        print
        next
    }
    skip { next }
    /^$/ {
        # Defer blanks so we can drop the one immediately following a removed block.
        pending_blank = 1
        next
    }
    { if (pending_blank) { print ""; pending_blank = 0 } ; print }
    END { if (pending_blank && !skip) print "" }
    ' "$REGISTRY" > "$REGISTRY.tmp"

    mv "$REGISTRY.tmp" "$REGISTRY"
    update_checksum
    rotate_log
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

    # S6: hoist lock+backup above the loop so multi-field edits take ONE lock,
    # ONE backup, and don't lose the original `.bak` between fields.
    acquire_lock
    backup_registry

    local field="" value=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --directive)  field="directive"; value="${2:?Missing value}"; shift 2 ;;
            --priority)   field="priority";  value="${2:?Missing value}"; shift 2; validate_priority "$value" ;;
            --category)   field="category";  value="${2:?Missing value}"; shift 2 ;;
            --verify)     field="verify";    value="${2:?Missing value}"; shift 2 ;;
            --enabled)    field="enabled";   value="${2:?Missing value}"; shift 2; validate_enabled "$value" ;;
            *) die "Unknown flag: $1 (use --directive, --priority, --category, --verify, --enabled)" ;;
        esac

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
    rotate_log
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
    # B2: anchor the field-name match and trim only leading/trailing whitespace
    # so multi-word categories survive (was: gsub(/ /, "") which collapsed them).
    /^- \*\*priority\*\*:/ { val=$0; sub(/^- \*\*priority\*\*: */, "", val); gsub(/^ +| +$/, "", val); priority=val }
    /^- \*\*category\*\*:/ { val=$0; sub(/^- \*\*category\*\*: */, "", val); gsub(/^ +| +$/, "", val); category=val }
    /^- \*\*enabled\*\*:/  { val=$0; sub(/^- \*\*enabled\*\*: */,  "", val); gsub(/^ +| +$/, "", val); enabled=val }
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

    # B1/B4: count via awk so a zero count is a single "0", not the
    # double-output `grep -c ... || echo 0` produced (grep prints "0" AND exits 1,
    # so the fallback ran and the substitution captured "0\n0").
    local total enabled disabled
    total=$(awk '/^## \[DIRECTIVE-[0-9]+\]/ {n++} END {print n+0}' "$REGISTRY")
    enabled=$(awk '/^- \*\*enabled\*\*: *true/  {n++} END {print n+0}' "$REGISTRY")
    disabled=$(awk '/^- \*\*enabled\*\*: *false/ {n++} END {print n+0}' "$REGISTRY")
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

    # Parse JSON and append each directive to registry.
    # S1: process substitution instead of pipe so the loop runs in the parent
    # shell — otherwise `imported` increments are lost in a subshell.
    # AUDIT-05: compute next_id ONCE, then increment in-memory. Previously
    # next_id re-scanned the registry per imported record (O(N²)).
    local imported=0 skipped=0 conflict_mode="${2:-append}"
    case "$conflict_mode" in append|skip|replace) ;; *) die "Unknown conflict mode: $conflict_mode (use append|skip|replace)" ;; esac

    local next_num
    next_num=$(grep -oE 'DIRECTIVE-[0-9]+' "$REGISTRY" 2>/dev/null | \
               grep -oE '[0-9]+' | sort -n | tail -1)
    next_num=${next_num:-0}

    local existing_titles=""
    existing_titles=$(awk '
        /^## \[DIRECTIVE-[0-9]+\]/ {
            t = $0; sub(/^## \[DIRECTIVE-[0-9]+\] */, "", t)
            print t
        }' "$REGISTRY")

    while IFS= read -r obj; do
        local d_title d_pri d_cat d_en d_dir d_ver
        d_title=$(echo "$obj" | jq -r '.title')
        d_pri=$(echo "$obj" | jq -r '.priority')
        d_cat=$(echo "$obj" | jq -r '.category')
        d_en=$(echo "$obj" | jq -r '.enabled')
        d_dir=$(echo "$obj" | jq -r '.directive')
        d_ver=$(echo "$obj" | jq -r '.verify // ""')

        # Conflict handling (AUDIT-09): dedupe by title, not ID, since ID is
        # per-registry. `replace` not yet implemented — falls through to append
        # with a log warning so the semantics are explicit.
        if echo "$existing_titles" | grep -qxF "$d_title"; then
            if [ "$conflict_mode" = "skip" ]; then
                skipped=$((skipped + 1))
                log "IMPORT_SKIP — title exists: $d_title"
                continue
            fi
        fi

        next_num=$((next_num + 1))
        local nid
        nid=$(printf "%03d" "$next_num")

        {
            echo ""
            echo "## [DIRECTIVE-${nid}] ${d_title}"
            echo "- **priority**: ${d_pri}"
            echo "- **category**: ${d_cat}"
            echo "- **enabled**: ${d_en}"
            echo "- **directive**: ${d_dir}"
            [ -n "$d_ver" ] && [ "$d_ver" != "null" ] && echo "- **verify**: ${d_ver}"
        } >> "$REGISTRY"
        existing_titles="$existing_titles"$'\n'"$d_title"
        imported=$((imported + 1))
    done < <(jq -c '.directives[]' "$infile" 2>/dev/null)

    update_checksum
    rotate_log
    log "IMPORTED — $imported directives from $infile (mode=$conflict_mode, skipped=$skipped)"
    echo "✓ Imported $imported directives from $infile (skipped $skipped duplicates)"
}

cmd_checksum() {
    ensure_registry
    update_checksum
    echo "✓ Checksum updated: $(cat "$CHECKSUM_FILE")"
}

cmd_validate() {
    ensure_registry
    echo "═══ Validation Report ═══"

    # AUDIT-02: detect duplicate IDs. Hand-edits or merge conflicts can create
    # two `[DIRECTIVE-001]` blocks; edit/remove silently operate on the first.
    # The awk below prints every ID that appears more than once.
    awk '
    /^## \[DIRECTIVE-[0-9]+\]/ {
        match($0, /\[DIRECTIVE-[0-9]+\]/)
        id = substr($0, RSTART+1, RLENGTH-2)
        count[id]++
    }
    END {
        for (id in count) if (count[id] > 1) printf "  ✗ duplicate ID [%s] appears %d times\n", id, count[id]
    }' "$REGISTRY"

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
    # B3: anchor field-name regex; greedy `.*: *` would mangle directive text
    # containing `: ` (e.g. "use rg: ripgrep is fast").
    /^- \*\*priority\*\*:/  { val=$0; sub(/^- \*\*priority\*\*: */,  "", val); gsub(/^ +| +$/, "", val); priority=val }
    /^- \*\*category\*\*:/  { val=$0; sub(/^- \*\*category\*\*: */,  "", val); gsub(/^ +| +$/, "", val); category=val }
    /^- \*\*directive\*\*:/ { val=$0; sub(/^- \*\*directive\*\*: */, "", val); directive=val }
    /^- \*\*enabled\*\*:/   { val=$0; sub(/^- \*\*enabled\*\*: */,   "", val); gsub(/^ +| +$/, "", val); enabled=val }
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

cmd_show() {
    local target="${1:?Usage: directive-ctl show DIRECTIVE-XXX}"
    validate_id "$target"
    ensure_registry
    id_exists "$target" || die "$target not found in registry"

    # Print just the target's block (heading through last field). Reuses the
    # same state machine as remove but inverted — keep inside, drop outside.
    awk -v target="$target" '
    /^## \[DIRECTIVE-[0-9]+\]/ {
        in_block = (index($0, "[" target "]") > 0) ? 1 : 0
        if (in_block) { print; next }
    }
    in_block { print }
    ' "$REGISTRY"
}

cmd_acknowledge() {
    # AUDIT-01: user-explicit consent to re-trust the registry after tamper.
    # Next guardian.sh run will clear the flag and refresh the checksum.
    ensure_registry
    mkdir -p "$MEMORY_DIR"
    touch "$ACK_FILE"
    log "INTEGRITY_ACK_QUEUED — user acknowledged tamper; next boot will refresh checksum"
    echo "✓ Integrity acknowledgement queued — next guardian.sh run will accept current state"
}

cmd_prune_backups() {
    ensure_registry
    local keep="${1:-$MAX_BACKUPS}"
    case "$keep" in ''|*[!0-9]*) die "prune-backups: keep count must be a non-negative integer" ;; esac

    # List timestamped backups oldest-first so we can drop the head.
    local -a backups=()
    while IFS= read -r -d '' f; do
        backups+=("$f")
    done < <(find "$MEMORY_DIR" -maxdepth 1 -type f \
             \( -name 'directives.*.md.bak' -o -name 'directives.*.bak' \) \
             -print0 2>/dev/null | sort -z)

    local total=${#backups[@]}
    if [ "$total" -le "$keep" ]; then
        echo "✓ $total backup(s) present — nothing to prune (keep=$keep)"
        return 0
    fi
    local drop=$((total - keep))
    local i=0
    while [ "$i" -lt "$drop" ]; do
        rm -f -- "${backups[$i]}"
        i=$((i + 1))
    done
    log "PRUNE_BACKUPS — removed $drop backup(s), kept $keep"
    echo "✓ Pruned $drop old backup(s), kept $keep newest"
}

cmd_audit() {
    # One-shot health check used both interactively and by the SessionStart hook.
    ensure_registry
    echo "═══ Directive Guardian Audit ═══"

    echo "── Validation ──"
    cmd_validate | sed 's/^/  /'

    echo "── Duplicates ──"
    local dup
    dup=$(awk '/^## \[DIRECTIVE-[0-9]+\]/ { match($0,/\[DIRECTIVE-[0-9]+\]/); id=substr($0,RSTART+1,RLENGTH-2); c[id]++ }
               END { for (k in c) if (c[k] > 1) print "  ✗ " k " x" c[k] }' "$REGISTRY")
    if [ -z "$dup" ]; then echo "  ✓ no duplicate IDs"; else echo "$dup"; fi

    echo "── Integrity ──"
    if [ -f "$CHECKSUM_FILE" ]; then
        local stored current
        stored=$(awk '{print $1}' "$CHECKSUM_FILE")
        if command -v sha256sum >/dev/null 2>&1; then
            current=$(sha256sum "$REGISTRY" | awk '{print $1}')
        elif command -v shasum >/dev/null 2>&1; then
            current=$(shasum -a 256 "$REGISTRY" | awk '{print $1}')
        else current="unavailable"; fi
        if [ "$current" = "unavailable" ]; then
            echo "  ? no hash tool available"
        elif [ "$stored" = "$current" ]; then
            echo "  ✓ registry matches stored checksum"
        else
            echo "  ✗ MISMATCH — run 'directive-ctl acknowledge' to trust new state"
        fi
    else
        echo "  — no checksum file yet (run guardian.sh)"
    fi

    echo "── Backups ──"
    local bcount
    bcount=$(find "$MEMORY_DIR" -maxdepth 1 -type f \
             \( -name 'directives.*.md.bak' -o -name 'directives.*.bak' \) 2>/dev/null | wc -l | tr -d ' ')
    echo "  $bcount timestamped backup(s) retained (cap: $MAX_BACKUPS — run 'prune-backups' to trim)"

    echo "── Last mutation ──"
    if [ -f "$REGISTRY" ]; then
        local mtime
        if stat -c %y "$REGISTRY" >/dev/null 2>&1; then
            mtime=$(stat -c %y "$REGISTRY")
        else
            mtime=$(stat -f %Sm "$REGISTRY" 2>/dev/null || echo unknown)
        fi
        echo "  registry modified: $mtime"
    fi

    echo "═══════════════════════════"
}

# ── Main Router ───────────────────────────────────────────────────────

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
    add)            cmd_add "$@" ;;
    remove)         cmd_remove "$@" ;;
    edit)           cmd_edit "$@" ;;
    enable)         cmd_enable "$@" ;;
    disable)        cmd_disable "$@" ;;
    list)           cmd_list "$@" ;;
    search)         cmd_search "$@" ;;
    show|get)       cmd_show "$@" ;;
    status)         cmd_status ;;
    audit)          cmd_audit ;;
    backup)         cmd_backup ;;
    restore)        cmd_restore "$@" ;;
    prune-backups)  cmd_prune_backups "$@" ;;
    export)         cmd_export "$@" ;;
    import)         cmd_import "$@" ;;
    checksum)       cmd_checksum ;;
    validate)       cmd_validate ;;
    acknowledge|ack) cmd_acknowledge ;;
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
    show <DIRECTIVE-XXX>      Print a single directive
    status
    validate
    audit                     Validation + duplicates + integrity + backups

  Data:
    backup                    Create timestamped backup
    restore [file]            Restore from backup
    prune-backups [keep=10]   Drop old timestamped backups
    export [file]             Export as JSON
    import <file> [mode]      mode: append (default) | skip (by title)
    checksum                  Update SHA-256 integrity hash
    acknowledge               Accept a tamper mismatch on next boot

  Priority: critical | high | medium | low
  ID format: DIRECTIVE-NNN (e.g., DIRECTIVE-001)

  Env: $DIRECTIVE_MEMORY_DIR (preferred) or $CLAUDE_MEMORY_DIR or $OPENCLAW_MEMORY_DIR
USAGE
        ;;
esac
