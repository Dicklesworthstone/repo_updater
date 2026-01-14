#!/usr/bin/env bash
#
# Integration tests: Review orchestration (bd-i99q)
#
# Exercises ru review end-to-end with mocked dependencies and injected
# session completion so the orchestration loop can terminate deterministically.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC2317  # Functions called indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the E2E framework (test isolation + assertions)
source "$SCRIPT_DIR/test_e2e_framework.sh"

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------

REVIEW_REPO_NAMES=()
REVIEW_REPO_SPECS=()

require_tools() {
    if ! command -v git &>/dev/null; then
        skip_test "git not available"
        return 1
    fi
    if ! command -v jq &>/dev/null; then
        skip_test "jq not available"
        return 1
    fi
    return 0
}

build_repo_specs() {
    local count="$1"
    REVIEW_REPO_NAMES=()
    REVIEW_REPO_SPECS=()

    local i
    for ((i=0; i<count; i++)); do
        local repo="repo${i}"
        REVIEW_REPO_NAMES+=("$repo")
        REVIEW_REPO_SPECS+=("owner/$repo")
    done
}

create_repo() {
    local repo_name="$1"
    local repo_path="$RU_PROJECTS_DIR/$repo_name"

    mkdir -p "$repo_path"
    git -C "$repo_path" init >/dev/null 2>&1
    git -C "$repo_path" config user.email "test@test.com"
    git -C "$repo_path" config user.name "Test User"

    printf 'hello %s\n' "$repo_name" > "$repo_path/README.md"
    git -C "$repo_path" add README.md >/dev/null 2>&1
    git -C "$repo_path" commit -m "init" >/dev/null 2>&1
    git -C "$repo_path" branch -M main >/dev/null 2>&1 || true
}

create_review_repos() {
    local name
    for name in "${REVIEW_REPO_NAMES[@]}"; do
        create_repo "$name"
    done
}

write_repo_list() {
    local list_file="$RU_CONFIG_DIR/repos.d/public.txt"
    mkdir -p "$(dirname "$list_file")"
    printf '%s\n' "${REVIEW_REPO_SPECS[@]}" > "$list_file"
}

setup_integration_env() {
    local repo_count="$1"

    e2e_setup
    export RU_STATE_DIR="$E2E_TEMP_DIR/state/ru"
    export PROJECTS_DIR="$RU_PROJECTS_DIR"
    export LAYOUT="flat"

    e2e_init_ru
    build_repo_specs "$repo_count"
    create_review_repos
    write_repo_list

    e2e_create_mock_gh 0 "$(e2e_graphql_response_with_items "$repo_count")"
    e2e_create_mock_ntm "ok"
}

wait_for_file() {
    local file="$1"
    local timeout="${2:-10}"
    local start
    start=$(date +%s)

    while [[ ! -f "$file" ]]; do
        if (( $(date +%s) - start >= timeout )); then
            return 1
        fi
        sleep 0.2
    done
    return 0
}

wait_for_pid_exit() {
    local pid="$1"
    local timeout="${2:-20}"
    local start
    start=$(date +%s)

    while kill -0 "$pid" 2>/dev/null; do
        if (( $(date +%s) - start >= timeout )); then
            log_warn "Timeout waiting for PID $pid"
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 0.2
    done

    wait "$pid"
    return $?
}

get_run_id() {
    local info_file="$1"
    if command -v jq &>/dev/null; then
        jq -r '.run_id // empty' "$info_file" 2>/dev/null
    else
        sed -n 's/.*"run_id":"\([^"]*\)".*/\1/p' "$info_file" | head -n 1
    fi
}

inject_plan_files() {
    local run_id="$1"
    local mapping_file="$RU_STATE_DIR/worktrees/$run_id/mapping.json"
    local repo_id wt_path

    for repo_id in "${REVIEW_REPO_SPECS[@]}"; do
        wt_path=$(jq -r --arg repo "$repo_id" '.[$repo].worktree_path // empty' "$mapping_file" 2>/dev/null)
        if [[ -n "$wt_path" ]]; then
            mkdir -p "$wt_path/.ru"
            cat > "$wt_path/.ru/review-plan.json" <<EOF
{"schema_version":"1","repo":"$repo_id","items":[]}
EOF
        fi
    done
}

inject_pipe_logs() {
    local run_id="$1"
    local repo_id session_id

    mkdir -p "$RU_STATE_DIR/pipes"
    for repo_id in "${REVIEW_REPO_SPECS[@]}"; do
        session_id="ru-review-${run_id}-${repo_id//\//-}"
        printf '{"type":"result","status":"success"}\n' > "$RU_STATE_DIR/pipes/${session_id}.pipe.log"
    done
}

start_review_background() {
    local stdout_file="$E2E_LOG_DIR/ru_stdout.txt"
    local stderr_file="$E2E_LOG_DIR/ru_stderr.txt"

    "$E2E_RU_SCRIPT" review "$@" >"$stdout_file" 2>"$stderr_file" &
    REVIEW_PID=$!
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_integration_review_plan_completes() {
    local test_name="integration: review plan completes"
    log_test_start "$test_name"

    if ! require_tools; then
        log_test_pass "$test_name"
        return 0
    fi

    setup_integration_env 2

    start_review_background --mode=local --parallel=1

    local info_file="$RU_STATE_DIR/review.lock.info"
    wait_for_file "$info_file" 10 || true
    assert_file_exists "$info_file" "lock info created"

    local run_id
    run_id=$(get_run_id "$info_file")
    assert_not_empty "$run_id" "captured run id"

    local mapping_file="$RU_STATE_DIR/worktrees/$run_id/mapping.json"
    wait_for_file "$mapping_file" 10 || true
    assert_file_exists "$mapping_file" "worktree mapping created"

    inject_plan_files "$run_id"
    inject_pipe_logs "$run_id"

    local exit_code=0
    wait_for_pid_exit "$REVIEW_PID" 25 || exit_code=$?
    assert_equals "0" "$exit_code" "review exits cleanly"

    local state_file="$RU_STATE_DIR/review/review-state.json"
    local completed
    completed=$(jq -r '[.repos | to_entries[] | select(.value.status == "completed")] | length' "$state_file" 2>/dev/null || echo "0")
    assert_equals "2" "$completed" "all repos completed"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_integration_review_max_repos_budget() {
    local test_name="integration: max-repos budget"
    log_test_start "$test_name"

    if ! require_tools; then
        log_test_pass "$test_name"
        return 0
    fi

    setup_integration_env 3

    start_review_background --mode=local --parallel=1 --max-repos=1

    local info_file="$RU_STATE_DIR/review.lock.info"
    wait_for_file "$info_file" 10 || true
    assert_file_exists "$info_file" "lock info created"

    local run_id
    run_id=$(get_run_id "$info_file")
    assert_not_empty "$run_id" "captured run id"

    local mapping_file="$RU_STATE_DIR/worktrees/$run_id/mapping.json"
    wait_for_file "$mapping_file" 10 || true
    assert_file_exists "$mapping_file" "worktree mapping created"

    inject_plan_files "$run_id"
    inject_pipe_logs "$run_id"

    local exit_code=0
    wait_for_pid_exit "$REVIEW_PID" 25 || exit_code=$?
    assert_equals "0" "$exit_code" "review exits cleanly"

    local state_file="$RU_STATE_DIR/review/review-state.json"
    local completed
    completed=$(jq -r '[.repos | to_entries[] | select(.value.status == "completed")] | length' "$state_file" 2>/dev/null || echo "0")
    assert_equals "1" "$completed" "max-repos enforced"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_integration_review_checkpoint_created_and_cleared() {
    local test_name="integration: checkpoint lifecycle"
    log_test_start "$test_name"

    if ! require_tools; then
        log_test_pass "$test_name"
        return 0
    fi

    setup_integration_env 1

    start_review_background --mode=local --parallel=1

    local checkpoint_file="$RU_STATE_DIR/review/review-checkpoint.json"
    wait_for_file "$checkpoint_file" 10 || true
    assert_file_exists "$checkpoint_file" "checkpoint created"

    local info_file="$RU_STATE_DIR/review.lock.info"
    wait_for_file "$info_file" 10 || true
    local run_id
    run_id=$(get_run_id "$info_file")

    local mapping_file="$RU_STATE_DIR/worktrees/$run_id/mapping.json"
    wait_for_file "$mapping_file" 10 || true

    inject_plan_files "$run_id"
    inject_pipe_logs "$run_id"

    local exit_code=0
    wait_for_pid_exit "$REVIEW_PID" 25 || exit_code=$?
    assert_equals "0" "$exit_code" "review exits cleanly"

    assert_file_not_exists "$checkpoint_file" "checkpoint cleared on success"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_integration_review_lock_released() {
    local test_name="integration: lock released after completion"
    log_test_start "$test_name"

    if ! require_tools; then
        log_test_pass "$test_name"
        return 0
    fi

    setup_integration_env 1

    start_review_background --mode=local --parallel=1

    local info_file="$RU_STATE_DIR/review.lock.info"
    wait_for_file "$info_file" 10 || true
    assert_file_exists "$info_file" "lock info created"

    local run_id
    run_id=$(get_run_id "$info_file")

    local mapping_file="$RU_STATE_DIR/worktrees/$run_id/mapping.json"
    wait_for_file "$mapping_file" 10 || true

    inject_plan_files "$run_id"
    inject_pipe_logs "$run_id"

    local exit_code=0
    wait_for_pid_exit "$REVIEW_PID" 25 || exit_code=$?
    assert_equals "0" "$exit_code" "review exits cleanly"

    assert_file_not_exists "$info_file" "lock info removed"

    e2e_cleanup
    log_test_pass "$test_name"
}

test_integration_review_session_ids_recorded() {
    local test_name="integration: session ids recorded"
    log_test_start "$test_name"

    if ! require_tools; then
        log_test_pass "$test_name"
        return 0
    fi

    setup_integration_env 1

    start_review_background --mode=local --parallel=1

    local info_file="$RU_STATE_DIR/review.lock.info"
    wait_for_file "$info_file" 10 || true
    local run_id
    run_id=$(get_run_id "$info_file")
    assert_not_empty "$run_id" "captured run id"

    local mapping_file="$RU_STATE_DIR/worktrees/$run_id/mapping.json"
    wait_for_file "$mapping_file" 10 || true

    inject_plan_files "$run_id"
    inject_pipe_logs "$run_id"

    local exit_code=0
    wait_for_pid_exit "$REVIEW_PID" 25 || exit_code=$?
    assert_equals "0" "$exit_code" "review exits cleanly"

    local state_file="$RU_STATE_DIR/review/review-state.json"
    local expected_sid="ru-review-${run_id}-${REVIEW_REPO_SPECS[0]//\//-}"
    local actual_sid
    actual_sid=$(jq -r --arg repo "${REVIEW_REPO_SPECS[0]}" '.repos[$repo].session_id // empty' "$state_file" 2>/dev/null)
    assert_equals "$expected_sid" "$actual_sid" "session id recorded in state"

    e2e_cleanup
    log_test_pass "$test_name"
}

#------------------------------------------------------------------------------
# Test Runner
#------------------------------------------------------------------------------

run_test test_integration_review_plan_completes
run_test test_integration_review_max_repos_budget
run_test test_integration_review_checkpoint_created_and_cleared
run_test test_integration_review_lock_released
run_test test_integration_review_session_ids_recorded

print_results
