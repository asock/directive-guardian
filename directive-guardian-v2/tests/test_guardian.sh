#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# directive-guardian v2 — test harness
# Exercises all commands and validates output correctness
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GUARDIAN="$SCRIPT_DIR/scripts/guardian.sh"
CTL="$SCRIPT_DIR/scripts/directive-ctl.sh"
SESSION_HOOK="$SCRIPT_DIR/hooks/session-start.sh"
TEST_DIR=$(mktemp -d)
# Tests use the new primary env var; legacy OPENCLAW_MEMORY_DIR still works
# (there is a dedicated fallback test later).
export DIRECTIVE_MEMORY_DIR="$TEST_DIR"
unset OPENCLAW_MEMORY_DIR CLAUDE_MEMORY_DIR || true

PASS=0
FAIL=0
TOTAL=0

# ── Test Helpers ──────────────────────────────────────────────────────

pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  ✗ $1" >&2; }

assert_contains() {
    local output="$1" expected="$2" label="$3"
    if echo "$output" | grep -qF "$expected"; then
        pass "$label"
    else
        fail "$label — expected to contain: $expected"
        echo "    GOT: $(echo "$output" | head -5)" >&2
    fi
}

# Exact-line match — substring assertions miss bugs like a counter splitting
# `0\n0` across two lines (B1/B4 regression).
assert_line() {
    local output="$1" expected="$2" label="$3"
    if echo "$output" | grep -qxF "$expected"; then
        pass "$label"
    else
        fail "$label — expected exact line: $expected"
        echo "    GOT:" >&2
        echo "$output" | sed 's/^/      /' >&2
    fi
}

assert_not_contains() {
    local output="$1" unexpected="$2" label="$3"
    if echo "$output" | grep -qF "$unexpected"; then
        fail "$label — should NOT contain: $unexpected"
    else
        pass "$label"
    fi
}

assert_valid_json() {
    local output="$1" label="$2"
    if command -v jq >/dev/null 2>&1; then
        if echo "$output" | jq . >/dev/null 2>&1; then
            pass "$label"
        else
            fail "$label — invalid JSON"
            echo "    GOT: $(echo "$output" | head -3)" >&2
        fi
    else
        # No jq, basic check
        if echo "$output" | grep -qF '"directives"'; then
            pass "$label (basic check, no jq)"
        else
            fail "$label — no directives key found"
        fi
    fi
}

assert_exit_code() {
    local expected="$1" label="$2"
    shift 2
    if "$@" >/dev/null 2>&1; then
        [ "$expected" -eq 0 ] && pass "$label" || fail "$label — expected exit $expected, got 0"
    else
        local actual=$?
        [ "$expected" -ne 0 ] && pass "$label" || fail "$label — expected exit 0, got $actual"
    fi
}

cleanup() {
    rm -rf "$TEST_DIR"
    echo ""
    echo "═══════════════════════════════════════"
    echo "  Results: $PASS passed, $FAIL failed (of $TOTAL)"
    echo "  Temp dir cleaned: $TEST_DIR"
    echo "═══════════════════════════════════════"
    [ "$FAIL" -eq 0 ] && exit 0 || exit 1
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════
echo "═══ directive-guardian v2 test suite ═══"
echo "  test dir: $TEST_DIR"
echo ""

# ── T1: Bootstrap ─────────────────────────────────────────────────────
echo "── T1: Bootstrap (empty directory) ──"

output=$("$GUARDIAN" 2>&1)
assert_valid_json "$output" "T1.1: Guardian outputs valid JSON on bootstrap"
assert_contains "$output" '"status": "bootstrapped"' "T1.2: Status is 'bootstrapped'"
assert_contains "$output" '"count": 0' "T1.3: Count is 0"
[ -f "$TEST_DIR/directives.md" ] && pass "T1.4: Registry file created" || fail "T1.4: Registry file missing"
[ -f "$TEST_DIR/directive-guardian.log" ] && pass "T1.5: Log file created" || fail "T1.5: Log file missing"

# ── T2: Add directives ───────────────────────────────────────────────
echo ""
echo "── T2: Add directives ──"

output=$("$CTL" add "Test Persona" critical identity "Be helpful and direct" "Check persona" 2>&1)
assert_contains "$output" "✓ Added DIRECTIVE-001" "T2.1: First add succeeds"

output=$("$CTL" add "Tool Prefs" high tooling "Use ripgrep over grep" 2>&1)
assert_contains "$output" "✓ Added DIRECTIVE-002" "T2.2: Second add auto-increments ID"

output=$("$CTL" add "Low Priority" low misc "Some optional rule" 2>&1)
assert_contains "$output" "✓ Added DIRECTIVE-003" "T2.3: Third add succeeds"

# ── T3: List directives ──────────────────────────────────────────────
echo ""
echo "── T3: List & filter ──"

output=$("$CTL" list 2>&1)
assert_contains "$output" "DIRECTIVE-001" "T3.1: List shows first directive"
assert_contains "$output" "DIRECTIVE-003" "T3.2: List shows third directive"
assert_contains "$output" "3 directives" "T3.3: Count is correct"

output=$("$CTL" list --priority critical 2>&1)
assert_contains "$output" "DIRECTIVE-001" "T3.4: Priority filter includes critical"
assert_not_contains "$output" "DIRECTIVE-002" "T3.5: Priority filter excludes high"

output=$("$CTL" list --category tooling 2>&1)
assert_contains "$output" "DIRECTIVE-002" "T3.6: Category filter works"

# ── T4: Guardian parse ────────────────────────────────────────────────
echo ""
echo "── T4: Guardian parse (with data) ──"

output=$("$GUARDIAN" 2>&1)
assert_valid_json "$output" "T4.1: Valid JSON with directives"
assert_contains "$output" '"count": 3' "T4.2: Parsed all 3 directives"
assert_contains "$output" '"enabled_count": 3' "T4.3: All 3 enabled"
assert_contains "$output" '"integrity"' "T4.4: Integrity field present"

# ── T5: Disable/Enable ───────────────────────────────────────────────
echo ""
echo "── T5: Disable & enable ──"

output=$("$CTL" disable DIRECTIVE-002 2>&1)
assert_contains "$output" "✓ Updated DIRECTIVE-002" "T5.1: Disable succeeds"

output=$("$CTL" list 2>&1)
assert_contains "$output" "DISABLED" "T5.2: Disabled shows in list"

output=$("$GUARDIAN" 2>&1)
assert_contains "$output" '"enabled_count": 2' "T5.3: Guardian sees 2 enabled"
assert_contains "$output" '"disabled_count": 1' "T5.4: Guardian sees 1 disabled"

output=$("$CTL" enable DIRECTIVE-002 2>&1)
assert_contains "$output" "✓ Updated DIRECTIVE-002" "T5.5: Re-enable succeeds"

# ── T6: Edit ──────────────────────────────────────────────────────────
echo ""
echo "── T6: Edit directive ──"

output=$("$CTL" edit DIRECTIVE-001 --directive "Updated persona text" 2>&1)
assert_contains "$output" "✓ Updated DIRECTIVE-001" "T6.1: Edit directive text"

output=$("$CTL" edit DIRECTIVE-003 --priority high 2>&1)
assert_contains "$output" "✓ Updated DIRECTIVE-003" "T6.2: Edit priority"

# ── T7: Search ────────────────────────────────────────────────────────
echo ""
echo "── T7: Search ──"

output=$("$CTL" search "ripgrep" 2>&1)
assert_contains "$output" "DIRECTIVE-002" "T7.1: Search finds matching directive"
assert_contains "$output" "1 matches" "T7.2: Correct match count"

output=$("$CTL" search "nonexistent_xyz_123" 2>&1)
assert_contains "$output" "0 matches" "T7.3: No-match returns 0"

# ── T8: Remove ────────────────────────────────────────────────────────
echo ""
echo "── T8: Remove directive ──"

output=$("$CTL" remove DIRECTIVE-003 2>&1)
assert_contains "$output" "✓ Removed DIRECTIVE-003" "T8.1: Remove succeeds"
[ -f "$TEST_DIR/directives.md.bak" ] && pass "T8.2: Backup created before remove" || fail "T8.2: No backup"

output=$("$CTL" list 2>&1)
assert_not_contains "$output" "DIRECTIVE-003" "T8.3: Removed directive gone from list"
assert_contains "$output" "2 directives" "T8.4: Count updated"

# ── T9: Validate ──────────────────────────────────────────────────────
echo ""
echo "── T9: Validate ──"

output=$("$CTL" validate 2>&1)
assert_contains "$output" "✓ All directives valid" "T9.1: Valid registry passes"

# ── T10: Input validation ─────────────────────────────────────────────
echo ""
echo "── T10: Input validation (should fail) ──"

assert_exit_code 1 "T10.1: Bad priority rejected" "$CTL" add "Bad" EXTREME misc "test"
assert_exit_code 1 "T10.2: Bad ID format rejected" "$CTL" remove "NOT-A-DIRECTIVE"
assert_exit_code 1 "T10.3: Remove nonexistent rejected" "$CTL" remove "DIRECTIVE-999"

# ── T11: Backup/Restore ──────────────────────────────────────────────
echo ""
echo "── T11: Backup & restore ──"

output=$("$CTL" backup 2>&1)
assert_contains "$output" "✓ Backed up" "T11.1: Backup creates file"

# Add a directive, then restore to remove it
"$CTL" add "Temp" low misc "will be removed by restore" >/dev/null 2>&1
output=$("$CTL" list 2>&1)
assert_contains "$output" "3 directives" "T11.2: Directive added before restore"

"$CTL" restore "$TEST_DIR/directives.md.bak" >/dev/null 2>&1
output=$("$CTL" list 2>&1)
assert_contains "$output" "2 directives" "T11.3: Restore reverted to 2 directives"

# ── T12: JSON special characters ──────────────────────────────────────
echo ""
echo "── T12: JSON escape handling (BUG-002 regression) ──"

"$CTL" add "Path Test" medium tooling 'Use C:\new\tools and "quoted" stuff' >/dev/null 2>&1
output=$("$GUARDIAN" 2>&1)
assert_valid_json "$output" "T12.1: JSON valid with backslashes and quotes in directive"

# ── T13: Export/Import ────────────────────────────────────────────────
echo ""
echo "── T13: Export ──"

if command -v jq >/dev/null 2>&1; then
    output=$("$CTL" export "$TEST_DIR/export.json" 2>&1)
    assert_contains "$output" "✓ Exported" "T13.1: Export succeeds"
    [ -f "$TEST_DIR/export.json" ] && pass "T13.2: Export file created" || fail "T13.2: Export file missing"
    assert_valid_json "$(cat "$TEST_DIR/export.json")" "T13.3: Export is valid JSON"
else
    echo "  ⊘ T13: Skipped (jq not available)"
fi

# ── T14: Checksum ─────────────────────────────────────────────────────
echo ""
echo "── T14: Checksum ──"

output=$("$CTL" checksum 2>&1)
assert_contains "$output" "✓ Checksum updated" "T14.1: Checksum command works"
[ -f "$TEST_DIR/directives.sha256" ] && pass "T14.2: Checksum file created" || fail "T14.2: Checksum file missing"

# ── T15: Status ───────────────────────────────────────────────────────
echo ""
echo "── T15: Status dashboard ──"

output=$("$CTL" status 2>&1)
assert_contains "$output" "Directives:" "T15.1: Shows directive count"
assert_contains "$output" "Integrity:" "T15.2: Shows integrity status"
assert_contains "$output" "GUARDIAN BOOT" "T15.3: Shows recent log entries"
# B1/B4 regression: counter line must be on a single line, not split because
# `grep -c ... || echo 0` captured "0\n0" when a count was zero.
assert_line "$output" "  Directives: 3 total (3 enabled, 0 disabled)" \
    "T15.4: Status counter line is single-line and well-formed"

# ── T16: Multi-word category survives list (B2 regression) ────────────
echo ""
echo "── T16: Multi-word category in list ──"

"$CTL" add "Spaced" medium "tool config" "use sane defaults" >/dev/null
output=$("$CTL" list 2>&1)
assert_contains "$output" "cat=tool config" "T16.1: Multi-word category not collapsed"
"$CTL" remove DIRECTIVE-004 >/dev/null

# ── T17: --enabled validation (S5) ────────────────────────────────────
echo ""
echo "── T17: --enabled value validation ──"

assert_exit_code 1 "T17.1: Bogus --enabled value rejected" \
    "$CTL" edit DIRECTIVE-001 --enabled maybe

# ── T18: show / get command ──────────────────────────────────────────
echo ""
echo "── T18: show command ──"

output=$("$CTL" show DIRECTIVE-001 2>&1)
assert_contains "$output" "[DIRECTIVE-001]" "T18.1: show prints target directive heading"
assert_contains "$output" "Updated persona text" "T18.2: show prints directive body"
assert_not_contains "$output" "DIRECTIVE-002" "T18.3: show does not leak neighbours"

assert_exit_code 1 "T18.4: show on missing ID fails" "$CTL" show DIRECTIVE-999

# ── T19: cmd_remove does not leak orphan content (AUDIT-03) ──────────
echo ""
echo "── T19: Remove keeps surrounding content intact ──"

# Seed an orphan comment inside a directive block, then remove the
# directive and assert neither the block NOR the orphan survive,
# but the next directive does.
"$CTL" add "RemoveSentinel" medium tooling "sentinel body" >/dev/null
sentinel_id=$("$CTL" list 2>&1 | awk '/RemoveSentinel/ {match($0, /DIRECTIVE-[0-9]+/); print substr($0, RSTART, RLENGTH)}')
# Inject an orphan line inside the sentinel's block by hand.
awk -v t="$sentinel_id" '
  /^## \[DIRECTIVE-[0-9]+\]/ { in_b = (index($0, "[" t "]") > 0) }
  { print }
  in_b && /^- \*\*directive\*\*:/ { print "this is an orphan line"; print ""; print "- stray note"; in_b = 0 }
' "$TEST_DIR/directives.md" > "$TEST_DIR/directives.tmp" && mv "$TEST_DIR/directives.tmp" "$TEST_DIR/directives.md"
"$CTL" add "RemoveNeighbour" low misc "still here" >/dev/null

"$CTL" remove "$sentinel_id" >/dev/null
content=$(cat "$TEST_DIR/directives.md")
assert_not_contains "$content" "this is an orphan line" "T19.1: orphan line inside removed block is gone"
assert_not_contains "$content" "RemoveSentinel" "T19.2: removed directive title is gone"
assert_contains "$content" "RemoveNeighbour" "T19.3: neighbour directive survives"

# ── T20: Duplicate-ID detection (AUDIT-02) ────────────────────────────
echo ""
echo "── T20: Duplicate ID detection ──"

# Hand-duplicate DIRECTIVE-001 block by appending a second copy.
{
  echo ""
  echo "## [DIRECTIVE-001] Duplicate Injected"
  echo "- **priority**: low"
  echo "- **category**: misc"
  echo "- **enabled**: true"
  echo "- **directive**: should be flagged"
} >> "$TEST_DIR/directives.md"

output=$("$CTL" validate 2>&1)
assert_contains "$output" "duplicate ID [DIRECTIVE-001]" "T20.1: validate flags duplicates"

output=$("$CTL" audit 2>&1)
assert_contains "$output" "DIRECTIVE-001" "T20.2: audit surfaces duplicate"

# Clean up duplicates so later tests pass
tmpf=$(mktemp)
awk 'BEGIN{seen=0} /^## \[DIRECTIVE-001\] Duplicate Injected/ {seen=1; next} seen && /^- \*\*/ {next} seen && /^$/ {seen=0; next} {print}' \
    "$TEST_DIR/directives.md" > "$tmpf" && mv "$tmpf" "$TEST_DIR/directives.md"
"$CTL" checksum >/dev/null

# ── T21: Integrity does NOT self-heal (AUDIT-01) ──────────────────────
echo ""
echo "── T21: Integrity persists tamper across boots ──"

"$GUARDIAN" >/dev/null 2>&1      # establish clean checksum
echo "# tampered" >> "$TEST_DIR/directives.md"

output=$("$GUARDIAN" 2>&1)
assert_contains "$output" '"integrity": "modified_since_last_checksum"' "T21.1: first boot reports mismatch"

# Second boot should STILL report mismatch — bug was that v2.0 silently
# overwrote the stored hash after the first mismatch.
output=$("$GUARDIAN" 2>&1)
assert_contains "$output" '"integrity": "modified_since_last_checksum"' \
    "T21.2: second boot also reports mismatch (no self-heal)"

# Acknowledge, then next boot should be verified.
"$CTL" acknowledge >/dev/null
output=$("$GUARDIAN" 2>&1)
assert_contains "$output" '"integrity": "modified_acknowledged"' "T21.3: acknowledged boot accepts new state"

output=$("$GUARDIAN" 2>&1)
assert_contains "$output" '"integrity": "verified"' "T21.4: subsequent boot is verified"

# --verify-only mode
assert_exit_code 0 "T21.5: --verify-only exits 0 on clean registry" "$GUARDIAN" --verify-only
echo "# tamper again" >> "$TEST_DIR/directives.md"
assert_exit_code 2 "T21.6: --verify-only exits 2 on mismatch" "$GUARDIAN" --verify-only
"$CTL" acknowledge >/dev/null
"$GUARDIAN" >/dev/null 2>&1      # refresh checksum

# ── T22: Import with skip-by-title conflict mode ──────────────────────
echo ""
echo "── T22: Import conflict handling ──"

if command -v jq >/dev/null 2>&1; then
    "$CTL" export "$TEST_DIR/roundtrip.json" >/dev/null
    before=$(awk '/^## \[DIRECTIVE-[0-9]+\]/ {n++} END {print n+0}' "$TEST_DIR/directives.md")
    "$CTL" import "$TEST_DIR/roundtrip.json" skip >/dev/null
    after=$(awk '/^## \[DIRECTIVE-[0-9]+\]/ {n++} END {print n+0}' "$TEST_DIR/directives.md")
    if [ "$before" = "$after" ]; then
        pass "T22.1: import in skip mode leaves count unchanged"
    else
        fail "T22.1: import in skip mode unchanged (before=$before after=$after)"
    fi
else
    echo "  ⊘ T22: Skipped (jq not available)"
fi

# ── T23: Prune backups ────────────────────────────────────────────────
echo ""
echo "── T23: prune-backups ──"

# Use distinct fake timestamps so prune has a deterministic set to work on.
# Use an isolated subdir so we don't count backups accumulated by earlier tests.
PRUNE_DIR=$(mktemp -d)
(
    export DIRECTIVE_MEMORY_DIR="$PRUNE_DIR"
    "$GUARDIAN" >/dev/null 2>&1
    for i in 1 2 3 4 5 6 7 8; do
        touch "$PRUNE_DIR/directives.2020010${i}-000000.md.bak"
    done
    "$CTL" prune-backups 3 >"$PRUNE_DIR/prune.out" 2>&1
)
prune_output=$(cat "$PRUNE_DIR/prune.out")
assert_contains "$prune_output" "kept 3 newest" "T23.1: prune reports keep count"
remaining=$(find "$PRUNE_DIR" -maxdepth 1 -type f \
            \( -name 'directives.*.md.bak' -o -name 'directives.*.bak' \) \
            ! -name 'directives.md.bak' | wc -l | tr -d ' ')
[ "$remaining" = "3" ] && pass "T23.2: only 3 timestamped backups remain" || fail "T23.2: expected 3, got $remaining"
rm -rf "$PRUNE_DIR"

# ── T24: SessionStart hook envelope ───────────────────────────────────
echo ""
echo "── T24: SessionStart hook ──"

if [ -x "$SESSION_HOOK" ]; then
    output=$(printf '{}' | "$SESSION_HOOK" 2>&1)
    assert_contains "$output" '"hookEventName":"SessionStart"' "T24.1: hook emits SessionStart envelope"
    assert_contains "$output" 'additionalContext' "T24.2: hook sets additionalContext"
    if command -v jq >/dev/null 2>&1; then
        if echo "$output" | jq . >/dev/null 2>&1; then
            pass "T24.3: hook output is valid JSON"
        else
            fail "T24.3: hook output is NOT valid JSON"
        fi
    fi
else
    fail "T24: SessionStart hook missing or not executable at $SESSION_HOOK"
fi

# ── T25: Markdown output mode ─────────────────────────────────────────
echo ""
echo "── T25: guardian --format markdown ──"

output=$("$GUARDIAN" --format markdown 2>&1)
assert_contains "$output" "# Active Directives" "T25.1: markdown brief has header"
assert_contains "$output" "DIRECTIVE-001" "T25.2: markdown brief lists a directive"

# ── T26: Legacy env var fallback ──────────────────────────────────────
echo ""
echo "── T26: OPENCLAW_MEMORY_DIR legacy fallback ──"

LEGACY_DIR=$(mktemp -d)
(
    unset DIRECTIVE_MEMORY_DIR CLAUDE_MEMORY_DIR
    export OPENCLAW_MEMORY_DIR="$LEGACY_DIR"
    "$GUARDIAN" >/dev/null 2>&1
)
[ -f "$LEGACY_DIR/directives.md" ] && pass "T26.1: legacy env var still creates registry" \
    || fail "T26.1: legacy env var did not bootstrap"
rm -rf "$LEGACY_DIR"

# ── T27: Multiline directive parsing ──────────────────────────────────
echo ""
echo "── T27: Multiline directive continuation lines ──"

# Hand-edit a multiline directive into the registry.
cat >> "$TEST_DIR/directives.md" << 'MULTI'

## [DIRECTIVE-099] Multiline Test
- **priority**: high
- **category**: testing
- **enabled**: true
- **directive**: First line of the directive.
  Second line extends it.
  Third line too.
- **verify**: verify line one.
  verify line two.
MULTI

"$CTL" checksum >/dev/null
output=$("$GUARDIAN" 2>&1)
assert_valid_json "$output" "T27.1: multiline JSON is well-formed"
assert_contains "$output" "Second line extends it." "T27.2: second line captured in manifest"
assert_contains "$output" "Third line too." "T27.3: third line captured"
assert_contains "$output" "verify line two." "T27.4: verify field continuation captured"

# Check that the JSON-encoded directive contains escaped newlines.
if command -v jq >/dev/null 2>&1; then
    dir_text=$(echo "$output" | jq -r '.directives[] | select(.id=="DIRECTIVE-099") | .directive')
    if echo "$dir_text" | grep -q "Second line extends it."; then
        pass "T27.5: jq reads multiline directive body"
    else
        fail "T27.5: jq could not read multiline body"
    fi
fi

# Markdown brief should have 2-space indented continuations (valid markdown list item).
md_output=$("$GUARDIAN" --format markdown 2>&1)
if echo "$md_output" | grep -qE "^  Second line extends it\."; then
    pass "T27.6: markdown brief indents continuation lines"
else
    fail "T27.6: markdown brief does not indent continuations"
    echo "$md_output" | grep -A2 "DIRECTIVE-099" | sed 's/^/    /' >&2
fi

# ── T28: Edit preserves no orphan continuation lines ─────────────────
echo ""
echo "── T28: Edit strips old multiline continuations ──"

"$CTL" edit DIRECTIVE-099 --directive "single line replacement" >/dev/null
content=$(cat "$TEST_DIR/directives.md")
assert_not_contains "$content" "Second line extends it." "T28.1: old continuation line 1 removed"
assert_not_contains "$content" "Third line too." "T28.2: old continuation line 2 removed"
assert_contains "$content" "single line replacement" "T28.3: new value written"
# The verify field's continuations should still be intact — we only edited directive.
assert_contains "$content" "verify line two." "T28.4: neighbouring field continuations preserved"
"$CTL" remove DIRECTIVE-099 >/dev/null

# ── T29: from-claude-md onboarding ────────────────────────────────────
echo ""
echo "── T29: from-claude-md import ──"

CLAUDE_SRC=$(mktemp)
cat > "$CLAUDE_SRC" << 'CLAUDE_EOF'
# Project Context

## Persona
Be direct and precise.
Avoid corporate fluff.

## Tool preferences
Prefer ripgrep.
Use Docker for isolation.

## Project awareness
The network is hellsy.net. Projects include VOIDROID, catio.cam.
CLAUDE_EOF

before=$(awk '/^## \[DIRECTIVE-[0-9]+\]/ {n++} END {print n+0}' "$TEST_DIR/directives.md")
"$CTL" from-claude-md "$CLAUDE_SRC" >/dev/null
after=$(awk '/^## \[DIRECTIVE-[0-9]+\]/ {n++} END {print n+0}' "$TEST_DIR/directives.md")
delta=$((after - before))
[ "$delta" = "3" ] && pass "T29.1: imported 3 directives from CLAUDE.md" \
    || fail "T29.1: expected 3 imports, got $delta"

assert_contains "$(cat "$TEST_DIR/directives.md")" "Persona" "T29.2: section title preserved"
assert_contains "$(cat "$TEST_DIR/directives.md")" "Use Docker for isolation." "T29.3: section body preserved"
assert_contains "$(cat "$TEST_DIR/directives.md")" "**category**: imported" "T29.4: imported category set"

# Round-trip: the guardian should parse the imported directives as multiline.
output=$("$GUARDIAN" 2>&1)
assert_valid_json "$output" "T29.5: registry still parses as valid JSON"
assert_contains "$output" "Avoid corporate fluff." "T29.6: multiline body survives round-trip"

rm -f "$CLAUDE_SRC"

# ── T30: Install script ───────────────────────────────────────────────
echo ""
echo "── T30: install.sh ──"

INSTALLER="$SCRIPT_DIR/install.sh"
if [ -x "$INSTALLER" ]; then
    INSTALL_TEST=$(mktemp -d)
    INSTALL_HOME=$(mktemp -d)
    (
        unset DIRECTIVE_MEMORY_DIR CLAUDE_MEMORY_DIR OPENCLAW_MEMORY_DIR
        export HOME="$INSTALL_HOME"
        export CLAUDE_PLUGINS_DIR="$INSTALL_TEST"
        "$INSTALLER" >/dev/null 2>&1
    )
    [ -f "$INSTALL_TEST/directive-guardian/scripts/guardian.sh" ] \
        && pass "T30.1: install.sh copies scripts to dest" \
        || fail "T30.1: install.sh did not copy scripts"
    [ -f "$INSTALL_TEST/directive-guardian/.claude-plugin/plugin.json" ] \
        && pass "T30.2: install.sh copies plugin manifest" \
        || fail "T30.2: install.sh did not copy plugin manifest"
    [ -x "$INSTALL_TEST/directive-guardian/hooks/session-start.sh" ] \
        && pass "T30.3: hook is executable after install" \
        || fail "T30.3: hook not executable after install"
    [ -d "$INSTALL_TEST/directive-guardian/commands" ] \
        && pass "T30.4: install.sh copies commands dir" \
        || fail "T30.4: install.sh did not copy commands"
    # Re-running the installer should replace cleanly, not error.
    (
        unset DIRECTIVE_MEMORY_DIR CLAUDE_MEMORY_DIR OPENCLAW_MEMORY_DIR
        export HOME="$INSTALL_HOME"
        export CLAUDE_PLUGINS_DIR="$INSTALL_TEST"
        "$INSTALLER" >/dev/null 2>&1
    ) && pass "T30.5: install.sh re-run succeeds" \
        || fail "T30.5: install.sh re-run failed"
    rm -rf "$INSTALL_TEST" "$INSTALL_HOME"
else
    echo "  ⊘ T30: install.sh not executable, skipping"
fi

# ── T31: Slash command files present ─────────────────────────────────
echo ""
echo "── T31: Slash commands present ──"

for cmd in directives directive-add directive-audit directive-reapply directive-ack; do
    f="$SCRIPT_DIR/commands/$cmd.md"
    [ -f "$f" ] && pass "T31.$cmd: $cmd.md exists" || fail "T31.$cmd: $cmd.md missing"
done
