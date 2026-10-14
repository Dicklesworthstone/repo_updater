#!/usr/bin/env bash
#
# Unit tests: Review apply merge/push workflow (bd-be4n)
#
# Covers:
# - verify_push_safe
# - push_worktree_changes (ff-only merge + push + archiving + state recording)
# Uses real local Git repositories and policies. These tests establish local
# push behavior; they do not establish live GitHub publication or qualification.
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test
# shellcheck disable=SC2034  # Globals consumed by sourced ru functions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

review_push_script_dir="$SCRIPT_DIR"
review_push_project_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../ru
source "$review_push_project_dir/ru"
SCRIPT_DIR="$review_push_script_dir"
PROJECT_DIR="$review_push_project_dir"

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
source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "_is_safe_path_segment"
source_ru_function "_is_safe_group_path"
source_ru_function "parse_repo_url"
source_ru_function "parse_repo_spec"
source_ru_function "resolve_repo_spec"
source_ru_function "load_repo_list"
source_ru_function "dedupe_repos"
source_ru_function "get_all_repos"
source_ru_function "find_repo_spec_for_repo_id"
source_ru_function "is_git_repo"
source_ru_function "repo_is_dirty"
source_ru_function "repo_is_dirty_excluding_ru"
source_ru_function "get_worktrees_dir"
source_ru_function "record_worktree_mapping"
source_ru_function "get_review_policy_dir"
source_ru_function "load_policy_for_repo"
source_ru_function "review_plan_digest"
source_ru_function "validate_review_identity"
source_ru_function "ensure_review_approval"
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

_setup_review_push_test() {
    local env_root="$1" run_id="$2"
    export RU_STATE_DIR="$env_root/state/ru"
    export RU_CONFIG_DIR="$env_root/config/ru"
    export PROJECTS_DIR="$env_root/projects"
    export LAYOUT="flat"
    export REVIEW_RUN_ID="$run_id"
    export REVIEW_NON_INTERACTIVE=true
    mkdir -p "$PROJECTS_DIR" "$RU_CONFIG_DIR/repos.d" "$RU_CONFIG_DIR/review-policies.d"
    printf '%s\n' 'owner/repo' > "$RU_CONFIG_DIR/repos.d/public.txt"
    printf '%s\n' 'REVIEW_REQUIRE_APPROVAL=false' 'REVIEW_ALLOW_PUSH=true' > "$RU_CONFIG_DIR/review-policies.d/_default"
}

_write_bound_push_plan() {
    local wt_path="$1" wt_branch="$2" base_sha="$3"
    local commits_json
    commits_json=$(git -C "$wt_path" rev-list --reverse --topo-order "$base_sha..HEAD" |
        jq -Rsc 'split("\n") | map(select(length > 0) | {sha:.})') || return 1
    mkdir -p "$wt_path/.ru"
    jq -n --arg run "$REVIEW_RUN_ID" --arg path "$wt_path" \
        --arg branch "$wt_branch" --arg base_sha "$base_sha" --argjson commits "$commits_json" '
        {
            schema_version:1, run_id:$run, repo:"owner/repo", worktree_path:$path,
            items:[], questions:[],
            metadata:{started_at:"2025-01-04T10:30:00Z",completed_at:"2025-01-04T10:45:00Z",model:"unit-test",driver:"local"},
            git:{branch:$branch,base_ref:"main",base_sha:$base_sha,commits:$commits,
                quality_gates_ok:true,quality_gates_warning:false,tests:{ran:true,ok:true}}
        }
    ' > "$wt_path/.ru/review-plan.json"
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
  "run_id": "run-unanswered",
  "repo": "owner/repo",
  "worktree_path": "/tmp/review-push-worktree",
  "items": [],
  "questions": [{"id":"q1","prompt":"x","answered":false}],
  "git": {
    "quality_gates_ok": true,
    "quality_gates_warning": false,
    "tests": {"ran": true, "ok": true}
  },
  "metadata": {"started_at":"2025-01-04T10:30:00Z","completed_at":"2025-01-04T10:45:00Z","model":"unit-test","driver":"local"}
}
EOF

    assert_exit_code 0 "unanswered-question fixture is structurally valid" validate_review_plan "$plan_file"
    assert_fails "should refuse push with unanswered questions" verify_push_safe "owner/repo" "$plan_file"
    log_test_pass "$test_name"
}

test_push_worktree_changes_ff_only_and_records_state() {
    local test_name="push_worktree_changes: ff-only merge + push + archive + state"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    _setup_review_push_test "$env_root" "test-push-run"

    local origin="$env_root/origin.git"
    _create_bare_remote "$origin"

    local main_repo="$PROJECTS_DIR/repo"
    _init_main_repo_with_origin "$origin" "$main_repo"
    local base_sha
    base_sha=$(git -C "$main_repo" rev-parse HEAD)

    local wt_branch="ru/review/${REVIEW_RUN_ID}/owner-repo"
    local wt_path="$RU_STATE_DIR/worktrees/$REVIEW_RUN_ID/owner_repo"
    git -C "$main_repo" worktree add -b "$wt_branch" "$wt_path" main >/dev/null 2>&1
    assert_exit_code 0 "worktree identity mapping should be recorded" record_worktree_mapping "owner/repo" "$wt_path" "$wt_branch" "main" "$main_repo" "$base_sha"

    mkdir -p "$wt_path/.ru"
    echo "change" >> "$wt_path/file.txt"
    git -C "$wt_path" add file.txt
    git -C "$wt_path" commit -m "Worktree change" --quiet
    echo "second change" >> "$wt_path/file.txt"
    git -C "$wt_path" add file.txt
    git -C "$wt_path" commit -m "Second worktree change" --quiet
    local wt_commit
    wt_commit=$(git -C "$wt_path" rev-parse HEAD)

    local plan_file="$wt_path/.ru/review-plan.json"
    assert_exit_code 0 "bound plan should be written" _write_bound_push_plan "$wt_path" "$wt_branch" "$base_sha"
    assert_equals "2" "$(jq '.git.commits | length' "$plan_file")" "both candidate commits are recorded in order"
    assert_equals "false" "$(load_policy_for_repo "owner/repo" | jq -r '.require_approval')" "real policy permits this push-focused test without approval prompts"
    assert_exit_code 0 "physical worktree and commits should match the plan" validate_review_identity "owner/repo" "$wt_path" "$plan_file"

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

test_push_worktree_changes_rejects_wrong_commit_order_then_accepts_correct_plan() {
    local test_name="push_worktree_changes: reject wrong commit order before mutation, then push valid candidate"
    log_test_start "$test_name"
    local env_root
    env_root=$(create_test_env)
    _setup_review_push_test "$env_root" "test-ordered-push-run"

    local origin="$env_root/origin.git"
    local main_repo="$PROJECTS_DIR/repo"
    _create_bare_remote "$origin"
    _init_main_repo_with_origin "$origin" "$main_repo"
    local base_sha
    base_sha=$(git -C "$main_repo" rev-parse HEAD)
    local wt_branch="ru/review/${REVIEW_RUN_ID}/owner-repo"
    local wt_path="$RU_STATE_DIR/worktrees/$REVIEW_RUN_ID/owner_repo"
    git -C "$main_repo" worktree add -b "$wt_branch" "$wt_path" main >/dev/null 2>&1
    assert_exit_code 0 "identity mapping should be recorded" record_worktree_mapping "owner/repo" "$wt_path" "$wt_branch" "main" "$main_repo" "$base_sha"

    echo "first change" >> "$wt_path/file.txt"
    git -C "$wt_path" add file.txt
    git -C "$wt_path" commit -m "First candidate commit" --quiet
    echo "second change" >> "$wt_path/file.txt"
    git -C "$wt_path" add file.txt
    git -C "$wt_path" commit -m "Second candidate commit" --quiet
    local wt_commit
    wt_commit=$(git -C "$wt_path" rev-parse HEAD)
    local plan_file="$wt_path/.ru/review-plan.json"
    assert_exit_code 0 "bound candidate plan should be written" _write_bound_push_plan "$wt_path" "$wt_branch" "$base_sha"

    # Both full SHAs are real and present; changing only their order must refuse
    # this otherwise valid candidate before merge, push, archive or state writes.
    jq '.git.commits |= reverse' "$plan_file" > "$wt_path/.ru/reversed-plan.json"
    mv "$wt_path/.ru/reversed-plan.json" "$plan_file"
    assert_exit_code 0 "wrong-order plan remains structurally valid" validate_review_plan "$plan_file"
    assert_exit_code 1 "wrong commit order must refuse push" push_worktree_changes "owner/repo" "$wt_path"
    assert_equals "$base_sha" "$(git -C "$main_repo" rev-parse HEAD)" "main HEAD is preserved on refusal"
    assert_equals "$base_sha" "$(git -C "$origin" rev-parse refs/heads/main)" "remote branch is preserved on refusal"
    assert_equals "$wt_commit" "$(git -C "$wt_path" rev-parse HEAD)" "candidate HEAD is preserved on refusal"
    assert_equals "" "$(git -C "$main_repo" for-each-ref --format='%(refname)' refs/ru/tmp)" "no transient merge ref is created on refusal"
    assert_false "[[ -f '$RU_STATE_DIR/review/applied-plans/$REVIEW_RUN_ID/owner_repo.json' ]]" "rejected plan is not archived as applied"

    assert_exit_code 0 "correct ordering should be restored from real Git history" _write_bound_push_plan "$wt_path" "$wt_branch" "$base_sha"
    assert_exit_code 0 "same candidate with correct ordering must push" push_worktree_changes "owner/repo" "$wt_path"
    assert_equals "$wt_commit" "$(git -C "$main_repo" rev-parse HEAD)" "correct candidate reaches main after push"
    assert_equals "$wt_commit" "$(git -C "$origin" rev-parse refs/heads/main)" "correct candidate reaches local remote after push"
    log_test_pass "$test_name"
}

run_test test_verify_push_safe_rejects_unanswered_questions
run_test test_push_worktree_changes_ff_only_and_records_state
run_test test_push_worktree_changes_rejects_wrong_commit_order_then_accepts_correct_plan

print_results
exit "$(get_exit_code)"
