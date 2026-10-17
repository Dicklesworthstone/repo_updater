#!/usr/bin/env bash
#
# Unit tests: Prompt generation (bd-prompt)
#
# Tests:
# - generate_digest_prompt
# - generate_review_prompt
#
# shellcheck disable=SC1091
# shellcheck disable=SC2317

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

# Source functions
source_ru_function "generate_digest_prompt"
source_ru_function "generate_review_prompt"
source_ru_function "get_worktrees_dir"

test_generate_digest_prompt() {
    local test_name="generate_digest_prompt: outputs expected text"
    log_test_start "$test_name"

    local output
    output=$(generate_digest_prompt)

    assert_contains "$output" "repo-digest.md" "Should mention repo-digest.md"
    assert_contains "$output" "AGENTS.md" "Should mention AGENTS.md"

    log_test_pass "$test_name"
}

test_generate_review_prompt() {
    local test_name="generate_review_prompt: outputs structured prompt"
    log_test_start "$test_name"

    local items_json='[{"number":1,"title":"Bug"}]'
    local env_root wt_path base_sha
    env_root=$(create_test_env)
    export RU_STATE_DIR="$env_root/state/ru" REVIEW_RUN_ID="run-123"
    wt_path="$(get_worktrees_dir)/owner_repo"
    mkdir -p "$wt_path"
    git -C "$wt_path" init -q
    git -C "$wt_path" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m Initial
    git -C "$wt_path" branch -m review-candidate
    base_sha=$(git -C "$wt_path" rev-parse HEAD)
    jq -n --arg sha "$base_sha" '{"owner/repo":{base_ref:"main",base_sha:$sha}}' > "$(get_worktrees_dir)/mapping.json"
    local output
    output=$(generate_review_prompt "owner/repo" "$wt_path" "run-123" "$items_json")

    assert_contains "$output" "owner/repo" "Should contain repo name"
    assert_contains "$output" "$wt_path" "Should contain worktree path"
    assert_contains "$output" "run-123" "Should contain run ID"
    assert_contains "$output" "Bug" "Should contain work items"
    assert_contains "$output" "schema_version: 1" "Should contain schema version"
    assert_contains "$output" "$base_sha" "Prompt carries the original exact base"
    assert_contains "$output" 'git.branch: "review-candidate"' "Prompt binds the actual candidate branch"
    assert_contains "$output" 'full sha and subject' "Prompt requests complete candidate identity"

    log_test_pass "$test_name"
}

run_test test_generate_digest_prompt
run_test test_generate_review_prompt

print_results
