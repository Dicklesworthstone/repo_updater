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

    cat > "$TEMP_DIR/mock_bin/gh" <<EOF
#!/usr/bin/env bash
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

    local -a cmds=(
        awk cat cut date flock grep head jq mkdir mktemp sed sort tr uniq wc
    )

    local cmd
    for cmd in "${cmds[@]}"; do
        local bin
        bin=$(command -v "$cmd" 2>/dev/null || echo "")
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
    "$bash_bin" "$RU_SCRIPT" --json review --dry-run --non-interactive >"$out_json" 2>"$err_txt"
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

    local lock_file="$state_dir/review.lock"
    local info_file="$state_dir/review.lock.info"
    local checkpoint_file="$state_dir/review/review-checkpoint.json"

    # Hold the lock in this test process.
    exec 8>"$lock_file"
    flock -n 8 2>/dev/null || { fail "failed to acquire test lock"; cleanup_test_env; return; }

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

    exec 8>&-

    assert_exit_code 0 "$exit_code" "--json review --status exits 0"
    assert_jq_filter "$out_json" '.mode' "status" "JSON mode is status"
    assert_jq_filter "$out_json" '.command' "review" "JSON command is review"
    assert_jq_filter "$out_json" '.lock.held' "true" "lock.held == true"
    assert_jq_filter "$out_json" '.checkpoint.exists' "true" "checkpoint.exists == true"
    assert_jq_number "$out_json" '.checkpoint.repos_pending' "1" "checkpoint.repos_pending == 1"

    cleanup_test_env
}


#==============================================================================
# Run Tests
#==============================================================================

test_review_dry_run_json_outputs_items
test_review_dry_run_json_outputs_empty
test_review_prereq_gh_auth_failure_exit_code_3
test_review_dry_run_succeeds_without_tmux_or_ntm
test_review_status_reports_free_when_no_lock
test_review_status_json_includes_lock_and_checkpoint

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
