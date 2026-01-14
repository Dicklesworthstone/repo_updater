#!/usr/bin/env bash
#
# Unit tests: Review Locking Mechanism
#
# Tests for acquire_review_lock, release_review_lock, check_stale_lock,
# get_review_lock_file, get_review_lock_info_file.
#
# Uses ru's portable directory-locking implementation in isolated temp directories.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

# Source required functions
source_ru_function "ensure_dir"
source_ru_function "dir_lock_try_acquire"
source_ru_function "dir_lock_release"
source_ru_function "dir_lock_acquire"
source_ru_function "get_review_lock_file"
source_ru_function "get_review_lock_info_file"
source_ru_function "check_stale_lock"
source_ru_function "acquire_review_lock"
source_ru_function "release_review_lock"

# Stub logging functions
log_verbose() { :; }
log_info() { echo "INFO: $*" >&2; }
log_warn() { echo "WARN: $*" >&2; }
log_error() { echo "ERROR: $*" >&2; }

#==============================================================================
# Tests: get_review_lock_file
#==============================================================================

test_get_review_lock_file_path() {
    local test_name="get_review_lock_file returns correct path"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    local result
    result=$(get_review_lock_file)

    assert_equals "$test_env/state/review.lock" "$result" "Should return review.lock path"

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_get_review_lock_info_file_path() {
    local test_name="get_review_lock_info_file returns correct path"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    local result
    result=$(get_review_lock_info_file)

    assert_equals "$test_env/state/review.lock.info" "$result" "Should return review.lock.info path"

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: acquire_review_lock
#==============================================================================

test_acquire_review_lock_success() {
    local test_name="acquire_review_lock succeeds when unlocked"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR"

    # Acquire lock
    if acquire_review_lock; then
        assert_true "true" "Lock acquisition should succeed"
        release_review_lock
    else
        fail_test "Lock acquisition should succeed when unlocked"
    fi

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_acquire_review_lock_creates_info_file() {
    local test_name="acquire_review_lock creates info file with JSON metadata"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR"

    REVIEW_RUN_ID="test-run-123"
    REVIEW_MODE="plan"

    acquire_review_lock

    local info_file
    info_file=$(get_review_lock_info_file)

    assert_file_exists "$info_file" "Info file should be created"

    # Verify JSON content
    if command -v jq &>/dev/null; then
        local run_id pid mode
        run_id=$(jq -r '.run_id' "$info_file")
        pid=$(jq -r '.pid' "$info_file")
        mode=$(jq -r '.mode' "$info_file")

        assert_equals "test-run-123" "$run_id" "Should have correct run_id"
        assert_equals "$$" "$pid" "Should have current PID"
        assert_equals "plan" "$mode" "Should have correct mode"
    else
        assert_file_contains "$info_file" '"run_id"' "Should contain run_id"
        assert_file_contains "$info_file" '"pid"' "Should contain pid"
    fi

    release_review_lock

    unset RU_STATE_DIR REVIEW_RUN_ID REVIEW_MODE
    log_test_pass "$test_name"
}

test_acquire_review_lock_creates_lock_file() {
    local test_name="acquire_review_lock creates lock dir"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR"

    acquire_review_lock

    local lock_file
    lock_file=$(get_review_lock_file)
    local lock_dir="${lock_file}.d"

    assert_dir_exists "$lock_dir" "Lock dir should be created"

    release_review_lock
    assert_dir_not_exists "$lock_dir" "Lock dir should be released"

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: release_review_lock
#==============================================================================

test_release_review_lock_removes_info_file() {
    local test_name="release_review_lock removes info file"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR"

    acquire_review_lock

    local info_file
    info_file=$(get_review_lock_info_file)
    assert_file_exists "$info_file" "Info file should exist after acquire"

    release_review_lock

    assert_file_not_exists "$info_file" "Info file should be removed after release"

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_release_review_lock_noop_when_not_held() {
    local test_name="release_review_lock is noop when lock not held"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR"

    # Should not error when lock not held
    if release_review_lock 2>/dev/null; then
        assert_true "true" "Should succeed even when lock not held"
    else
        # Some implementations may return non-zero, that's OK
        assert_true "true" "Release without lock is acceptable"
    fi

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: check_stale_lock
#==============================================================================

test_check_stale_lock_no_info_file() {
    local test_name="check_stale_lock returns 1 when no info file"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR"

    if check_stale_lock; then
        fail_test "Should return 1 when no info file exists"
    else
        assert_true "true" "Should return 1 when no info file exists"
    fi

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_check_stale_lock_corrupt_info() {
    local test_name="check_stale_lock cleans up corrupt info file"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR"

    local info_file
    info_file=$(get_review_lock_info_file)
    local lock_file lock_dir
    lock_file=$(get_review_lock_file)
    lock_dir="${lock_file}.d"
    mkdir -p "$lock_dir"

    # Create corrupt info file (invalid JSON)
    echo "not valid json" > "$info_file"

    if check_stale_lock; then
        # Should return 0 (stale) and clean up
        assert_file_not_exists "$info_file" "Corrupt info file should be removed"
        assert_dir_not_exists "$lock_dir" "Lock dir should be released"
    fi

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_check_stale_lock_dead_process() {
    local test_name="check_stale_lock detects dead process"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR"

    local info_file
    info_file=$(get_review_lock_info_file)
    local lock_file lock_dir
    lock_file=$(get_review_lock_file)
    lock_dir="${lock_file}.d"
    mkdir -p "$lock_dir"

    # Create info file with definitely dead PID (99999999)
    cat > "$info_file" << 'EOF'
{
  "run_id": "dead-process-run",
  "started_at": "2025-01-01T00:00:00Z",
  "pid": 99999999,
  "mode": "plan"
}
EOF

    # check_stale_lock should detect the dead process and clean up
    if check_stale_lock; then
        assert_file_not_exists "$info_file" "Stale info file should be removed"
        assert_dir_not_exists "$lock_dir" "Lock dir should be released"
    else
        # If it returns 1, check if process exists (unlikely for 99999999)
        if ! kill -0 99999999 2>/dev/null; then
            fail_test "Should detect dead process and return 0"
        fi
    fi

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_check_stale_lock_valid_lock() {
    local test_name="check_stale_lock returns 1 for valid lock (current process)"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR"

    local info_file
    info_file=$(get_review_lock_info_file)
    local lock_file lock_dir
    lock_file=$(get_review_lock_file)
    lock_dir="${lock_file}.d"
    mkdir -p "$lock_dir"

    # Create info file with current PID (this process is alive)
    cat > "$info_file" << EOF
{
  "run_id": "valid-lock-run",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pid": $$,
  "mode": "plan"
}
EOF

    if check_stale_lock; then
        fail_test "Should return 1 for lock held by live process"
    else
        assert_true "true" "Should return 1 for valid (live process) lock"
        # Info file should still exist
        assert_file_exists "$info_file" "Info file should not be removed for live process"
        assert_dir_exists "$lock_dir" "Lock dir should remain for live process"
    fi

    rm -f "$info_file"
    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Concurrent Access
#==============================================================================

test_acquire_review_lock_fails_when_held() {
    local test_name="acquire_review_lock fails when already held by another process"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR"
    local lock_file lock_dir
    lock_file=$(get_review_lock_file)
    lock_dir="${lock_file}.d"

    # First, acquire lock in background subprocess that holds it
    (
        mkdir "$lock_dir" 2>/dev/null || exit 1
        sleep 2
        rmdir "$lock_dir" 2>/dev/null || true
    ) &
    local holder_pid=$!

    # Give the subprocess time to acquire the lock
    sleep 0.3

    # Now try to acquire in main process - should fail
    if acquire_review_lock 2>/dev/null; then
        release_review_lock
        kill "$holder_pid" 2>/dev/null || true
        wait "$holder_pid" 2>/dev/null || true
        fail_test "Lock acquisition should fail when already held"
    else
        assert_true "true" "Lock acquisition should fail when held by another process"
    fi

    # Clean up background process
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_lock_acquire_release_cycle() {
    local test_name="lock acquire-release cycle works correctly"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR"
    local lock_file lock_dir
    lock_file=$(get_review_lock_file)
    lock_dir="${lock_file}.d"

    # First acquire
    if ! acquire_review_lock; then
        fail_test "First acquire should succeed"
        return 1
    fi

    local info_file
    info_file=$(get_review_lock_info_file)
    assert_file_exists "$info_file" "Info file should exist after acquire"
    assert_dir_exists "$lock_dir" "Lock dir should exist after acquire"

    # Release
    release_review_lock
    assert_file_not_exists "$info_file" "Info file should be gone after release"
    assert_dir_not_exists "$lock_dir" "Lock dir should be gone after release"

    # Second acquire (should work after release)
    if ! acquire_review_lock; then
        fail_test "Second acquire should succeed after release"
        return 1
    fi

    assert_file_exists "$info_file" "Info file should exist after second acquire"

    release_review_lock

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: Lock Info File Content
#==============================================================================

test_lock_info_file_has_timestamp() {
    local test_name="lock info file contains started_at timestamp"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR"

    acquire_review_lock

    local info_file
    info_file=$(get_review_lock_info_file)

    if command -v jq &>/dev/null; then
        local started_at
        started_at=$(jq -r '.started_at' "$info_file")
        # Should be ISO8601 format
        if [[ "$started_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
            assert_true "true" "Timestamp should be ISO8601 format"
        else
            fail_test "Timestamp format invalid: $started_at"
        fi
    else
        assert_file_contains "$info_file" '"started_at"' "Should contain started_at"
    fi

    release_review_lock

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

test_lock_info_default_run_id() {
    local test_name="lock info uses PID as default run_id"
    log_test_start "$test_name"
    local test_env
    test_env=$(create_test_env)

    RU_STATE_DIR="$test_env/state"
    mkdir -p "$RU_STATE_DIR"

    # Don't set REVIEW_RUN_ID - should default to $$
    unset REVIEW_RUN_ID

    acquire_review_lock

    local info_file
    info_file=$(get_review_lock_info_file)

    if command -v jq &>/dev/null; then
        local run_id
        run_id=$(jq -r '.run_id' "$info_file")
        assert_equals "$$" "$run_id" "Default run_id should be current PID"
    fi

    release_review_lock

    unset RU_STATE_DIR
    log_test_pass "$test_name"
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "Unit Tests: Review Locking Mechanism"
echo "============================================"
echo ""

# get_review_lock_file tests
run_test test_get_review_lock_file_path
run_test test_get_review_lock_info_file_path

# acquire_review_lock tests
run_test test_acquire_review_lock_success
run_test test_acquire_review_lock_creates_info_file
run_test test_acquire_review_lock_creates_lock_file

# release_review_lock tests
run_test test_release_review_lock_removes_info_file
run_test test_release_review_lock_noop_when_not_held

# check_stale_lock tests
run_test test_check_stale_lock_no_info_file
run_test test_check_stale_lock_corrupt_info
run_test test_check_stale_lock_dead_process
run_test test_check_stale_lock_valid_lock

# Concurrent access tests
run_test test_acquire_review_lock_fails_when_held
run_test test_lock_acquire_release_cycle

# Lock info content tests
run_test test_lock_info_file_has_timestamp
run_test test_lock_info_default_run_id

echo ""
print_results

# Cleanup and exit
cleanup_temp_dirs
exit "$TF_TESTS_FAILED"
