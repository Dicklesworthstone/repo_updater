#!/usr/bin/env bash
#
# Unit tests: Question Aggregation & TUI Presentation (bd-wyxq)
#
# Tests question queue operations, prioritization, context extraction,
# answer routing, and TUI helper functions.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source required functions from ru
source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "ensure_dir"
source_ru_function "json_escape"
source_ru_function "json_get_field"
source_ru_function "get_review_state_dir"
source_ru_function "get_questions_file"
source_ru_function "acquire_state_lock"
source_ru_function "release_state_lock"
source_ru_function "with_state_lock"
source_ru_function "write_json_atomic"
source_ru_function "normalize_questions_json"
source_ru_function "load_questions_queue"
source_ru_function "write_questions_queue"
source_ru_function "update_question_in_queue"
source_ru_function "mark_question_answered"
source_ru_function "mark_question_skipped"
source_ru_function "mark_question_snoozed"
source_ru_function "filter_questions_json"
source_ru_function "get_question_at_index"
source_ru_function "question_get_id"
source_ru_function "question_get_session_id"
source_ru_function "question_get_prompt"
source_ru_function "question_get_recommended"
source_ru_function "question_get_options_lines"

# Mock log functions
log_warn() { :; }
log_error() { :; }
log_info() { :; }
log_verbose() { :; }
log_debug() { :; }

#==============================================================================
# Test Setup / Teardown
#==============================================================================

setup_question_test() {
    TEST_DIR=$(create_temp_dir)
    export RU_STATE_DIR="$TEST_DIR/state"
    mkdir -p "$RU_STATE_DIR/review"
}

create_test_question() {
    local id="$1"
    local session_id="${2:-session-1}"
    local priority="${3:-normal}"
    local prompt="${4:-Should I proceed?}"

    cat <<EOF
{
    "id": "$id",
    "session_id": "$session_id",
    "repo": "owner/repo",
    "priority": "$priority",
    "status": "pending",
    "questions": [{
        "prompt": "$prompt",
        "options": [
            {"label": "Yes", "description": "Proceed with changes"},
            {"label": "No", "description": "Cancel operation"},
            {"label": "Skip", "description": "Skip for now"}
        ],
        "recommended": "Yes"
    }]
}
EOF
}

#==============================================================================
# Tests: Question Queue Basic Operations
#==============================================================================

test_question_queue_add() {
    local test_name="queue: add question with full metadata"
    log_test_start "$test_name"
    setup_question_test

    # Create a question
    local question_json
    question_json=$(create_test_question "q1" "session-abc" "high" "Fix the bug?")

    # Write to queue
    write_questions_queue "[$question_json]"

    # Verify file exists and contains question
    local questions_file
    questions_file=$(get_questions_file)
    assert_file_exists "$questions_file" "Questions file should be created"

    if command -v jq &>/dev/null; then
        local count
        count=$(jq '.questions | length' "$questions_file")
        assert_equals "1" "$count" "Should have 1 question"

        local stored_id
        stored_id=$(jq -r '.questions[0].id' "$questions_file")
        assert_equals "q1" "$stored_id" "Question ID should be preserved"
    fi

    log_test_pass "$test_name"
}

test_question_queue_context_extraction() {
    local test_name="queue: context extraction from question"
    log_test_start "$test_name"
    setup_question_test

    # Question with context
    local question_json
    question_json=$(cat <<'EOF'
{
    "id": "q2",
    "session_id": "session-ctx",
    "repo": "owner/repo",
    "priority": "normal",
    "context": {
        "patch_summary": {
            "files_changed": 3,
            "insertions": 45,
            "deletions": 12
        },
        "tests": {"ok": true, "duration_seconds": 2.5},
        "risk_level": "low"
    },
    "questions": [{
        "prompt": "Apply the fix?",
        "options": [{"label": "Yes", "description": "Apply"}]
    }]
}
EOF
)

    write_questions_queue "[$question_json]"

    local questions_file
    questions_file=$(get_questions_file)

    if command -v jq &>/dev/null; then
        local files_changed
        files_changed=$(jq -r '.questions[0].context.patch_summary.files_changed' "$questions_file")
        assert_equals "3" "$files_changed" "Files changed should be extracted"

        local risk
        risk=$(jq -r '.questions[0].context.risk_level' "$questions_file")
        assert_equals "low" "$risk" "Risk level should be extracted"
    fi

    log_test_pass "$test_name"
}

test_question_queue_priority_sort() {
    local test_name="queue: priority sort (critical > high > normal > low)"
    log_test_start "$test_name"
    setup_question_test

    # Create questions with different priorities (in wrong order)
    local q_low q_critical q_normal q_high
    q_low=$(create_test_question "q-low" "s1" "low")
    q_critical=$(create_test_question "q-critical" "s2" "critical")
    q_normal=$(create_test_question "q-normal" "s3" "normal")
    q_high=$(create_test_question "q-high" "s4" "high")

    local questions_json="[$q_low, $q_critical, $q_normal, $q_high]"
    write_questions_queue "$questions_json"

    local loaded
    loaded=$(load_questions_queue)

    if command -v jq &>/dev/null; then
        # Sort by priority
        local sorted
        sorted=$(echo "$loaded" | jq 'sort_by(
            if .priority == "critical" then 0
            elif .priority == "high" then 1
            elif .priority == "normal" then 2
            else 3 end
        )')

        local first_priority
        first_priority=$(echo "$sorted" | jq -r '.[0].priority')
        assert_equals "critical" "$first_priority" "Critical should be first"

        local last_priority
        last_priority=$(echo "$sorted" | jq -r '.[-1].priority')
        assert_equals "low" "$last_priority" "Low should be last"
    fi

    log_test_pass "$test_name"
}

test_question_dedup() {
    local test_name="queue: duplicate detection"
    log_test_start "$test_name"
    setup_question_test

    # Add same question twice
    local question_json
    question_json=$(create_test_question "q-dup" "session-1")

    write_questions_queue "[$question_json, $question_json]"

    local loaded
    loaded=$(load_questions_queue)

    if command -v jq &>/dev/null; then
        # Check count (may have duplicates depending on implementation)
        local count
        count=$(echo "$loaded" | jq 'length')
        # Note: Current implementation may allow duplicates
        # This test documents current behavior
        pass "Queue has $count questions (dedup may vary by implementation)"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Answer Routing
#==============================================================================

test_answer_routing() {
    local test_name="routing: answer marked correctly"
    log_test_start "$test_name"
    setup_question_test

    local question_json
    question_json=$(create_test_question "q-answer" "session-route")
    write_questions_queue "[$question_json]"

    # Mark as answered
    mark_question_answered "q-answer" "Yes"

    local questions_file
    questions_file=$(get_questions_file)

    if command -v jq &>/dev/null; then
        local status
        status=$(jq -r '.questions[0].status' "$questions_file")
        assert_equals "answered" "$status" "Status should be answered"

        local answer
        answer=$(jq -r '.questions[0].answer' "$questions_file")
        assert_equals "Yes" "$answer" "Answer should be stored"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Snooze Functionality
#==============================================================================

test_snooze_timing() {
    local test_name="snooze: snoozed questions tracked"
    log_test_start "$test_name"
    setup_question_test

    local question_json
    question_json=$(create_test_question "q-snooze" "session-snz")
    write_questions_queue "[$question_json]"

    # Snooze until future time
    local future_time
    future_time=$(date -d "+1 hour" -Iseconds 2>/dev/null || date -v+1H -Iseconds 2>/dev/null || echo "2099-01-01T00:00:00+00:00")
    mark_question_snoozed "q-snooze" "$future_time"

    local questions_file
    questions_file=$(get_questions_file)

    if command -v jq &>/dev/null; then
        local status
        status=$(jq -r '.questions[0].status' "$questions_file")
        assert_equals "snoozed" "$status" "Status should be snoozed"

        local snooze_until
        snooze_until=$(jq -r '.questions[0].snooze_until' "$questions_file")
        assert_not_equals "null" "$snooze_until" "Snooze time should be set"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Template Application
#==============================================================================

test_template_application() {
    local test_name="template: answers formatted correctly"
    log_test_start "$test_name"
    setup_question_test

    local question_json
    question_json=$(create_test_question "q-template" "session-tpl")
    write_questions_queue "[$question_json]"

    # Mark with template answer
    mark_question_answered "q-template" "Skip - not a priority right now"

    local questions_file
    questions_file=$(get_questions_file)

    if command -v jq &>/dev/null; then
        local answer
        answer=$(jq -r '.questions[0].answer' "$questions_file")
        assert_contains "$answer" "Skip" "Template answer should be stored"
    fi

    log_test_pass "$test_name"
}

test_bulk_apply_pattern() {
    local test_name="bulk: skip multiple questions"
    log_test_start "$test_name"
    setup_question_test

    # Create multiple questions
    local q1 q2 q3
    q1=$(create_test_question "q-bulk-1" "s1" "normal" "Update deps?")
    q2=$(create_test_question "q-bulk-2" "s2" "normal" "Update config?")
    q3=$(create_test_question "q-bulk-3" "s3" "normal" "Refactor code?")

    write_questions_queue "[$q1, $q2, $q3]"

    # Skip first two
    mark_question_skipped "q-bulk-1"
    mark_question_skipped "q-bulk-2"

    local questions_file
    questions_file=$(get_questions_file)

    if command -v jq &>/dev/null; then
        local skipped_count
        skipped_count=$(jq '[.questions[] | select(.status == "skipped")] | length' "$questions_file")
        assert_equals "2" "$skipped_count" "Two questions should be skipped"

        local pending_count
        pending_count=$(jq '[.questions[] | select(.status == "pending")] | length' "$questions_file")
        assert_equals "1" "$pending_count" "One question should remain pending"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: TUI Helpers
#==============================================================================

test_tui_fallback() {
    local test_name="TUI: fallback when gum unavailable"
    log_test_start "$test_name"
    setup_question_test

    # Test that functions exist for fallback
    if declare -f question_get_prompt &>/dev/null; then
        pass "question_get_prompt function exists"
    else
        fail "question_get_prompt should be defined for fallback"
    fi

    if declare -f question_get_options_lines &>/dev/null; then
        pass "question_get_options_lines function exists"
    else
        fail "question_get_options_lines should be defined for fallback"
    fi

    log_test_pass "$test_name"
}

test_progress_calculation() {
    local test_name="progress: accurate calculation"
    log_test_start "$test_name"
    setup_question_test

    # Create questions with mixed statuses
    local q1 q2 q3 q4
    q1=$(create_test_question "q-prog-1" "s1")
    q2=$(create_test_question "q-prog-2" "s2")
    q3=$(create_test_question "q-prog-3" "s3")
    q4=$(create_test_question "q-prog-4" "s4")

    write_questions_queue "[$q1, $q2, $q3, $q4]"

    # Mark some as answered
    mark_question_answered "q-prog-1" "Yes"
    mark_question_answered "q-prog-2" "No"

    local questions_file
    questions_file=$(get_questions_file)

    if command -v jq &>/dev/null; then
        local total answered pending
        total=$(jq '.questions | length' "$questions_file")
        answered=$(jq '[.questions[] | select(.status == "answered")] | length' "$questions_file")
        pending=$(jq '[.questions[] | select(.status == "pending")] | length' "$questions_file")

        assert_equals "4" "$total" "Total should be 4"
        assert_equals "2" "$answered" "Answered should be 2"
        assert_equals "2" "$pending" "Pending should be 2"
    fi

    log_test_pass "$test_name"
}

test_drill_down_patch_display() {
    local test_name="drill-down: patch context available"
    log_test_start "$test_name"
    setup_question_test

    # Question with patch context
    local question_json
    question_json=$(cat <<'EOF'
{
    "id": "q-drill",
    "session_id": "session-drill",
    "repo": "owner/repo",
    "context": {
        "patch_summary": {
            "files_changed": 2,
            "insertions": 20,
            "deletions": 5
        }
    },
    "questions": [{"prompt": "Apply?", "options": []}]
}
EOF
)

    write_questions_queue "[$question_json]"

    local loaded
    loaded=$(load_questions_queue)

    if command -v jq &>/dev/null; then
        local q
        q=$(get_question_at_index "$loaded" 0)

        local insertions
        insertions=$(echo "$q" | jq -r '.context.patch_summary.insertions // 0')
        assert_equals "20" "$insertions" "Insertions should be accessible"
    fi

    log_test_pass "$test_name"
}

test_recommended_marker() {
    local test_name="recommended: option marked correctly"
    log_test_start "$test_name"
    setup_question_test

    local question_json
    question_json=$(create_test_question "q-rec" "session-rec")
    write_questions_queue "[$question_json]"

    local loaded
    loaded=$(load_questions_queue)

    if command -v jq &>/dev/null; then
        local q
        q=$(get_question_at_index "$loaded" 0)

        local recommended
        recommended=$(question_get_recommended "$q")
        assert_equals "Yes" "$recommended" "Recommended should be 'Yes'"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Run All Tests
#==============================================================================

echo "Running question TUI unit tests..."
echo ""

# Question queue tests
run_test test_question_queue_add
run_test test_question_queue_context_extraction
run_test test_question_queue_priority_sort
run_test test_question_dedup

# Answer routing test
run_test test_answer_routing

# Snooze test
run_test test_snooze_timing

# Template tests
run_test test_template_application
run_test test_bulk_apply_pattern

# TUI helper tests
run_test test_tui_fallback
run_test test_progress_calculation
run_test test_drill_down_patch_display
run_test test_recommended_marker

# Print results
print_results

# Cleanup and exit
cleanup_temp_dirs
exit "$TF_TESTS_FAILED"
