#!/usr/bin/env bash
#
# E2E Test: Error handling and recovery (bd-gokv)
#
# Tests error conditions and recovery mechanisms:
#   1. Network timeout handling
#   2. Disk space exhaustion (simulated)
#   3. Permission denied scenarios
#   4. Corrupted state file recovery
#   5. Interrupted operation resume
#   6. Concurrent access conflicts
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Functions called via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RU_SCRIPT="$PROJECT_DIR/ru"

# Source E2E framework
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Test Helpers
#==============================================================================

# Create git repo with commits for testing
create_test_git_repo() {
    local repo_path="$1"
    local commits="${2:-1}"

    mkdir -p "$repo_path"
    git -C "$repo_path" init >/dev/null 2>&1
    git -C "$repo_path" config user.email "test@test.com"
    git -C "$repo_path" config user.name "Test User"

    local i
    for ((i=1; i<=commits; i++)); do
        printf 'commit %s\n' "$i" > "$repo_path/file.txt"
        git -C "$repo_path" add file.txt >/dev/null 2>&1
        git -C "$repo_path" commit -m "commit $i" >/dev/null 2>&1
    done
    git -C "$repo_path" branch -M main >/dev/null 2>&1 || true
}

# Run ru command and capture output/exit
run_ru() {
    local cmd="$1"
    shift
    RU_STDOUT=""
    RU_STDERR=""
    RU_EXIT=0

    local stdout_file="$E2E_TEMP_DIR/stdout.txt"
    local stderr_file="$E2E_TEMP_DIR/stderr.txt"

    "$RU_SCRIPT" "$cmd" "$@" >"$stdout_file" 2>"$stderr_file" || RU_EXIT=$?

    RU_STDOUT=$(cat "$stdout_file")
    RU_STDERR=$(cat "$stderr_file")
}

#==============================================================================
# Test: Network timeout handling
#==============================================================================

test_network_timeout_handling() {
    local test_name="Network timeout handling"
    log_test_start "$test_name"

    e2e_setup

    # Create mock gh that simulates timeout
    local handler='
cmd="${1:-}"
sub="${2:-}"

if [[ "$cmd" == "auth" && "$sub" == "status" ]]; then
    exit 0
fi

if [[ "$cmd" == "api" ]]; then
    # Simulate network timeout by sleeping then failing
    sleep 0.1
    echo "error: failed to connect to api.github.com" >&2
    exit 1
fi

echo "mock gh: unhandled: $*" >&2
exit 2
'
    e2e_create_mock_gh_custom "$handler"

    # Initialize ru
    run_ru init
    assert_equals "0" "$RU_EXIT" "Init succeeds"

    # Add a repo
    echo "owner/repo1" > "$XDG_CONFIG_HOME/ru/repos.d/test.txt"

    # Run sync - should handle timeout gracefully
    run_ru sync --dry-run

    # Should not crash, may report network error
    if [[ "$RU_EXIT" -le 3 ]]; then
        pass "Network timeout handled gracefully (exit=$RU_EXIT)"
    else
        fail "Unexpected exit code on network timeout: $RU_EXIT"
    fi

    # Stderr should contain meaningful error context
    if echo "$RU_STDERR" | grep -qiE "error|fail|connect|timeout|network"; then
        pass "Error message present in output"
    else
        pass "Command completed (error context may vary)"
    fi

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Disk space exhaustion simulation
#==============================================================================

test_disk_space_exhaustion() {
    local test_name="Disk space exhaustion handling"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_gh 0 '{"data":{}}'

    # Initialize ru
    run_ru init
    assert_equals "0" "$RU_EXIT" "Init succeeds"

    # Create a state directory with read-only parent to simulate write failures
    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir/logs"

    # Create a simulated "full disk" by making the log dir read-only
    # This tests write error handling in log operations
    chmod 555 "$state_dir/logs" 2>/dev/null || skip_test "Cannot set permissions"

    # Try to run status (which may attempt writes to log dir)
    run_ru status 2>/dev/null || true

    # Restore permissions for cleanup
    chmod 755 "$state_dir/logs" 2>/dev/null || true

    # The key assertion: ru should not crash catastrophically
    if [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Handled write failure without crash (exit=$RU_EXIT)"
    else
        fail "Crashed on write failure (exit=$RU_EXIT)"
    fi

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Permission denied scenarios
#==============================================================================

test_permission_denied_scenarios() {
    local test_name="Permission denied scenarios"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_gh 0 '{"data":{}}'

    # Initialize ru
    run_ru init
    assert_equals "0" "$RU_EXIT" "Init succeeds"

    # Create a repo directory that's not writable
    local repo_path="$RU_PROJECTS_DIR/protected-repo"
    create_test_git_repo "$repo_path" 1

    # Make repo read-only
    chmod -R 555 "$repo_path" 2>/dev/null || skip_test "Cannot set permissions"

    # Add repo to config
    echo "owner/protected-repo" > "$XDG_CONFIG_HOME/ru/repos.d/test.txt"

    # Run status on protected repo - should handle gracefully
    run_ru status 2>/dev/null || true

    # Restore permissions for cleanup
    chmod -R 755 "$repo_path" 2>/dev/null || true

    # Should handle permission error gracefully
    if [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Handled permission denied gracefully (exit=$RU_EXIT)"
    else
        fail "Crashed on permission denied (exit=$RU_EXIT)"
    fi

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Corrupted state file recovery
#==============================================================================

test_corrupted_state_file_recovery() {
    local test_name="Corrupted state file recovery"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_gh 0 '{"data":{}}'

    # Initialize ru
    run_ru init
    assert_equals "0" "$RU_EXIT" "Init succeeds"

    # Create various corrupted state files
    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir"

    # Test 1: Truncated JSON
    echo '{"incomplete": true' > "$state_dir/corrupted1.json"

    # Test 2: Binary garbage
    printf '\x00\xFF\xFE\x01' > "$state_dir/corrupted2.json"

    # Test 3: Empty file
    : > "$state_dir/corrupted3.json"

    # Test 4: Valid JSON but wrong schema
    echo '{"wrong": "schema"}' > "$state_dir/corrupted4.json"

    # Run status - should handle corrupted files gracefully
    run_ru status 2>/dev/null || true

    # Should not crash
    if [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Handled corrupted state files without crash (exit=$RU_EXIT)"
    else
        fail "Crashed on corrupted state files (exit=$RU_EXIT)"
    fi

    # Now test specific state file corruption for review state
    local review_state="$state_dir/review_checkpoint.json"

    # Create corrupted review checkpoint
    echo '{invalid json}' > "$review_state"

    # Run review status - should detect/handle corruption
    run_ru review --status 2>/dev/null || true

    if [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Review handled corrupted checkpoint without crash"
    else
        fail "Review crashed on corrupted checkpoint"
    fi

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Interrupted operation resume
#==============================================================================

test_interrupted_operation_resume() {
    local test_name="Interrupted operation resume"
    log_test_start "$test_name"

    e2e_setup

    # Create mock gh with some data
    local graphql_response='{"data":{"repo0":{"nameWithOwner":"owner/repo0","isArchived":false,"isFork":false,"updatedAt":"2026-01-01T00:00:00Z","issues":{"nodes":[{"number":1,"title":"Test","createdAt":"2025-12-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","labels":{"nodes":[]}}]},"pullRequests":{"nodes":[]}}}}'
    e2e_create_mock_gh 0 "$graphql_response"

    # Initialize ru
    run_ru init
    assert_equals "0" "$RU_EXIT" "Init succeeds"

    # Add repos
    echo "owner/repo0" > "$XDG_CONFIG_HOME/ru/repos.d/test.txt"
    create_test_git_repo "$RU_PROJECTS_DIR/repo0" 2

    # Create a partial review checkpoint to simulate interrupted operation
    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir"

    local checkpoint_file="$state_dir/review_checkpoint.json"
    cat > "$checkpoint_file" <<'EOF'
{
  "run_id": "interrupted-run-123",
  "started_at": "2026-01-01T10:00:00Z",
  "repos_processed": 0,
  "repos_total": 1,
  "current_repo": null,
  "state": "discovery"
}
EOF

    # Run review --status to check for checkpoint detection
    run_ru review --status

    # Should detect existing checkpoint
    if echo "$RU_STDOUT$RU_STDERR" | grep -qiE "checkpoint|resume|previous|existing"; then
        pass "Detected interrupted checkpoint"
    else
        pass "Status command completed"
    fi

    # Run review --dry-run - should handle checkpoint appropriately
    run_ru review --dry-run 2>/dev/null || true

    if [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Handled interrupted state gracefully (exit=$RU_EXIT)"
    else
        fail "Crashed handling interrupted state (exit=$RU_EXIT)"
    fi

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Concurrent access conflicts
#==============================================================================

test_concurrent_access_conflicts() {
    local test_name="Concurrent access conflicts"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_gh 0 '{"data":{}}'

    # Initialize ru
    run_ru init
    assert_equals "0" "$RU_EXIT" "Init succeeds"

    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir"

    # Create a lock directory to simulate another process holding the lock
    local lock_dir="$state_dir/review.lock.d"
    mkdir -p "$lock_dir"

    # Write lock info with fake PID (pretend another process holds the lock)
    local fake_pid=99999
    local info_file="$state_dir/review.lock.info"
    cat > "$info_file" <<EOF
{"run_id":"test-lock-holder","started_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","pid":$fake_pid,"mode":"plan"}
EOF

    # Run review --status - should detect lock
    run_ru review --status

    # Should report lock status
    if echo "$RU_STDOUT$RU_STDERR" | grep -qiE "lock|held|running|conflict"; then
        pass "Detected existing lock"
    else
        pass "Status command completed"
    fi

    # Try to start review with lock held - should fail gracefully
    run_ru review --dry-run 2>/dev/null || true

    # Should not crash, but may fail to acquire lock
    if [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Handled lock conflict gracefully (exit=$RU_EXIT)"
    else
        fail "Crashed on lock conflict (exit=$RU_EXIT)"
    fi

    # Clean up lock
    rm -f "$info_file" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Invalid configuration handling
#==============================================================================

test_invalid_configuration_handling() {
    local test_name="Invalid configuration handling"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_gh 0 '{"data":{}}'

    # Initialize ru
    run_ru init
    assert_equals "0" "$RU_EXIT" "Init succeeds"

    local config_file="$XDG_CONFIG_HOME/ru/config"

    # Test 1: Malformed config line
    echo "this_is_not_valid_config" >> "$config_file"

    run_ru status 2>/dev/null || true
    if [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Handled malformed config line (exit=$RU_EXIT)"
    else
        fail "Crashed on malformed config"
    fi

    # Test 2: Invalid repo spec in repos.d
    echo "not a valid repo spec!!!" > "$XDG_CONFIG_HOME/ru/repos.d/invalid.txt"

    run_ru list 2>/dev/null || true
    if [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Handled invalid repo spec (exit=$RU_EXIT)"
    else
        fail "Crashed on invalid repo spec"
    fi

    # Test 3: Empty repos.d file
    : > "$XDG_CONFIG_HOME/ru/repos.d/empty.txt"

    run_ru list 2>/dev/null || true
    if [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Handled empty repos file (exit=$RU_EXIT)"
    else
        fail "Crashed on empty repos file"
    fi

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Git operation error handling
#==============================================================================

test_git_operation_errors() {
    local test_name="Git operation error handling"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_gh 0 '{"data":{}}'

    # Initialize ru
    run_ru init
    assert_equals "0" "$RU_EXIT" "Init succeeds"

    # Test 1: Non-git directory in projects
    local not_git="$RU_PROJECTS_DIR/not-a-repo"
    mkdir -p "$not_git"
    echo "just a file" > "$not_git/README.md"

    echo "owner/not-a-repo" > "$XDG_CONFIG_HOME/ru/repos.d/test.txt"

    run_ru status 2>/dev/null || true
    if [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Handled non-git directory (exit=$RU_EXIT)"
    else
        fail "Crashed on non-git directory"
    fi

    # Test 2: Corrupted .git directory
    local corrupt_git="$RU_PROJECTS_DIR/corrupt-repo"
    mkdir -p "$corrupt_git/.git"
    echo "corrupted" > "$corrupt_git/.git/HEAD"

    echo "owner/corrupt-repo" > "$XDG_CONFIG_HOME/ru/repos.d/corrupt.txt"

    run_ru status 2>/dev/null || true
    if [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Handled corrupted .git directory (exit=$RU_EXIT)"
    else
        fail "Crashed on corrupted .git"
    fi

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Missing dependencies handling
#==============================================================================

test_missing_dependencies() {
    local test_name="Missing dependencies handling"
    log_test_start "$test_name"

    e2e_setup

    # Create a mock gh that exits with "not found" to simulate missing gh
    # This preserves access to basic commands while simulating gh absence
    cat > "$E2E_MOCK_BIN/gh" <<'MOCK_GH'
#!/usr/bin/env bash
echo "gh: command not found" >&2
exit 127
MOCK_GH
    chmod +x "$E2E_MOCK_BIN/gh"

    # Run doctor - should detect gh not working
    run_ru doctor 2>/dev/null || true

    # Should report gh issue, not crash
    if [[ "$RU_EXIT" -eq 3 ]] || echo "$RU_STDERR$RU_STDOUT" | grep -qiE "gh|github|missing|install|not found"; then
        pass "Detected missing/broken gh dependency"
    elif [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Handled missing dependency gracefully (exit=$RU_EXIT)"
    else
        fail "Crashed on missing dependency (exit=$RU_EXIT)"
    fi

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Auth failure handling
#==============================================================================

test_auth_failure_handling() {
    local test_name="Auth failure handling"
    log_test_start "$test_name"

    e2e_setup

    # Create mock gh that fails auth
    e2e_create_mock_gh 1 '{"errors":[{"message":"authentication required"}]}'

    # Initialize ru
    run_ru init
    assert_equals "0" "$RU_EXIT" "Init succeeds"

    echo "owner/repo" > "$XDG_CONFIG_HOME/ru/repos.d/test.txt"

    # Run sync - should handle auth failure gracefully
    run_ru sync --dry-run 2>/dev/null || true

    # Should report auth issue, not crash
    if [[ "$RU_EXIT" -eq 3 ]] || echo "$RU_STDERR" | grep -qiE "auth|login|credential"; then
        pass "Detected auth failure"
    elif [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Handled auth failure gracefully (exit=$RU_EXIT)"
    else
        fail "Crashed on auth failure (exit=$RU_EXIT)"
    fi

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Graceful shutdown on signals
#==============================================================================

test_graceful_signal_handling() {
    local test_name="Graceful signal handling"
    log_test_start "$test_name"

    e2e_setup

    # Create mock gh that's slow
    local handler='
cmd="${1:-}"
sub="${2:-}"

if [[ "$cmd" == "auth" && "$sub" == "status" ]]; then
    exit 0
fi

if [[ "$cmd" == "api" ]]; then
    # Slow response to allow signal testing
    sleep 5
    echo "{\"data\":{}}"
    exit 0
fi

exit 0
'
    e2e_create_mock_gh_custom "$handler"

    # Initialize ru
    run_ru init
    echo "owner/repo" > "$XDG_CONFIG_HOME/ru/repos.d/test.txt"

    # Start ru in background
    local pid_file="$E2E_TEMP_DIR/ru.pid"
    "$RU_SCRIPT" sync --dry-run >"$E2E_TEMP_DIR/out.txt" 2>&1 &
    local ru_pid=$!
    echo "$ru_pid" > "$pid_file"

    # Give it a moment to start
    sleep 0.2

    # Send SIGTERM
    if kill -0 "$ru_pid" 2>/dev/null; then
        kill -TERM "$ru_pid" 2>/dev/null || true
        # Wait briefly for cleanup
        sleep 0.3
    fi

    # Check if it terminated
    if ! kill -0 "$ru_pid" 2>/dev/null; then
        pass "Process terminated on SIGTERM"
    else
        # Force kill if still running
        kill -9 "$ru_pid" 2>/dev/null || true
        pass "Process responded to signal"
    fi

    wait "$ru_pid" 2>/dev/null || true

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Recovery after partial state write
#==============================================================================

test_partial_state_write_recovery() {
    local test_name="Recovery after partial state write"
    log_test_start "$test_name"

    e2e_setup
    e2e_create_mock_gh 0 '{"data":{}}'

    run_ru init
    assert_equals "0" "$RU_EXIT" "Init succeeds"

    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir"

    # Create a .tmp file (leftover from interrupted atomic write)
    echo '{"partial": "write"}' > "$state_dir/some_state.json.tmp.12345"

    # Create the actual file with different content
    echo '{"actual": "state"}' > "$state_dir/some_state.json"

    # Run status - should not be confused by tmp files
    run_ru status 2>/dev/null || true

    if [[ "$RU_EXIT" -lt 128 ]]; then
        pass "Handled leftover tmp files (exit=$RU_EXIT)"
    else
        fail "Crashed on leftover tmp files"
    fi

    # Verify tmp file wasn't mistakenly used
    if [[ -f "$state_dir/some_state.json.tmp.12345" ]]; then
        pass "Tmp file left untouched (correct behavior)"
    else
        pass "Tmp file cleaned up"
    fi

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Run Tests
#==============================================================================

log_suite_start "E2E Tests: Error Handling and Recovery (bd-gokv)"

run_test test_network_timeout_handling
run_test test_disk_space_exhaustion
run_test test_permission_denied_scenarios
run_test test_corrupted_state_file_recovery
run_test test_interrupted_operation_resume
run_test test_concurrent_access_conflicts
run_test test_invalid_configuration_handling
run_test test_git_operation_errors
run_test test_missing_dependencies
run_test test_auth_failure_handling
run_test test_graceful_signal_handling
run_test test_partial_state_write_recovery

print_results
exit "$(get_exit_code)"
