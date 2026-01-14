#!/usr/bin/env bash
#
# Unit Tests: Core Utilities
# Tests for ensure_dir, json_escape, write_result functions
#
# Test coverage:
#   - ensure_dir creates directories
#   - ensure_dir is idempotent (handles existing dirs)
#   - ensure_dir creates nested directories
#   - json_escape handles quotes
#   - json_escape handles backslashes
#   - json_escape handles newlines, tabs, carriage returns
#   - json_escape handles empty strings
#   - json_escape handles complex strings
#   - write_result creates valid NDJSON
#   - write_result includes all fields
#   - write_result handles special characters in fields
#   - write_result respects RESULTS_FILE being unset
#
# shellcheck disable=SC2034  # Variables used by sourced functions
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

# Colors (disabled if stdout is not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
else
    RED='' GREEN='' BLUE='' RESET=''
fi

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_STATE_HOME="$TEMP_DIR/state"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
    export HOME="$TEMP_DIR/home"
    mkdir -p "$HOME"
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

#==============================================================================
# Source Functions from ru
# Extract the specific functions we want to test
#==============================================================================

# Source just the utility functions we need to test
# We do this by extracting them from ru to avoid side effects
extract_functions() {
    # Extract ensure_dir
    eval "$(sed -n '/^ensure_dir()/,/^}/p' "$RU_SCRIPT")"

    # Extract json_escape
    eval "$(sed -n '/^json_escape()/,/^}/p' "$RU_SCRIPT")"

    # Extract write_result
    eval "$(sed -n '/^write_result()/,/^}/p' "$RU_SCRIPT")"
}

extract_functions

#==============================================================================
# Tests: ensure_dir
#==============================================================================

test_ensure_dir_creates_directory() {
    echo -e "${BLUE}Test:${RESET} ensure_dir creates a new directory"
    setup_test_env

    local test_dir="$TEMP_DIR/new_dir"

    ensure_dir "$test_dir"

    if [[ -d "$test_dir" ]]; then
        pass "Directory was created"
    else
        fail "Directory was not created"
    fi

    cleanup_test_env
}

test_ensure_dir_idempotent() {
    echo -e "${BLUE}Test:${RESET} ensure_dir is idempotent (handles existing dirs)"
    setup_test_env

    local test_dir="$TEMP_DIR/existing_dir"
    mkdir -p "$test_dir"

    # Should not fail when dir exists
    if ensure_dir "$test_dir"; then
        pass "ensure_dir succeeds on existing directory"
    else
        fail "ensure_dir failed on existing directory"
    fi

    cleanup_test_env
}

test_ensure_dir_creates_nested() {
    echo -e "${BLUE}Test:${RESET} ensure_dir creates nested directories"
    setup_test_env

    local test_dir="$TEMP_DIR/level1/level2/level3"

    ensure_dir "$test_dir"

    if [[ -d "$test_dir" ]]; then
        pass "Nested directories were created"
    else
        fail "Nested directories were not created"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: json_escape
#==============================================================================

test_json_escape_quotes() {
    echo -e "${BLUE}Test:${RESET} json_escape handles double quotes"

    local input='Hello "World"'
    local expected='Hello \"World\"'
    local result
    result=$(json_escape "$input")

    if [[ "$result" == "$expected" ]]; then
        pass "Quotes escaped correctly"
    else
        fail "Quotes not escaped correctly (got: $result, expected: $expected)"
    fi
}

test_json_escape_backslashes() {
    echo -e "${BLUE}Test:${RESET} json_escape handles backslashes"

    local input='path\to\file'
    local expected='path\\to\\file'
    local result
    result=$(json_escape "$input")

    if [[ "$result" == "$expected" ]]; then
        pass "Backslashes escaped correctly"
    else
        fail "Backslashes not escaped correctly (got: $result, expected: $expected)"
    fi
}

test_json_escape_newlines() {
    echo -e "${BLUE}Test:${RESET} json_escape handles newlines"

    local input=$'line1\nline2'
    local expected='line1\nline2'
    local result
    result=$(json_escape "$input")

    if [[ "$result" == "$expected" ]]; then
        pass "Newlines escaped correctly"
    else
        fail "Newlines not escaped correctly (got: $result, expected: $expected)"
    fi
}

test_json_escape_tabs() {
    echo -e "${BLUE}Test:${RESET} json_escape handles tabs"

    local input=$'col1\tcol2'
    local expected='col1\tcol2'
    local result
    result=$(json_escape "$input")

    if [[ "$result" == "$expected" ]]; then
        pass "Tabs escaped correctly"
    else
        fail "Tabs not escaped correctly (got: $result, expected: $expected)"
    fi
}

test_json_escape_carriage_return() {
    echo -e "${BLUE}Test:${RESET} json_escape handles carriage returns"

    local input=$'line1\rline2'
    local expected='line1\rline2'
    local result
    result=$(json_escape "$input")

    if [[ "$result" == "$expected" ]]; then
        pass "Carriage returns escaped correctly"
    else
        fail "Carriage returns not escaped correctly (got: $result, expected: $expected)"
    fi
}

test_json_escape_empty_string() {
    echo -e "${BLUE}Test:${RESET} json_escape handles empty strings"

    local input=""
    local expected=""
    local result
    result=$(json_escape "$input")

    if [[ "$result" == "$expected" ]]; then
        pass "Empty string handled correctly"
    else
        fail "Empty string not handled correctly (got: '$result', expected: '$expected')"
    fi
}

test_json_escape_complex_string() {
    echo -e "${BLUE}Test:${RESET} json_escape handles complex strings with multiple escapes"

    local input=$'Error: "file\\path"\nDetails:\ttab\rend'
    local expected='Error: \"file\\path\"\nDetails:\ttab\rend'
    local result
    result=$(json_escape "$input")

    if [[ "$result" == "$expected" ]]; then
        pass "Complex string escaped correctly"
    else
        fail "Complex string not escaped correctly"
        echo "  Got:      $result" >&2
        echo "  Expected: $expected" >&2
    fi
}

test_json_escape_preserves_simple_strings() {
    echo -e "${BLUE}Test:${RESET} json_escape preserves strings without special chars"

    local input="simple string 123"
    local expected="simple string 123"
    local result
    result=$(json_escape "$input")

    if [[ "$result" == "$expected" ]]; then
        pass "Simple string preserved"
    else
        fail "Simple string was modified (got: $result)"
    fi
}

#==============================================================================
# Tests: write_result
#==============================================================================

test_write_result_creates_ndjson() {
    echo -e "${BLUE}Test:${RESET} write_result creates valid NDJSON"
    setup_test_env

    export RESULTS_FILE="$TEMP_DIR/results.ndjson"
    touch "$RESULTS_FILE"

    write_result "owner/repo" "clone" "success" "5" "Cloned successfully" "/path/to/repo"

    if [[ -f "$RESULTS_FILE" ]]; then
        local content
        content=$(cat "$RESULTS_FILE")
        if echo "$content" | grep -q '"repo":"owner/repo"'; then
            pass "NDJSON contains repo field"
        else
            fail "NDJSON missing repo field"
        fi
    else
        fail "Results file was not created"
    fi

    unset RESULTS_FILE
    cleanup_test_env
}

test_write_result_includes_all_fields() {
    echo -e "${BLUE}Test:${RESET} write_result includes all required fields"
    setup_test_env

    export RESULTS_FILE="$TEMP_DIR/results.ndjson"
    touch "$RESULTS_FILE"

    write_result "test-repo" "pull" "success" "10" "Updated" "/home/projects/test-repo"

    local content
    content=$(cat "$RESULTS_FILE")

    local all_fields=true
    for field in repo path action status duration message timestamp; do
        if ! echo "$content" | grep -q "\"$field\":"; then
            fail "Missing field: $field"
            all_fields=false
        fi
    done

    if [[ "$all_fields" == "true" ]]; then
        pass "All fields present in NDJSON"
    fi

    unset RESULTS_FILE
    cleanup_test_env
}

test_write_result_escapes_special_chars() {
    echo -e "${BLUE}Test:${RESET} write_result escapes special characters in fields"
    setup_test_env

    export RESULTS_FILE="$TEMP_DIR/results.ndjson"
    touch "$RESULTS_FILE"

    write_result 'repo "with" quotes' "sync" "error" "0" $'Message\nwith\nnewlines' "/path/to/repo"

    local content
    content=$(cat "$RESULTS_FILE")

    # Check that quotes are escaped
    if echo "$content" | grep -q '\\\"'; then
        pass "Quotes are escaped in output"
    else
        fail "Quotes not escaped in output"
    fi

    # Verify it's valid JSON by checking structure
    if echo "$content" | grep -q '^{.*}$'; then
        pass "Output is valid JSON structure"
    else
        fail "Output is not valid JSON structure"
    fi

    unset RESULTS_FILE
    cleanup_test_env
}

test_write_result_handles_empty_results_file() {
    echo -e "${BLUE}Test:${RESET} write_result handles RESULTS_FILE being empty"
    setup_test_env

    # Set to empty string (not unset, due to set -u)
    export RESULTS_FILE=""

    # Should not fail when RESULTS_FILE is empty
    if write_result "repo" "action" "status" "0" "message" "/path"; then
        pass "write_result succeeds when RESULTS_FILE is empty"
    else
        fail "write_result failed when RESULTS_FILE is empty"
    fi

    cleanup_test_env
}

test_write_result_appends_multiple() {
    echo -e "${BLUE}Test:${RESET} write_result appends multiple results"
    setup_test_env

    export RESULTS_FILE="$TEMP_DIR/results.ndjson"
    touch "$RESULTS_FILE"

    write_result "repo1" "clone" "success" "5" "msg1" "/path1"
    write_result "repo2" "pull" "success" "3" "msg2" "/path2"
    write_result "repo3" "clone" "error" "0" "msg3" "/path3"

    local line_count
    line_count=$(wc -l < "$RESULTS_FILE" | tr -d ' ')

    if [[ "$line_count" -eq 3 ]]; then
        pass "Three results appended correctly"
    else
        fail "Expected 3 lines, got $line_count"
    fi

    unset RESULTS_FILE
    cleanup_test_env
}

test_write_result_default_duration() {
    echo -e "${BLUE}Test:${RESET} write_result uses 0 as default duration"
    setup_test_env

    export RESULTS_FILE="$TEMP_DIR/results.ndjson"
    touch "$RESULTS_FILE"

    # Omit duration
    write_result "repo" "action" "status" "" "message" "/path"

    local content
    content=$(cat "$RESULTS_FILE")

    if echo "$content" | grep -q '"duration":0'; then
        pass "Default duration is 0"
    else
        fail "Default duration not set to 0"
    fi

    unset RESULTS_FILE
    cleanup_test_env
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "Unit Tests: Core Utilities"
echo "============================================"
echo ""

# ensure_dir tests
test_ensure_dir_creates_directory
echo ""
test_ensure_dir_idempotent
echo ""
test_ensure_dir_creates_nested
echo ""

# json_escape tests
test_json_escape_quotes
echo ""
test_json_escape_backslashes
echo ""
test_json_escape_newlines
echo ""
test_json_escape_tabs
echo ""
test_json_escape_carriage_return
echo ""
test_json_escape_empty_string
echo ""
test_json_escape_complex_string
echo ""
test_json_escape_preserves_simple_strings
echo ""

# write_result tests
test_write_result_creates_ndjson
echo ""
test_write_result_includes_all_fields
echo ""
test_write_result_escapes_special_chars
echo ""
test_write_result_handles_empty_results_file
echo ""
test_write_result_appends_multiple
echo ""
test_write_result_default_duration
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

exit $TESTS_FAILED
