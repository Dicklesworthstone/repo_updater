#!/usr/bin/env bash
#
# E2E Test: ru add/remove workflow
# Tests adding and removing repositories from the config
#
# Test coverage:
#   - ru add adds repos to public.txt
#   - ru add validates repo format
#   - ru add detects duplicates
#   - ru add supports multiple repos at once
#   - ru list shows configured repos
#   - ru list --paths shows local paths
#   - ru remove removes repos from public.txt
#   - ru remove matches by owner/repo (not substring)
#   - ru remove handles not-found gracefully
#   - ru import --stars/--org/--user/--limit (controlled gh stub): visibility
#     routing, limits, --private, dry run, fail-closed listing, validation
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
set -uo pipefail

#==============================================================================
# Source E2E Test Framework
#==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Tests: ru add
#==============================================================================

test_add_single_repo() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    # Initialize config
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" add owner/repo 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "ru add exits with code 0"
    assert_contains "$output" "Added" "Output confirms repo added"
    assert_file_contains "$repos_file" "owner/repo" "public.txt contains the repo"

    e2e_cleanup
}

test_add_multiple_repos() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add cli/cli charmbracelet/gum koalaman/shellcheck 2>&1

    assert_file_contains "$repos_file" "cli/cli" "public.txt contains cli/cli"
    assert_file_contains "$repos_file" "charmbracelet/gum" "public.txt contains charmbracelet/gum"
    assert_file_contains "$repos_file" "koalaman/shellcheck" "public.txt contains koalaman/shellcheck"

    e2e_cleanup
}

test_add_duplicate_repo() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add owner/repo 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" add owner/repo 2>&1)

    assert_contains "$output" "Already configured" "Duplicate is detected"

    e2e_cleanup
}

test_add_invalid_format() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" add "invalid-format" 2>&1)

    assert_contains "$output" "Invalid" "Invalid format is rejected"

    e2e_cleanup
}

test_add_and_remove_invalid_specs_fail() {
    e2e_setup
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt" exit_code

    exit_code=0
    "$E2E_RU_SCRIPT" add "invalid-format" >/dev/null 2>&1 || exit_code=$?
    assert_equals "4" "$exit_code" "add with only an invalid spec is a bad argument"
    exit_code=0
    "$E2E_RU_SCRIPT" add owner/good "invalid-format" >/dev/null 2>&1 || exit_code=$?
    assert_equals "1" "$exit_code" "add with a valid and an invalid spec is a partial failure"
    assert_file_contains "$repos_file" "owner/good" "the valid repo is still added"
    exit_code=0
    "$E2E_RU_SCRIPT" remove "invalid-format" >/dev/null 2>&1 || exit_code=$?
    assert_equals "4" "$exit_code" "remove with only an invalid spec is a bad argument"
    exit_code=0
    "$E2E_RU_SCRIPT" remove owner/good "invalid-format" >/dev/null 2>&1 || exit_code=$?
    assert_equals "1" "$exit_code" "remove with a valid and an invalid spec is a partial failure"

    e2e_cleanup
}

test_config_commands_print_one_json_result() {
    e2e_setup
    local out exit_code
    exit_code=0
    out=$("$E2E_RU_SCRIPT" --json init 2>/dev/null) || exit_code=$?
    assert_equals "0 init true 0" "$exit_code $(printf '%s\n' "$out" | jq -r '"\(.command) \(.data.created) \(._meta.exit_code)"' 2>/dev/null)" "init reports the created configuration"
    out=$("$E2E_RU_SCRIPT" --json init 2>/dev/null)
    assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.data.created' 2>/dev/null)" "a second init reports the existing configuration"

    exit_code=0
    out=$("$E2E_RU_SCRIPT" --json add owner/one "invalid-format" 2>/dev/null) || exit_code=$?
    assert_equals "1" "$(printf '%s\n' "$out" | jq -s 'length' 2>/dev/null)" "add prints exactly one JSON document"
    assert_equals "1 owner/one invalid_format 1" \
        "$exit_code $(printf '%s\n' "$out" | jq -r '"\(.data.added[0].repo) \(.data.invalid[0].reason) \(._meta.exit_code)"' 2>/dev/null)" \
        "add reports the added and the invalid spec with the exit code"
    out=$("$E2E_RU_SCRIPT" --json add owner/one 2>/dev/null)
    assert_equals "owner/one public 0" "$(printf '%s\n' "$out" | jq -r '"\(.data.already_configured[0].repo) \(.data.already_configured[0].list) \(._meta.exit_code)"' 2>/dev/null)" \
        "a repeated add reports the repo as already configured"

    exit_code=0
    out=$("$E2E_RU_SCRIPT" --json remove owner/one owner/missing 2>/dev/null) || exit_code=$?
    assert_equals "0 owner/one owner/missing 0" \
        "$exit_code $(printf '%s\n' "$out" | jq -r '"\(.data.removed[0].repo) \(.data.not_found[0]) \(._meta.exit_code)"' 2>/dev/null)" \
        "remove reports the removed and the missing repo"
    exit_code=0
    out=$("$E2E_RU_SCRIPT" --json add 2>/dev/null) || exit_code=$?
    assert_equals "4 missing_repository 4" "$exit_code $(printf '%s\n' "$out" | jq -r '"\(.data.error.reason) \(._meta.exit_code)"' 2>/dev/null)" \
        "an add without a repo prints its refusal as JSON"

    e2e_cleanup
}

test_add_https_url() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add "https://github.com/owner/repo" 2>&1

    assert_file_contains "$repos_file" "https://github.com/owner/repo" "HTTPS URL is added"

    e2e_cleanup
}

test_add_no_args() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" add 2>&1) || exit_code=$?

    assert_equals "4" "$exit_code" "ru add with no args exits with code 4"
    assert_contains "$output" "Usage" "Shows usage message"

    e2e_cleanup
}

#==============================================================================
# Tests: ru list
#==============================================================================

test_list_shows_repos() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add owner/repo1 owner/repo2 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" list 2>&1)

    assert_contains "$output" "owner/repo1" "list shows repo1"
    assert_contains "$output" "owner/repo2" "list shows repo2"

    e2e_cleanup
}

test_list_empty() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" list 2>&1)

    assert_contains "$output" "No repositories configured" "Empty list message shown"

    e2e_cleanup
}

test_list_paths_mode() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add owner/repo 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" list --paths 2>&1)

    # Should show a path containing the repo name
    assert_contains "$output" "repo" "Path output contains repo name"

    e2e_cleanup
}

#==============================================================================
# Tests: ru remove
#==============================================================================

test_remove_single_repo() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add owner/repo 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" remove owner/repo 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "ru remove exits with code 0"
    assert_contains "$output" "Removed" "Output confirms repo removed"
    if [[ -f "$repos_file" ]] && ! grep -q "^owner/repo$" "$repos_file"; then
        pass "public.txt no longer contains the repo"
    else
        fail "public.txt no longer contains the repo"
    fi

    e2e_cleanup
}

test_remove_not_found() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" remove nonexistent/repo 2>&1) || exit_code=$?

    assert_equals "1" "$exit_code" "ru remove exits with code 1 for not found"
    assert_contains "$output" "Not found" "Not found message shown"

    e2e_cleanup
}

test_remove_no_substring_match() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    # Add two repos with similar names
    "$E2E_RU_SCRIPT" add owner/repo owner/repo-extra 2>&1

    # Remove only owner/repo
    "$E2E_RU_SCRIPT" remove owner/repo 2>&1

    # owner/repo-extra should still be present
    assert_file_contains "$repos_file" "owner/repo-extra" "repo-extra still present after removing repo"

    e2e_cleanup
}

test_remove_no_args() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" remove 2>&1) || exit_code=$?

    assert_equals "4" "$exit_code" "ru remove with no args exits with code 4"
    assert_contains "$output" "Usage" "Shows usage message"

    e2e_cleanup
}

test_remove_preserves_comments() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add owner/repo 2>&1

    # Add a comment manually
    echo "# My custom comment" >> "$repos_file"

    "$E2E_RU_SCRIPT" remove owner/repo 2>&1

    assert_file_contains "$repos_file" "My custom comment" "Comments are preserved"

    e2e_cleanup
}

#==============================================================================
# Tests: Private repos (--private flag)
#==============================================================================

test_add_private_repo() {
    e2e_setup

    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    local private_file="$XDG_CONFIG_HOME/ru/repos.d/private.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" add --private secret/repo 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "ru add --private exits with code 0"
    assert_contains "$output" "Added" "Output confirms repo added"
    assert_contains "$output" "private" "Output mentions private"
    if [[ -f "$repos_file" ]] && ! grep -q "secret/repo" "$repos_file"; then
        pass "public.txt does NOT contain the private repo"
    else
        fail "public.txt does NOT contain the private repo"
    fi

    if [[ -f "$private_file" ]] && grep -q "secret/repo" "$private_file"; then
        pass "private.txt contains the private repo"
    else
        fail "private.txt should contain secret/repo"
    fi

    e2e_cleanup
}

test_list_public_filter() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add public/repo1 public/repo2 2>&1
    "$E2E_RU_SCRIPT" add --private private/repo 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" list --public 2>&1)

    assert_contains "$output" "public/repo1" "Shows public repo1"
    assert_contains "$output" "public/repo2" "Shows public repo2"
    assert_not_contains "$output" "private/repo" "list --public excludes private repo"

    e2e_cleanup
}

test_list_private_filter() {
    e2e_setup

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add public/repo 2>&1
    "$E2E_RU_SCRIPT" add --private private/repo1 private/repo2 2>&1

    local output
    output=$("$E2E_RU_SCRIPT" list --private 2>&1)

    assert_contains "$output" "private/repo1" "Shows private repo1"
    assert_contains "$output" "private/repo2" "Shows private repo2"
    assert_not_contains "$output" "public/repo" "list --private excludes public repo"

    e2e_cleanup
}

test_remove_from_private() {
    e2e_setup

    local private_file="$XDG_CONFIG_HOME/ru/repos.d/private.txt"

    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add --private secret/repo 2>&1

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" remove secret/repo 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "ru remove exits with code 0 for private repo"
    assert_contains "$output" "Removed" "Output confirms repo removed"
    assert_contains "$output" "private" "Output mentions it was from private"

    if [[ -f "$private_file" ]] && grep -q "secret/repo" "$private_file"; then
        fail "private.txt should no longer contain secret/repo"
    else
        pass "secret/repo removed from private.txt"
    fi

    e2e_cleanup
}

#==============================================================================
# Tests: ru import from GitHub (--stars, --org, --user, --limit)
# A controlled gh stub stands in for GitHub: it proves the CLI wiring,
# selection, limits, visibility routing and failure handling, not live API
# behavior. Any call the stub does not expect exits 99.
#==============================================================================

create_import_gh_stub() {
    e2e_create_mock_gh_custom '
case "$*" in
    "auth status"*) exit 0 ;;
    "api --paginate user/starred?per_page=100 "*)
        printf "%s\t%s\n" starowner/public-one false starowner/secret-two true starowner/public-three false
        exit 0 ;;
    "repo list acme "*)
        printf "%s\t%s\n" acme/alpha false acme/beta false acme/gamma true
        exit 0 ;;
    "repo list missing "*)
        echo "GraphQL: Could not resolve to a User with the login of missing" >&2
        exit 1 ;;
esac
echo "unexpected gh call: $*" >&2
exit 99'
}

test_import_stars_routes_by_visibility() {
    e2e_setup
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    create_import_gh_stub
    local public_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    local private_file="$XDG_CONFIG_HOME/ru/repos.d/private.txt"

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" import --stars 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "ru import --stars exits 0"
    assert_file_contains "$public_file" "starowner/public-one" "public starred repo goes to public.txt"
    assert_file_contains "$public_file" "starowner/public-three" "second public starred repo goes to public.txt"
    assert_file_contains "$private_file" "starowner/secret-two" "private starred repo goes to private.txt"
    assert_false "grep -q 'secret-two' '$public_file'" "private starred repo is not in public.txt"
    assert_false "grep -q '^.* gh api repos/' '$E2E_LOG_DIR/gh_calls.log'" "visibility comes from the listing, not per-repo lookups"
    assert_not_contains "$output" "unexpected gh call" "only expected gh calls are made"

    e2e_cleanup
}

test_import_org_limit_and_private() {
    e2e_setup
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    create_import_gh_stub
    local public_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    local private_file="$XDG_CONFIG_HOME/ru/repos.d/private.txt"

    local exit_code=0
    "$E2E_RU_SCRIPT" import --org=acme --limit=2 >/dev/null 2>&1 || exit_code=$?
    assert_equals "0" "$exit_code" "ru import --org=acme --limit=2 exits 0"
    assert_file_contains "$public_file" "acme/alpha" "first org repo imported"
    assert_file_contains "$public_file" "acme/beta" "second org repo imported"
    assert_false "grep -q 'acme/gamma' '$public_file' '$private_file'" "--limit=2 stops after two repos"

    exit_code=0
    "$E2E_RU_SCRIPT" import --org=acme --private >/dev/null 2>&1 || exit_code=$?
    assert_equals "0" "$exit_code" "ru import --org=acme --private exits 0"
    assert_file_contains "$private_file" "acme/gamma" "--private forces the remaining repo into private.txt"

    e2e_cleanup
}

test_import_dry_run_writes_nothing() {
    e2e_setup
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    create_import_gh_stub
    local repos_dir="$XDG_CONFIG_HOME/ru/repos.d"
    local before after
    before=$(cat "$repos_dir"/*.txt 2>/dev/null)

    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" import --stars --dry-run 2>&1) || exit_code=$?
    after=$(cat "$repos_dir"/*.txt 2>/dev/null)

    assert_equals "0" "$exit_code" "ru import --stars --dry-run exits 0"
    assert_contains "$output" "Import Preview" "dry run shows a preview"
    assert_equals "$before" "$after" "dry run leaves the repo lists unchanged"

    e2e_cleanup
}

test_import_failed_listing_imports_nothing() {
    e2e_setup
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    create_import_gh_stub
    local repos_dir="$XDG_CONFIG_HOME/ru/repos.d"
    local before after
    before=$(cat "$repos_dir"/*.txt 2>/dev/null)

    # acme lists fine, but missing fails: nothing may be imported
    local output exit_code=0
    output=$("$E2E_RU_SCRIPT" import --org=acme --user=missing 2>&1) || exit_code=$?
    after=$(cat "$repos_dir"/*.txt 2>/dev/null)

    assert_equals "3" "$exit_code" "a failed GitHub listing exits 3"
    assert_contains "$output" "Could not list GitHub user missing" "the failing source is named"
    assert_contains "$output" "Could not resolve" "gh's error is shown"
    assert_equals "$before" "$after" "nothing is imported when any listing fails"

    e2e_cleanup
}

test_import_github_argument_validation() {
    e2e_setup
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
    create_import_gh_stub

    local args exit_code
    for args in "--stars --limit=0" "--stars --limit=two" "--org=bad.name" "--limit=3"; do
        exit_code=0
        # shellcheck disable=SC2086  # each case is a list of separate flags
        "$E2E_RU_SCRIPT" import $args >/dev/null 2>&1 || exit_code=$?
        assert_equals "4" "$exit_code" "ru import $args exits 4"
    done

    local out
    out=$("$E2E_RU_SCRIPT" --json import --stars --limit=0 2>/dev/null)
    assert_equals "invalid_limit 4" "$(printf '%s\n' "$out" | jq -r '"\(.data.error.reason) \(._meta.exit_code)"' 2>/dev/null)" \
        "a refused import prints its reason as JSON"
    exit_code=0
    out=$("$E2E_RU_SCRIPT" --json import --stars --dry-run 2>/dev/null) || exit_code=$?
    assert_equals "1" "$(printf '%s\n' "$out" | jq -s 'length' 2>/dev/null)" "an import prints exactly one JSON document"
    assert_equals "$exit_code true import" "$(printf '%s\n' "$out" | jq -r '"\(._meta.exit_code) \(.data.dry_run) \(.command)"' 2>/dev/null)" \
        "the import result carries the dry run and the exit code"

    e2e_cleanup
}

#==============================================================================
# Run Tests
#==============================================================================

run_test test_add_single_repo
run_test test_add_multiple_repos
run_test test_add_duplicate_repo
run_test test_add_invalid_format
run_test test_add_and_remove_invalid_specs_fail
run_test test_config_commands_print_one_json_result
run_test test_add_https_url
run_test test_add_no_args
run_test test_list_shows_repos
run_test test_list_empty
run_test test_list_paths_mode
run_test test_remove_single_repo
run_test test_remove_not_found
run_test test_remove_no_substring_match
run_test test_remove_no_args
run_test test_remove_preserves_comments
run_test test_add_private_repo
run_test test_list_public_filter
run_test test_list_private_filter
run_test test_remove_from_private
run_test test_import_stars_routes_by_visibility
run_test test_import_org_limit_and_private
run_test test_import_dry_run_writes_nothing
run_test test_import_failed_listing_imports_nothing
run_test test_import_github_argument_validation

print_results
