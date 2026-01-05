#!/usr/bin/env bash
#
# Unit tests: Stream-JSON event parsing
# (parse_stream_json_event, detect_ask_user_question, extract_question_info, etc.)
#
# Tests parsing of Claude Code's --output-format stream-json NDJSON output.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source helpers
source_ru_function "json_escape"

# Mock log functions for testing
log_warn() { :; }
log_error() { :; }
log_info() { :; }
log_verbose() { :; }

#==============================================================================
# Stream-JSON Parsing Functions (from ru script)
#==============================================================================

# Use namerefs to avoid variable shadowing when caller passes "event_type"
# as output variable name (same as current ru implementation)
parse_stream_json_event() {
    local line="$1"
    local -n _pse_event_type=$2
    local -n _pse_event_data=$3

    if ! echo "$line" | jq empty 2>/dev/null; then
        _pse_event_type="invalid"
        _pse_event_data="$line"
        return 1
    fi

    _pse_event_type=$(echo "$line" | jq -r '.type // "unknown"')

    case "$_pse_event_type" in
        system)
            local subtype
            subtype=$(echo "$line" | jq -r '.subtype // ""')
            if [[ "$subtype" == "init" ]]; then
                _pse_event_data=$(echo "$line" | jq -c '{session_id, tools, cwd}')
            else
                _pse_event_data=$(echo "$line" | jq -c '.')
            fi
            ;;
        assistant)
            _pse_event_data=$(echo "$line" | jq -c '.message.content // []')
            ;;
        user)
            _pse_event_data=$(echo "$line" | jq -c '.message.content // []')
            ;;
        result)
            _pse_event_data=$(echo "$line" | jq -c '{status, duration_ms, session_id, cost_usd}')
            ;;
        *)
            _pse_event_data="$line"
            ;;
    esac

    return 0
}

detect_ask_user_question() {
    local event_data="$1"
    echo "$event_data" | jq -e \
        '.[] | select(.type == "tool_use" and .name == "AskUserQuestion")' \
        >/dev/null 2>&1
}

extract_question_info() {
    local event_data="$1"
    local question_input
    question_input=$(echo "$event_data" | jq -c \
        '[.[] | select(.name == "AskUserQuestion")] | .[0].input // {}')
    local tool_use_id
    tool_use_id=$(echo "$event_data" | jq -r \
        '[.[] | select(.name == "AskUserQuestion")] | .[0].id // ""')
    echo "$question_input" | jq --arg tool_id "$tool_use_id" '{
        questions: .questions,
        tool_use_id: $tool_id,
        detected_at: (now | todate)
    }'
}

detect_text_question() {
    local text="$1"
    local -a patterns=(
        'Should I'
        'Do you want'
        'Would you like'
        'Please confirm'
        'Choose.*:'
        'Which.*\?'
        'What.*\?'
        'How should'
        '\[y/N\]'
        '\[Y/n\]'
        'Enter.*:'
        'Press.*to'
    )
    for pattern in "${patterns[@]}"; do
        if echo "$text" | grep -qiE "$pattern"; then
            return 0
        fi
    done
    return 1
}

extract_text_content() {
    local event_data="$1"
    echo "$event_data" | jq -r \
        '[.[] | select(.type == "text") | .text] | join("\n")'
}

get_tool_uses() {
    local event_data="$1"
    echo "$event_data" | jq -r \
        '[.[] | select(.type == "tool_use") | .name] | .[]'
}

#==============================================================================
# Test Fixtures
#==============================================================================

SYSTEM_INIT_EVENT='{"type":"system","subtype":"init","session_id":"test-123","tools":["Read","Write","Edit","Bash"]}'

ASSISTANT_TEXT_EVENT='{"type":"assistant","message":{"content":[{"type":"text","text":"I will analyze the code."}]}}'

ASSISTANT_TOOL_USE_EVENT='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_123","name":"Read","input":{"file_path":"/src/main.py"}}]}}'

ASK_USER_QUESTION_EVENT='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_456","name":"AskUserQuestion","input":{"questions":[{"question":"Should I refactor the auth module?","header":"Approach","options":[{"label":"Quick fix","description":"Fix only this bug"},{"label":"Full refactor","description":"Modernize entire module"}],"multiSelect":false}]}}]}}'

TOOL_RESULT_EVENT='{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_123","content":"file contents here"}]}}'

RESULT_EVENT='{"type":"result","status":"success","duration_ms":45000,"session_id":"test-123","cost_usd":0.05}'

#==============================================================================
# Tests: parse_stream_json_event
#==============================================================================

test_parse_invalid_json() {
    local test_name="parse_stream_json_event: rejects invalid JSON"
    log_test_start "$test_name"

    local event_type="" event_data=""
    if parse_stream_json_event "not valid json {" event_type event_data; then
        fail "Should return non-zero for invalid JSON"
    else
        pass "Should return non-zero for invalid JSON"
    fi
    assert_equals "invalid" "$event_type" "Event type should be 'invalid'"

    log_test_pass "$test_name"
}

test_parse_system_init() {
    local test_name="parse_stream_json_event: parses system init event"
    log_test_start "$test_name"

    local event_type="" event_data=""
    parse_stream_json_event "$SYSTEM_INIT_EVENT" event_type event_data

    assert_equals "system" "$event_type" "Event type should be 'system'"

    local session_id
    session_id=$(echo "$event_data" | jq -r '.session_id')
    assert_equals "test-123" "$session_id" "Session ID should be extracted"

    log_test_pass "$test_name"
}

test_parse_assistant_text() {
    local test_name="parse_stream_json_event: parses assistant text event"
    log_test_start "$test_name"

    local event_type="" event_data=""
    parse_stream_json_event "$ASSISTANT_TEXT_EVENT" event_type event_data

    assert_equals "assistant" "$event_type" "Event type should be 'assistant'"

    local text
    text=$(echo "$event_data" | jq -r '.[0].text')
    assert_contains "$text" "analyze" "Should contain text content"

    log_test_pass "$test_name"
}

test_parse_result() {
    local test_name="parse_stream_json_event: parses result event"
    log_test_start "$test_name"

    local event_type="" event_data=""
    parse_stream_json_event "$RESULT_EVENT" event_type event_data

    assert_equals "result" "$event_type" "Event type should be 'result'"

    local status
    status=$(echo "$event_data" | jq -r '.status')
    assert_equals "success" "$status" "Status should be 'success'"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: detect_ask_user_question
#==============================================================================

test_detect_ask_user_question_found() {
    local test_name="detect_ask_user_question: detects AskUserQuestion"
    log_test_start "$test_name"

    local event_type="" event_data=""
    parse_stream_json_event "$ASK_USER_QUESTION_EVENT" event_type event_data

    if detect_ask_user_question "$event_data"; then
        pass "Should detect AskUserQuestion tool use"
    else
        fail "Should detect AskUserQuestion tool use"
    fi

    log_test_pass "$test_name"
}

test_detect_ask_user_question_not_found() {
    local test_name="detect_ask_user_question: returns false for regular tool"
    log_test_start "$test_name"

    local event_type="" event_data=""
    parse_stream_json_event "$ASSISTANT_TOOL_USE_EVENT" event_type event_data

    if detect_ask_user_question "$event_data"; then
        fail "Should not detect AskUserQuestion in regular tool use"
    else
        pass "Should not detect AskUserQuestion in regular tool use"
    fi

    log_test_pass "$test_name"
}

test_detect_ask_user_question_text() {
    local test_name="detect_ask_user_question: returns false for text only"
    log_test_start "$test_name"

    local event_type="" event_data=""
    parse_stream_json_event "$ASSISTANT_TEXT_EVENT" event_type event_data

    if detect_ask_user_question "$event_data"; then
        fail "Should not detect AskUserQuestion in text-only message"
    else
        pass "Should not detect AskUserQuestion in text-only message"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: extract_question_info
#==============================================================================

test_extract_question_info() {
    local test_name="extract_question_info: extracts question details"
    log_test_start "$test_name"

    local event_type="" event_data=""
    parse_stream_json_event "$ASK_USER_QUESTION_EVENT" event_type event_data

    local question_info
    question_info=$(extract_question_info "$event_data")

    # Verify JSON is valid
    if ! echo "$question_info" | jq empty 2>/dev/null; then
        fail "Should produce valid JSON"
    fi

    local tool_id question_text
    tool_id=$(echo "$question_info" | jq -r '.tool_use_id')
    question_text=$(echo "$question_info" | jq -r '.questions[0].question')

    assert_equals "toolu_456" "$tool_id" "Should extract tool_use_id"
    assert_contains "$question_text" "refactor" "Should extract question text"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: detect_text_question
#==============================================================================

test_detect_text_question_should_i() {
    local test_name="detect_text_question: detects 'Should I' pattern"
    log_test_start "$test_name"

    if detect_text_question "Should I refactor this code?"; then
        pass "Should detect 'Should I' pattern"
    else
        fail "Should detect 'Should I' pattern"
    fi

    log_test_pass "$test_name"
}

test_detect_text_question_y_n() {
    local test_name="detect_text_question: detects [y/N] pattern"
    log_test_start "$test_name"

    if detect_text_question "Continue with this change? [y/N]"; then
        pass "Should detect [y/N] pattern"
    else
        fail "Should detect [y/N] pattern"
    fi

    log_test_pass "$test_name"
}

test_detect_text_question_no_pattern() {
    local test_name="detect_text_question: returns false for non-question"
    log_test_start "$test_name"

    if detect_text_question "I am analyzing the codebase now."; then
        fail "Should not detect question in statement"
    else
        pass "Should not detect question in statement"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: extract_text_content
#==============================================================================

test_extract_text_content() {
    local test_name="extract_text_content: extracts text from message"
    log_test_start "$test_name"

    local event_type="" event_data=""
    parse_stream_json_event "$ASSISTANT_TEXT_EVENT" event_type event_data

    local text
    text=$(extract_text_content "$event_data")

    assert_contains "$text" "analyze" "Should extract text content"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: get_tool_uses
#==============================================================================

test_get_tool_uses() {
    local test_name="get_tool_uses: lists tools used"
    log_test_start "$test_name"

    local event_type="" event_data=""
    parse_stream_json_event "$ASSISTANT_TOOL_USE_EVENT" event_type event_data

    local tools
    tools=$(get_tool_uses "$event_data")

    assert_equals "Read" "$tools" "Should list tool names"

    log_test_pass "$test_name"
}

test_get_tool_uses_ask_user() {
    local test_name="get_tool_uses: includes AskUserQuestion"
    log_test_start "$test_name"

    local event_type="" event_data=""
    parse_stream_json_event "$ASK_USER_QUESTION_EVENT" event_type event_data

    local tools
    tools=$(get_tool_uses "$event_data")

    assert_equals "AskUserQuestion" "$tools" "Should list AskUserQuestion"

    log_test_pass "$test_name"
}

#==============================================================================
# Main
#==============================================================================

run_all_tests() {
    log_suite_start "Stream-JSON Event Parsing"

    # parse_stream_json_event tests
    run_test test_parse_invalid_json
    run_test test_parse_system_init
    run_test test_parse_assistant_text
    run_test test_parse_result

    # detect_ask_user_question tests
    run_test test_detect_ask_user_question_found
    run_test test_detect_ask_user_question_not_found
    run_test test_detect_ask_user_question_text

    # extract_question_info tests
    run_test test_extract_question_info

    # detect_text_question tests
    run_test test_detect_text_question_should_i
    run_test test_detect_text_question_y_n
    run_test test_detect_text_question_no_pattern

    # extract_text_content tests
    run_test test_extract_text_content

    # get_tool_uses tests
    run_test test_get_tool_uses
    run_test test_get_tool_uses_ask_user

    print_results
    return $TF_TESTS_FAILED
}

run_all_tests
