#!/usr/bin/env bash
#
# E2E Test: Review worktree management
#
# Covers bd-33aj scenarios using real git worktree operations:
#   1. Create worktree from main/HEAD
#   2. Create worktree from specific commit (pinned ref)
#   3. Worktree directory respects custom RU_STATE_DIR
#   4. List and validate worktree mapping
#   5. Cleanup removes worktrees and mapping
#   6. Corrupted/non-git repo is skipped safely
#   7. Concurrent worktree mapping updates remain valid JSON
#
# shellcheck disable=SC2034  # Variables used by sourced functions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the E2E framework (test isolation + assertions)
source "$SCRIPT_DIR/test_e2e_framework.sh"

#------------------------------------------------------------------------------
# Minimal stubs + helpers for isolated worktree tests
#------------------------------------------------------------------------------

log_verbose() { :; }
log_info() { :; }
log_warn() { printf 'WARN: %s\n' "$*" >&2; }
log_error() { printf 'ERROR: %s\n' "$*" >&2; }

# Source required ru functions (avoid sourcing whole script)
source_ru_function "_is_valid_var_name"
source_ru_function "_set_out_var"
source_ru_function "_is_path_under_base"
source_ru_function "_is_safe_path_segment"
source_ru_function "ensure_dir"
source_ru_function "dir_lock_try_acquire"
source_ru_function "dir_lock_release"
source_ru_function "dir_lock_acquire"
source_ru_function "get_worktrees_dir"
source_ru_function "record_worktree_mapping"
source_ru_function "get_worktree_path"
source_ru_function "worktree_exists"
source_ru_function "list_review_worktrees"
source_ru_function "cleanup_review_worktrees"
source_ru_function "is_git_repo"
source_ru_function "repo_is_dirty"
source_ru_function "ensure_clean_or_fail"
source_ru_function "prepare_review_worktrees"

# prepare_review_worktrees calls digest helpers; keep tests focused on worktrees.
prepare_repo_digest_for_worktree() { :; }

# resolve_repo_spec is large; stub just enough for worktree tests.
# Supports branch/ref pinning via "owner/repo@ref".
resolve_repo_spec() {
    local spec="$1"
    local projects_dir="$2"
    local layout="$3"  # unused (tests assume flat)
    local url_var="$4"
    local branch_var="$5"
    local custom_var="$6"
    local path_var="$7"
    local repo_id_var="$8"

    local repo_spec="$spec"
    local ref=""
    if [[ "$repo_spec" == *"@"* ]]; then
        ref="${repo_spec##*@}"
        repo_spec="${repo_spec%@*}"
    fi

    local owner="${repo_spec%%/*}"
    local repo="${repo_spec##*/}"

    _set_out_var "$url_var" "https://github.com/$owner/$repo" || return 1
    _set_out_var "$branch_var" "$ref" || return 1
    _set_out_var "$custom_var" "" || return 1
    _set_out_var "$path_var" "$projects_dir/$repo" || return 1
    _set_out_var "$repo_id_var" "$owner/$repo" || return 1
    return 0
}

create_git_repo_with_commits() {
    local repo_path="$1"
    local commits="${2:-1}"

    ensure_dir "$repo_path"
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

worktree_path_for_repo() {
    local repo_id="$1"
    local worktrees_dir
    worktrees_dir=$(get_worktrees_dir)
    printf '%s/%s\n' "$worktrees_dir" "${repo_id//\//_}"
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_worktree_create_from_head() {
    log_test_start "worktrees: create from HEAD"
    e2e_setup

    export PROJECTS_DIR="$RU_PROJECTS_DIR"
    export LAYOUT="flat"
    export REVIEW_RUN_ID="wt-head-$$"

    local repo_id="acme/alpha"
    local repo_path="$PROJECTS_DIR/alpha"
    create_git_repo_with_commits "$repo_path" 1

    local item="${repo_id}|issue|1"
    local rc=0
    prepare_review_worktrees "$item" >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "prepare_review_worktrees succeeds"

    local wt_path
    wt_path=$(worktree_path_for_repo "$repo_id")
    assert_dir_exists "$wt_path" "Worktree directory created"
    local mapping_file
    mapping_file="$(get_worktrees_dir)/mapping.json"
    assert_file_exists "$mapping_file" "mapping.json written"

    if command -v jq >/dev/null 2>&1; then
        local mapped_path="" mapped_base=""
        mapped_path=$(jq -r --arg r "$repo_id" '.[$r].worktree_path // ""' "$mapping_file")
        mapped_base=$(jq -r --arg r "$repo_id" '.[$r].base_ref // ""' "$mapping_file")
        assert_equals "$wt_path" "$mapped_path" "Mapping stores worktree_path"
        assert_not_equals "" "$mapped_base" "Mapping stores base_ref"
    fi

    local mapped_path=""
    get_worktree_path "$repo_id" mapped_path >/dev/null 2>&1 || true
    assert_equals "$wt_path" "$mapped_path" "get_worktree_path returns worktree path"

    local head_main head_wt
    head_main=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || echo "")
    head_wt=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo "")
    assert_equals "$head_main" "$head_wt" "Worktree HEAD matches main repo HEAD"

    cleanup_review_worktrees "$REVIEW_RUN_ID" >/dev/null 2>&1 || true
    e2e_cleanup
    log_test_pass "worktrees: create from HEAD"
}

test_worktree_create_from_specific_commit() {
    log_test_start "worktrees: create from specific commit"
    e2e_setup

    export PROJECTS_DIR="$RU_PROJECTS_DIR"
    export LAYOUT="flat"
    export REVIEW_RUN_ID="wt-commit-$$"

    local repo_id="acme/beta"
    local repo_path="$PROJECTS_DIR/beta"
    create_git_repo_with_commits "$repo_path" 2

    local first_commit
    first_commit=$(git -C "$repo_path" rev-list --max-count=1 --reverse HEAD 2>/dev/null || echo "")
    assert_not_equals "" "$first_commit" "First commit SHA discovered"

    # Pinned ref in spec; resolved repo id should still be repo_id without @ref.
    local item="${repo_id}@${first_commit}|issue|1"
    local rc=0
    prepare_review_worktrees "$item" >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "prepare_review_worktrees succeeds with pinned ref"

    local wt_path
    wt_path=$(worktree_path_for_repo "$repo_id")
    assert_dir_exists "$wt_path" "Worktree directory created"

    local head_wt
    head_wt=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo "")
    assert_equals "$first_commit" "$head_wt" "Worktree HEAD matches pinned commit"

    local mapped_path=""
    get_worktree_path "$repo_id" mapped_path >/dev/null 2>&1 || true
    assert_equals "$wt_path" "$mapped_path" "Mapping key uses resolved repo id (no @ref)"

    local mapping_file
    mapping_file="$(get_worktrees_dir)/mapping.json"
    if command -v jq >/dev/null 2>&1; then
        local mapped_base=""
        mapped_base=$(jq -r --arg r "$repo_id" '.[$r].base_ref // ""' "$mapping_file")
        assert_equals "$first_commit" "$mapped_base" "Mapping stores pinned base_ref"
    fi

    cleanup_review_worktrees "$REVIEW_RUN_ID" >/dev/null 2>&1 || true
    e2e_cleanup
    log_test_pass "worktrees: create from specific commit"
}

test_worktree_respects_custom_state_dir() {
    log_test_start "worktrees: respects RU_STATE_DIR"
    e2e_setup

    export PROJECTS_DIR="$RU_PROJECTS_DIR"
    export LAYOUT="flat"
    export REVIEW_RUN_ID="wt-state-$$"

    export RU_STATE_DIR="$E2E_TEMP_DIR/custom_state/ru"
    ensure_dir "$RU_STATE_DIR"

    local repo_id="acme/gamma"
    local repo_path="$PROJECTS_DIR/gamma"
    create_git_repo_with_commits "$repo_path" 1

    local item="${repo_id}|issue|1"
    prepare_review_worktrees "$item" >/dev/null 2>&1 || true

    local wt_dir
    wt_dir=$(get_worktrees_dir)
    assert_contains "$wt_dir" "$RU_STATE_DIR/worktrees/$REVIEW_RUN_ID" "Worktrees dir uses RU_STATE_DIR"

    cleanup_review_worktrees "$REVIEW_RUN_ID" >/dev/null 2>&1 || true
    unset RU_STATE_DIR
    e2e_cleanup
    log_test_pass "worktrees: respects RU_STATE_DIR"
}

test_worktree_list_and_validate() {
    log_test_start "worktrees: list and validate mapping"
    e2e_setup

    export PROJECTS_DIR="$RU_PROJECTS_DIR"
    export LAYOUT="flat"
    export REVIEW_RUN_ID="wt-list-$$"

    local repo_a="acme/delta"
    local repo_b="acme/epsilon"
    create_git_repo_with_commits "$PROJECTS_DIR/delta" 1
    create_git_repo_with_commits "$PROJECTS_DIR/epsilon" 1

    prepare_review_worktrees "${repo_a}|issue|1" "${repo_b}|pr|2" >/dev/null 2>&1 || true

    local json
    json=$(list_review_worktrees "$REVIEW_RUN_ID" 2>/dev/null)
    if command -v jq >/dev/null 2>&1; then
        assert_equals "object" "$(printf '%s' "$json" | jq -r 'type')" "list_review_worktrees returns JSON object"
        assert_not_equals "" "$(printf '%s' "$json" | jq -r --arg r "$repo_a" '.[$r].worktree_path // ""')" "Repo A mapping present"
        assert_not_equals "" "$(printf '%s' "$json" | jq -r --arg r "$repo_b" '.[$r].worktree_path // ""')" "Repo B mapping present"
    else
        skip_test "jq not installed - skipping mapping validation"
    fi

    cleanup_review_worktrees "$REVIEW_RUN_ID" >/dev/null 2>&1 || true
    e2e_cleanup
    log_test_pass "worktrees: list and validate mapping"
}

test_worktree_cleanup_removes_all() {
    log_test_start "worktrees: cleanup removes all associated files"
    e2e_setup

    export PROJECTS_DIR="$RU_PROJECTS_DIR"
    export LAYOUT="flat"
    export REVIEW_RUN_ID="wt-clean-$$"

    local repo_id="acme/zeta"
    local repo_path="$PROJECTS_DIR/zeta"
    create_git_repo_with_commits "$repo_path" 1

    prepare_review_worktrees "${repo_id}|issue|1" >/dev/null 2>&1 || true

    local wt_path
    wt_path=$(worktree_path_for_repo "$repo_id")
    assert_dir_exists "$wt_path" "Worktree created"

    cleanup_review_worktrees "$REVIEW_RUN_ID" >/dev/null 2>&1 || true

    local base_dir="${XDG_STATE_HOME}/ru/worktrees/${REVIEW_RUN_ID}"
    assert_dir_not_exists "$base_dir" "Run worktrees directory removed"

    # Worktree should be gone from git's perspective
    if git -C "$repo_path" worktree list 2>/dev/null | grep -qF "$wt_path"; then
        fail "git worktree list should not include removed worktree"
    else
        pass "git worktree list does not include removed worktree"
    fi

    e2e_cleanup
    log_test_pass "worktrees: cleanup removes all associated files"
}

test_worktree_skips_corrupted_repo() {
    log_test_start "worktrees: corrupted/non-git repo is skipped safely"
    e2e_setup

    export PROJECTS_DIR="$RU_PROJECTS_DIR"
    export LAYOUT="flat"
    export REVIEW_RUN_ID="wt-corrupt-$$"

    local repo_id="acme/broken"
    local repo_path="$PROJECTS_DIR/broken"
    ensure_dir "$repo_path"
    printf '%s\n' "not a repo" > "$repo_path/README.txt"

    local rc=0
    prepare_review_worktrees "${repo_id}|issue|1" >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "prepare_review_worktrees does not hard-fail on non-git repo"

    if worktree_exists "$repo_id"; then
        fail "worktree_exists should be false for skipped repo"
    else
        pass "worktree_exists is false for skipped repo"
    fi

    cleanup_review_worktrees "$REVIEW_RUN_ID" >/dev/null 2>&1 || true
    e2e_cleanup
    log_test_pass "worktrees: corrupted/non-git repo is skipped safely"
}

test_worktree_mapping_concurrent_updates() {
    log_test_start "worktrees: concurrent mapping updates stay valid"
    e2e_setup

    export PROJECTS_DIR="$RU_PROJECTS_DIR"
    export LAYOUT="flat"
    export REVIEW_RUN_ID="wt-concurrent-$$"

    local repo_a="acme/cona"
    local repo_b="acme/conb"
    create_git_repo_with_commits "$PROJECTS_DIR/cona" 1
    create_git_repo_with_commits "$PROJECTS_DIR/conb" 1

    (
        prepare_review_worktrees "${repo_a}|issue|1" >/dev/null 2>&1 || true
    ) &
    local pid_a=$!
    (
        prepare_review_worktrees "${repo_b}|issue|1" >/dev/null 2>&1 || true
    ) &
    local pid_b=$!

    wait "$pid_a" 2>/dev/null || true
    wait "$pid_b" 2>/dev/null || true

    if command -v jq >/dev/null 2>&1; then
        local mapping_file
        mapping_file="$(get_worktrees_dir)/mapping.json"
        assert_file_exists "$mapping_file" "mapping.json exists after concurrent runs"
        if jq empty "$mapping_file" >/dev/null 2>&1; then
            pass "mapping.json is valid JSON after concurrent updates"
        else
            fail "mapping.json is invalid JSON after concurrent updates"
        fi
        assert_not_equals "" "$(jq -r --arg r "$repo_a" '.[$r].worktree_path // ""' "$mapping_file")" "Repo A mapping present"
        assert_not_equals "" "$(jq -r --arg r "$repo_b" '.[$r].worktree_path // ""' "$mapping_file")" "Repo B mapping present"
    else
        skip_test "jq not installed - skipping concurrent mapping validation"
    fi

    cleanup_review_worktrees "$REVIEW_RUN_ID" >/dev/null 2>&1 || true
    e2e_cleanup
    log_test_pass "worktrees: concurrent mapping updates stay valid"
}

#------------------------------------------------------------------------------
# Run tests
#------------------------------------------------------------------------------

log_suite_start "E2E Tests: worktree management"

run_test test_worktree_create_from_head
run_test test_worktree_create_from_specific_commit
run_test test_worktree_respects_custom_state_dir
run_test test_worktree_list_and_validate
run_test test_worktree_cleanup_removes_all
run_test test_worktree_skips_corrupted_repo
run_test test_worktree_mapping_concurrent_updates

print_results
exit "$(get_exit_code)"
