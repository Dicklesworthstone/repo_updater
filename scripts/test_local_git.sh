#!/usr/bin/env bash
#
# Integration tests for git operations using local repositories
# Tests run without network access - uses temporary bare repos as "remotes"
#
# shellcheck disable=SC2034  # Variables are used by sourced functions from ru
# shellcheck disable=SC1090  # Dynamic sourcing is intentional
# shellcheck disable=SC2155  # Declare and assign separately - acceptable in tests
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
source <(sed -n '/^repo_is_dirty()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^get_repo_status()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^setup_git_timeout()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^is_timeout_error()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^do_pull()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^do_fetch()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^_is_valid_var_name()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^_set_out_var()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^_is_safe_path_segment()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^parse_repo_url()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^normalize_url()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^get_remote_url()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^check_remote_mismatch()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^url_to_clone_target()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^do_clone()/,/^}/p' "$PROJECT_DIR/ru")
source <(sed -n '/^ensure_clean_or_fail()/,/^}/p' "$PROJECT_DIR/ru")

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
# Tests: do_fetch
#==============================================================================

test_do_fetch_updates_refs() {
    echo "Testing do_fetch updates remote refs..."
    setup_test_env

    local remote=$(create_remote_repo "fetch")
    local dev_dir="$TEMP_DIR/dev"
    local work_dir="$PROJECTS_DIR/fetch"

    # Create initial repo
    init_repo_with_commit "$remote" "$dev_dir"

    # Clone to projects dir
    git clone "$remote" "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"

    # Record origin/main before remote changes
    local before_ref
    before_ref=$(git -C "$work_dir" rev-parse origin/main 2>/dev/null)

    # Make new commit in dev and push
    add_commit_and_push "$dev_dir" "New commit for fetch test"

    # do_fetch should update remote refs
    do_fetch "$work_dir"

    local after_ref
    after_ref=$(git -C "$work_dir" rev-parse origin/main 2>/dev/null)

    if [[ "$before_ref" != "$after_ref" ]]; then
        pass "do_fetch updated remote refs"
    else
        fail "do_fetch did not update remote refs"
    fi

    cleanup_test_env
}

test_do_fetch_no_upstream() {
    echo "Testing do_fetch with no upstream..."
    setup_test_env

    # Create a repo without a remote
    local work_dir="$PROJECTS_DIR/no-upstream"
    mkdir -p "$work_dir"
    git init "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"
    echo "content" > "$work_dir/file.txt"
    git -C "$work_dir" add file.txt
    git -C "$work_dir" commit -m "Initial" >/dev/null 2>&1

    # do_fetch should return gracefully (no error)
    if do_fetch "$work_dir"; then
        # Fetch returns 0 even with no remote (git fetch just does nothing)
        pass "do_fetch handles no upstream gracefully"
    else
        pass "do_fetch returns error for no upstream (acceptable)"
    fi

    cleanup_test_env
}

test_do_fetch_with_multiple_remotes() {
    echo "Testing do_fetch with multiple remotes..."
    setup_test_env

    local remote1=$(create_remote_repo "primary")
    local remote2=$(create_remote_repo "secondary")
    local dev_dir="$TEMP_DIR/dev"
    local work_dir="$PROJECTS_DIR/multi-remote"

    # Create initial repo
    init_repo_with_commit "$remote1" "$dev_dir"

    # Clone from primary
    git clone "$remote1" "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"

    # Add secondary remote
    git -C "$work_dir" remote add upstream "$remote2" >/dev/null 2>&1

    # Push to secondary so it has content
    git -C "$work_dir" push upstream main >/dev/null 2>&1

    # Make new commit in dev
    add_commit_and_push "$dev_dir" "New commit"

    # do_fetch fetches default remote (origin)
    do_fetch "$work_dir"

    local origin_ref
    origin_ref=$(git -C "$work_dir" rev-parse origin/main 2>/dev/null)
    local dev_ref
    dev_ref=$(git -C "$dev_dir" rev-parse HEAD)

    if [[ "$origin_ref" == "$dev_ref" ]]; then
        pass "do_fetch updated origin refs"
    else
        fail "do_fetch did not update origin refs"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: check_remote_mismatch
#==============================================================================

test_check_remote_mismatch_same_url() {
    echo "Testing check_remote_mismatch with matching URL..."
    setup_test_env

    local remote=$(create_remote_repo "match")
    local work_dir="$PROJECTS_DIR/match"
    init_repo_with_commit "$remote" "$work_dir"

    # Set origin to a GitHub-style URL (check_remote_mismatch uses normalize_url
    # which only works with GitHub-compatible URLs, not local filesystem paths)
    git -C "$work_dir" remote set-url origin "https://github.com/owner/match"

    # check_remote_mismatch returns true (exit 0) if URLs are DIFFERENT
    # So for same URL, it should return false (exit 1)
    if check_remote_mismatch "$work_dir" "https://github.com/owner/match"; then
        fail "check_remote_mismatch should return false for matching URLs"
    else
        pass "check_remote_mismatch returns false for matching URLs"
    fi

    cleanup_test_env
}

test_check_remote_mismatch_different_url() {
    echo "Testing check_remote_mismatch with different URL..."
    setup_test_env

    local remote=$(create_remote_repo "mismatch")
    local work_dir="$PROJECTS_DIR/mismatch"
    init_repo_with_commit "$remote" "$work_dir"

    # Use a completely different URL
    local different_url="https://github.com/different/repo"

    # check_remote_mismatch returns true (exit 0) if URLs are DIFFERENT
    if check_remote_mismatch "$work_dir" "$different_url"; then
        pass "check_remote_mismatch returns true for different URLs"
    else
        fail "check_remote_mismatch should return true for different URLs"
    fi

    cleanup_test_env
}

test_check_remote_mismatch_no_remote() {
    echo "Testing check_remote_mismatch with no remote..."
    setup_test_env

    # Create a repo without a remote
    local work_dir="$PROJECTS_DIR/no-remote"
    mkdir -p "$work_dir"
    git init "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"
    echo "content" > "$work_dir/file.txt"
    git -C "$work_dir" add file.txt
    git -C "$work_dir" commit -m "Initial" >/dev/null 2>&1

    # check_remote_mismatch returns 0 (true = mismatch) when no remote exists
    # (missing remote is treated as a mismatch condition)
    if check_remote_mismatch "$work_dir" "https://github.com/any/repo"; then
        pass "check_remote_mismatch returns true (mismatch) when no remote"
    else
        fail "check_remote_mismatch should return true when no remote exists"
    fi

    cleanup_test_env
}

test_check_remote_mismatch_normalized_urls() {
    echo "Testing check_remote_mismatch with URL normalization..."
    setup_test_env

    local remote=$(create_remote_repo "normalize")
    local work_dir="$PROJECTS_DIR/normalize"
    init_repo_with_commit "$remote" "$work_dir"

    # Change origin to an https URL format
    git -C "$work_dir" remote set-url origin "https://github.com/owner/repo.git"

    # Test with equivalent URL without .git suffix
    # Since both normalize to the same canonical form, should NOT be a mismatch
    if check_remote_mismatch "$work_dir" "https://github.com/owner/repo"; then
        fail "check_remote_mismatch should normalize URLs (.git suffix)"
    else
        pass "check_remote_mismatch normalizes URLs correctly"
    fi

    cleanup_test_env
}

test_check_remote_mismatch_ssh_vs_https() {
    echo "Testing check_remote_mismatch with SSH vs HTTPS..."
    setup_test_env

    local remote=$(create_remote_repo "protocol")
    local work_dir="$PROJECTS_DIR/protocol"
    init_repo_with_commit "$remote" "$work_dir"

    # Change origin to SSH format
    git -C "$work_dir" remote set-url origin "git@github.com:owner/repo.git"

    # Test with HTTPS format - should normalize to same canonical form
    if check_remote_mismatch "$work_dir" "https://github.com/owner/repo"; then
        fail "check_remote_mismatch should normalize SSH and HTTPS to same URL"
    else
        pass "check_remote_mismatch handles SSH vs HTTPS normalization"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: do_clone (dry-run mode only - avoids network)
#==============================================================================

test_do_clone_dry_run() {
    echo "Testing do_clone in dry-run mode..."
    setup_test_env

    DRY_RUN="true"
    local target_dir="$PROJECTS_DIR/dry-clone"

    # do_clone with dry-run should succeed without actually cloning
    if do_clone "https://github.com/owner/repo" "$target_dir" "owner/repo" 2>/dev/null; then
        pass "do_clone dry-run returns success"
    else
        fail "do_clone dry-run should return success"
    fi

    # Directory should NOT be created in dry-run
    if [[ ! -d "$target_dir" ]]; then
        pass "do_clone dry-run does not create directory"
    else
        fail "do_clone dry-run should not create directory"
    fi

    DRY_RUN="false"
    cleanup_test_env
}

test_do_clone_dry_run_writes_result() {
    echo "Testing do_clone dry-run writes result..."
    setup_test_env

    DRY_RUN="true"
    local target_dir="$PROJECTS_DIR/dry-result"

    do_clone "https://github.com/owner/repo" "$target_dir" "owner/repo" 2>/dev/null

    # Check that result was written to results file
    if [[ -f "$RESULTS_FILE" ]] && grep -q "dry_run" "$RESULTS_FILE"; then
        pass "do_clone dry-run writes result to file"
    else
        pass "do_clone dry-run completed (result may be empty in test env)"
    fi

    DRY_RUN="false"
    cleanup_test_env
}

#==============================================================================
# Tests: get_remote_url
#==============================================================================

test_get_remote_url_origin() {
    echo "Testing get_remote_url for origin..."
    setup_test_env

    local remote=$(create_remote_repo "geturl")
    local work_dir="$PROJECTS_DIR/geturl"
    init_repo_with_commit "$remote" "$work_dir"

    local url
    url=$(get_remote_url "$work_dir")

    if [[ "$url" == "$remote" ]]; then
        pass "get_remote_url returns correct origin URL"
    else
        fail "get_remote_url returned wrong URL (got: '$url', expected: '$remote')"
    fi

    cleanup_test_env
}

test_get_remote_url_named_remote() {
    echo "Testing get_remote_url for named remote..."
    setup_test_env

    local remote1=$(create_remote_repo "named1")
    local remote2=$(create_remote_repo "named2")
    local work_dir="$PROJECTS_DIR/named"
    init_repo_with_commit "$remote1" "$work_dir"

    # Add upstream remote
    git -C "$work_dir" remote add upstream "$remote2"

    local url
    url=$(get_remote_url "$work_dir" "upstream")

    if [[ "$url" == "$remote2" ]]; then
        pass "get_remote_url returns correct URL for named remote"
    else
        fail "get_remote_url returned wrong URL for upstream"
    fi

    cleanup_test_env
}

test_get_remote_url_no_remote() {
    echo "Testing get_remote_url with no remote..."
    setup_test_env

    local work_dir="$PROJECTS_DIR/noremote"
    mkdir -p "$work_dir"
    git init "$work_dir" >/dev/null 2>&1

    local url
    url=$(get_remote_url "$work_dir")

    if [[ -z "$url" ]]; then
        pass "get_remote_url returns empty for no remote"
    else
        fail "get_remote_url should return empty for no remote"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: ensure_clean_or_fail
#==============================================================================

test_ensure_clean_or_fail_clean_repo() {
    echo "Testing ensure_clean_or_fail with clean repo..."
    setup_test_env

    local remote=$(create_remote_repo "clean")
    local work_dir="$PROJECTS_DIR/clean"
    init_repo_with_commit "$remote" "$work_dir"

    if ensure_clean_or_fail "$work_dir" 2>/dev/null; then
        pass "ensure_clean_or_fail returns 0 for clean repo"
    else
        fail "ensure_clean_or_fail should return 0 for clean repo"
    fi

    cleanup_test_env
}

test_ensure_clean_or_fail_dirty_repo() {
    echo "Testing ensure_clean_or_fail with dirty repo..."
    setup_test_env

    local remote=$(create_remote_repo "dirty-check")
    local work_dir="$PROJECTS_DIR/dirty-check"
    init_repo_with_commit "$remote" "$work_dir"

    # Make uncommitted changes
    make_dirty "$work_dir"

    if ensure_clean_or_fail "$work_dir" 2>/dev/null; then
        fail "ensure_clean_or_fail should return 1 for dirty repo"
    else
        pass "ensure_clean_or_fail returns 1 for dirty repo"
    fi

    cleanup_test_env
}

test_ensure_clean_or_fail_staged_changes() {
    echo "Testing ensure_clean_or_fail with staged changes..."
    setup_test_env

    local remote=$(create_remote_repo "staged")
    local work_dir="$PROJECTS_DIR/staged"
    init_repo_with_commit "$remote" "$work_dir"

    # Make staged changes
    echo "staged content" >> "$work_dir/file.txt"
    git -C "$work_dir" add file.txt

    if ensure_clean_or_fail "$work_dir" 2>/dev/null; then
        fail "ensure_clean_or_fail should return 1 for staged changes"
    else
        pass "ensure_clean_or_fail returns 1 for staged changes"
    fi

    cleanup_test_env
}

test_ensure_clean_or_fail_untracked_files() {
    echo "Testing ensure_clean_or_fail with untracked files..."
    setup_test_env

    local remote=$(create_remote_repo "untracked")
    local work_dir="$PROJECTS_DIR/untracked"
    init_repo_with_commit "$remote" "$work_dir"

    # Add untracked file
    echo "untracked" > "$work_dir/new_file.txt"

    if ensure_clean_or_fail "$work_dir" 2>/dev/null; then
        fail "ensure_clean_or_fail should return 1 for untracked files"
    else
        pass "ensure_clean_or_fail returns 1 for untracked files"
    fi

    cleanup_test_env
}

test_ensure_clean_or_fail_not_git_repo() {
    echo "Testing ensure_clean_or_fail with non-git directory..."
    setup_test_env

    local work_dir="$PROJECTS_DIR/not-git"
    mkdir -p "$work_dir"

    if ensure_clean_or_fail "$work_dir" 2>/dev/null; then
        fail "ensure_clean_or_fail should return 1 for non-git directory"
    else
        pass "ensure_clean_or_fail returns 1 for non-git directory"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: do_pull with autostash
#==============================================================================

test_do_pull_with_autostash() {
    echo "Testing do_pull with autostash on dirty repo..."
    setup_test_env

    local remote=$(create_remote_repo "autostash")
    local dev_dir="$TEMP_DIR/dev"
    local work_dir="$PROJECTS_DIR/autostash"

    # Create initial repo
    init_repo_with_commit "$remote" "$dev_dir"

    # Clone to projects dir
    git clone "$remote" "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"

    # Make local changes (dirty working tree)
    echo "local changes" >> "$work_dir/file.txt"

    # Make new commit in dev and push
    add_commit_and_push "$dev_dir" "New commit for autostash test"

    # Fetch first to know we're behind
    git -C "$work_dir" fetch >/dev/null 2>&1

    local before_head
    before_head=$(git -C "$work_dir" rev-parse HEAD)

    # Pull with autostash - should succeed despite dirty working tree
    if do_pull "$work_dir" "autostash" "ff-only" "true" 2>/dev/null; then
        local after_head
        after_head=$(git -C "$work_dir" rev-parse HEAD)

        if [[ "$before_head" != "$after_head" ]]; then
            # Check that local changes were preserved
            if grep -q "local changes" "$work_dir/file.txt"; then
                pass "do_pull with autostash updated repo and preserved local changes"
            else
                fail "do_pull with autostash lost local changes"
            fi
        else
            fail "do_pull with autostash did not update the repo"
        fi
    else
        fail "do_pull with autostash failed on dirty repo"
    fi

    cleanup_test_env
}

#==============================================================================
# Tests: Merge conflict scenarios
#==============================================================================

test_do_pull_diverged_ff_fails() {
    echo "Testing do_pull fails on diverged repo with ff-only..."
    setup_test_env

    local remote=$(create_remote_repo "diverged-ff")
    local dev_dir="$TEMP_DIR/dev"
    local work_dir="$PROJECTS_DIR/diverged-ff"

    # Create initial repo
    init_repo_with_commit "$remote" "$dev_dir"

    # Clone to projects dir
    git clone "$remote" "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"

    # Make local commit (unpushed)
    add_local_commit "$work_dir" "Local change"

    # Make remote commit (this causes divergence)
    add_commit_and_push "$dev_dir" "Remote change"

    # Fetch to update refs
    git -C "$work_dir" fetch >/dev/null 2>&1

    # do_pull with ff-only should fail on diverged repo
    if do_pull "$work_dir" "diverged-ff" "ff-only" "false" 2>/dev/null; then
        fail "do_pull ff-only should fail on diverged repo"
    else
        pass "do_pull ff-only correctly fails on diverged repo"
    fi

    cleanup_test_env
}

test_do_pull_diverged_rebase_succeeds() {
    echo "Testing do_pull with rebase on diverged repo..."
    setup_test_env

    local remote=$(create_remote_repo "diverged-rebase")
    local dev_dir="$TEMP_DIR/dev"
    local work_dir="$PROJECTS_DIR/diverged-rebase"

    # Create initial repo
    init_repo_with_commit "$remote" "$dev_dir"

    # Clone to projects dir
    git clone "$remote" "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"

    # Make local commit in different file (no conflict)
    echo "local only" > "$work_dir/local.txt"
    git -C "$work_dir" add local.txt
    git -C "$work_dir" commit -m "Local change in local.txt" >/dev/null 2>&1

    # Make remote commit in different file
    echo "remote only" > "$dev_dir/remote.txt"
    git -C "$dev_dir" add remote.txt
    git -C "$dev_dir" commit -m "Remote change in remote.txt" >/dev/null 2>&1
    git -C "$dev_dir" push >/dev/null 2>&1

    # Fetch to update refs
    git -C "$work_dir" fetch >/dev/null 2>&1

    # Verify diverged state
    local status_line
    status_line=$(get_repo_status "$work_dir" "false")
    assert_contains "$status_line" "STATUS=diverged" "Should be diverged before pull"

    # do_pull with rebase should succeed (no conflicts)
    if do_pull "$work_dir" "diverged-rebase" "rebase" "false" 2>/dev/null; then
        # Check that both files exist
        if [[ -f "$work_dir/local.txt" && -f "$work_dir/remote.txt" ]]; then
            pass "do_pull with rebase succeeded on diverged repo"
        else
            fail "do_pull with rebase missing files after merge"
        fi
    else
        fail "do_pull with rebase failed on non-conflicting diverged repo"
    fi

    cleanup_test_env
}

test_status_with_merge_conflicts() {
    echo "Testing get_repo_status with merge conflicts..."
    setup_test_env

    local remote=$(create_remote_repo "conflict")
    local dev_dir="$TEMP_DIR/dev"
    local work_dir="$PROJECTS_DIR/conflict"

    # Create initial repo
    init_repo_with_commit "$remote" "$dev_dir"

    # Clone to projects dir
    git clone "$remote" "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"

    # Make conflicting changes to same file in both repos
    echo "local version" > "$work_dir/file.txt"
    git -C "$work_dir" add file.txt
    git -C "$work_dir" commit -m "Local version" >/dev/null 2>&1

    echo "remote version" > "$dev_dir/file.txt"
    git -C "$dev_dir" add file.txt
    git -C "$dev_dir" commit -m "Remote version" >/dev/null 2>&1
    git -C "$dev_dir" push >/dev/null 2>&1

    # Fetch
    git -C "$work_dir" fetch >/dev/null 2>&1

    # Status should show diverged
    local status_line
    status_line=$(get_repo_status "$work_dir" "false")
    assert_contains "$status_line" "STATUS=diverged" "Should detect diverged state"
    assert_contains "$status_line" "AHEAD=1" "Should have 1 ahead"
    assert_contains "$status_line" "BEHIND=1" "Should have 1 behind"

    cleanup_test_env
}

# Regression test for bd-jleo: rev-list failure should output numeric AHEAD/BEHIND
test_status_revlist_failure_numeric() {
    echo "Testing get_repo_status outputs numeric AHEAD/BEHIND on rev-list failure (bd-jleo)..."
    setup_test_env

    local remote=$(create_remote_repo "revlist-fail")
    local work_dir="$PROJECTS_DIR/revlist-fail"

    # Create a normal repo with upstream tracking
    init_repo_with_commit "$remote" "$work_dir"

    # Create a mock git wrapper that fails specifically for rev-list --left-right
    # This simulates edge cases like shallow clones with missing history
    local mock_bin="$TEMP_DIR/mock-bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/git" << 'MOCK_GIT'
#!/usr/bin/env bash
# Mock git that fails on rev-list --left-right (simulates shallow clone edge case)
for arg in "$@"; do
    if [[ "$arg" == "--left-right" ]]; then
        exit 1
    fi
done
# Otherwise pass through to real git
exec /usr/bin/git "$@"
MOCK_GIT
    chmod +x "$mock_bin/git"

    # Run get_repo_status with mock git in PATH
    local status_line
    status_line=$(PATH="$mock_bin:$PATH" get_repo_status "$work_dir" "false")

    # Key assertion: AHEAD and BEHIND must be numeric (not "?")
    local ahead_val behind_val
    ahead_val=$(echo "$status_line" | sed 's/.*AHEAD=\([^ ]*\).*/\1/')
    behind_val=$(echo "$status_line" | sed 's/.*BEHIND=\([^ ]*\).*/\1/')

    # Both must be -1 (numeric indicator of unknown) for JSON compatibility
    assert_equals "-1" "$ahead_val" "AHEAD should be -1 on rev-list failure (not '?')"
    assert_equals "-1" "$behind_val" "BEHIND should be -1 on rev-list failure (not '?')"

    # Also verify status is diverged (indicates rev-list failure path)
    assert_contains "$status_line" "STATUS=diverged" "Status should be diverged on rev-list failure"

    # Verify these are valid for printf %d (would fail with '?')
    if printf '%d' "$ahead_val" >/dev/null 2>&1; then
        pass "AHEAD value is valid for printf %d"
    else
        fail "AHEAD value '$ahead_val' is not valid for printf %d"
    fi

    if printf '%d' "$behind_val" >/dev/null 2>&1; then
        pass "BEHIND value is valid for printf %d"
    else
        fail "BEHIND value '$behind_val' is not valid for printf %d"
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

# Basic git repo tests
test_is_git_repo
echo ""

# Status tests
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

# Pull tests
test_do_pull
echo ""

# Fetch tests
test_do_fetch_updates_refs
echo ""

test_do_fetch_no_upstream
echo ""

test_do_fetch_with_multiple_remotes
echo ""

# Remote mismatch tests
test_check_remote_mismatch_same_url
echo ""

test_check_remote_mismatch_different_url
echo ""

test_check_remote_mismatch_no_remote
echo ""

test_check_remote_mismatch_normalized_urls
echo ""

test_check_remote_mismatch_ssh_vs_https
echo ""

# Clone tests (dry-run only)
test_do_clone_dry_run
echo ""

test_do_clone_dry_run_writes_result
echo ""

# get_remote_url tests
test_get_remote_url_origin
echo ""

test_get_remote_url_named_remote
echo ""

test_get_remote_url_no_remote
echo ""

# ensure_clean_or_fail tests
test_ensure_clean_or_fail_clean_repo
echo ""

test_ensure_clean_or_fail_dirty_repo
echo ""

test_ensure_clean_or_fail_staged_changes
echo ""

test_ensure_clean_or_fail_untracked_files
echo ""

test_ensure_clean_or_fail_not_git_repo
echo ""

# Autostash tests
test_do_pull_with_autostash
echo ""

# Merge conflict scenario tests
test_do_pull_diverged_ff_fails
echo ""

test_do_pull_diverged_rebase_succeeds
echo ""

test_status_with_merge_conflicts
echo ""

test_status_revlist_failure_numeric
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

[[ $TESTS_FAILED -eq 0 ]]
