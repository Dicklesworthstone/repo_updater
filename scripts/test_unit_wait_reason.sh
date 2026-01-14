#!/usr/bin/env bash
#
# Unit tests: Wait Reason Detection (bd-4ps0)
# Tests for detect_external_prompt, classify_external_prompt_risk,
# detect_wait_reason, format_wait_info, etc.
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
# Wait Reason Detection Functions (from ru script)
#==============================================================================

detect_external_prompt() {
    local output="$1"

    local -a patterns=(
        'CONFLICT.*Merge conflict'
        'Please enter.*commit message'
        'Enter passphrase'
        'Password:'
        '\(yes/no\)'
        '\(yes/no/\[fingerprint\]\)'
        'error: cannot pull with rebase'
        'Username for'
        'gh auth login'
        'fatal: could not read'
        'Permission denied'
        'Are you sure you want to continue connecting'
        'Host key verification failed'
        'Authentication failed'
        'Error: authentication required'
        'npm login'
        'Enter OTP'
        'Two-factor authentication'
    )

    for pattern in "${patterns[@]}"; do
        if echo "$output" | grep -qE "$pattern"; then
            echo "$pattern"
            return 0
        fi
    done

    return 1
}

classify_external_prompt_risk() {
    local prompt="$1"

    local lower
    lower=$(echo "$prompt" | tr '[:upper:]' '[:lower:]')

    # High risk: credentials, auth, security
    if echo "$lower" | grep -qE 'password|passphrase|credential|auth|token|otp|two-factor|permission denied|authentication'; then
        echo "high"
        return
    fi

    # Medium risk: merge conflicts, host verification
    if echo "$lower" | grep -qE 'conflict|merge|rebase|overwrite|delete|host key|fingerprint|yes/no'; then
        echo "medium"
        return
    fi

    # Low risk: informational prompts
    echo "low"
}

extract_question_from_text() {
    local output="$1"

    local question_line
    question_line=$(echo "$output" | grep -nE 'Should I|Do you want|Would you|Which.*\?|What.*\?|How should' | tail -1)

    if [[ -n "$question_line" ]]; then
        local line_num="${question_line%%:*}"
        local start=$((line_num - 5))
        [[ $start -lt 1 ]] && start=1
        local end=$((line_num + 2))
        echo "$output" | sed -n "${start},${end}p"
    else
        echo "$output" | tail -10
    fi
}

extract_inline_options() {
    local output="$1"
    echo "$output" | grep -E '^[[:space:]]*[a-z]\)|^[[:space:]]*[0-9]+\.|^[[:space:]]*-[[:space:]]+[A-Z]' | head -5
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

format_wait_info() {
    local reason="$1"
    local context="$2"
    local options="${3:-}"
    local risk_level="${4:-low}"

    if echo "$context" | jq empty 2>/dev/null; then
        jq -n \
            --arg reason "$reason" \
            --argjson context "$context" \
            --arg options "$options" \
            --arg risk "$risk_level" \
            '{
                reason: $reason,
                context: $context,
                options: ($options | split("\n") | map(select(. != ""))),
                risk_level: $risk,
                detected_at: (now | todate)
            }'
    else
        jq -n \
            --arg reason "$reason" \
            --arg context "$context" \
            --arg options "$options" \
            --arg risk "$risk_level" \
            '{
                reason: $reason,
                context: $context,
                options: ($options | split("\n") | map(select(. != ""))),
                risk_level: $risk,
                detected_at: (now | todate)
            }'
    fi
}

detect_wait_reason() {
    local session_id="$1"
    local event_data="${2:-}"
    local output="${3:-}"

    local reason="unknown"
    local context=""
    local options=""
    local risk_level="low"

    if [[ -n "$event_data" ]] && detect_ask_user_question "$event_data"; then
        reason="ask_user_question"
        context=$(extract_question_info "$event_data")
        format_wait_info "$reason" "$context" "" "low"
        return 0
    fi

    local ext_prompt
    if [[ -n "$output" ]]; then
        if ext_prompt=$(detect_external_prompt "$output"); then
            reason="external_prompt"
            context="$ext_prompt"
            risk_level=$(classify_external_prompt_risk "$ext_prompt")
            format_wait_info "$reason" "$context" "" "$risk_level"
            return 0
        fi

        if detect_text_question "$output"; then
            reason="agent_question_text"
            context=$(extract_question_from_text "$output")
            options=$(extract_inline_options "$output")
            format_wait_info "$reason" "$context" "$options" "low"
            return 0
        fi
    fi

    if [[ -n "$output" ]]; then
        context=$(echo "$output" | tail -10)
    fi
    format_wait_info "$reason" "$context" "" "$risk_level"
    return 0
}

#==============================================================================
# Test Fixtures
#==============================================================================

GIT_MERGE_CONFLICT="Auto-merging src/app.py
CONFLICT (content): Merge conflict in src/app.py
Automatic merge failed; fix conflicts and then commit the result."

SSH_PASSWORD_PROMPT="The authenticity of host 'github.com (192.30.253.113)' can't be established.
ED25519 key fingerprint is SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU.
This key is not known by any other names.
Are you sure you want to continue connecting (yes/no/[fingerprint])?"

PASSWORD_PROMPT="Password:"

GH_AUTH_PROMPT="! First copy your one-time code: XXXX-XXXX
- Press Enter to open github.com in your browser..."

TEXT_QUESTION="I found multiple implementations of this function.

Should I refactor all of them to use a common interface, or
just fix the specific bug in the main implementation?"

TEXT_WITH_OPTIONS="Which approach would you prefer?

a) Quick fix - just patch the immediate issue
b) Partial refactor - fix the bug and clean up related code
c) Full refactor - rewrite the entire module
- Default: Quick fix"

ASK_USER_QUESTION_DATA='[{"type":"tool_use","id":"toolu_123","name":"AskUserQuestion","input":{"questions":[{"question":"Should I continue?","header":"Action","options":[{"label":"Yes","description":"Continue"},{"label":"No","description":"Stop"}],"multiSelect":false}]}}]'

PLAIN_ASSISTANT_DATA='[{"type":"text","text":"I am analyzing the code now."}]'

#==============================================================================
# Tests: detect_external_prompt
#==============================================================================

test_detect_external_prompt_merge_conflict() {
    local test_name="detect_external_prompt: detects merge conflict"
    log_test_start "$test_name"

    local result
    if result=$(detect_external_prompt "$GIT_MERGE_CONFLICT"); then
        pass "Should detect merge conflict"
        assert_contains "$result" "CONFLICT" "Should return matched pattern"
    else
        fail "Should detect merge conflict"
    fi

    log_test_pass "$test_name"
}

test_detect_external_prompt_ssh() {
    local test_name="detect_external_prompt: detects SSH fingerprint prompt"
    log_test_start "$test_name"

    local result
    if result=$(detect_external_prompt "$SSH_PASSWORD_PROMPT"); then
        pass "Should detect SSH prompt"
    else
        fail "Should detect SSH prompt"
    fi

    log_test_pass "$test_name"
}

test_detect_external_prompt_password() {
    local test_name="detect_external_prompt: detects password prompt"
    log_test_start "$test_name"

    local result
    if result=$(detect_external_prompt "$PASSWORD_PROMPT"); then
        pass "Should detect password prompt"
    else
        fail "Should detect password prompt"
    fi

    log_test_pass "$test_name"
}

test_detect_external_prompt_none() {
    local test_name="detect_external_prompt: returns false for regular output"
    log_test_start "$test_name"

    if detect_external_prompt "Just some normal output from a program"; then
        fail "Should not detect external prompt in normal output"
    else
        pass "Should not detect external prompt in normal output"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: classify_external_prompt_risk
#==============================================================================

test_classify_risk_high_password() {
    local test_name="classify_external_prompt_risk: password is high risk"
    log_test_start "$test_name"

    local risk
    risk=$(classify_external_prompt_risk "Password:")
    assert_equals "high" "$risk" "Password should be high risk"

    log_test_pass "$test_name"
}

test_classify_risk_high_auth() {
    local test_name="classify_external_prompt_risk: authentication is high risk"
    log_test_start "$test_name"

    local risk
    risk=$(classify_external_prompt_risk "Authentication failed")
    assert_equals "high" "$risk" "Authentication should be high risk"

    log_test_pass "$test_name"
}

test_classify_risk_medium_conflict() {
    local test_name="classify_external_prompt_risk: merge conflict is medium risk"
    log_test_start "$test_name"

    local risk
    risk=$(classify_external_prompt_risk "CONFLICT.*Merge conflict")
    assert_equals "medium" "$risk" "Merge conflict should be medium risk"

    log_test_pass "$test_name"
}

test_classify_risk_medium_yesno() {
    local test_name="classify_external_prompt_risk: yes/no prompt is medium risk"
    log_test_start "$test_name"

    local risk
    risk=$(classify_external_prompt_risk "(yes/no)")
    assert_equals "medium" "$risk" "Yes/no prompt should be medium risk"

    log_test_pass "$test_name"
}

test_classify_risk_low() {
    local test_name="classify_external_prompt_risk: unknown prompt is low risk"
    log_test_start "$test_name"

    local risk
    risk=$(classify_external_prompt_risk "Some other prompt")
    assert_equals "low" "$risk" "Unknown prompt should be low risk"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: extract_question_from_text
#==============================================================================

test_extract_question_context() {
    local test_name="extract_question_from_text: extracts context"
    log_test_start "$test_name"

    local context
    context=$(extract_question_from_text "$TEXT_QUESTION")

    assert_contains "$context" "Should I" "Should include question"
    assert_contains "$context" "refactor" "Should include context"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: extract_inline_options
#==============================================================================

test_extract_inline_options() {
    local test_name="extract_inline_options: extracts a) b) c) options"
    log_test_start "$test_name"

    local options
    options=$(extract_inline_options "$TEXT_WITH_OPTIONS")

    assert_contains "$options" "Quick fix" "Should extract option a"
    assert_contains "$options" "Partial refactor" "Should extract option b"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: format_wait_info
#==============================================================================

test_format_wait_info_text() {
    local test_name="format_wait_info: formats text context"
    log_test_start "$test_name"

    local result
    result=$(format_wait_info "agent_question_text" "Should I continue?" "" "low")

    if ! echo "$result" | jq empty 2>/dev/null; then
        fail "Should produce valid JSON"
    fi

    local reason
    reason=$(echo "$result" | jq -r '.reason')
    assert_equals "agent_question_text" "$reason" "Should include reason"

    local risk
    risk=$(echo "$result" | jq -r '.risk_level')
    assert_equals "low" "$risk" "Should include risk level"

    log_test_pass "$test_name"
}

test_format_wait_info_json_context() {
    local test_name="format_wait_info: handles JSON context"
    log_test_start "$test_name"

    local json_context='{"questions":[{"question":"Test?"}]}'
    local result
    result=$(format_wait_info "ask_user_question" "$json_context" "" "low")

    if ! echo "$result" | jq empty 2>/dev/null; then
        fail "Should produce valid JSON"
    fi

    local question
    question=$(echo "$result" | jq -r '.context.questions[0].question')
    assert_equals "Test?" "$question" "Should embed JSON context"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: detect_wait_reason
#==============================================================================

test_detect_wait_reason_ask_user() {
    local test_name="detect_wait_reason: prioritizes AskUserQuestion"
    log_test_start "$test_name"

    local result
    result=$(detect_wait_reason "sess-123" "$ASK_USER_QUESTION_DATA" "$GIT_MERGE_CONFLICT")

    local reason
    reason=$(echo "$result" | jq -r '.reason')
    assert_equals "ask_user_question" "$reason" "Should detect AskUserQuestion first"

    log_test_pass "$test_name"
}

test_detect_wait_reason_external() {
    local test_name="detect_wait_reason: detects external prompt"
    log_test_start "$test_name"

    local result
    result=$(detect_wait_reason "sess-123" "" "$PASSWORD_PROMPT")

    local reason
    reason=$(echo "$result" | jq -r '.reason')
    assert_equals "external_prompt" "$reason" "Should detect external prompt"

    local risk
    risk=$(echo "$result" | jq -r '.risk_level')
    assert_equals "high" "$risk" "Password should be high risk"

    log_test_pass "$test_name"
}

test_detect_wait_reason_text_question() {
    local test_name="detect_wait_reason: detects text question"
    log_test_start "$test_name"

    local result
    result=$(detect_wait_reason "sess-123" "" "$TEXT_QUESTION")

    local reason
    reason=$(echo "$result" | jq -r '.reason')
    assert_equals "agent_question_text" "$reason" "Should detect text question"

    log_test_pass "$test_name"
}

test_detect_wait_reason_unknown() {
    local test_name="detect_wait_reason: returns unknown for unrecognized"
    log_test_start "$test_name"

    local result
    result=$(detect_wait_reason "sess-123" "" "Just regular output nothing special")

    local reason
    reason=$(echo "$result" | jq -r '.reason')
    assert_equals "unknown" "$reason" "Should return unknown"

    log_test_pass "$test_name"
}

test_detect_wait_reason_priority() {
    local test_name="detect_wait_reason: respects priority order"
    log_test_start "$test_name"

    # AskUserQuestion should win even if text also has question patterns
    local combined_output="$TEXT_QUESTION
$PASSWORD_PROMPT"

    local result
    result=$(detect_wait_reason "sess-123" "$ASK_USER_QUESTION_DATA" "$combined_output")

    local reason
    reason=$(echo "$result" | jq -r '.reason')
    assert_equals "ask_user_question" "$reason" "AskUserQuestion should have highest priority"

    log_test_pass "$test_name"
}

#==============================================================================
# Main
#==============================================================================

run_all_tests() {
    log_suite_start "Wait Reason Detection"

    # detect_external_prompt tests
    run_test test_detect_external_prompt_merge_conflict
    run_test test_detect_external_prompt_ssh
    run_test test_detect_external_prompt_password
    run_test test_detect_external_prompt_none

    # classify_external_prompt_risk tests
    run_test test_classify_risk_high_password
    run_test test_classify_risk_high_auth
    run_test test_classify_risk_medium_conflict
    run_test test_classify_risk_medium_yesno
    run_test test_classify_risk_low

    # extract_question_from_text tests
    run_test test_extract_question_context

    # extract_inline_options tests
    run_test test_extract_inline_options

    # format_wait_info tests
    run_test test_format_wait_info_text
    run_test test_format_wait_info_json_context

    # detect_wait_reason tests
    run_test test_detect_wait_reason_ask_user
    run_test test_detect_wait_reason_external
    run_test test_detect_wait_reason_text_question
    run_test test_detect_wait_reason_unknown
    run_test test_detect_wait_reason_priority

    print_results
    return "$(get_exit_code)"
}

run_all_tests
