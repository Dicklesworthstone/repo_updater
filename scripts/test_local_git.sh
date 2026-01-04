#!/usr/bin/env bash
#
# Integration tests for git operations using local repositories
# Tests run without network access - uses temporary bare repos as "remotes"
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source required functions from ru
# We need to source selectively to avoid running main()
extract_function() {
    local func_name="$1"
    local source_file="$2"
    # Extract function definition
    sed -n "/^${func_name}()/,/^}/p" "$source_file"
}

# Set up minimal environment
RU_LOG_DIR="${TMPDIR:-/tmp}/ru-test-logs"
PROJECTS_DIR=""  # Will be set per test
LAYOUT="flat"
UPDATE_STRATEGY="ff-only"
AUTOSTASH="false"
FETCH_REMOTES="true"
DRY_RUN="false"
VERBOSE="false"
QUIET="false"
RESULTS_FILE=""
GIT_TIMEOUT="${GIT_TIMEOUT:-30}"
GIT_LOW_SPEED_LIMIT="${GIT_LOW_SPEED_LIMIT:-1000}"

# Define minimal log functions
log_info() { echo "INFO: $*"; }
log_success() { echo "SUCCESS: $*"; }
log_warn() { echo "WARN: $*"; }
log_error() { echo "ERROR: $*" >&2; }
log_step() { echo "STEP: $*"; }
log_verbose() { [[ "$VERBOSE" == "true" ]] && echo "VERBOSE: $*"; }

# Source core functions from ru
source <(sed -n '/^ensure_dir()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^json_escape()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^write_result()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^get_repo_log_path()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^is_git_repo()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^get_repo_status()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^setup_git_timeout()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^is_timeout_error()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^do_pull()/,/^}/p' "$PROJECT_DIR/ru")

#==============================================================================
# Test Framework
#==============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEMP_DIR=""

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
    PROJECTS_DIR="$TEMP_DIR/projects"
    RU_LOG_DIR="$TEMP_DIR/logs"
    RESULTS_FILE="$TEMP_DIR/results.ndjson"
    mkdir -p "$PROJECTS_DIR" "$RU_LOG_DIR"
    echo "" > "$RESULTS_FILE"
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

pass() {
    echo "PASS: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo "FAIL: $1"
    ((TESTS_FAILED++))
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$msg"
    else
        fail "$msg (expected to contain '$needle')"
    fi
}

#==============================================================================
# Helper Functions
#==============================================================================

# Create a bare "remote" repository
create_remote_repo() {
    local name="$1"
    local remote_dir="$TEMP_DIR/remotes/$name.git"
    mkdir -p "$remote_dir"
    git init --bare "$remote_dir" >/dev/null 2>&1
    # Set default branch to main so clones check out main and track it
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main
    echo "$remote_dir"
}

# Clone a remote to a working directory and make initial commit
init_repo_with_commit() {
    local remote_dir="$1"
    local work_dir="$2"

    git clone "$remote_dir" "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test User"
    # Explicitly create main branch (cloning empty repo has no branch)
    git -C "$work_dir" checkout -b main 2>/dev/null || true
    echo "initial content" > "$work_dir/file.txt"
    git -C "$work_dir" add file.txt
    git -C "$work_dir" commit -m "Initial commit" >/dev/null 2>&1
    # Use -u to set upstream tracking in one command
    git -C "$work_dir" push -u origin main >/dev/null 2>&1
}

# Add a commit to a repo and push
add_commit_and_push() {
    local work_dir="$1"
    local msg="$2"

    echo "$msg" >> "$work_dir/file.txt"
    git -C "$work_dir" add file.txt
    git -C "$work_dir" commit -m "$msg" >/dev/null 2>&1
    git -C "$work_dir" push >/dev/null 2>&1
}

# Add a local commit (don't push)
add_local_commit() {
    local work_dir="$1"
    local msg="$2"

    echo "$msg" >> "$work_dir/file.txt"
    git -C "$work_dir" add file.txt
    git -C "$work_dir" commit -m "$msg" >/dev/null 2>&1
}

# Make repo dirty (uncommitted changes)
make_dirty() {
    local work_dir="$1"
    echo "dirty" >> "$work_dir/file.txt"
}

#==============================================================================
# Tests
#==============================================================================

test_is_git_repo() {
    echo "Testing is_git_repo..."
    setup_test_env

    local remote=$(create_remote_repo "test1")
    local work_dir="$TEMP_DIR/work1"
    init_repo_with_commit "$remote" "$work_dir"

    if is_git_repo "$work_dir"; then
        pass "is_git_repo returns true for git directory"
    else
        fail "is_git_repo returns false for git directory"
    fi

    if is_git_repo "$TEMP_DIR"; then
        fail "is_git_repo returns true for non-git directory"
    else
        pass "is_git_repo returns false for non-git directory"
    fi

    cleanup_test_env
}

test_status_current() {
    echo "Testing get_repo_status for current repo..."
    setup_test_env

    local remote=$(create_remote_repo "current")
    local work_dir="$PROJECTS_DIR/current"
    init_repo_with_commit "$remote" "$work_dir"

    local status_line
    status_line=$(get_repo_status "$work_dir" "false")

    assert_contains "$status_line" "STATUS=current" "Status should be 'current'"
    assert_contains "$status_line" "AHEAD=0" "Should have 0 ahead"
    assert_contains "$status_line" "BEHIND=0" "Should have 0 behind"
    assert_contains "$status_line" "DIRTY=false" "Should not be dirty"

    cleanup_test_env
}

test_status_behind() {
    echo "Testing get_repo_status for behind repo..."
    setup_test_env

    local remote=$(create_remote_repo "behind")
    local dev_dir="$TEMP_DIR/dev"
    local work_dir="$PROJECTS_DIR/behind"

    # Create initial repo
    init_repo_with_commit "$remote" "$dev_dir"

    # Clone to projects dir (repo now has content, so tracking works)
    git clone "$remote" "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"

    # Make new commit in dev (simulating someone else pushing)
    add_commit_and_push "$dev_dir" "New commit"

    # Fetch to update refs
    git -C "$work_dir" fetch >/dev/null 2>&1

    local status_line
    status_line=$(get_repo_status "$work_dir" "false")

    assert_contains "$status_line" "STATUS=behind" "Status should be 'behind'"
    assert_contains "$status_line" "BEHIND=1" "Should have 1 behind"
    assert_contains "$status_line" "AHEAD=0" "Should have 0 ahead"

    cleanup_test_env
}

test_status_ahead() {
    echo "Testing get_repo_status for ahead repo..."
    setup_test_env

    local remote=$(create_remote_repo "ahead")
    local work_dir="$PROJECTS_DIR/ahead"
    init_repo_with_commit "$remote" "$work_dir"

    # Add local commit without pushing
    add_local_commit "$work_dir" "Local commit"

    local status_line
    status_line=$(get_repo_status "$work_dir" "false")

    assert_contains "$status_line" "STATUS=ahead" "Status should be 'ahead'"
    assert_contains "$status_line" "AHEAD=1" "Should have 1 ahead"
    assert_contains "$status_line" "BEHIND=0" "Should have 0 behind"

    cleanup_test_env
}

test_status_diverged() {
    echo "Testing get_repo_status for diverged repo..."
    setup_test_env

    local remote=$(create_remote_repo "diverged")
    local dev_dir="$TEMP_DIR/dev"
    local work_dir="$PROJECTS_DIR/diverged"

    # Create initial repo
    init_repo_with_commit "$remote" "$dev_dir"

    # Clone to projects dir (repo now has content, so tracking works)
    git clone "$remote" "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"

    # Make local commit
    add_local_commit "$work_dir" "Local change"

    # Make remote commit
    add_commit_and_push "$dev_dir" "Remote change"

    # Fetch to update refs
    git -C "$work_dir" fetch >/dev/null 2>&1

    local status_line
    status_line=$(get_repo_status "$work_dir" "false")

    assert_contains "$status_line" "STATUS=diverged" "Status should be 'diverged'"
    assert_contains "$status_line" "AHEAD=1" "Should have 1 ahead"
    assert_contains "$status_line" "BEHIND=1" "Should have 1 behind"

    cleanup_test_env
}

test_status_dirty() {
    echo "Testing get_repo_status for dirty repo..."
    setup_test_env

    local remote=$(create_remote_repo "dirty")
    local work_dir="$PROJECTS_DIR/dirty"
    init_repo_with_commit "$remote" "$work_dir"

    # Make uncommitted changes
    make_dirty "$work_dir"

    local status_line
    status_line=$(get_repo_status "$work_dir" "false")

    assert_contains "$status_line" "DIRTY=true" "Should be dirty"

    cleanup_test_env
}

test_do_pull() {
    echo "Testing do_pull..."
    setup_test_env

    local remote=$(create_remote_repo "pull")
    local dev_dir="$TEMP_DIR/dev"
    local work_dir="$PROJECTS_DIR/pull"

    # Create initial repo
    init_repo_with_commit "$remote" "$dev_dir"

    # Clone to projects dir (repo now has content, so tracking works)
    git clone "$remote" "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"

    # Make new commit in dev
    add_commit_and_push "$dev_dir" "New commit for pull test"

    # Verify we're behind
    git -C "$work_dir" fetch >/dev/null 2>&1
    local before_head
    before_head=$(git -C "$work_dir" rev-parse HEAD)

    # Pull
    do_pull "$work_dir" "pull" "ff-only" "false"

    local after_head
    after_head=$(git -C "$work_dir" rev-parse HEAD)

    if [[ "$before_head" != "$after_head" ]]; then
        pass "do_pull updated the repo"
    else
        fail "do_pull did not update the repo"
    fi

    cleanup_test_env
}

#==============================================================================
# Run Tests
#==============================================================================

echo "============================================"
echo "Integration Tests for Git Operations"
echo "============================================"
echo ""

test_is_git_repo
echo ""

test_status_current
echo ""

test_status_behind
echo ""

test_status_ahead
echo ""

test_status_diverged
echo ""

test_status_dirty
echo ""

test_do_pull
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

exit $TESTS_FAILED
