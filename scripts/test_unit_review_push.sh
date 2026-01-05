#!/usr/bin/env bash
#
# Unit tests: Review apply merge/push workflow (bd-be4n)
#
# Covers:
# - verify_push_safe
# - push_worktree_changes (ff-only merge + push + archiving + state recording)
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

source_ru_function "ensure_dir"
source_ru_function "get_review_state_dir"
source_ru_function "acquire_state_lock"
source_ru_function "release_state_lock"
source_ru_function "with_state_lock"
source_ru_function "write_json_atomic"
source_ru_function "get_review_state_file"
source_ru_function "init_review_state"
source_ru_function "update_review_state"

source_ru_function "validate_review_plan"
source_ru_function "get_main_repo_path_from_worktree"
source_ru_function "archive_review_plan"
source_ru_function "verify_push_safe"
source_ru_function "record_review_push"
source_ru_function "push_worktree_changes"

# Required global used by acquire_state_lock/release_state_lock (normally set in ru)
export STATE_LOCK_FD=201

# Mock logging used by the functions under test
log_step() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
log_success() { :; }
log_verbose() { :; }

_create_bare_remote() {
    local path="$1"
    mkdir -p "$path"
    git init --bare --quiet "$path"
    git -C "$path" symbolic-ref HEAD refs/heads/main
}

_init_main_repo_with_origin() {
    local origin_path="$1"
    local main_repo_path="$2"

    git clone --quiet "$origin_path" "$main_repo_path"
    git -C "$main_repo_path" config user.email "test@test.com"
    git -C "$main_repo_path" config user.name "Test User"
    git -C "$main_repo_path" checkout -b main >/dev/null 2>&1 || true
    echo "initial" > "$main_repo_path/file.txt"
    git -C "$main_repo_path" add file.txt
    git -C "$main_repo_path" commit -m "Initial commit" --quiet
    git -C "$main_repo_path" push -u origin main --quiet
}

test_verify_push_safe_rejects_unanswered_questions() {
    local test_name="verify_push_safe: rejects unanswered questions"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    export RU_STATE_DIR="$env_root/state/ru"

    local plan_file="$env_root/plan.json"
    cat > "$plan_file" <<'EOF'
{
  "schema_version": 1,
  "repo": "owner/repo",
  "items": [],
  "questions": [{"id":"q1","prompt":"x","answered":false}],
  "git": {
    "quality_gates_ok": true,
    "quality_gates_warning": false,
    "tests": {"ran": true, "ok": true}
  }
}
EOF

    assert_fails "should refuse push with unanswered questions" verify_push_safe "owner/repo" "$plan_file"
    log_test_pass "$test_name"
}

test_push_worktree_changes_ff_only_and_records_state() {
    local test_name="push_worktree_changes: ff-only merge + push + archive + state"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    export RU_STATE_DIR="$env_root/state/ru"
    REVIEW_RUN_ID="test-run-$(date +%s)"
    export REVIEW_RUN_ID

    local origin="$env_root/origin.git"
    _create_bare_remote "$origin"

    local main_repo="$env_root/projects/main"
    _init_main_repo_with_origin "$origin" "$main_repo"

    local wt_branch="ru/review/${REVIEW_RUN_ID}/owner-repo"
    local wt_path="$env_root/worktree"
    git -C "$main_repo" worktree add -b "$wt_branch" "$wt_path" main >/dev/null 2>&1

    mkdir -p "$wt_path/.ru"
    echo "change" >> "$wt_path/file.txt"
    git -C "$wt_path" add file.txt
    git -C "$wt_path" commit -m "Worktree change" --quiet
    local wt_commit
    wt_commit=$(git -C "$wt_path" rev-parse HEAD)

    local plan_file="$wt_path/.ru/review-plan.json"
    cat > "$plan_file" <<EOF
{
  "schema_version": 1,
  "repo": "owner/repo",
  "items": [],
  "questions": [],
  "git": {
    "branch": "$wt_branch",
    "base_ref": "main",
    "commits": [{"sha": "$wt_commit"}],
    "quality_gates_ok": true,
    "quality_gates_warning": false,
    "tests": {"ran": true, "ok": true}
  }
}
EOF

    assert_exit_code 0 "verify_push_safe should allow push" verify_push_safe "owner/repo" "$plan_file" "$wt_path"
    assert_exit_code 0 "push_worktree_changes should succeed" push_worktree_changes "owner/repo" "$wt_path"

    local head_commit
    head_commit=$(git -C "$main_repo" rev-parse HEAD)
    assert_equals "$wt_commit" "$head_commit" "main repo HEAD should match worktree commit after merge"

    git -C "$main_repo" fetch --quiet origin
    local remote_commit
    remote_commit=$(git -C "$main_repo" rev-parse origin/main)
    assert_equals "$wt_commit" "$remote_commit" "origin/main should match after push"

    local archive_path
    archive_path="$RU_STATE_DIR/review/applied-plans/$REVIEW_RUN_ID/owner_repo.json"
    assert_file_exists "$archive_path" "plan should be archived"

    local state_file
    state_file=$(get_review_state_file)
    assert_file_exists "$state_file" "review state file should exist"
    assert_equals "main" "$(jq -r '.repos["owner/repo"].last_push_branch' "$state_file")" "state should record pushed branch"

    log_test_pass "$test_name"
}

run_test test_verify_push_safe_rejects_unanswered_questions
run_test test_push_worktree_changes_ff_only_and_records_state

print_results
exit $?
