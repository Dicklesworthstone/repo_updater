#!/usr/bin/env bash
#
# Unit tests: State Locking
# Tests for acquire_state_lock, release_state_lock, and security checks
#
# shellcheck disable=SC2034
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

# Extract functions
source_ru_function "ensure_dir"
source_ru_function "get_review_state_dir"
source_ru_function "acquire_state_lock"
source_ru_function "release_state_lock"
source_ru_function "log_error"

# Mock dependencies
log_error() { :; }
STATE_LOCK_FD=201

test_acquire_state_lock_creates_lock_file() {
    local test_name="acquire_state_lock: creates lock dir"
    log_test_start "$test_name"
    local env_root
    env_root=$(create_test_env)
    
    export RU_STATE_DIR="$env_root/state/ru"
    
    if acquire_state_lock; then
        pass "Lock acquired"
    else
        fail "Failed to acquire lock"
    fi
    
    assert_dir_exists "$RU_STATE_DIR/review/state.lock.d" "Lock dir should exist"
    assert_file_exists "$RU_STATE_DIR/review/state.lock.info" "Lock info file should exist"
    
    release_state_lock
    cleanup_temp_dirs
}

test_acquire_state_lock_safe_from_injection() {
    local test_name="acquire_state_lock: safe from eval injection"
    log_test_start "$test_name"
    local env_root
    env_root=$(create_test_env)

    local pwned_file="/tmp/ru_pwned_global_test"
    rm -f "$pwned_file"

    # Run from temp dir to avoid leaving artifacts in repo root
    local orig_dir="$PWD"
    cd "$env_root" || return 1

    # Attempt command injection via RU_STATE_DIR
    export RU_STATE_DIR="\$(touch $pwned_file)"

    # This should fail to acquire lock (invalid path) but NOT execute the injection
    acquire_state_lock >/dev/null 2>&1

    if [[ -f "$pwned_file" ]]; then
        fail "Command injection successful! File $pwned_file was created."
        rm -f "$pwned_file"
    else
        pass "Command injection failed (safe)."
    fi

    # Return to original directory before cleanup
    cd "$orig_dir" || true
    cleanup_temp_dirs
}

run_test test_acquire_state_lock_creates_lock_file
run_test test_acquire_state_lock_safe_from_injection

print_results
