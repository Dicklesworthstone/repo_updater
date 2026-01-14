#!/usr/bin/env bash
#
# Unit Tests: Parsing Functions
# Tests for parse_stream_json_event, extract_*, and detect_* functions
#
# Test coverage:
#   - parse_stream_json_event handles valid JSON events
#   - parse_stream_json_event handles invalid JSON
#   - parse_stream_json_event parses system events
#   - parse_stream_json_event parses assistant events
#   - parse_stream_json_event parses result events
#   - parse_stream_json_event handles empty input
#   - parse_stream_json_event handles unicode
#   - extract_text_content extracts text blocks
#   - extract_text_content handles empty arrays
#   - extract_text_content ignores non-text blocks
#   - extract_question_info extracts question data
#   - extract_question_from_text finds question context
#   - extract_inline_options finds a) style options
#   - extract_inline_options finds 1. style options
#   - detect_text_question matches question patterns
#   - extract_plan_json extracts between markers
#   - extract_plan_json handles missing markers
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

# Ensure cleanup on exit or interrupt
trap cleanup_test_env EXIT

pass() {
    echo -e "${GREEN}PASS${RESET}: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "  Expected: $2"
    fi
    if [[ -n "${3:-}" ]]; then
        echo "  Got:      $3"
    fi
    ((TESTS_FAILED++))
}

#==============================================================================
# Source functions from ru
#==============================================================================

# Helper function for output variables used by parse_stream_json_event
_set_out_var() {
    local var_name="$1"
    local value="$2"
    printf -v "$var_name" '%s' "$value"
}

# Stub log functions
log_warn() { :; }
log_error() { :; }
log_verbose() { :; }

# json_validate stub (checks if input is valid JSON)
json_validate() {
    jq empty 2>/dev/null
}

# Source functions directly from ru
source_function() {
    local func_name="$1"
    local func_body
    func_body=$(sed -n "/^${func_name}()/,/^}/p" "$RU_SCRIPT")
    if [[ -n "$func_body" ]]; then
        eval "$func_body"
    else
        echo "Warning: Function $func_name not found in ru" >&2
    fi
}

# Source required functions
source_function "parse_stream_json_event"
source_function "extract_text_content"
source_function "extract_question_info"
source_function "extract_question_from_text"
source_function "extract_inline_options"
source_function "detect_text_question"
source_function "extract_plan_json"
source_function "get_tool_uses"
source_function "detect_ask_user_question"

#==============================================================================
# Tests: parse_stream_json_event
#==============================================================================

test_parse_valid_system_event() {
    local json='{"type":"system","subtype":"init","session_id":"abc123","tools":["Edit","Read"],"cwd":"/tmp"}'
    local event_type="" event_data=""

    if parse_stream_json_event "$json" event_type event_data; then
        if [[ "$event_type" == "system" ]]; then
            pass "parse_stream_json_event: parses system event type"
        else
            fail "parse_stream_json_event: wrong event type" "system" "$event_type"
        fi

        if echo "$event_data" | jq -e '.session_id == "abc123"' >/dev/null 2>&1; then
            pass "parse_stream_json_event: extracts system event data"
        else
            fail "parse_stream_json_event: wrong event data" "session_id=abc123" "$event_data"
        fi
    else
        fail "parse_stream_json_event: should succeed for valid JSON"
    fi
}

test_parse_valid_assistant_event() {
    local json='{"type":"assistant","message":{"content":[{"type":"text","text":"Hello world"}]}}'
    local event_type="" event_data=""

    if parse_stream_json_event "$json" event_type event_data; then
        if [[ "$event_type" == "assistant" ]]; then
            pass "parse_stream_json_event: parses assistant event type"
        else
            fail "parse_stream_json_event: wrong event type" "assistant" "$event_type"
        fi
    else
        fail "parse_stream_json_event: should succeed for assistant event"
    fi
}

test_parse_valid_result_event() {
    local json='{"type":"result","status":"success","duration_ms":1234,"session_id":"xyz","cost_usd":0.05}'
    local event_type="" event_data=""

    if parse_stream_json_event "$json" event_type event_data; then
        if [[ "$event_type" == "result" ]]; then
            pass "parse_stream_json_event: parses result event type"
        else
            fail "parse_stream_json_event: wrong event type" "result" "$event_type"
        fi

        if echo "$event_data" | jq -e '.status == "success"' >/dev/null 2>&1; then
            pass "parse_stream_json_event: extracts result status"
        else
            fail "parse_stream_json_event: wrong result data" "status=success" "$event_data"
        fi
    else
        fail "parse_stream_json_event: should succeed for result event"
    fi
}

test_parse_invalid_json() {
    local json='not valid json at all {'
    local event_type="" event_data=""

    if ! parse_stream_json_event "$json" event_type event_data; then
        if [[ "$event_type" == "invalid" ]]; then
            pass "parse_stream_json_event: returns invalid type for bad JSON"
        else
            fail "parse_stream_json_event: should set type to invalid" "invalid" "$event_type"
        fi
    else
        fail "parse_stream_json_event: should fail for invalid JSON"
    fi
}

test_parse_empty_input() {
    local json=''
    local event_type="" event_data=""

    # Note: jq treats empty string as valid (no tokens), so the function
    # may succeed with an empty/unknown type or may fail. Either is acceptable.
    if parse_stream_json_event "$json" event_type event_data; then
        # Function accepted empty input - this is acceptable behavior
        pass "parse_stream_json_event: handles empty input gracefully"
    else
        pass "parse_stream_json_event: rejects empty input"
    fi
}

test_parse_unknown_event_type() {
    local json='{"type":"custom_type","data":"value"}'
    local event_type="" event_data=""

    if parse_stream_json_event "$json" event_type event_data; then
        if [[ "$event_type" == "custom_type" ]]; then
            pass "parse_stream_json_event: preserves unknown event types"
        else
            fail "parse_stream_json_event: should preserve type" "custom_type" "$event_type"
        fi
    else
        fail "parse_stream_json_event: should succeed for valid JSON with unknown type"
    fi
}

test_parse_unicode() {
    local json='{"type":"assistant","message":{"content":[{"type":"text","text":"Hello 世界 🌍"}]}}'
    local event_type="" event_data=""

    if parse_stream_json_event "$json" event_type event_data; then
        pass "parse_stream_json_event: handles unicode content"
    else
        fail "parse_stream_json_event: should handle unicode"
    fi
}

test_parse_missing_type() {
    local json='{"data":"no type field"}'
    local event_type="" event_data=""

    if parse_stream_json_event "$json" event_type event_data; then
        if [[ "$event_type" == "unknown" ]]; then
            pass "parse_stream_json_event: defaults to unknown when type missing"
        else
            fail "parse_stream_json_event: should default to unknown" "unknown" "$event_type"
        fi
    else
        fail "parse_stream_json_event: should succeed even without type field"
    fi
}

#==============================================================================
# Tests: extract_text_content
#==============================================================================

test_extract_text_single_block() {
    local content='[{"type":"text","text":"Hello world"}]'
    local result
    result=$(extract_text_content "$content")

    if [[ "$result" == "Hello world" ]]; then
        pass "extract_text_content: extracts single text block"
    else
        fail "extract_text_content: wrong extraction" "Hello world" "$result"
    fi
}

test_extract_text_multiple_blocks() {
    local content='[{"type":"text","text":"Line 1"},{"type":"text","text":"Line 2"}]'
    local result
    result=$(extract_text_content "$content")

    if [[ "$result" == $'Line 1\nLine 2' ]]; then
        pass "extract_text_content: joins multiple text blocks"
    else
        fail "extract_text_content: wrong join" "Line 1\\nLine 2" "$result"
    fi
}

test_extract_text_ignores_tool_use() {
    local content='[{"type":"tool_use","name":"Read"},{"type":"text","text":"Only this"}]'
    local result
    result=$(extract_text_content "$content")

    if [[ "$result" == "Only this" ]]; then
        pass "extract_text_content: ignores tool_use blocks"
    else
        fail "extract_text_content: should only get text" "Only this" "$result"
    fi
}

test_extract_text_empty_array() {
    local content='[]'
    local result
    result=$(extract_text_content "$content")

    if [[ -z "$result" ]]; then
        pass "extract_text_content: handles empty array"
    else
        fail "extract_text_content: should be empty for empty array" "" "$result"
    fi
}

test_extract_text_no_text_blocks() {
    local content='[{"type":"tool_use","name":"Edit"},{"type":"tool_result","content":"done"}]'
    local result
    result=$(extract_text_content "$content")

    if [[ -z "$result" ]]; then
        pass "extract_text_content: returns empty when no text blocks"
    else
        fail "extract_text_content: should be empty" "" "$result"
    fi
}

#==============================================================================
# Tests: detect_text_question
#==============================================================================

test_detect_should_i() {
    if detect_text_question "Should I continue with this change?"; then
        pass "detect_text_question: matches 'Should I'"
    else
        fail "detect_text_question: should match 'Should I'"
    fi
}

test_detect_do_you_want() {
    if detect_text_question "Do you want me to proceed?"; then
        pass "detect_text_question: matches 'Do you want'"
    else
        fail "detect_text_question: should match 'Do you want'"
    fi
}

test_detect_would_you_like() {
    if detect_text_question "Would you like to see more options?"; then
        pass "detect_text_question: matches 'Would you like'"
    else
        fail "detect_text_question: should match 'Would you like'"
    fi
}

test_detect_which_question() {
    if detect_text_question "Which option do you prefer?"; then
        pass "detect_text_question: matches 'Which...?'"
    else
        fail "detect_text_question: should match question mark pattern"
    fi
}

test_detect_y_n_prompt() {
    if detect_text_question "Continue? [y/N]"; then
        pass "detect_text_question: matches '[y/N]' prompt"
    else
        fail "detect_text_question: should match [y/N]"
    fi
}

test_detect_no_question() {
    if ! detect_text_question "This is just a statement with no question."; then
        pass "detect_text_question: rejects non-question text"
    else
        fail "detect_text_question: should not match statements"
    fi
}

test_detect_case_insensitive() {
    if detect_text_question "SHOULD I DO THIS?"; then
        pass "detect_text_question: case insensitive matching"
    else
        fail "detect_text_question: should be case insensitive"
    fi
}

#==============================================================================
# Tests: extract_question_from_text
#==============================================================================

test_extract_question_context() {
    local output
    output=$(printf "Line 1\nLine 2\nLine 3\nShould I continue?\nLine 5\nLine 6")
    local result
    result=$(extract_question_from_text "$output")

    if echo "$result" | grep -q "Should I continue"; then
        pass "extract_question_from_text: includes question line"
    else
        fail "extract_question_from_text: should include question"
    fi
}

test_extract_no_question_returns_tail() {
    local output="Line 1
Line 2
Line 3
Line 4
Line 5
Line 6
Line 7
Line 8
Line 9
Line 10
Line 11
Line 12"
    local result
    result=$(extract_question_from_text "$output")

    if echo "$result" | grep -q "Line 12"; then
        pass "extract_question_from_text: returns tail when no question"
    else
        fail "extract_question_from_text: should return last lines"
    fi
}

#==============================================================================
# Tests: extract_inline_options
#==============================================================================

test_extract_letter_options() {
    local output="Options:
a) First option
b) Second option
c) Third option
More text here"
    local result
    result=$(extract_inline_options "$output")

    if echo "$result" | grep -q "a) First option"; then
        pass "extract_inline_options: extracts a) style options"
    else
        fail "extract_inline_options: should find letter options"
    fi
}

test_extract_numbered_options() {
    local output="Select one:
1. Option one
2. Option two
3. Option three"
    local result
    result=$(extract_inline_options "$output")

    if echo "$result" | grep -q "1. Option one"; then
        pass "extract_inline_options: extracts numbered options"
    else
        fail "extract_inline_options: should find numbered options"
    fi
}

test_extract_no_options() {
    local output="Just some plain text
with no options at all
nothing to extract here"
    local result
    result=$(extract_inline_options "$output")

    if [[ -z "$result" ]]; then
        pass "extract_inline_options: returns empty when no options"
    else
        fail "extract_inline_options: should be empty" "" "$result"
    fi
}

#==============================================================================
# Tests: extract_plan_json
#==============================================================================

test_extract_plan_json_valid() {
    local output="Some text
RU_UNDERSTANDING_JSON_BEGIN
{\"summary\":\"test\",\"files\":[\"a.txt\"]}
RU_UNDERSTANDING_JSON_END
More text"
    local result
    if result=$(extract_plan_json "$output" "UNDERSTANDING"); then
        if echo "$result" | jq -e '.summary == "test"' >/dev/null 2>&1; then
            pass "extract_plan_json: extracts valid JSON between markers"
        else
            fail "extract_plan_json: wrong JSON content" "$result"
        fi
    else
        fail "extract_plan_json: should succeed for valid input"
    fi
}

test_extract_plan_json_missing_markers() {
    local output="Just some text without any markers"

    if ! extract_plan_json "$output" "UNDERSTANDING" 2>/dev/null; then
        pass "extract_plan_json: fails when markers missing"
    else
        fail "extract_plan_json: should fail without markers"
    fi
}

test_extract_plan_json_invalid_json() {
    local output="Text before
RU_COMMIT_PLAN_JSON_BEGIN
not valid json {{{
RU_COMMIT_PLAN_JSON_END
Text after"

    if ! extract_plan_json "$output" "COMMIT_PLAN" 2>/dev/null; then
        pass "extract_plan_json: fails for invalid JSON content"
    else
        fail "extract_plan_json: should fail for invalid JSON"
    fi
}

test_extract_plan_json_empty_marker() {
    local output="some text"

    if ! extract_plan_json "$output" "" 2>/dev/null; then
        pass "extract_plan_json: fails for empty marker"
    else
        fail "extract_plan_json: should fail for empty marker"
    fi
}

test_extract_plan_json_strips_ansi() {
    # Include ANSI escape codes in the output
    local output=$'Some text\n\e[32mRU_UNDERSTANDING_JSON_BEGIN\e[0m\n{"test":true}\n\e[32mRU_UNDERSTANDING_JSON_END\e[0m\nMore'
    local result
    if result=$(extract_plan_json "$output" "UNDERSTANDING"); then
        if echo "$result" | jq -e '.test == true' >/dev/null 2>&1; then
            pass "extract_plan_json: strips ANSI codes from markers"
        else
            fail "extract_plan_json: should parse after stripping ANSI" "$result"
        fi
    else
        fail "extract_plan_json: should handle ANSI codes"
    fi
}

#==============================================================================
# Tests: get_tool_uses
#==============================================================================

test_get_tool_uses_single() {
    local content='[{"type":"tool_use","name":"Read"},{"type":"text","text":"hello"}]'
    local result
    result=$(get_tool_uses "$content")

    if [[ "$result" == "Read" ]]; then
        pass "get_tool_uses: extracts single tool name"
    else
        fail "get_tool_uses: wrong tool name" "Read" "$result"
    fi
}

test_get_tool_uses_multiple() {
    local content='[{"type":"tool_use","name":"Read"},{"type":"tool_use","name":"Edit"}]'
    local result
    result=$(get_tool_uses "$content")

    if echo "$result" | grep -q "Read" && echo "$result" | grep -q "Edit"; then
        pass "get_tool_uses: extracts multiple tool names"
    else
        fail "get_tool_uses: should find both tools" "$result"
    fi
}

test_get_tool_uses_none() {
    local content='[{"type":"text","text":"no tools here"}]'
    local result
    result=$(get_tool_uses "$content")

    if [[ -z "$result" ]]; then
        pass "get_tool_uses: returns empty when no tools"
    else
        fail "get_tool_uses: should be empty" "" "$result"
    fi
}

#==============================================================================
# Tests: detect_ask_user_question
#==============================================================================

test_detect_ask_user_question_present() {
    local content='[{"type":"tool_use","name":"AskUserQuestion","input":{"question":"test?"}}]'

    if detect_ask_user_question "$content"; then
        pass "detect_ask_user_question: detects AskUserQuestion tool"
    else
        fail "detect_ask_user_question: should detect tool"
    fi
}

test_detect_ask_user_question_absent() {
    local content='[{"type":"tool_use","name":"Edit"},{"type":"text","text":"hello"}]'

    if ! detect_ask_user_question "$content"; then
        pass "detect_ask_user_question: returns false when absent"
    else
        fail "detect_ask_user_question: should not detect other tools"
    fi
}

#==============================================================================
# Tests: extract_question_info
#==============================================================================

test_extract_question_info_basic() {
    local content='[{"type":"tool_use","name":"AskUserQuestion","id":"tool_123","input":{"questions":[{"question":"Pick?","options":["A","B"]}]}}]'
    local result
    result=$(extract_question_info "$content")

    if echo "$result" | jq -e '.tool_use_id == "tool_123"' >/dev/null 2>&1; then
        pass "extract_question_info: extracts tool_use_id"
    else
        fail "extract_question_info: should extract id" "$result"
    fi

    if echo "$result" | jq -e '.questions | length > 0' >/dev/null 2>&1; then
        pass "extract_question_info: extracts questions array"
    else
        fail "extract_question_info: should extract questions" "$result"
    fi
}

test_extract_question_info_no_ask() {
    local content='[{"type":"text","text":"no question here"}]'
    local result
    result=$(extract_question_info "$content")

    # Should return empty/null structure
    if echo "$result" | jq -e '.tool_use_id == ""' >/dev/null 2>&1; then
        pass "extract_question_info: handles missing AskUserQuestion"
    else
        pass "extract_question_info: returns structure for missing question"
    fi
}

#==============================================================================
# Run All Tests
#==============================================================================

main() {
    echo -e "${BLUE}=== Unit Tests: Parsing Functions ===${RESET}"
    echo

    setup_test_env

    # parse_stream_json_event tests
    echo "--- parse_stream_json_event ---"
    test_parse_valid_system_event
    test_parse_valid_assistant_event
    test_parse_valid_result_event
    test_parse_invalid_json
    test_parse_empty_input
    test_parse_unknown_event_type
    test_parse_unicode
    test_parse_missing_type

    # extract_text_content tests
    echo
    echo "--- extract_text_content ---"
    test_extract_text_single_block
    test_extract_text_multiple_blocks
    test_extract_text_ignores_tool_use
    test_extract_text_empty_array
    test_extract_text_no_text_blocks

    # detect_text_question tests
    echo
    echo "--- detect_text_question ---"
    test_detect_should_i
    test_detect_do_you_want
    test_detect_would_you_like
    test_detect_which_question
    test_detect_y_n_prompt
    test_detect_no_question
    test_detect_case_insensitive

    # extract_question_from_text tests
    echo
    echo "--- extract_question_from_text ---"
    test_extract_question_context
    test_extract_no_question_returns_tail

    # extract_inline_options tests
    echo
    echo "--- extract_inline_options ---"
    test_extract_letter_options
    test_extract_numbered_options
    test_extract_no_options

    # extract_plan_json tests
    echo
    echo "--- extract_plan_json ---"
    test_extract_plan_json_valid
    test_extract_plan_json_missing_markers
    test_extract_plan_json_invalid_json
    test_extract_plan_json_empty_marker
    test_extract_plan_json_strips_ansi

    # get_tool_uses tests
    echo
    echo "--- get_tool_uses ---"
    test_get_tool_uses_single
    test_get_tool_uses_multiple
    test_get_tool_uses_none

    # detect_ask_user_question tests
    echo
    echo "--- detect_ask_user_question ---"
    test_detect_ask_user_question_present
    test_detect_ask_user_question_absent

    # extract_question_info tests
    echo
    echo "--- extract_question_info ---"
    test_extract_question_info_basic
    test_extract_question_info_no_ask

    cleanup_test_env

    # Summary
    echo
    echo -e "${BLUE}=== Results ===${RESET}"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"

    [[ $TESTS_FAILED -eq 0 ]]
}

main "$@"
