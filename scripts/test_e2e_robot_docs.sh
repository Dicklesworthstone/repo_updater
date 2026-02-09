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
#   - ru robot-docs schemas includes command schemas
#   - ru --schema shortcut works
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
set -uo pipefail

#==============================================================================
# Source E2E Test Framework
#==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Tests
#==============================================================================

test_valid_json_all_topics() {
    e2e_setup

    local topics=("quickstart" "commands" "examples" "exit-codes" "formats" "schemas" "all")
    for topic in "${topics[@]}"; do
        local output
        output=$("$E2E_RU_SCRIPT" robot-docs "$topic" 2>/dev/null)
        if echo "$output" | python3 -m json.tool >/dev/null 2>&1; then
            pass "robot-docs $topic produces valid JSON"
        else
            fail "robot-docs $topic does NOT produce valid JSON"
        fi
    done

    e2e_cleanup
}

test_envelope_structure() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs quickstart 2>/dev/null)

    for key in generated_at version output_format command data; do
        if echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$key' in d" 2>/dev/null; then
            pass "Envelope has key: $key"
        else
            fail "Envelope missing key: $key"
        fi
    done

    local cmd
    cmd=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['command'])" 2>/dev/null)
    assert_equals "robot-docs" "$cmd" "Envelope command = robot-docs"

    local fmt
    fmt=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['output_format'])" 2>/dev/null)
    assert_equals "json" "$fmt" "Envelope output_format = json"

    e2e_cleanup
}

test_schema_version() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs quickstart 2>/dev/null)
    local sv
    sv=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['schema_version'])" 2>/dev/null)
    assert_equals "1.0.0" "$sv" "schema_version = 1.0.0"

    e2e_cleanup
}

test_all_topic_includes_sections() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs all 2>/dev/null)

    for section in quickstart commands examples exit_codes formats schemas; do
        if echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; assert '$section' in d" 2>/dev/null; then
            pass "'all' topic includes section: $section"
        else
            fail "'all' topic missing section: $section"
        fi
    done

    e2e_cleanup
}

test_commands_topic_coverage() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs commands 2>/dev/null)

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

    e2e_cleanup
}

test_exit_codes_coverage() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs exit-codes 2>/dev/null)

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

    e2e_cleanup
}

test_invalid_topic() {
    e2e_setup

    assert_exit_code 4 "Invalid topic exits with code 4" \
        "$E2E_RU_SCRIPT" robot-docs nonexistent_topic

    e2e_cleanup
}

test_default_topic_is_all() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs 2>/dev/null)
    local topic
    topic=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['topic'])" 2>/dev/null)
    assert_equals "all" "$topic" "Default topic = all"

    e2e_cleanup
}

test_schemas_has_command_schemas() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" robot-docs schemas 2>/dev/null)

    for cmd in status list sync error; do
        if echo "$output" | python3 -c "
import sys,json
cmds = json.load(sys.stdin)['data']['content']['commands']
assert '$cmd' in cmds
assert 'data_schema' in cmds['$cmd']
" 2>/dev/null; then
            pass "Schemas includes $cmd with data_schema"
        else
            fail "Schemas missing $cmd or data_schema"
        fi
    done

    if echo "$output" | python3 -c "
import sys,json
d = json.load(sys.stdin)['data']['content']
assert 'envelope' in d
assert '\$schema' in d['envelope']
" 2>/dev/null; then
        pass "Schemas has envelope with \$schema"
    else
        fail "Schemas missing envelope or \$schema"
    fi

    e2e_cleanup
}

test_schema_shortcut() {
    e2e_setup

    local output
    output=$("$E2E_RU_SCRIPT" --schema 2>/dev/null)
    if echo "$output" | python3 -c "
import sys,json
d = json.load(sys.stdin)
assert d['data']['topic'] == 'schemas'
assert 'commands' in d['data']['content']
" 2>/dev/null; then
        pass "--schema shortcut returns schemas topic"
    else
        fail "--schema shortcut does not return schemas topic"
    fi

    e2e_cleanup
}

test_version_matches() {
    e2e_setup

    local ru_version
    ru_version=$("$E2E_RU_SCRIPT" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    local doc_version
    doc_version=$("$E2E_RU_SCRIPT" robot-docs quickstart 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null)

    assert_equals "$ru_version" "$doc_version" "Envelope version matches ru --version"

    e2e_cleanup
}

#==============================================================================
# Run Tests
#==============================================================================

run_test test_valid_json_all_topics
run_test test_envelope_structure
run_test test_schema_version
run_test test_all_topic_includes_sections
run_test test_commands_topic_coverage
run_test test_exit_codes_coverage
run_test test_invalid_topic
run_test test_default_topic_is_all
run_test test_schemas_has_command_schemas
run_test test_schema_shortcut
run_test test_version_matches

print_results
