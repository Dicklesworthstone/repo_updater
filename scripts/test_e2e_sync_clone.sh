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
# shellcheck disable=SC1091  # Sourced files checked separately
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Helper Functions
#==============================================================================

# Initialize ru config with test settings
init_test_config() {
    local layout="${1:-flat}"

    # Remove framework-created config so ru init creates a fresh one
    rm -rf "$XDG_CONFIG_HOME/ru"

    # Initialize config
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

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
        sed "s|^PROJECTS_DIR=.*|PROJECTS_DIR=$RU_PROJECTS_DIR|" "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
    else
        echo "PROJECTS_DIR=$RU_PROJECTS_DIR" >> "$config_file"
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
    e2e_setup

    init_test_config "flat"
    add_test_repo "testowner/testrepo"

    # Run sync with dry-run
    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || exit_code=$?

    # Dry-run should succeed
    assert_equals "0" "$exit_code" "dry-run exits with code 0"

    # Should mention dry-run
    assert_contains "$output" "DRY RUN" "Output mentions DRY RUN"

    # Projects directory should be empty (no actual clones)
    if [[ -z "$(ls -A "$RU_PROJECTS_DIR" 2>/dev/null)" ]]; then
        pass "Projects directory remains empty during dry-run"
    else
        fail "Projects directory should be empty during dry-run"
    fi

    e2e_cleanup
}

test_sync_dry_run_shows_would_clone() {
    e2e_setup

    init_test_config "flat"
    add_test_repo "charmbracelet/gum"

    # Run sync with dry-run
    local output
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1)

    # Should show what would be cloned
    assert_contains "$output" "Would clone" "Output shows 'Would clone'"
    assert_contains "$output" "gum" "Output mentions repo name"

    e2e_cleanup
}

#==============================================================================
# Tests: Layout Modes
#==============================================================================

test_layout_flat_dry_run() {
    e2e_setup

    init_test_config "flat"
    add_test_repo "owner/myrepo"

    local output
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1)

    # Flat layout: $PROJECTS_DIR/repo
    assert_contains "$output" "$RU_PROJECTS_DIR/myrepo" "Flat layout path is correct"

    e2e_cleanup
}

test_layout_owner_repo_dry_run() {
    e2e_setup

    init_test_config "owner-repo"
    add_test_repo "someowner/somerepo"

    local output
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1)

    # Owner-repo layout: $PROJECTS_DIR/owner/repo
    assert_contains "$output" "$RU_PROJECTS_DIR/someowner/somerepo" "Owner-repo layout path is correct"

    e2e_cleanup
}

test_layout_full_dry_run() {
    e2e_setup

    init_test_config "full"
    add_test_repo "https://github.com/fullowner/fullrepo"

    local output
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1)

    # Full layout: $PROJECTS_DIR/host/owner/repo
    assert_contains "$output" "$RU_PROJECTS_DIR/github.com/fullowner/fullrepo" "Full layout path is correct"

    e2e_cleanup
}

#==============================================================================
# Tests: JSON Output
#==============================================================================

test_sync_json_output_structure() {
    e2e_setup

    init_test_config "flat"
    add_test_repo "jsontest/repo"

    # Run sync with dry-run and JSON output
    local json_output exit_code=0
    json_output=$("$E2E_RU_SCRIPT" sync --dry-run --json --non-interactive 2>/dev/null) || exit_code=$?

    assert_equals "0" "$exit_code" "sync --json exits with code 0"

    # Validate JSON
    if command -v jq >/dev/null 2>&1; then
        if printf '%s\n' "$json_output" | jq . >/dev/null 2>&1; then
            pass "JSON output is valid"
        else
            fail "JSON output is valid (invalid JSON)"
        fi
    elif command -v python3 >/dev/null 2>&1; then
        if printf '%s\n' "$json_output" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
            pass "JSON output is valid"
        else
            fail "JSON output is valid (invalid JSON)"
        fi
    else
        # Fallback: basic structure check (starts with { or [, ends with } or ])
        local trimmed
        trimmed=$(printf '%s' "$json_output" | tr -d '[:space:]')
        if [[ "$trimmed" =~ ^[\{\[] && "$trimmed" =~ [\}\]]$ ]]; then
            pass "JSON output is valid (basic check - install jq for full validation)"
        else
            fail "JSON output is valid (invalid JSON structure)"
        fi
    fi

    e2e_cleanup
}

test_sync_json_has_required_fields() {
    e2e_setup

    init_test_config "flat"
    add_test_repo "fieldtest/repo"

    local json_output
    json_output=$("$E2E_RU_SCRIPT" sync --dry-run --json --non-interactive 2>/dev/null)

    # Check for required envelope fields using jq, python3, or grep fallback
    local fields=("version" "generated_at" "command")
    for field in "${fields[@]}"; do
        if command -v jq >/dev/null 2>&1; then
            if printf '%s\n' "$json_output" | jq -e ".$field" >/dev/null 2>&1; then
                pass "JSON has '$field' field"
            else
                fail "JSON has '$field' field (field '$field' not found in JSON)"
            fi
        elif command -v python3 >/dev/null 2>&1; then
            if printf '%s\n' "$json_output" | python3 -c "import sys, json; d=json.load(sys.stdin); assert '$field' in d" 2>/dev/null; then
                pass "JSON has '$field' field"
            else
                fail "JSON has '$field' field (field '$field' not found in JSON)"
            fi
        else
            if printf '%s\n' "$json_output" | grep -q "\"$field\""; then
                pass "JSON has '$field' field (basic check)"
            else
                fail "JSON has '$field' field (field '$field' not found in JSON)"
            fi
        fi
    done

    e2e_cleanup
}

test_sync_json_summary_counts() {
    e2e_setup

    init_test_config "flat"
    add_test_repo "counttest/repo1"
    add_test_repo "counttest/repo2"

    local json_output
    json_output=$("$E2E_RU_SCRIPT" sync --dry-run --json --non-interactive 2>/dev/null)

    # Check summary contains count fields (with fallbacks for different tools)
    local has_total="false"
    if command -v jq >/dev/null 2>&1; then
        if printf '%s\n' "$json_output" | jq -e '.data.summary.total' >/dev/null 2>&1; then
            has_total="true"
        fi
    elif command -v python3 >/dev/null 2>&1; then
        if printf '%s\n' "$json_output" | python3 -c "import sys, json; d=json.load(sys.stdin); assert 'total' in d.get('data', {}).get('summary', {})" 2>/dev/null; then
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

    e2e_cleanup
}

#==============================================================================
# Tests: Non-Interactive Mode
#==============================================================================

test_sync_non_interactive_no_prompts() {
    e2e_setup

    init_test_config "flat"
    add_test_repo "nonprompt/repo"

    # Run with stdin closed to simulate no TTY
    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1 </dev/null) || exit_code=$?

    # Should complete without hanging
    assert_equals "0" "$exit_code" "Non-interactive mode exits cleanly"

    e2e_cleanup
}

#==============================================================================
# Tests: Multiple Repos
#==============================================================================

test_sync_multiple_repos_dry_run() {
    e2e_setup

    init_test_config "flat"
    add_test_repo "multi/repo1"
    add_test_repo "multi/repo2"
    add_test_repo "multi/repo3"

    local output
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1)

    # Should show all repos
    assert_contains "$output" "repo1" "Output shows repo1"
    assert_contains "$output" "repo2" "Output shows repo2"
    assert_contains "$output" "repo3" "Output shows repo3"

    e2e_cleanup
}

#==============================================================================
# Tests: Clone-Only Mode
#==============================================================================

test_sync_clone_only_dry_run() {
    e2e_setup

    init_test_config "flat"
    add_test_repo "cloneonly/repo"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" sync --clone-only --dry-run --non-interactive 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "clone-only with dry-run exits cleanly"
    assert_contains "$output" "Would clone" "Shows would clone message"

    e2e_cleanup
}

#==============================================================================
# Run Tests
#==============================================================================

log_suite_start "E2E Tests: ru sync clone workflow"

run_test test_sync_dry_run_no_changes
run_test test_sync_dry_run_shows_would_clone
run_test test_layout_flat_dry_run
run_test test_layout_owner_repo_dry_run
run_test test_layout_full_dry_run
run_test test_sync_json_output_structure
run_test test_sync_json_has_required_fields
run_test test_sync_json_summary_counts
run_test test_sync_non_interactive_no_prompts
run_test test_sync_multiple_repos_dry_run
run_test test_sync_clone_only_dry_run

print_results
exit "$(get_exit_code)"
