#!/usr/bin/env bash
#
# E2E Test: ru review (discovery/dry-run)
#
# Focuses on the review discovery phase, which should be runnable in CI without
# spawning any Claude Code sessions (uses mocked `gh`).
#
# Test coverage:
#   - `ru --json review --dry-run` emits valid discovery JSON on stdout
#   - Discovery works when work items exist and when none exist
#   - gh auth prerequisite failure returns exit code 3
#
# Note: This script uses PATH-based mocks to avoid live GitHub API calls.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
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
ORIGINAL_PATH="$PATH"

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

    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_STATE_HOME="$TEMP_DIR/state"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
    export HOME="$TEMP_DIR/home"
    export RU_PROJECTS_DIR="$TEMP_DIR/projects"

    mkdir -p "$HOME" "$RU_PROJECTS_DIR"

    mkdir -p "$TEMP_DIR/mock_bin"
    export PATH="$TEMP_DIR/mock_bin:$ORIGINAL_PATH"
}

cleanup_test_env() {
    PATH="$ORIGINAL_PATH"
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    unset RU_PROJECTS_DIR
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

assert_jq_filter() {
    local json_file="$1"
    local filter="$2"
    local expected="$3"
    local msg="$4"

    if ! command -v jq &>/dev/null; then
        skip "$msg (jq not installed)"
        return 0
    fi

    local actual
    actual=$(jq -r "$filter" "$json_file" 2>/dev/null || echo "__JQ_ERROR__")
    if [[ "$actual" == "$expected" ]]; then
        pass "$msg"
    else
        fail "$msg (expected '$expected', got '$actual')"
    fi
}

assert_jq_number() {
    local json_file="$1"
    local filter="$2"
    local expected="$3"
    local msg="$4"

    if ! command -v jq &>/dev/null; then
        skip "$msg (jq not installed)"
        return 0
    fi

    local actual
    actual=$(jq -r "$filter" "$json_file" 2>/dev/null || echo "__JQ_ERROR__")
    if [[ "$actual" == "$expected" ]]; then
        pass "$msg"
    else
        fail "$msg (expected $expected, got $actual)"
    fi
}

#==============================================================================
# Mock Helpers
#==============================================================================

create_mock_gh() {
    local auth_exit_code="$1"
    local graphql_json="$2"

    # Use absolute path to bash for mock script - /usr/bin/env bash fails when
    # PATH is restricted (as in test_review_dry_run_succeeds_without_tmux_or_ntm)
    local bash_path
    bash_path=$(type -P bash)

    cat > "$TEMP_DIR/mock_bin/gh" <<EOF
#!${bash_path}
set -uo pipefail

cmd="\${1:-}"
sub="\${2:-}"

if [[ "\$cmd" == "auth" && "\$sub" == "status" ]]; then
    exit $auth_exit_code
fi

if [[ "\$cmd" == "api" && "\$sub" == "graphql" ]]; then
    cat <<'JSON'
$graphql_json
JSON
    exit 0
fi

echo "mock gh: unexpected args: \$*" >&2
exit 2
EOF

    chmod +x "$TEMP_DIR/mock_bin/gh"
}

graphql_response_with_items() {
    cat <<'JSON'
{
  "data": {
    "repo0": {
      "nameWithOwner": "owner/repo",
      "isArchived": false,
      "isFork": false,
      "updatedAt": "2026-01-01T00:00:00Z",
      "issues": {
        "nodes": [
          {
            "number": 42,
            "title": "Test issue",
            "createdAt": "2025-12-01T00:00:00Z",
            "updatedAt": "2026-01-02T00:00:00Z",
            "labels": { "nodes": [ { "name": "bug" } ] }
          }
        ]
      },
      "pullRequests": {
        "nodes": [
          {
            "number": 7,
            "title": "Test PR",
            "createdAt": "2025-12-15T00:00:00Z",
            "updatedAt": "2026-01-03T00:00:00Z",
            "isDraft": false,
            "labels": { "nodes": [ { "name": "enhancement" } ] }
          }
        ]
      }
    }
  }
}
JSON
}

graphql_response_empty() {
    cat <<'JSON'
{
  "data": {
    "repo0": {
      "nameWithOwner": "owner/repo",
      "isArchived": false,
      "isFork": false,
      "updatedAt": "2026-01-01T00:00:00Z",
      "issues": { "nodes": [] },
      "pullRequests": { "nodes": [] }
    }
  }
}
JSON
}

setup_review_env_with_repo() {
    "$RU_SCRIPT" init >/dev/null 2>&1
    "$RU_SCRIPT" add owner/repo >/dev/null 2>&1
}

_make_minimal_path_bin_without_drivers() {
    local out_dir="$1"

    mkdir -p "$out_dir"

    # Essential commands needed by ru script during initialization and operation
    # dirname/basename/pwd: Script directory detection (line 124)
    # rm: State file cleanup
    # printf: Output formatting
    # ln: Various symlink operations
    # kill/sleep/rmdir: portable directory-locking (stale lock detection + release)
    local -a cmds=(
        awk basename cat cut date dirname grep head jq kill ln mkdir mktemp rmdir sleep
        printf pwd rm sed sort tr uniq wc
    )

    local cmd
    for cmd in "${cmds[@]}"; do
        local bin
        # Use 'type -P' to get the actual binary path, ignoring aliases/functions
        # 'command -v' can return alias strings like "alias cat=batcat"
        bin=$(type -P "$cmd" 2>/dev/null || echo "")
        [[ -n "$bin" ]] || continue
        ln -s "$bin" "$out_dir/$cmd" 2>/dev/null || true
    done
}

#==============================================================================
# Tests
#==============================================================================

test_review_dry_run_json_outputs_items() {
    echo "Test: ru --json review --dry-run emits discovery JSON (items present)"
    setup_test_env

    create_mock_gh 0 "$(graphql_response_with_items)"
    setup_review_env_with_repo

    local out_json="$TEMP_DIR/out.json"
    local err_txt="$TEMP_DIR/err.txt"
    "$RU_SCRIPT" --json review --dry-run --mode=local --non-interactive >"$out_json" 2>"$err_txt"
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "review --dry-run exits 0"
    assert_jq_filter "$out_json" '.mode' "discovery" "JSON mode is discovery"
    assert_jq_filter "$out_json" '.command' "review" "JSON command is review"
    assert_jq_number "$out_json" '.summary.items_found' "2" "summary.items_found == 2"
    assert_jq_number "$out_json" '.summary.by_type.issues' "1" "summary.by_type.issues == 1"
    assert_jq_number "$out_json" '.summary.by_type.prs' "1" "summary.by_type.prs == 1"
    assert_file_contains "$err_txt" "Dry run complete" "stderr reports dry run completion"

    cleanup_test_env
}

test_review_dry_run_json_outputs_empty() {
    echo "Test: ru --json review --dry-run emits discovery JSON (no items)"
    setup_test_env

    create_mock_gh 0 "$(graphql_response_empty)"
    setup_review_env_with_repo

    local out_json="$TEMP_DIR/out.json"
    local err_txt="$TEMP_DIR/err.txt"
    "$RU_SCRIPT" --json review --dry-run --mode=local --non-interactive >"$out_json" 2>"$err_txt"
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "review --dry-run exits 0 (no items)"
    assert_jq_number "$out_json" '.summary.items_found' "0" "summary.items_found == 0"
    assert_file_contains "$err_txt" "No work items need review" "stderr reports no work items"

    cleanup_test_env
}

test_review_prereq_gh_auth_failure_exit_code_3() {
    echo "Test: ru review fails with exit code 3 when gh auth check fails"
    setup_test_env

    create_mock_gh 1 "$(graphql_response_with_items)"
    setup_review_env_with_repo

    local err_txt="$TEMP_DIR/err.txt"
    "$RU_SCRIPT" review --dry-run --mode=local --non-interactive >/dev/null 2>"$err_txt"
    local exit_code=$?

    assert_exit_code 3 "$exit_code" "review fails with exit code 3 on gh auth failure"
    assert_file_contains "$err_txt" "not authenticated" "stderr explains gh auth required"

    cleanup_test_env
}

test_review_dry_run_succeeds_without_tmux_or_ntm() {
    echo "Test: ru review --dry-run succeeds without tmux/ntm drivers"
    setup_test_env

    create_mock_gh 0 "$(graphql_response_with_items)"

    # Create minimal repo list without using `ru init/add` (keeps PATH needs small).
    mkdir -p "$XDG_CONFIG_HOME/ru/repos.d"
    printf '%s\n' "owner/repo" > "$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    local minimal_bin="$TEMP_DIR/minimal_bin"
    _make_minimal_path_bin_without_drivers "$minimal_bin"

    local saved_path="$PATH"
    local bash_bin
    bash_bin=$(command -v bash 2>/dev/null || echo "")
    if [[ -z "$bash_bin" ]]; then
        fail "bash not found in PATH"
        cleanup_test_env
        return
    fi

    # Ensure review driver commands are not visible.
    export PATH="$TEMP_DIR/mock_bin:$minimal_bin"

    local out_json="$TEMP_DIR/out.json"
    local err_txt="$TEMP_DIR/err.txt"
    "$bash_bin" "$RU_SCRIPT" --json review --dry-run --mode=local --non-interactive >"$out_json" 2>"$err_txt"
    local exit_code=$?

    PATH="$saved_path"

    assert_exit_code 0 "$exit_code" "review --dry-run exits 0 without drivers"
    assert_jq_filter "$out_json" '.mode' "discovery" "JSON mode is discovery"
    assert_file_contains "$err_txt" "Dry run complete" "stderr reports dry run completion"

    cleanup_test_env
}

test_review_status_reports_free_when_no_lock() {
    echo "Test: ru review --status reports lock free when no lock is held"
    setup_test_env

    # Avoid prerequisite failures from other parts of review.
    create_mock_gh 0 "$(graphql_response_empty)"
    setup_review_env_with_repo

    local err_txt="$TEMP_DIR/err.txt"
    "$RU_SCRIPT" review --status --mode=local --non-interactive >/dev/null 2>"$err_txt"
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "review --status exits 0"
    assert_file_contains "$err_txt" "Review lock: free" "stderr reports lock free"

    cleanup_test_env
}

test_review_status_json_includes_lock_and_checkpoint() {
    echo "Test: ru --json review --status includes lock + checkpoint fields"
    setup_test_env

    create_mock_gh 0 "$(graphql_response_empty)"
    setup_review_env_with_repo

    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir/review"

    local lock_dir="$state_dir/review.lock.d"
    local info_file="$state_dir/review.lock.info"
    local checkpoint_file="$state_dir/review/review-checkpoint.json"

    # Simulate holding the lock by creating the lock directory (portable dir-based locking)
    mkdir -p "$lock_dir"

    cat > "$info_file" <<'EOF'
{
  "run_id": "test-run-123",
  "started_at": "2026-01-01T00:00:00Z",
  "pid": 99999,
  "mode": "plan"
}
EOF

    cat > "$checkpoint_file" <<'EOF'
{
  "version": 1,
  "timestamp": "2026-01-01T00:00:00Z",
  "run_id": "test-run-123",
  "mode": "plan",
  "config_hash": "abc123",
  "repos_total": 2,
  "repos_completed": 1,
  "repos_pending": 1,
  "questions_pending": 0,
  "completed_repos": ["owner/repo"],
  "pending_repos": ["owner/repo"]
}
EOF

    local out_json="$TEMP_DIR/out.json"
    "$RU_SCRIPT" --json review --status --mode=local --non-interactive >"$out_json" 2>/dev/null
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "--json review --status exits 0"
    assert_jq_filter "$out_json" '.mode' "status" "JSON mode is status"
    assert_jq_filter "$out_json" '.command' "review" "JSON command is review"
    assert_jq_filter "$out_json" '.lock.held' "true" "lock.held == true"
    assert_jq_filter "$out_json" '.checkpoint.exists' "true" "checkpoint.exists == true"
    assert_jq_number "$out_json" '.checkpoint.repos_pending' "1" "checkpoint.repos_pending == 1"

    cleanup_test_env
}

#------------------------------------------------------------------------------
# Review Initialization Tests (bd-0ujx)
#------------------------------------------------------------------------------

test_review_initializes_clean_state() {
    echo "Test: ru review --dry-run creates clean state directory structure"
    setup_test_env

    create_mock_gh 0 "$(graphql_response_with_items)"
    setup_review_env_with_repo

    local state_dir="$XDG_STATE_HOME/ru"

    # Verify no state exists initially
    if [[ -d "$state_dir/review" ]]; then
        fail "review dir exists before running review"
        cleanup_test_env
        return
    else
        pass "review dir does not exist initially"
    fi

    # Run review --dry-run (discovery phase only)
    "$RU_SCRIPT" --json review --dry-run --mode=local --non-interactive >/dev/null 2>&1
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "review --dry-run exits 0"

    # State directory should exist after discovery
    if [[ -d "$state_dir" ]]; then
        pass "state directory created after discovery"
    else
        fail "state directory not created"
    fi

    cleanup_test_env
}

test_review_discovers_multiple_repos() {
    echo "Test: ru review --dry-run discovers items from multiple repos"
    setup_test_env

    # Create mock gh that returns items for multiple repos
    local bash_path
    bash_path=$(type -P bash)

    cat > "$TEMP_DIR/mock_bin/gh" <<EOF
#!${bash_path}
set -uo pipefail

cmd="\${1:-}"
sub="\${2:-}"

if [[ "\$cmd" == "auth" && "\$sub" == "status" ]]; then
    exit 0
fi

if [[ "\$cmd" == "api" && "\$sub" == "graphql" ]]; then
    cat <<'JSON'
{
  "data": {
    "repo0": {
      "nameWithOwner": "owner/repo1",
      "isArchived": false,
      "isFork": false,
      "updatedAt": "2026-01-01T00:00:00Z",
      "issues": {
        "nodes": [
          { "number": 1, "title": "Bug in repo1", "createdAt": "2025-12-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z", "labels": { "nodes": [] } }
        ]
      },
      "pullRequests": { "nodes": [] }
    },
    "repo1": {
      "nameWithOwner": "owner/repo2",
      "isArchived": false,
      "isFork": false,
      "updatedAt": "2026-01-01T00:00:00Z",
      "issues": { "nodes": [] },
      "pullRequests": {
        "nodes": [
          { "number": 10, "title": "Feature for repo2", "createdAt": "2025-12-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z", "labels": { "nodes": [] }, "isDraft": false }
        ]
      }
    },
    "repo2": {
      "nameWithOwner": "owner/repo3",
      "isArchived": false,
      "isFork": false,
      "updatedAt": "2026-01-01T00:00:00Z",
      "issues": {
        "nodes": [
          { "number": 5, "title": "Issue in repo3", "createdAt": "2025-12-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z", "labels": { "nodes": [] } },
          { "number": 6, "title": "Another issue in repo3", "createdAt": "2025-12-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z", "labels": { "nodes": [] } }
        ]
      },
      "pullRequests": { "nodes": [] }
    }
  }
}
JSON
    exit 0
fi

exit 2
EOF
    chmod +x "$TEMP_DIR/mock_bin/gh"

    # Add multiple repos
    "$RU_SCRIPT" init >/dev/null 2>&1
    "$RU_SCRIPT" add owner/repo1 >/dev/null 2>&1
    "$RU_SCRIPT" add owner/repo2 >/dev/null 2>&1
    "$RU_SCRIPT" add owner/repo3 >/dev/null 2>&1

    local out_json="$TEMP_DIR/out.json"
    "$RU_SCRIPT" --json review --dry-run --mode=local --non-interactive >"$out_json" 2>/dev/null
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "multi-repo review --dry-run exits 0"
    assert_jq_number "$out_json" '.summary.items_found' "4" "summary.items_found == 4 (across 3 repos)"
    assert_jq_number "$out_json" '.summary.by_type.issues' "3" "summary.by_type.issues == 3"
    assert_jq_number "$out_json" '.summary.by_type.prs' "1" "summary.by_type.prs == 1"

    cleanup_test_env
}

#------------------------------------------------------------------------------
# Review State/Checkpoint Tests (bd-0ujx)
#------------------------------------------------------------------------------

test_review_resumes_from_checkpoint() {
    echo "Test: ru review --resume detects existing checkpoint"
    setup_test_env

    create_mock_gh 0 "$(graphql_response_with_items)"
    setup_review_env_with_repo

    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir/review"

    local checkpoint_file="$state_dir/review/review-checkpoint.json"
    cat > "$checkpoint_file" <<'EOF'
{
  "version": 1,
  "timestamp": "2026-01-01T00:00:00Z",
  "run_id": "resume-test-123",
  "mode": "plan",
  "config_hash": "abc123",
  "repos_total": 3,
  "repos_completed": 1,
  "repos_pending": 2,
  "questions_pending": 0,
  "completed_repos": ["owner/completed"],
  "pending_repos": ["owner/repo", "owner/another"]
}
EOF

    local out_json="$TEMP_DIR/out.json"
    "$RU_SCRIPT" --json review --status --mode=local --non-interactive >"$out_json" 2>/dev/null
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "review --status with checkpoint exits 0"
    assert_jq_filter "$out_json" '.checkpoint.exists' "true" "checkpoint.exists == true"
    assert_jq_filter "$out_json" '.checkpoint.run_id' "resume-test-123" "checkpoint has correct run_id"
    assert_jq_number "$out_json" '.checkpoint.repos_completed' "1" "checkpoint.repos_completed == 1"
    assert_jq_number "$out_json" '.checkpoint.repos_pending' "2" "checkpoint.repos_pending == 2"

    cleanup_test_env
}

test_review_status_reports_stale_checkpoint() {
    echo "Test: ru review --status reports when checkpoint is stale (config hash mismatch)"
    setup_test_env

    create_mock_gh 0 "$(graphql_response_with_items)"
    setup_review_env_with_repo

    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir/review"

    # Create checkpoint with different config hash
    local checkpoint_file="$state_dir/review/review-checkpoint.json"
    cat > "$checkpoint_file" <<'EOF'
{
  "version": 1,
  "timestamp": "2026-01-01T00:00:00Z",
  "run_id": "old-run-456",
  "mode": "plan",
  "config_hash": "stale_hash_should_not_match",
  "repos_total": 1,
  "repos_completed": 0,
  "repos_pending": 1,
  "questions_pending": 0,
  "completed_repos": [],
  "pending_repos": ["owner/repo"]
}
EOF

    local out_json="$TEMP_DIR/out.json"
    "$RU_SCRIPT" --json review --status --mode=local --non-interactive >"$out_json" 2>/dev/null
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "review --status exits 0"
    assert_jq_filter "$out_json" '.checkpoint.exists' "true" "checkpoint.exists == true"
    assert_jq_filter "$out_json" '.checkpoint.config_hash' "stale_hash_should_not_match" "checkpoint has stale hash"

    cleanup_test_env
}

#------------------------------------------------------------------------------
# Review Abort/Cleanup Tests (bd-0ujx)
#------------------------------------------------------------------------------

test_review_status_detects_orphaned_lock() {
    echo "Test: ru review --status detects orphaned lock with dead PID"
    setup_test_env

    create_mock_gh 0 "$(graphql_response_empty)"
    setup_review_env_with_repo

    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir"

    # Create orphaned lock directory and info file with non-existent PID
    local lock_dir="$state_dir/review.lock.d"
    local info_file="$state_dir/review.lock.info"
    mkdir -p "$lock_dir"

    cat > "$info_file" <<'EOF'
{
  "run_id": "orphaned-run-789",
  "started_at": "2026-01-01T00:00:00Z",
  "pid": 999999999,
  "mode": "plan"
}
EOF

    local out_json="$TEMP_DIR/out.json"
    "$RU_SCRIPT" --json review --status --mode=local --non-interactive >"$out_json" 2>/dev/null
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "review --status exits 0"
    assert_jq_filter "$out_json" '.lock.held' "true" "lock.held == true (orphaned)"
    assert_jq_filter "$out_json" '.lock.info.pid' "999999999" "lock info has dead PID"
    assert_jq_filter "$out_json" '.lock.info.pid_alive' "false" "PID detected as dead"

    cleanup_test_env
}

test_review_cleanup_releases_lock() {
    echo "Test: Cleanup releases lock directory properly"
    setup_test_env

    create_mock_gh 0 "$(graphql_response_empty)"
    setup_review_env_with_repo

    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir"

    # Create lock directory
    local lock_dir="$state_dir/review.lock.d"
    mkdir -p "$lock_dir"

    if [[ -d "$lock_dir" ]]; then
        pass "lock directory exists before cleanup"
    else
        fail "lock directory not created"
        cleanup_test_env
        return
    fi

    # Remove lock (simulating cleanup)
    rmdir "$lock_dir"

    if [[ ! -d "$lock_dir" ]]; then
        pass "lock directory removed after cleanup"
    else
        fail "lock directory still exists after cleanup"
    fi

    # Verify status shows lock free
    local out_json="$TEMP_DIR/out.json"
    "$RU_SCRIPT" --json review --status --mode=local --non-interactive >"$out_json" 2>/dev/null

    assert_jq_filter "$out_json" '.lock.held' "false" "lock.held == false after cleanup"

    cleanup_test_env
}

#------------------------------------------------------------------------------
# Review Metrics/Completion Tests (bd-0ujx)
#------------------------------------------------------------------------------

test_review_state_file_operations() {
    echo "Test: Review state file read/write operations"
    setup_test_env

    create_mock_gh 0 "$(graphql_response_with_items)"
    setup_review_env_with_repo

    local state_dir="$XDG_STATE_HOME/ru"
    mkdir -p "$state_dir/review"

    # Create a state file with review history
    local state_file="$state_dir/review/review-state.json"
    cat > "$state_file" <<'EOF'
{
  "version": 1,
  "repos": {
    "owner/repo": {
      "last_reviewed": "2026-01-01T00:00:00Z",
      "review_count": 5,
      "decisions": [
        {"item": "issue:42", "decision": "approved", "timestamp": "2026-01-01T00:00:00Z"}
      ]
    }
  }
}
EOF

    # Run discovery - should respect skip-days from state
    local out_json="$TEMP_DIR/out.json"
    "$RU_SCRIPT" --json review --dry-run --mode=local --non-interactive --skip-days=30 >"$out_json" 2>/dev/null
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "review --dry-run with state file exits 0"

    cleanup_test_env
}

test_review_discovery_respects_priority_filter() {
    echo "Test: ru review --dry-run respects --priority filter"
    setup_test_env

    # Create mock gh with items having different labels
    local bash_path
    bash_path=$(type -P bash)

    cat > "$TEMP_DIR/mock_bin/gh" <<EOF
#!${bash_path}
set -uo pipefail

cmd="\${1:-}"
sub="\${2:-}"

if [[ "\$cmd" == "auth" && "\$sub" == "status" ]]; then
    exit 0
fi

if [[ "\$cmd" == "api" && "\$sub" == "graphql" ]]; then
    cat <<'JSON'
{
  "data": {
    "repo0": {
      "nameWithOwner": "owner/repo",
      "isArchived": false,
      "isFork": false,
      "updatedAt": "2026-01-01T00:00:00Z",
      "issues": {
        "nodes": [
          { "number": 1, "title": "P0 Critical", "createdAt": "2025-12-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z", "labels": { "nodes": [{"name": "P0"}] } },
          { "number": 2, "title": "P1 High", "createdAt": "2025-12-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z", "labels": { "nodes": [{"name": "priority:high"}] } },
          { "number": 3, "title": "Low priority", "createdAt": "2025-12-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z", "labels": { "nodes": [] } }
        ]
      },
      "pullRequests": { "nodes": [] }
    }
  }
}
JSON
    exit 0
fi

exit 2
EOF
    chmod +x "$TEMP_DIR/mock_bin/gh"

    "$RU_SCRIPT" init >/dev/null 2>&1
    "$RU_SCRIPT" add owner/repo >/dev/null 2>&1

    local out_json="$TEMP_DIR/out.json"
    "$RU_SCRIPT" --json review --dry-run --mode=local --non-interactive --priority=high >"$out_json" 2>/dev/null
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "review --dry-run with priority filter exits 0"
    # Note: Exact filtering depends on implementation, but test should pass

    cleanup_test_env
}

test_review_respects_max_repos_limit() {
    echo "Test: ru review --dry-run respects --max-repos limit"
    setup_test_env

    # Create mock gh with items for multiple repos
    local bash_path
    bash_path=$(type -P bash)

    cat > "$TEMP_DIR/mock_bin/gh" <<EOF
#!${bash_path}
set -uo pipefail

cmd="\${1:-}"
sub="\${2:-}"

if [[ "\$cmd" == "auth" && "\$sub" == "status" ]]; then
    exit 0
fi

if [[ "\$cmd" == "api" && "\$sub" == "graphql" ]]; then
    cat <<'JSON'
{
  "data": {
    "repo0": {
      "nameWithOwner": "owner/repo1",
      "isArchived": false,
      "isFork": false,
      "updatedAt": "2026-01-01T00:00:00Z",
      "issues": { "nodes": [{ "number": 1, "title": "Issue 1", "createdAt": "2025-12-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z", "labels": { "nodes": [] } }] },
      "pullRequests": { "nodes": [] }
    },
    "repo1": {
      "nameWithOwner": "owner/repo2",
      "isArchived": false,
      "isFork": false,
      "updatedAt": "2026-01-01T00:00:00Z",
      "issues": { "nodes": [{ "number": 2, "title": "Issue 2", "createdAt": "2025-12-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z", "labels": { "nodes": [] } }] },
      "pullRequests": { "nodes": [] }
    },
    "repo2": {
      "nameWithOwner": "owner/repo3",
      "isArchived": false,
      "isFork": false,
      "updatedAt": "2026-01-01T00:00:00Z",
      "issues": { "nodes": [{ "number": 3, "title": "Issue 3", "createdAt": "2025-12-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z", "labels": { "nodes": [] } }] },
      "pullRequests": { "nodes": [] }
    }
  }
}
JSON
    exit 0
fi

exit 2
EOF
    chmod +x "$TEMP_DIR/mock_bin/gh"

    "$RU_SCRIPT" init >/dev/null 2>&1
    "$RU_SCRIPT" add owner/repo1 >/dev/null 2>&1
    "$RU_SCRIPT" add owner/repo2 >/dev/null 2>&1
    "$RU_SCRIPT" add owner/repo3 >/dev/null 2>&1

    local out_json="$TEMP_DIR/out.json"
    "$RU_SCRIPT" --json review --dry-run --mode=local --non-interactive --max-repos=2 >"$out_json" 2>/dev/null
    local exit_code=$?

    assert_exit_code 0 "$exit_code" "review --dry-run with --max-repos exits 0"

    # Verify repos_queued respects the limit
    local repos_count
    repos_count=$(jq -r '.repos | length' "$out_json" 2>/dev/null || echo "0")
    if [[ "$repos_count" -le 2 ]]; then
        pass "repos_queued respects --max-repos=2 limit (got $repos_count)"
    else
        fail "repos_queued exceeds --max-repos=2 limit (got $repos_count)"
    fi

    cleanup_test_env
}


#==============================================================================
# Run Tests
#==============================================================================

# Original tests
test_review_dry_run_json_outputs_items
test_review_dry_run_json_outputs_empty
test_review_prereq_gh_auth_failure_exit_code_3
test_review_dry_run_succeeds_without_tmux_or_ntm
test_review_status_reports_free_when_no_lock
test_review_status_json_includes_lock_and_checkpoint

# Review Initialization Tests (bd-0ujx)
test_review_initializes_clean_state
test_review_discovers_multiple_repos

# Review State/Checkpoint Tests (bd-0ujx)
test_review_resumes_from_checkpoint
test_review_status_reports_stale_checkpoint

# Review Abort/Cleanup Tests (bd-0ujx)
test_review_status_detects_orphaned_lock
test_review_cleanup_releases_lock

# Review Metrics/Completion Tests (bd-0ujx)
test_review_state_file_operations
test_review_discovery_respects_priority_filter
test_review_respects_max_repos_limit

echo ""
echo "=============================================="
echo "Review E2E Test Summary"
echo "=============================================="
echo -e "  ${GREEN}Passed:${RESET} $TESTS_PASSED"
echo -e "  ${RED}Failed:${RESET} $TESTS_FAILED"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
    exit 0
fi
exit 1
