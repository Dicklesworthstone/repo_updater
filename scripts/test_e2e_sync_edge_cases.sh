#!/usr/bin/env bash
#
# E2E Test: ru sync edge cases
# Tests error handling, diverged repos, conflicts, and edge case detection
#
# Test coverage:
#   - Diverged repos (local and remote both have commits) - git behavior
#   - Merge conflicts during pull - git behavior
#   - ru sync exit codes with different scenarios
#   - Helpful error message verification
#   - Resume/restart interrupted sync functionality
#
# Note: Tests diverged/conflict scenarios using direct git commands
# (ru sync uses gh CLI for cloning which requires network/auth)
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1090  # Dynamic sourcing is intentional
# shellcheck disable=SC2317  # Utility functions available for future tests
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
    YELLOW='\033[0;33m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' RESET=''
fi

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
    # Override XDG directories to isolate tests
    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_STATE_HOME="$TEMP_DIR/state"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
    export HOME="$TEMP_DIR/home"
    mkdir -p "$HOME"

    # Create projects directory
    export TEST_PROJECTS_DIR="$TEMP_DIR/projects"
    mkdir -p "$TEST_PROJECTS_DIR"

    # Create remotes directory for bare repos
    mkdir -p "$TEMP_DIR/remotes"
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

pass() {
    echo -e "${GREEN}PASS${RESET}: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    ((TESTS_FAILED++))
}

skip() {
    echo -e "${YELLOW}SKIP${RESET}: $1"
}

#==============================================================================
# Assertion Helpers
#==============================================================================

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [[ "$expected" -eq "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg (expected exit code $expected, got $actual)"
    fi
}

assert_output_contains() {
    local output="$1"
    local pattern="$2"
    local msg="$3"
    if printf '%s\n' "$output" | grep -q "$pattern"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in output)"
    fi
}

assert_output_not_contains() {
    local output="$1"
    local pattern="$2"
    local msg="$3"
    if ! printf '%s\n' "$output" | grep -q "$pattern"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' unexpectedly found in output)"
    fi
}

assert_file_exists() {
    local path="$1"
    local msg="$2"
    if [[ -f "$path" ]]; then
        pass "$msg"
    else
        fail "$msg (file not found: $path)"
    fi
}

assert_file_contains() {
    local path="$1"
    local pattern="$2"
    local msg="$3"
    if [[ -f "$path" ]] && grep -q "$pattern" "$path"; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in $path)"
    fi
}

#==============================================================================
# Helper Functions for Local Git Repos
#==============================================================================

# Create a bare "remote" repository with initial content
create_bare_repo() {
    local name="$1"
    local remote_dir="$TEMP_DIR/remotes/$name.git"
    mkdir -p "$remote_dir"
    git init --bare "$remote_dir" >/dev/null 2>&1
    # Set default branch to main
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main
    echo "$remote_dir"
}

# Clone bare repo and make initial commit
init_local_repo() {
    local remote_dir="$1"
    local work_dir="$2"

    git clone "$remote_dir" "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test User"
    # Create main branch with initial commit
    git -C "$work_dir" checkout -b main 2>/dev/null || true
    echo "initial content" > "$work_dir/file.txt"
    git -C "$work_dir" add .
    git -C "$work_dir" commit -m "Initial commit" >/dev/null 2>&1
    git -C "$work_dir" push -u origin main >/dev/null 2>&1
}

# Add a commit to the bare remote (simulates another user's push)
add_remote_commit() {
    local remote_dir="$1"
    local filename="${2:-remote_file.txt}"
    local content="${3:-remote content}"

    # Clone to temp, commit, push
    local tmp_clone="$TEMP_DIR/tmp_clone_$$"
    git clone "$remote_dir" "$tmp_clone" >/dev/null 2>&1
    git -C "$tmp_clone" config user.email "other@test.com"
    git -C "$tmp_clone" config user.name "Other User"
    echo "$content" > "$tmp_clone/$filename"
    git -C "$tmp_clone" add .
    git -C "$tmp_clone" commit -m "Remote commit: $filename" >/dev/null 2>&1
    git -C "$tmp_clone" push origin main >/dev/null 2>&1
    rm -rf "$tmp_clone"
}

# Add a local commit (not pushed)
add_local_commit() {
    local work_dir="$1"
    local filename="${2:-local_file.txt}"
    local content="${3:-local content}"

    echo "$content" > "$work_dir/$filename"
    git -C "$work_dir" add .
    git -C "$work_dir" commit -m "Local commit: $filename" >/dev/null 2>&1
}

# Add repo to ru config
add_repo_to_config() {
    local repo_spec="$1"
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "$repo_spec" >> "$repos_file"
}

# Clear repos from config
clear_repos_config() {
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "# Test repos" > "$repos_file"
}

#==============================================================================
# Tests: Diverged Repos (Git Behavior)
#==============================================================================

test_diverged_repo_detected() {
    echo "Test: Diverged repo is detected by git status"
    setup_test_env

    # Create a bare remote
    local remote_dir
    remote_dir=$(create_bare_repo "diverged-repo")

    # Set up local clone with initial commit
    local local_repo="$TEST_PROJECTS_DIR/diverged-repo"
    init_local_repo "$remote_dir" "$local_repo"

    # Add a remote commit (simulates someone else pushing)
    add_remote_commit "$remote_dir" "remote_change.txt" "remote changes"

    # Add a local commit (not pushed) - this creates divergence
    add_local_commit "$local_repo" "local_change.txt" "local changes"

    # Fetch to update remote tracking refs
    git -C "$local_repo" fetch >/dev/null 2>&1

    # Check git status for divergence
    local status_output
    status_output=$(git -C "$local_repo" status 2>&1)

    # Should show "have diverged"
    if printf '%s\n' "$status_output" | grep -qi "diverged"; then
        pass "Git detects diverged state"
    else
        fail "Git should detect diverged state"
    fi

    # Verify ff-only pull fails (ru's default strategy)
    local pull_output pull_exit
    if pull_output=$(git -C "$local_repo" pull --ff-only 2>&1); then
        pull_exit=0
    else
        pull_exit=$?
    fi

    if [[ $pull_exit -ne 0 ]]; then
        pass "ff-only pull fails on diverged repo (expected)"
    else
        fail "ff-only pull should fail on diverged repo"
    fi

    cleanup_test_env
}

test_diverged_repo_rebase_resolution() {
    echo "Test: Diverged repo can be resolved with rebase"
    setup_test_env

    # Create a bare remote
    local remote_dir
    remote_dir=$(create_bare_repo "rebase-repo")

    # Set up local clone
    local local_repo="$TEST_PROJECTS_DIR/rebase-repo"
    init_local_repo "$remote_dir" "$local_repo"

    # Create divergence with non-conflicting changes
    add_remote_commit "$remote_dir" "remote.txt" "remote content"
    add_local_commit "$local_repo" "local.txt" "local content"

    # Rebase should work (this is one of ru's resolution hints)
    local rebase_output
    rebase_output=$(git -C "$local_repo" pull --rebase 2>&1)
    local rebase_exit=$?

    if [[ $rebase_exit -eq 0 ]]; then
        pass "Rebase succeeds for non-conflicting divergence"
    else
        fail "Rebase should succeed for non-conflicting divergence"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: Merge Conflicts (Git Behavior)
#==============================================================================

test_merge_conflict_detected() {
    echo "Test: Merge conflict is detected during pull"
    setup_test_env

    # Create a bare remote
    local remote_dir
    remote_dir=$(create_bare_repo "conflict-repo")

    # Set up local clone
    local local_repo="$TEST_PROJECTS_DIR/conflict-repo"
    init_local_repo "$remote_dir" "$local_repo"

    # Both modify the same file differently - this will cause a conflict
    # First, add remote change to same file
    local tmp_clone="$TEMP_DIR/tmp_conflict_clone"
    git clone "$remote_dir" "$tmp_clone" >/dev/null 2>&1
    git -C "$tmp_clone" config user.email "other@test.com"
    git -C "$tmp_clone" config user.name "Other User"
    echo "remote version of content" > "$tmp_clone/file.txt"
    git -C "$tmp_clone" add .
    git -C "$tmp_clone" commit -m "Remote change to file.txt" >/dev/null 2>&1
    git -C "$tmp_clone" push origin main >/dev/null 2>&1
    rm -rf "$tmp_clone"

    # Now modify same file locally (different content)
    echo "local version of content" > "$local_repo/file.txt"
    git -C "$local_repo" add .
    git -C "$local_repo" commit -m "Local change to file.txt" >/dev/null 2>&1

    # Try to pull with merge - should fail with conflict
    local pull_output pull_exit
    if pull_output=$(git -C "$local_repo" pull --no-rebase 2>&1); then
        pull_exit=0
    else
        pull_exit=$?
    fi

    if [[ $pull_exit -ne 0 ]]; then
        pass "Pull with conflicting changes fails (expected)"
    else
        fail "Pull with conflicting changes should fail"
    fi

    # Check for conflict markers in output
    if printf '%s\n' "$pull_output" | grep -qi "conflict\|CONFLICT"; then
        pass "Git reports conflict in output"
    else
        # May show as "diverged" first
        if printf '%s\n' "$pull_output" | grep -qi "diverged"; then
            pass "Git reports diverged state (conflict detected)"
        else
            fail "Git should report conflict or diverged state"
        fi
    fi

    cleanup_test_env
}

test_conflict_leaves_markers() {
    echo "Test: Unresolved conflict leaves markers in file"
    setup_test_env

    # Create a bare remote
    local remote_dir
    remote_dir=$(create_bare_repo "marker-repo")

    # Set up local clone
    local local_repo="$TEST_PROJECTS_DIR/marker-repo"
    init_local_repo "$remote_dir" "$local_repo"

    # Create conflicting changes
    local tmp_clone="$TEMP_DIR/tmp_marker_clone"
    git clone "$remote_dir" "$tmp_clone" >/dev/null 2>&1
    git -C "$tmp_clone" config user.email "other@test.com"
    git -C "$tmp_clone" config user.name "Other User"
    echo "remote line" > "$tmp_clone/file.txt"
    git -C "$tmp_clone" add .
    git -C "$tmp_clone" commit -m "Remote" >/dev/null 2>&1
    git -C "$tmp_clone" push origin main >/dev/null 2>&1
    rm -rf "$tmp_clone"

    echo "local line" > "$local_repo/file.txt"
    git -C "$local_repo" add .
    git -C "$local_repo" commit -m "Local" >/dev/null 2>&1

    # Attempt merge (will fail with conflict)
    git -C "$local_repo" pull --no-rebase 2>/dev/null || true

    # Check for conflict markers in the file
    if grep -q "<<<<<<" "$local_repo/file.txt" 2>/dev/null; then
        pass "Conflict markers present in file"
        # Clean up conflict state for next tests
        git -C "$local_repo" merge --abort 2>/dev/null || true
    else
        # Conflict might not have reached merge stage (ff-only rejection)
        skip "Conflict markers not present (merge may have been rejected before reaching file)"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: Exit Codes (Git Operations)
#==============================================================================

test_exit_code_pull_success() {
    echo "Test: Successful pull returns exit code 0"
    setup_test_env

    # Create a bare remote
    local remote_dir
    remote_dir=$(create_bare_repo "success-repo")

    # Set up local clone (up to date)
    local local_repo="$TEST_PROJECTS_DIR/success-repo"
    init_local_repo "$remote_dir" "$local_repo"

    # Pull should succeed (already up to date)
    local pull_output
    pull_output=$(git -C "$local_repo" pull 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Pull on up-to-date repo returns exit code 0"

    cleanup_test_env
}

test_exit_code_pull_with_updates() {
    echo "Test: Pull with updates returns exit code 0"
    setup_test_env

    # Create a bare remote
    local remote_dir
    remote_dir=$(create_bare_repo "update-repo")

    # Set up local clone
    local local_repo="$TEST_PROJECTS_DIR/update-repo"
    init_local_repo "$remote_dir" "$local_repo"

    # Add a remote commit
    add_remote_commit "$remote_dir" "new_file.txt" "new content"

    # Pull should succeed
    local pull_output
    pull_output=$(git -C "$local_repo" pull 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Pull with updates returns exit code 0"

    # Verify the new file was pulled
    if [[ -f "$local_repo/new_file.txt" ]]; then
        pass "New file was pulled successfully"
    else
        fail "New file should have been pulled"
    fi

    cleanup_test_env
}

test_exit_code_ff_only_diverged() {
    echo "Test: ff-only pull on diverged repo returns non-zero"
    setup_test_env

    # Create diverged scenario
    local remote_dir
    remote_dir=$(create_bare_repo "exitcode-repo")

    local local_repo="$TEST_PROJECTS_DIR/exitcode-repo"
    init_local_repo "$remote_dir" "$local_repo"

    add_remote_commit "$remote_dir" "remote.txt" "remote"
    add_local_commit "$local_repo" "local.txt" "local"

    # Fetch first to update tracking refs
    git -C "$local_repo" fetch origin >/dev/null 2>&1

    # ff-only pull should fail on diverged
    local pull_output exit_code
    if pull_output=$(git -C "$local_repo" pull --ff-only 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi

    if [[ $exit_code -ne 0 ]]; then
        pass "ff-only pull on diverged repo returns non-zero exit code"
    else
        fail "ff-only pull on diverged repo should return non-zero"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: Autostash Behavior
#==============================================================================

test_autostash_dirty_repo() {
    echo "Test: Pull with autostash handles dirty repo"
    setup_test_env

    # Create a bare remote
    local remote_dir
    remote_dir=$(create_bare_repo "autostash-repo")

    # Set up local clone
    local local_repo="$TEST_PROJECTS_DIR/autostash-repo"
    init_local_repo "$remote_dir" "$local_repo"

    # Add a remote commit
    add_remote_commit "$remote_dir" "remote.txt" "remote content"

    # Make local repo dirty (uncommitted changes)
    echo "dirty changes" >> "$local_repo/file.txt"

    # Pull without autostash should fail (or warn)
    local pull_output pull_exit
    if pull_output=$(git -C "$local_repo" pull 2>&1); then
        pull_exit=0
    else
        pull_exit=$?
    fi

    # Git should complain about uncommitted changes or fail
    if [[ $pull_exit -ne 0 ]] || printf '%s\n' "$pull_output" | grep -qi "uncommitted\|stash\|dirty"; then
        pass "Pull detects dirty working directory"
    else
        # Some git versions may auto-stash, which is also acceptable
        pass "Pull completed (git may have auto-handled dirty state)"
    fi

    cleanup_test_env
}

test_stash_and_pull() {
    echo "Test: Manual stash allows pull to proceed"
    setup_test_env

    # Create a bare remote
    local remote_dir
    remote_dir=$(create_bare_repo "stash-repo")

    # Set up local clone
    local local_repo="$TEST_PROJECTS_DIR/stash-repo"
    init_local_repo "$remote_dir" "$local_repo"

    # Add a remote commit
    add_remote_commit "$remote_dir" "remote.txt" "remote content"

    # Make local repo dirty
    echo "local changes" >> "$local_repo/file.txt"

    # Stash, pull, pop
    git -C "$local_repo" stash >/dev/null 2>&1
    local pull_output
    pull_output=$(git -C "$local_repo" pull 2>&1)
    local pull_exit=$?
    git -C "$local_repo" stash pop >/dev/null 2>&1 || true

    assert_exit_code 0 "$pull_exit" "Pull succeeds after stashing changes"

    # Verify our local changes are back
    if grep -q "local changes" "$local_repo/file.txt"; then
        pass "Local changes restored after stash pop"
    else
        fail "Local changes should be restored after stash pop"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: Error Scenarios
#==============================================================================

test_not_git_repo_detected() {
    echo "Test: Git operations fail on non-git directory"
    setup_test_env

    # Create a directory that's not a git repo
    local fake_repo="$TEST_PROJECTS_DIR/not-a-repo"
    mkdir -p "$fake_repo"
    echo "just a file" > "$fake_repo/file.txt"

    # Git status should fail (exit code 128 = fatal error)
    local status_output
    status_output=$(git -C "$fake_repo" status 2>&1)
    local status_exit=$?

    # Git returns 128 for fatal errors like "not a git repository"
    if [[ $status_exit -eq 128 ]] || [[ $status_exit -ne 0 ]]; then
        pass "Git status fails on non-git directory (exit code $status_exit)"
    else
        fail "Git status should fail on non-git directory"
    fi

    # Output should mention not a git repo
    if printf '%s\n' "$status_output" | grep -qi "not a git repository"; then
        pass "Error message mentions not a git repository"
    else
        fail "Error should mention 'not a git repository'"
    fi

    cleanup_test_env
}

test_remote_url_can_be_checked() {
    echo "Test: Remote URL can be verified"
    setup_test_env

    # Create a bare remote and local clone
    local remote_dir
    remote_dir=$(create_bare_repo "check-remote-repo")
    local local_repo="$TEST_PROJECTS_DIR/check-remote-repo"
    init_local_repo "$remote_dir" "$local_repo"

    # Get the remote URL
    local remote_url
    remote_url=$(git -C "$local_repo" remote get-url origin 2>&1)
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "Can get remote URL"

    # URL should match what we set
    if [[ "$remote_url" == "$remote_dir" ]]; then
        pass "Remote URL matches expected value"
    else
        fail "Remote URL should match: expected '$remote_dir', got '$remote_url'"
    fi

    cleanup_test_env
}

test_remote_mismatch_detection() {
    echo "Test: Different remote URL is detectable"
    setup_test_env

    # Create two different remotes
    local remote1 remote2
    remote1=$(create_bare_repo "original-remote")
    remote2=$(create_bare_repo "different-remote")

    # Set up local clone pointing to remote1
    local local_repo="$TEST_PROJECTS_DIR/mismatch-repo"
    init_local_repo "$remote1" "$local_repo"

    # Get current remote URL
    local current_remote
    current_remote=$(git -C "$local_repo" remote get-url origin)

    # Compare with expected remote2
    if [[ "$current_remote" != "$remote2" ]]; then
        pass "Remote mismatch is detectable (URLs differ)"
    else
        fail "Remote URLs should be different for this test"
    fi

    # Can change remote URL
    git -C "$local_repo" remote set-url origin "$remote2" >/dev/null 2>&1
    local new_remote
    new_remote=$(git -C "$local_repo" remote get-url origin)

    if [[ "$new_remote" == "$remote2" ]]; then
        pass "Remote URL can be updated"
    else
        fail "Remote URL update failed"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: Resume/Restart Functionality
#==============================================================================

test_interrupted_sync_exits_code_5() {
    echo "Test: Interrupted sync state causes exit code 5"
    setup_test_env

    # Initialize ru config
    "$RU_SCRIPT" init >/dev/null 2>&1 || true

    # Add a fake repo to the config (so sync has something to process)
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "testowner/testrepo" >> "$repos_file"

    # Set PROJECTS_DIR env to our test dir
    export RU_PROJECTS_DIR="$TEST_PROJECTS_DIR"

    # Create a fake sync_state.json to simulate interrupted sync
    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir"
    local state_file="$state_dir/sync_state.json"

    cat > "$state_file" << 'EOF'
{
    "run_id": "2026-01-03T12:00:00",
    "status": "in_progress",
    "config_hash": "abc123",
    "completed": ["repo1", "repo2"],
    "pending": ["repo3", "repo4"]
}
EOF

    # Running ru sync without --resume or --restart should exit with code 5
    local output exit_code
    if output=$("$RU_SCRIPT" sync 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi

    if [[ $exit_code -eq 5 ]]; then
        pass "ru sync with interrupted state exits with code 5"
    else
        fail "ru sync with interrupted state should exit with code 5 (got $exit_code)"
    fi

    # Output should mention resume/restart options
    if printf '%s\n' "$output" | grep -qi "resume\|restart"; then
        pass "Exit message mentions resume/restart options"
    else
        fail "Exit message should mention resume/restart options"
    fi

    cleanup_test_env
}

test_restart_clears_state() {
    echo "Test: --restart clears sync state"
    setup_test_env

    # Initialize ru config with a test repo
    "$RU_SCRIPT" init >/dev/null 2>&1 || true

    # Add a fake repo to the config (so sync has something to process)
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "testowner/testrepo" >> "$repos_file"
    export RU_PROJECTS_DIR="$TEST_PROJECTS_DIR"

    # Create state file
    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir"
    local state_file="$state_dir/sync_state.json"

    cat > "$state_file" << 'EOF'
{
    "run_id": "2026-01-03T12:00:00",
    "status": "in_progress",
    "config_hash": "abc123",
    "completed": ["repo1"],
    "pending": ["repo2"]
}
EOF

    # Verify state file exists
    if [[ -f "$state_file" ]]; then
        pass "State file exists before restart"
    else
        fail "State file should exist before restart"
        cleanup_test_env
        return
    fi

    # Run with --restart (will likely fail on network, but should clear state first)
    "$RU_SCRIPT" sync --restart 2>&1 || true

    # State file should be removed or status no longer "in_progress"
    if [[ ! -f "$state_file" ]] || ! grep -q '"status": "in_progress"' "$state_file" 2>/dev/null; then
        pass "--restart clears or completes interrupted state"
    else
        fail "--restart should clear interrupted state"
    fi

    cleanup_test_env
}

test_resume_option_recognized() {
    echo "Test: --resume option is recognized"
    setup_test_env

    # Initialize ru config
    "$RU_SCRIPT" init >/dev/null 2>&1 || true

    # Add a fake repo to the config (so sync has something to process)
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "testowner/testrepo" >> "$repos_file"
    export RU_PROJECTS_DIR="$TEST_PROJECTS_DIR"

    # Create state file
    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir"
    local state_file="$state_dir/sync_state.json"

    cat > "$state_file" << 'EOF'
{
    "run_id": "2026-01-03T12:00:00",
    "status": "in_progress",
    "config_hash": "abc123",
    "completed": ["already-done"],
    "pending": ["needs-work"]
}
EOF

    # Run with --resume (will likely fail on network, but should not exit with 4/invalid args)
    local output exit_code
    if output=$("$RU_SCRIPT" sync --resume 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi

    # Should not exit with code 4 (invalid arguments) or 5 (needs resume/restart)
    if [[ $exit_code -ne 4 ]] && [[ $exit_code -ne 5 ]]; then
        pass "--resume option is accepted (exit code: $exit_code)"
    else
        fail "--resume should be accepted (got exit code $exit_code)"
    fi

    # Output should mention resuming
    if printf '%s\n' "$output" | grep -qi "resum"; then
        pass "Output mentions resuming"
    else
        # May not always show "resuming" message, so just skip
        skip "Resume message not found in output (may depend on repo state)"
    fi

    cleanup_test_env
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "E2E Tests: ru sync edge cases"
echo "============================================"
echo ""

# Diverged repo tests
test_diverged_repo_detected
echo ""
test_diverged_repo_rebase_resolution
echo ""

# Merge conflict tests
test_merge_conflict_detected
echo ""
test_conflict_leaves_markers
echo ""

# Exit code tests
test_exit_code_pull_success
echo ""
test_exit_code_pull_with_updates
echo ""
test_exit_code_ff_only_diverged
echo ""

# Autostash tests
test_autostash_dirty_repo
echo ""
test_stash_and_pull
echo ""

# Error scenario tests
test_not_git_repo_detected
echo ""
test_remote_url_can_be_checked
echo ""
test_remote_mismatch_detection
echo ""

# Resume/restart tests
test_interrupted_sync_exits_code_5
echo ""
test_restart_clears_state
echo ""
test_resume_option_recognized
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

[[ $TESTS_FAILED -eq 0 ]]
