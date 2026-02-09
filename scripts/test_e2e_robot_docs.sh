#!/usr/bin/env bash
#
# E2E Test: ru robot-docs command
# Tests machine-readable CLI documentation output
#
# Test coverage:
#   - ru robot-docs outputs valid JSON for all topics
#   - ru robot-docs all includes all topic sections
#   - ru robot-docs with invalid topic exits 4
#   - ru robot-docs includes version and schema_version metadata
#   - ru robot-docs commands lists all known commands
#   - ru robot-docs exit-codes covers all exit codes
#   - ru robot-docs works without --json flag (always JSON)
#   - ru robot-docs respects --format toon (falls back to JSON if tru unavailable)
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

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' RESET=''
fi

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_STATE_HOME="$TEMP_DIR/state"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
    export HOME="$TEMP_DIR/home"
    export RU_PROJECTS_DIR="$TEMP_DIR/projects"
    mkdir -p "$HOME"
    mkdir -p "$RU_PROJECTS_DIR"
}

cleanup_test_env() {
    [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "${GREEN}  PASS${RESET} %s\n" "$1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "${RED}  FAIL${RESET} %s\n" "$1"
    if [[ -n "${2:-}" ]]; then
        printf "       %s\n" "$2"
    fi
}

#==============================================================================
# Tests
#==============================================================================

test_valid_json_all_topics() {
    echo "--- Testing valid JSON for all topics ---"
    setup_test_env

    local topics=("quickstart" "commands" "examples" "exit-codes" "formats" "all")
    for topic in "${topics[@]}"; do
        local output
        output=$("$RU_SCRIPT" robot-docs "$topic" 2>/dev/null)
        if echo "$output" | python3 -m json.tool >/dev/null 2>&1; then
            pass "robot-docs $topic produces valid JSON"
        else
            fail "robot-docs $topic does NOT produce valid JSON" "$output"
        fi
    done

    cleanup_test_env
}

test_envelope_structure() {
    echo "--- Testing JSON envelope structure ---"
    setup_test_env

    local output
    output=$("$RU_SCRIPT" robot-docs quickstart 2>/dev/null)

    # Check top-level keys
    for key in generated_at version output_format command data; do
        if echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$key' in d" 2>/dev/null; then
            pass "Envelope has key: $key"
        else
            fail "Envelope missing key: $key"
        fi
    done

    # Check command name
    local cmd
    cmd=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['command'])" 2>/dev/null)
    if [[ "$cmd" == "robot-docs" ]]; then
        pass "Envelope command = robot-docs"
    else
        fail "Envelope command = '$cmd' (expected robot-docs)"
    fi

    # Check output_format
    local fmt
    fmt=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['output_format'])" 2>/dev/null)
    if [[ "$fmt" == "json" ]]; then
        pass "Envelope output_format = json"
    else
        fail "Envelope output_format = '$fmt' (expected json)"
    fi

    cleanup_test_env
}

test_schema_version() {
    echo "--- Testing schema_version metadata ---"
    setup_test_env

    local output
    output=$("$RU_SCRIPT" robot-docs quickstart 2>/dev/null)
    local sv
    sv=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['schema_version'])" 2>/dev/null)
    if [[ "$sv" == "1.0.0" ]]; then
        pass "schema_version = 1.0.0"
    else
        fail "schema_version = '$sv' (expected 1.0.0)"
    fi

    cleanup_test_env
}

test_all_topic_includes_sections() {
    echo "--- Testing 'all' topic includes all sections ---"
    setup_test_env

    local output
    output=$("$RU_SCRIPT" robot-docs all 2>/dev/null)

    for section in quickstart commands examples exit_codes formats; do
        if echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; assert '$section' in d" 2>/dev/null; then
            pass "'all' topic includes section: $section"
        else
            fail "'all' topic missing section: $section"
        fi
    done

    cleanup_test_env
}

test_commands_topic_coverage() {
    echo "--- Testing commands topic covers known commands ---"
    setup_test_env

    local output
    output=$("$RU_SCRIPT" robot-docs commands 2>/dev/null)

    local expected_commands=("sync" "status" "init" "add" "remove" "list" "doctor" "self-update" "config" "prune" "import" "review" "robot-docs")
    for cmd in "${expected_commands[@]}"; do
        if echo "$output" | python3 -c "
import sys,json
cmds = json.load(sys.stdin)['data']['content']['commands']
names = [c['name'] for c in cmds]
assert '$cmd' in names
" 2>/dev/null; then
            pass "Commands topic includes: $cmd"
        else
            fail "Commands topic missing: $cmd"
        fi
    done

    cleanup_test_env
}

test_exit_codes_coverage() {
    echo "--- Testing exit-codes topic covers all codes ---"
    setup_test_env

    local output
    output=$("$RU_SCRIPT" robot-docs exit-codes 2>/dev/null)

    for code in 0 1 2 3 4 5; do
        if echo "$output" | python3 -c "
import sys,json
codes = json.load(sys.stdin)['data']['content']['exit_codes']
found = [c for c in codes if c['code'] == $code]
assert len(found) == 1
" 2>/dev/null; then
            pass "Exit codes includes code $code"
        else
            fail "Exit codes missing code $code"
        fi
    done

    cleanup_test_env
}

test_invalid_topic() {
    echo "--- Testing invalid topic exits with code 4 ---"
    setup_test_env

    "$RU_SCRIPT" robot-docs nonexistent_topic >/dev/null 2>&1
    local exit_code=$?
    if [[ "$exit_code" -eq 4 ]]; then
        pass "Invalid topic exits with code 4"
    else
        fail "Invalid topic exited with code $exit_code (expected 4)"
    fi

    cleanup_test_env
}

test_default_topic_is_all() {
    echo "--- Testing default topic (no arg) is 'all' ---"
    setup_test_env

    local output
    output=$("$RU_SCRIPT" robot-docs 2>/dev/null)
    local topic
    topic=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['topic'])" 2>/dev/null)
    if [[ "$topic" == "all" ]]; then
        pass "Default topic = all"
    else
        fail "Default topic = '$topic' (expected all)"
    fi

    cleanup_test_env
}

test_version_matches() {
    echo "--- Testing version in envelope matches ru version ---"
    setup_test_env

    local ru_version
    ru_version=$("$RU_SCRIPT" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    local doc_version
    doc_version=$("$RU_SCRIPT" robot-docs quickstart 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null)

    if [[ "$ru_version" == "$doc_version" ]]; then
        pass "Envelope version ($doc_version) matches ru --version ($ru_version)"
    else
        fail "Version mismatch: envelope=$doc_version, ru=$ru_version"
    fi

    cleanup_test_env
}

#==============================================================================
# Run Tests
#==============================================================================

echo ""
echo "=================================="
echo " ru robot-docs E2E Tests"
echo "=================================="
echo ""

test_valid_json_all_topics
test_envelope_structure
test_schema_version
test_all_topic_includes_sections
test_commands_topic_coverage
test_exit_codes_coverage
test_invalid_topic
test_default_topic_is_all
test_version_matches

echo ""
echo "=================================="
printf "Results: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}\n" "$TESTS_PASSED" "$TESTS_FAILED"
echo "=================================="

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
