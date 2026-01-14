#!/usr/bin/env bash
#
# E2E Test: ru sync clone workflow
# Tests cloning with different layouts, dry-run mode, and JSON output
#
# Test coverage:
#   - Layout modes: flat, owner-repo, full
#   - --dry-run mode makes no filesystem changes
#   - --json produces valid structured output
#   - --non-interactive mode works correctly
#   - Path generation is correct for all layouts
#
# Note: Actual clone operations require network/gh CLI. We test:
#   - Dry-run behavior (offline)
#   - Path generation logic (offline)
#   - JSON output structure (offline)
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1090  # Dynamic sourcing is intentional
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RU_SCRIPT="$PROJECT_DIR/ru"

#==============================================================================
# Test Framework
#==============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEMP_DIR=""

# Colors (disabled if not a terminal)
if [[ -t 2 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' RESET=''
fi

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
    # Override XDG directories to isolate tests
    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_STATE_HOME="$TEMP_DIR/state"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
    export HOME="$TEMP_DIR/home"
    mkdir -p "$HOME"

    # Force sequential mode for predictable output
    export RU_PARALLEL=1

    # Create projects directory
    export TEST_PROJECTS_DIR="$TEMP_DIR/projects"
    mkdir -p "$TEST_PROJECTS_DIR"
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

pass() {
    echo -e "${GREEN}PASS${RESET}: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    ((TESTS_FAILED++))
}

skip() {
    echo -e "${YELLOW}SKIP${RESET}: $1"
}

#==============================================================================
# Assertion Helpers
#==============================================================================

assert_dir_exists() {
    local path="$1"
    local msg="$2"
    if [[ -d "$path" ]]; then
        pass "$msg"
    else
        fail "$msg (directory not found: $path)"
    fi
}

assert_dir_not_exists() {
    local path="$1"
    local msg="$2"
    if [[ ! -d "$path" ]]; then
        pass "$msg"
    else
        fail "$msg (directory unexpectedly exists: $path)"
    fi
}

assert_file_exists() {
    local path="$1"
    local msg="$2"
    if [[ -f "$path" ]]; then
        pass "$msg"
    else
        fail "$msg (file not found: $path)"
    fi
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [[ "$expected" -eq "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg (expected exit code $expected, got $actual)"
    fi
}

assert_output_contains() {
    local output="$1"
    local pattern="$2"
    local msg="$3"
    if printf '%s\n' "$output" | grep -q "$pattern"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in output)"
    fi
}

assert_json_valid() {
    local json="$1"
    local msg="$2"
    # Try jq first (fast), then python3, then basic pattern check
    if command -v jq >/dev/null 2>&1; then
        if printf '%s\n' "$json" | jq . >/dev/null 2>&1; then
            pass "$msg"
        else
            fail "$msg (invalid JSON)"
        fi
    elif command -v python3 >/dev/null 2>&1; then
        if printf '%s\n' "$json" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
            pass "$msg"
        else
            fail "$msg (invalid JSON)"
        fi
    else
        # Fallback: basic structure check (starts with { or [, ends with } or ])
        local trimmed
        trimmed=$(printf '%s' "$json" | tr -d '[:space:]')
        if [[ "$trimmed" =~ ^[\{\[] && "$trimmed" =~ [\}\]]$ ]]; then
            pass "$msg (basic check - install jq for full validation)"
        else
            fail "$msg (invalid JSON structure)"
        fi
    fi
}

assert_json_has_field() {
    local json="$1"
    local field="$2"
    local msg="$3"
    # Try jq first, then python3, then grep fallback
    if command -v jq >/dev/null 2>&1; then
        if printf '%s\n' "$json" | jq -e ".$field" >/dev/null 2>&1; then
            pass "$msg"
        else
            fail "$msg (field '$field' not found in JSON)"
        fi
    elif command -v python3 >/dev/null 2>&1; then
        if printf '%s\n' "$json" | python3 -c "import sys, json; d=json.load(sys.stdin); assert '$field' in d" 2>/dev/null; then
            pass "$msg"
        else
            fail "$msg (field '$field' not found in JSON)"
        fi
    else
        # Fallback: grep for the field name (not precise but works for simple cases)
        if printf '%s\n' "$json" | grep -q "\"$field\""; then
            pass "$msg (basic check)"
        else
            fail "$msg (field '$field' not found in JSON)"
        fi
    fi
}

#==============================================================================
# Helper Functions
#==============================================================================

# Initialize ru config with test settings
init_test_config() {
    local layout="${1:-flat}"

    # Initialize config
    "$RU_SCRIPT" init >/dev/null 2>&1

    # Set layout and projects dir directly in config file
    # Use temp file approach for macOS/Linux compatibility (sed -i differs)
    local config_file="$XDG_CONFIG_HOME/ru/config"
    local tmp_file="$config_file.tmp"

    # Update existing values or add new ones
    if grep -q "^LAYOUT=" "$config_file" 2>/dev/null; then
        sed "s|^LAYOUT=.*|LAYOUT=$layout|" "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
    else
        echo "LAYOUT=$layout" >> "$config_file"
    fi

    if grep -q "^PROJECTS_DIR=" "$config_file" 2>/dev/null; then
        sed "s|^PROJECTS_DIR=.*|PROJECTS_DIR=$TEST_PROJECTS_DIR|" "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
    else
        echo "PROJECTS_DIR=$TEST_PROJECTS_DIR" >> "$config_file"
    fi
}

# Add a test repo to the config
add_test_repo() {
    local repo="$1"
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "$repo" >> "$repos_file"
}

#==============================================================================
# Tests: Dry-Run Mode
#==============================================================================

test_sync_dry_run_no_changes() {
    echo "Test: ru sync --dry-run makes no filesystem changes"
    setup_test_env

    init_test_config "flat"
    add_test_repo "testowner/testrepo"

    # Run sync with dry-run
    local output
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1)
    local exit_code=$?

    # Dry-run should succeed
    assert_exit_code 0 "$exit_code" "dry-run exits with code 0"

    # Should mention dry-run
    assert_output_contains "$output" "DRY RUN" "Output mentions DRY RUN"

    # Projects directory should be empty (no actual clones)
    if [[ -z "$(ls -A "$TEST_PROJECTS_DIR" 2>/dev/null)" ]]; then
        pass "Projects directory remains empty during dry-run"
    else
        fail "Projects directory should be empty during dry-run"
    fi

    cleanup_test_env
}

test_sync_dry_run_shows_would_clone() {
    echo "Test: ru sync --dry-run shows what would be cloned"
    setup_test_env

    init_test_config "flat"
    add_test_repo "charmbracelet/gum"

    # Run sync with dry-run
    local output
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1)

    # Should show what would be cloned
    assert_output_contains "$output" "Would clone" "Output shows 'Would clone'"
    assert_output_contains "$output" "gum" "Output mentions repo name"

    cleanup_test_env
}

#==============================================================================
# Tests: Layout Modes
#==============================================================================

test_layout_flat_dry_run() {
    echo "Test: flat layout shows correct path in dry-run"
    setup_test_env

    init_test_config "flat"
    add_test_repo "owner/myrepo"

    local output
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1)

    # Flat layout: $PROJECTS_DIR/repo
    assert_output_contains "$output" "$TEST_PROJECTS_DIR/myrepo" "Flat layout path is correct"

    cleanup_test_env
}

test_layout_owner_repo_dry_run() {
    echo "Test: owner-repo layout shows correct path in dry-run"
    setup_test_env

    init_test_config "owner-repo"
    add_test_repo "someowner/somerepo"

    local output
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1)

    # Owner-repo layout: $PROJECTS_DIR/owner/repo
    assert_output_contains "$output" "$TEST_PROJECTS_DIR/someowner/somerepo" "Owner-repo layout path is correct"

    cleanup_test_env
}

test_layout_full_dry_run() {
    echo "Test: full layout shows correct path in dry-run"
    setup_test_env

    init_test_config "full"
    add_test_repo "https://github.com/fullowner/fullrepo"

    local output
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1)

    # Full layout: $PROJECTS_DIR/host/owner/repo
    assert_output_contains "$output" "$TEST_PROJECTS_DIR/github.com/fullowner/fullrepo" "Full layout path is correct"

    cleanup_test_env
}

#==============================================================================
# Tests: JSON Output
#==============================================================================

test_sync_json_output_structure() {
    echo "Test: ru sync --json produces valid JSON"
    setup_test_env

    init_test_config "flat"
    add_test_repo "jsontest/repo"

    # Run sync with dry-run and JSON output
    local json_output
    json_output=$("$RU_SCRIPT" sync --dry-run --json --non-interactive 2>/dev/null)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "sync --json exits with code 0"
    assert_json_valid "$json_output" "JSON output is valid"

    cleanup_test_env
}

test_sync_json_has_required_fields() {
    echo "Test: ru sync --json has required fields"
    setup_test_env

    init_test_config "flat"
    add_test_repo "fieldtest/repo"

    local json_output
    json_output=$("$RU_SCRIPT" sync --dry-run --json --non-interactive 2>/dev/null)

    # Check for required top-level fields
    assert_json_has_field "$json_output" "version" "JSON has 'version' field"
    assert_json_has_field "$json_output" "timestamp" "JSON has 'timestamp' field"
    assert_json_has_field "$json_output" "summary" "JSON has 'summary' field"

    cleanup_test_env
}

test_sync_json_summary_counts() {
    echo "Test: ru sync --json summary has count fields"
    setup_test_env

    init_test_config "flat"
    add_test_repo "counttest/repo1"
    add_test_repo "counttest/repo2"

    local json_output
    json_output=$("$RU_SCRIPT" sync --dry-run --json --non-interactive 2>/dev/null)

    # Check summary contains count fields (with fallbacks for different tools)
    local has_total="false"
    if command -v jq >/dev/null 2>&1; then
        if printf '%s\n' "$json_output" | jq -e '.summary.total' >/dev/null 2>&1; then
            has_total="true"
        fi
    elif command -v python3 >/dev/null 2>&1; then
        if printf '%s\n' "$json_output" | python3 -c "import sys, json; d=json.load(sys.stdin); assert 'total' in d.get('summary', {})" 2>/dev/null; then
            has_total="true"
        fi
    else
        # Fallback: grep for pattern
        if printf '%s\n' "$json_output" | grep -q '"total"'; then
            has_total="true"
        fi
    fi

    if [[ "$has_total" == "true" ]]; then
        pass "JSON summary has 'total' field"
    else
        fail "JSON summary missing 'total' field"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: Non-Interactive Mode
#==============================================================================

test_sync_non_interactive_no_prompts() {
    echo "Test: ru sync --non-interactive works without TTY"
    setup_test_env

    init_test_config "flat"
    add_test_repo "nonprompt/repo"

    # Run with stdin closed to simulate no TTY
    local output
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1 </dev/null)
    local exit_code=$?

    # Should complete without hanging
    assert_exit_code 0 "$exit_code" "Non-interactive mode exits cleanly"

    cleanup_test_env
}

#==============================================================================
# Tests: Multiple Repos
#==============================================================================

test_sync_multiple_repos_dry_run() {
    echo "Test: ru sync --dry-run handles multiple repos"
    setup_test_env

    init_test_config "flat"
    add_test_repo "multi/repo1"
    add_test_repo "multi/repo2"
    add_test_repo "multi/repo3"

    local output
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1)

    # Should show all repos
    assert_output_contains "$output" "repo1" "Output shows repo1"
    assert_output_contains "$output" "repo2" "Output shows repo2"
    assert_output_contains "$output" "repo3" "Output shows repo3"

    cleanup_test_env
}

#==============================================================================
# Tests: Clone-Only Mode
#==============================================================================

test_sync_clone_only_dry_run() {
    echo "Test: ru sync --clone-only --dry-run works correctly"
    setup_test_env

    init_test_config "flat"
    add_test_repo "cloneonly/repo"

    local output
    output=$("$RU_SCRIPT" sync --clone-only --dry-run --non-interactive 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "clone-only with dry-run exits cleanly"
    assert_output_contains "$output" "Would clone" "Shows would clone message"

    cleanup_test_env
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "E2E Tests: ru sync clone workflow"
echo "============================================"
echo ""

test_sync_dry_run_no_changes
echo ""

test_sync_dry_run_shows_would_clone
echo ""

test_layout_flat_dry_run
echo ""

test_layout_owner_repo_dry_run
echo ""

test_layout_full_dry_run
echo ""

test_sync_json_output_structure
echo ""

test_sync_json_has_required_fields
echo ""

test_sync_json_summary_counts
echo ""

test_sync_non_interactive_no_prompts
echo ""

test_sync_multiple_repos_dry_run
echo ""

test_sync_clone_only_dry_run
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

[[ $TESTS_FAILED -eq 0 ]]
