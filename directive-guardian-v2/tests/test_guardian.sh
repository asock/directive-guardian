#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# directive-guardian v2 — test harness
# Exercises all commands and validates output correctness
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GUARDIAN="$SCRIPT_DIR/scripts/guardian.sh"
CTL="$SCRIPT_DIR/scripts/directive-ctl.sh"
TEST_DIR=$(mktemp -d)
export OPENCLAW_MEMORY_DIR="$TEST_DIR"

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
