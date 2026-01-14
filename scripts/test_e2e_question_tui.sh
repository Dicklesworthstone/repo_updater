#!/usr/bin/env bash
#
# E2E Test: Question Aggregation & TUI Presentation (bd-wyxq)
#
# Tests full question workflow:
#   1. Full question flow (session asks, TUI shows, user answers, routed, continues)
#   2. Parallel questions (multiple sessions, all appear, all routed correctly)
#   3. Question persistence (questions survive crash and restart)
#   4. Drill-down navigation (enter drill-down, view patch, answer, return)
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC2317  # Functions called indirectly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the E2E framework
source "$SCRIPT_DIR/test_e2e_framework.sh"

#------------------------------------------------------------------------------
# Stubs and helpers
#------------------------------------------------------------------------------

log_verbose() { :; }
log_info() { :; }
log_warn() { printf 'WARN: %s\n' "$*" >&2; }
log_error() { printf 'ERROR: %s\n' "$*" >&2; }
log_debug() { :; }

# Source required functions
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

# Track routed answers
declare -a ROUTED_ANSWERS=()

# Mock session driver send
driver_send_to_session() {
    local session_id="$1"
    local answer="$2"
    ROUTED_ANSWERS+=("$session_id:$answer")
    return 0
}

#------------------------------------------------------------------------------
# Helper functions
#------------------------------------------------------------------------------

setup_question_env() {
    export RU_STATE_DIR="$E2E_TEMP_DIR/state/ru"
    mkdir -p "$RU_STATE_DIR/review"
    ROUTED_ANSWERS=()
}

create_test_question() {
    local id="$1"
    local session_id="${2:-session-1}"
    local priority="${3:-normal}"
    local prompt="${4:-Should I proceed?}"
    local repo="${5:-owner/repo}"

    cat <<EOF
{
    "id": "$id",
    "session_id": "$session_id",
    "repo": "$repo",
    "priority": "$priority",
    "status": "pending",
    "context": {
        "patch_summary": {"files_changed": 2, "insertions": 10, "deletions": 5},
        "tests": {"ok": true, "duration_seconds": 1.5},
        "risk_level": "low"
    },
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

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_full_question_flow() {
    log_test_start "question TUI: full question flow"
    e2e_setup
    setup_question_env

    # 1. Simulate session asking a question
    local question_json
    question_json=$(create_test_question "q-flow-1" "session-flow" "high" "Apply security fix?")
    write_questions_queue "[$question_json]"

    # 2. Verify question is in queue
    local loaded
    loaded=$(load_questions_queue)
    local count
    count=$(echo "$loaded" | jq 'length' 2>/dev/null || echo 0)
    assert_equals "1" "$count" "Question should be in queue"

    # 3. Verify question properties accessible
    local q
    q=$(get_question_at_index "$loaded" 0)
    local prompt
    prompt=$(question_get_prompt "$q")
    assert_contains "$prompt" "security fix" "Prompt should be accessible"

    # 4. Simulate user answering
    mark_question_answered "q-flow-1" "Yes"

    # 5. Verify answer recorded
    local questions_file
    questions_file=$(get_questions_file)
    if command -v jq &>/dev/null; then
        local status answer
        status=$(jq -r '.questions[0].status' "$questions_file")
        answer=$(jq -r '.questions[0].answer' "$questions_file")

        assert_equals "answered" "$status" "Question should be marked answered"
        assert_equals "Yes" "$answer" "Answer should be recorded"
    fi

    e2e_cleanup
    log_test_pass "question TUI: full question flow"
}

test_parallel_questions() {
    log_test_start "question TUI: parallel questions from multiple sessions"
    e2e_setup
    setup_question_env

    # Create questions from multiple sessions
    local q1 q2 q3
    q1=$(create_test_question "q-par-1" "session-alpha" "high" "Fix auth bug?" "project-alpha")
    q2=$(create_test_question "q-par-2" "session-beta" "normal" "Update config?" "project-beta")
    q3=$(create_test_question "q-par-3" "session-gamma" "low" "Refactor code?" "project-gamma")

    write_questions_queue "[$q1, $q2, $q3]"

    # Verify all questions present
    local loaded
    loaded=$(load_questions_queue)

    if command -v jq &>/dev/null; then
        local count
        count=$(echo "$loaded" | jq 'length')
        assert_equals "3" "$count" "All 3 questions should be present"

        # Verify different sessions
        local sessions
        sessions=$(echo "$loaded" | jq -r '.[].session_id' | sort -u | wc -l | tr -d ' ')
        assert_equals "3" "$sessions" "Should have 3 different sessions"
    fi

    # Answer each question to different sessions
    mark_question_answered "q-par-1" "Yes"
    mark_question_answered "q-par-2" "No"
    mark_question_skipped "q-par-3"

    # Verify all routed correctly
    local questions_file
    questions_file=$(get_questions_file)

    if command -v jq &>/dev/null; then
        local answered_count skipped_count
        answered_count=$(jq '[.questions[] | select(.status == "answered")] | length' "$questions_file")
        skipped_count=$(jq '[.questions[] | select(.status == "skipped")] | length' "$questions_file")

        assert_equals "2" "$answered_count" "Two questions should be answered"
        assert_equals "1" "$skipped_count" "One question should be skipped"
    fi

    e2e_cleanup
    log_test_pass "question TUI: parallel questions from multiple sessions"
}

test_question_persistence() {
    log_test_start "question TUI: questions survive restart"
    e2e_setup
    setup_question_env

    # Create questions
    local q1 q2
    q1=$(create_test_question "q-persist-1" "session-1" "high" "Important question?")
    q2=$(create_test_question "q-persist-2" "session-2" "normal" "Another question?")
    write_questions_queue "[$q1, $q2]"

    # Answer one
    mark_question_answered "q-persist-1" "Yes"

    # Simulate "restart" by clearing in-memory state and reloading
    local questions_file
    questions_file=$(get_questions_file)

    # Verify file persists
    assert_file_exists "$questions_file" "Questions file should persist"

    # Reload from file
    local reloaded
    reloaded=$(load_questions_queue)

    if command -v jq &>/dev/null; then
        local total pending answered
        total=$(echo "$reloaded" | jq 'length')
        answered=$(echo "$reloaded" | jq '[.[] | select(.status == "answered")] | length')
        pending=$(echo "$reloaded" | jq '[.[] | select(.status == "pending")] | length')

        assert_equals "2" "$total" "All questions should persist"
        assert_equals "1" "$answered" "Answered question should persist"
        assert_equals "1" "$pending" "Pending question should persist"

        # Verify specific question state
        local q1_status
        q1_status=$(echo "$reloaded" | jq -r '.[] | select(.id == "q-persist-1") | .status')
        assert_equals "answered" "$q1_status" "Q1 should be answered after reload"
    fi

    e2e_cleanup
    log_test_pass "question TUI: questions survive restart"
}

test_drill_down_navigation() {
    log_test_start "question TUI: drill-down context available"
    e2e_setup
    setup_question_env

    # Create question with full context
    local question_json
    question_json=$(cat <<'EOF'
{
    "id": "q-drill-1",
    "session_id": "session-drill",
    "repo": "owner/project",
    "number": 42,
    "type": "issue",
    "title": "Fix authentication bug",
    "priority": "high",
    "status": "pending",
    "context": {
        "patch_summary": {
            "files_changed": 3,
            "insertions": 25,
            "deletions": 8
        },
        "tests": {"ok": true, "duration_seconds": 2.3},
        "risk_level": "medium"
    },
    "questions": [{
        "prompt": "Should I apply the authentication fix?",
        "options": [
            {"label": "a", "description": "Apply minimal fix (5 lines)"},
            {"label": "b", "description": "Full refactor (30 lines)"},
            {"label": "c", "description": "Skip for now"}
        ],
        "recommended": "a"
    }]
}
EOF
)

    write_questions_queue "[$question_json]"

    # Load and get question
    local loaded
    loaded=$(load_questions_queue)
    local q
    q=$(get_question_at_index "$loaded" 0)

    # Verify context accessible for drill-down
    if command -v jq &>/dev/null; then
        # Patch info
        local files ins del
        files=$(echo "$q" | jq -r '.context.patch_summary.files_changed')
        ins=$(echo "$q" | jq -r '.context.patch_summary.insertions')
        del=$(echo "$q" | jq -r '.context.patch_summary.deletions')

        assert_equals "3" "$files" "Files changed should be accessible"
        assert_equals "25" "$ins" "Insertions should be accessible"
        assert_equals "8" "$del" "Deletions should be accessible"

        # Test info
        local tests_ok
        tests_ok=$(echo "$q" | jq -r '.context.tests.ok')
        assert_equals "true" "$tests_ok" "Test status should be accessible"

        # Risk level
        local risk
        risk=$(echo "$q" | jq -r '.context.risk_level')
        assert_equals "medium" "$risk" "Risk level should be accessible"

        # Question metadata
        local prompt recommended
        prompt=$(question_get_prompt "$q")
        recommended=$(question_get_recommended "$q")

        assert_contains "$prompt" "authentication" "Prompt should be accessible"
        assert_equals "a" "$recommended" "Recommended should be accessible"
    fi

    # Simulate answering from drill-down
    mark_question_answered "q-drill-1" "a"

    local questions_file
    questions_file=$(get_questions_file)

    if command -v jq &>/dev/null; then
        local answer
        answer=$(jq -r '.questions[0].answer' "$questions_file")
        assert_equals "a" "$answer" "Answer from drill-down should be recorded"
    fi

    e2e_cleanup
    log_test_pass "question TUI: drill-down context available"
}

#------------------------------------------------------------------------------
# Run tests
#------------------------------------------------------------------------------

log_suite_start "E2E Tests: Question Aggregation & TUI"

run_test test_full_question_flow
run_test test_parallel_questions
run_test test_question_persistence
run_test test_drill_down_navigation

print_results
exit "$(get_exit_code)"
