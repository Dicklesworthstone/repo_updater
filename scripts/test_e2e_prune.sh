#!/usr/bin/env bash
#
# E2E Test: ru prune workflow
# Tests detection and management of orphan repositories
#
# Test coverage:
#   - ru prune detects orphan repos (dry run by default)
#   - ru prune shows no orphans when all are configured
#   - ru prune --archive moves orphans to archive directory
#   - ru prune --delete removes orphans (with confirmation)
#   - ru prune --delete --non-interactive skips confirmation
#   - ru prune handles empty projects directory
#   - ru prune handles different layout modes
#   - ru prune respects custom names
#   - ru prune with conflicting options shows error
#   - ru prune handles JSON output
#   - ru prune --delete keeps orphans with unsaved work unless --force
#   - ru prune --archive/--delete keep clones of configured repos at old paths
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Test-Specific Helpers
#==============================================================================

setup_initialized_env() {
    e2e_setup
    export RU_LAYOUT="flat"
    # Clear env vars that might interfere
    unset RU_AUTOSTASH RU_UPDATE_STRATEGY
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1
}

# Configure one repo that is never cloned. Destructive prune refuses to run
# with no configured repos at all (every clone would be an "orphan").
configure_placeholder_repo() {
    printf '%s\n' "owner/placeholder" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"
}

# Create an orphan git repo
create_orphan_repo() {
    local name="$1"
    local path="$RU_PROJECTS_DIR/$name"
    mkdir -p "$path"
    git -C "$path" init --quiet 2>/dev/null
}

#==============================================================================
# Tests: Basic Prune Detection
#==============================================================================

test_prune_detects_orphans() {
    setup_initialized_env

    # Add a configured repo (don't clone)
    "$E2E_RU_SCRIPT" add owner/configured-repo >/dev/null 2>&1

    # Create orphan repos
    create_orphan_repo "orphan1"
    create_orphan_repo "orphan2"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "Found 2 orphan" "Reports 2 orphans"
    assert_contains "$stderr_output" "orphan1" "Lists orphan1"
    assert_contains "$stderr_output" "orphan2" "Lists orphan2"
    assert_contains "$stderr_output" "Use --archive" "Shows usage hint"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_no_orphans() {
    setup_initialized_env

    # Add a repo and create its directory
    "$E2E_RU_SCRIPT" add owner/myrepo >/dev/null 2>&1
    create_orphan_repo "myrepo"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "No orphan" "Reports no orphans"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_empty_projects_dir() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "No orphan" "Reports no orphans"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_nonexistent_projects_dir() {
    setup_initialized_env

    rm -rf "$RU_PROJECTS_DIR"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "does not exist" "Reports missing directory"

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: Archive Mode
#==============================================================================

test_prune_archive_mode() {
    setup_initialized_env
    configure_placeholder_repo

    create_orphan_repo "orphan-to-archive"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune --archive 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "Archived" "Reports archiving"
    assert_contains "$stderr_output" "orphan-to-archive" "Mentions orphan name"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-to-archive" "Orphan removed from projects"
    assert_dir_exists "$XDG_STATE_HOME/ru/archived" "Archive directory created"

    # Verify archive contains the repo with timestamp
    local archived_count=0
    # Use find instead of ls | grep to handle non-alphanumeric filenames safely
    archived_count=$(/usr/bin/find "$XDG_STATE_HOME/ru/archived" -maxdepth 1 -type d -name "orphan-to-archive*" 2>/dev/null | wc -l)
    if [[ "$archived_count" -eq 1 ]]; then
        pass "Orphan archived with timestamp"
    else
        fail "Orphan not found in archive (found $archived_count)"
    fi

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: Delete Mode
#==============================================================================

test_prune_delete_noninteractive() {
    setup_initialized_env
    configure_placeholder_repo

    create_orphan_repo "orphan-to-delete"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" --non-interactive prune --delete 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "Deleted" "Reports deletion"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-to-delete" "Orphan removed"

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: Error Handling
#==============================================================================

test_prune_conflicting_options() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune --archive --delete 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "4" "$exit_code" "Exits with code 4 for invalid args"
    assert_contains "$stderr_output" "Cannot use both" "Shows error message"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_unknown_option() {
    setup_initialized_env

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune --invalid 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "4" "$exit_code" "Exits with code 4 for unknown option"
    assert_contains "$stderr_output" "Unknown option" "Shows error message"

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: Layout Modes
#==============================================================================

test_prune_owner_repo_layout() {
    setup_initialized_env
    export RU_LAYOUT="owner-repo"

    "$E2E_RU_SCRIPT" add owner/configured >/dev/null 2>&1

    # Create orphan at owner-repo depth
    mkdir -p "$RU_PROJECTS_DIR/orphan-owner/orphan-repo"
    git -C "$RU_PROJECTS_DIR/orphan-owner/orphan-repo" init --quiet 2>/dev/null

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "Found 1 orphan" "Reports 1 orphan"
    assert_contains "$stderr_output" "orphan-owner/orphan-repo" "Shows full path"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_grouped_repos() {
    setup_initialized_env
    export RU_LAYOUT="owner-repo"

    # Configured grouped repo, plus an unconfigured repo in the same group folder
    "$E2E_RU_SCRIPT" add --group illo tmchow/illo-website >/dev/null 2>&1
    mkdir -p "$RU_PROJECTS_DIR/tmchow/illo/illo-website" "$RU_PROJECTS_DIR/tmchow/illo/stale"
    git -C "$RU_PROJECTS_DIR/tmchow/illo/illo-website" init --quiet 2>/dev/null
    git -C "$RU_PROJECTS_DIR/tmchow/illo/stale" init --quiet 2>/dev/null
    # A repo nested inside a configured working tree is not an orphan
    mkdir -p "$RU_PROJECTS_DIR/tmchow/illo/illo-website/vendor/dep"
    git -C "$RU_PROJECTS_DIR/tmchow/illo/illo-website/vendor/dep" init --quiet 2>/dev/null

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "Found 1 orphan" "Only the stale grouped repo is an orphan"
    assert_contains "$stderr_output" "tmchow/illo/stale" "Scans one level deeper for the group"
    assert_not_contains "$stderr_output" "vendor/dep" "Skips repos nested in configured repos"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_group_does_not_widen_scan() {
    setup_initialized_env

    # One grouped repo must not expose unrelated deeper repos elsewhere
    "$E2E_RU_SCRIPT" add --group illo owner/illo-website >/dev/null 2>&1
    create_orphan_repo "illo/illo-website"
    create_orphan_repo "work/client-a"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)

    assert_contains "$stderr_output" "No orphan" "Plain folders stay out of the scan"
    assert_not_contains "$stderr_output" "work/client-a" "Unmanaged repo in a plain folder is not an orphan"

    e2e_cleanup
}

test_prune_never_deletes_repo_containing_configured_repo() {
    setup_initialized_env

    "$E2E_RU_SCRIPT" add --group illo owner/illo-website >/dev/null 2>&1
    create_orphan_repo "illo/illo-website"
    # Someone ran 'git init' in the group folder itself
    git -C "$RU_PROJECTS_DIR/illo" init --quiet 2>/dev/null

    "$E2E_RU_SCRIPT" prune --delete --non-interactive >/dev/null 2>&1

    assert_dir_exists "$RU_PROJECTS_DIR/illo/illo-website/.git" "Configured grouped repo survives prune --delete"

    e2e_cleanup
}

test_prune_matches_configured_repo_by_physical_path() {
    setup_initialized_env
    export RU_LAYOUT="owner-repo"

    # Configured under an owner folder that is a symlink to the real one (org
    # rename), and with different letter case than the clone on disk.
    "$E2E_RU_SCRIPT" add OldOrg/tool >/dev/null 2>&1
    "$E2E_RU_SCRIPT" add Owner/Repo >/dev/null 2>&1
    create_orphan_repo "NewOrg/tool"
    ln -s NewOrg "$RU_PROJECTS_DIR/OldOrg"
    create_orphan_repo "owner/repo"
    # Same repo spelled with a trailing slash in PROJECTS_DIR
    local projects_dir="$RU_PROJECTS_DIR"
    export RU_PROJECTS_DIR="$projects_dir/"

    "$E2E_RU_SCRIPT" prune --delete --non-interactive >/dev/null 2>&1

    export RU_PROJECTS_DIR="$projects_dir"
    assert_dir_exists "$RU_PROJECTS_DIR/NewOrg/tool/.git" "Repo configured via a symlinked owner folder survives"
    assert_dir_exists "$RU_PROJECTS_DIR/owner/repo/.git" "Repo configured with different case survives"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_refuses_destructive_modes_with_unresolvable_specs() {
    setup_initialized_env

    # An older ru resolved this line to $PROJECTS_DIR/y; this one rejects it.
    printf '%s\n' "owner/repo as x as y" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    create_orphan_repo "y"

    local output exit_code
    output=$("$E2E_RU_SCRIPT" prune --delete --non-interactive 2>&1)
    exit_code=$?

    assert_equals "4" "$exit_code" "Exits with code 4"
    assert_contains "$output" "Refusing to archive or delete" "Explains the refusal"
    assert_dir_exists "$RU_PROJECTS_DIR/y/.git" "Clone of the unresolvable line survives"

    e2e_cleanup
}

test_prune_matches_configured_repo_across_unicode_normalization() {
    setup_initialized_env

    # Config spells the name precomposed (NFC); the clone on disk is
    # decomposed (NFD), as HFS+ stores it or as a hand-made clone may be.
    # Same directory on a normalization-insensitive filesystem (APFS, HFS+).
    local nfc nfd
    nfc=$(printf 'caf\xc3\xa9')
    nfd=$(printf 'cafe\xcc\x81')
    printf '%s\n' "owner/tool as $nfc" "owner/lib in $nfc" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    create_orphan_repo "$nfd"
    if [[ ! "$RU_PROJECTS_DIR/$nfc" -ef "$RU_PROJECTS_DIR/$nfd" ]]; then
        # Normalization-sensitive filesystem: the two names are two folders
        e2e_cleanup
        return 0
    fi
    create_orphan_repo "$nfd/lib"

    "$E2E_RU_SCRIPT" prune --delete --non-interactive >/dev/null 2>&1

    assert_dir_exists "$RU_PROJECTS_DIR/$nfd/.git" "Configured repo spelled in another Unicode normalization survives"
    assert_dir_exists "$RU_PROJECTS_DIR/$nfd/lib/.git" "Grouped repo under that folder survives"

    e2e_cleanup
}

test_prune_refuses_destructive_modes_with_unreadable_list() {
    setup_initialized_env
    configure_placeholder_repo

    printf '%s\n' "owner/tool" > "$XDG_CONFIG_HOME/ru/repos.d/work.txt"
    create_orphan_repo "tool"
    chmod 000 "$XDG_CONFIG_HOME/ru/repos.d/work.txt"
    if [[ -r "$XDG_CONFIG_HOME/ru/repos.d/work.txt" ]]; then
        # Running as root: permissions do not apply
        chmod 644 "$XDG_CONFIG_HOME/ru/repos.d/work.txt"
        e2e_cleanup
        return 0
    fi

    local output exit_code
    output=$("$E2E_RU_SCRIPT" prune --delete --non-interactive 2>&1)
    exit_code=$?
    chmod 644 "$XDG_CONFIG_HOME/ru/repos.d/work.txt"

    assert_equals "4" "$exit_code" "Exits with code 4"
    assert_contains "$output" "Refusing to archive or delete" "Explains the refusal"
    assert_dir_exists "$RU_PROJECTS_DIR/tool/.git" "Clone listed in the unreadable file survives"

    e2e_cleanup
}

test_prune_never_acts_on_newline_split_fragments() {
    setup_initialized_env

    # A clone folder whose name holds a newline reaches prune as two lines
    # of find output; the relative fragment "bar" must not resolve against
    # the current directory.
    create_orphan_repo $'x\nbar'
    local cwd="$E2E_TEMP_DIR/cwd"
    mkdir -p "$cwd/bar"
    git -C "$cwd/bar" init --quiet 2>/dev/null

    (cd "$cwd" && "$E2E_RU_SCRIPT" prune --delete --non-interactive >/dev/null 2>&1)

    assert_dir_exists "$cwd/bar/.git" "Repo in the current directory is untouched"

    e2e_cleanup
}

test_prune_keeps_clone_of_deduped_repeat() {
    setup_initialized_env

    # Listed plain and again in a group: sync dedupes to the plain line, but a
    # clone at the grouped path is still a configured location, not an orphan.
    printf '%s\n' "owner/tool" "owner/tool in grp" "owner/other in grp" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    create_orphan_repo "tool"
    create_orphan_repo "grp/tool"
    create_orphan_repo "grp/other"

    "$E2E_RU_SCRIPT" prune --delete --non-interactive >/dev/null 2>&1

    assert_dir_exists "$RU_PROJECTS_DIR/grp/tool/.git" "Grouped repeat's clone survives"
    assert_dir_exists "$RU_PROJECTS_DIR/tool/.git" "Plain clone survives"

    e2e_cleanup
}

test_prune_full_layout() {
    setup_initialized_env
    export RU_LAYOUT="full"

    "$E2E_RU_SCRIPT" add owner/configured >/dev/null 2>&1

    # Create orphan at full depth
    mkdir -p "$RU_PROJECTS_DIR/github.com/orphan-owner/orphan-repo"
    git -C "$RU_PROJECTS_DIR/github.com/orphan-owner/orphan-repo" init --quiet 2>/dev/null

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "Found 1 orphan" "Reports 1 orphan"
    assert_contains "$stderr_output" "github.com" "Shows host in path"

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: Custom Names
#==============================================================================

test_prune_respects_custom_names() {
    setup_initialized_env

    # Add repo with custom name
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "owner/long-repository-name as shortname" >> "$repos_file"

    # Create directory with custom name
    create_orphan_repo "shortname"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "No orphan" "Custom name directory not marked as orphan"

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: JSON Output
#==============================================================================

test_prune_json_output() {
    setup_initialized_env

    create_orphan_repo "orphan-json"

    local stdout_output
    stdout_output=$("$E2E_RU_SCRIPT" --json prune 2>/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stdout_output" '"path"' "JSON output contains path field"
    assert_contains "$stdout_output" "orphan-json" "JSON output contains orphan path"

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Tests: Multiple Orphans
#==============================================================================

test_prune_archive_multiple() {
    setup_initialized_env
    configure_placeholder_repo

    create_orphan_repo "orphan-a"
    create_orphan_repo "orphan-b"
    create_orphan_repo "orphan-c"

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune --archive 2>&1 >/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$stderr_output" "Archived 3" "Reports 3 archived"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-a" "orphan-a removed"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-b" "orphan-b removed"
    assert_dir_not_exists "$RU_PROJECTS_DIR/orphan-c" "orphan-c removed"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_archive_same_named_orphans_stay_separate() {
    setup_initialized_env
    export RU_LAYOUT="owner-repo"
    configure_placeholder_repo

    # owner-a/tool, owner-b/tool, owner-c/tool archive to the same
    # <name>_<timestamp> within one second; each must get its own folder
    # rather than being moved into the previous one's working tree.
    local o
    for o in owner-a owner-b owner-c; do
        create_orphan_repo "$o/tool"
        printf '%s\n' "$o" | tee "$RU_PROJECTS_DIR/$o/tool/marker" >/dev/null
    done

    local stderr_output
    stderr_output=$("$E2E_RU_SCRIPT" prune --archive 2>&1 >/dev/null)

    assert_contains "$stderr_output" "Archived 3" "Reports 3 archived"
    local top_level nested
    top_level=$(/usr/bin/find "$XDG_STATE_HOME/ru/archived" -mindepth 2 -maxdepth 2 -name marker | wc -l | tr -d ' ')
    nested=$(/usr/bin/find "$XDG_STATE_HOME/ru/archived" -mindepth 3 -name marker | wc -l | tr -d ' ')
    assert_equals "3" "$top_level" "Each clone has its own archive folder"
    assert_equals "0" "$nested" "No clone archived inside another"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_refuses_destructive_modes_with_unlistable_list_dir() {
    setup_initialized_env

    printf '%s\n' "owner/tool" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    create_orphan_repo "tool"
    # Searchable but not listable: the *.txt glob matches nothing, so no
    # list is read at all and every configured clone looks like an orphan.
    chmod 311 "$XDG_CONFIG_HOME/ru/repos.d"
    if [[ -r "$XDG_CONFIG_HOME/ru/repos.d" ]]; then
        # Running as root: permissions do not apply
        chmod 755 "$XDG_CONFIG_HOME/ru/repos.d"
        e2e_cleanup
        return 0
    fi

    local output exit_code
    output=$("$E2E_RU_SCRIPT" prune --archive 2>&1)
    exit_code=$?
    chmod 755 "$XDG_CONFIG_HOME/ru/repos.d"

    assert_equals "4" "$exit_code" "Exits with code 4"
    assert_contains "$output" "Refusing to archive or delete" "Explains the refusal"
    assert_dir_exists "$RU_PROJECTS_DIR/tool/.git" "Configured clone survives"

    e2e_cleanup
}

test_prune_refuses_destructive_modes_with_dangling_list_symlink() {
    setup_initialized_env

    # A list kept elsewhere (dotfiles repo, unmounted share) and symlinked into
    # repos.d: while the target is missing the link is not a regular file, so
    # the list was skipped silently and its clones looked like orphans.
    printf '%s\n' "owner/keep" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    ln -s "$E2E_TEMP_DIR/missing/work.txt" "$XDG_CONFIG_HOME/ru/repos.d/work.txt"
    create_orphan_repo "keep"
    create_orphan_repo "tool"

    local output exit_code
    output=$("$E2E_RU_SCRIPT" prune --delete --non-interactive 2>&1)
    exit_code=$?

    assert_equals "4" "$exit_code" "Exits with code 4"
    assert_contains "$output" "work.txt" "Names the missing list"
    assert_dir_exists "$RU_PROJECTS_DIR/tool/.git" "Clone named by the missing list survives"

    e2e_cleanup
}

test_prune_refuses_destructive_modes_without_configured_repos() {
    setup_initialized_env

    # Fresh 'ru init' (or another user's config dir, e.g. under sudo): no
    # repo is configured, so every clone would be deleted.
    create_orphan_repo "work"

    local output exit_code
    output=$("$E2E_RU_SCRIPT" prune --delete --non-interactive 2>&1)
    exit_code=$?

    assert_equals "4" "$exit_code" "Exits with code 4"
    assert_contains "$output" "no repos are configured" "Explains the refusal"
    assert_dir_exists "$RU_PROJECTS_DIR/work/.git" "Clone survives"

    # Listing still works
    output=$("$E2E_RU_SCRIPT" prune 2>&1)
    assert_contains "$output" "Found 1 orphan" "Dry run still lists"

    e2e_cleanup
}

#==============================================================================
# Tests: Unsaved work and clones of configured repos (A12)
#==============================================================================

prune_git() {
    git -c user.name=ru-test -c user.email=ru-test@example.invalid -c init.defaultBranch=main "$@"
}

# Create an orphan cloned from a local bare "remote" and fully pushed, so it
# holds no unsaved work: the baseline that --delete may remove.
create_pushed_orphan() {
    local name="$1"
    local bare="$E2E_TEMP_DIR/remotes/$name.git"
    local path="$RU_PROJECTS_DIR/$name"
    mkdir -p "$E2E_TEMP_DIR/remotes"
    prune_git init --quiet --bare "$bare"
    prune_git clone --quiet "$bare" "$path" 2>/dev/null
    printf 'hello\n' | tee "$path/README" >/dev/null
    prune_git -C "$path" add README
    prune_git -C "$path" commit --quiet -m init
    prune_git -C "$path" push --quiet origin HEAD 2>/dev/null
}

prune_delete() {
    "$E2E_RU_SCRIPT" --non-interactive prune --delete "$@" 2>&1
}

test_prune_delete_removes_clean_pushed_clone() {
    setup_initialized_env
    configure_placeholder_repo
    create_pushed_orphan "done-with-it"

    local output exit_code
    output=$(prune_delete)
    exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_dir_not_exists "$RU_PROJECTS_DIR/done-with-it" "Clean, pushed clone deleted"
    assert_not_contains "$output" "Skipping" "Nothing skipped"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_delete_keeps_orphans_with_unsaved_work() {
    setup_initialized_env
    configure_placeholder_repo

    # Uncommitted change to a tracked file
    create_pushed_orphan "edited"
    printf 'changed\n' | tee -a "$RU_PROJECTS_DIR/edited/README" >/dev/null
    # Untracked file that is not ignored
    create_pushed_orphan "untracked"
    printf 'x\n' | tee "$RU_PROJECTS_DIR/untracked/notes.txt" >/dev/null
    # Stash
    create_pushed_orphan "stashed"
    printf 'wip\n' | tee -a "$RU_PROJECTS_DIR/stashed/README" >/dev/null
    prune_git -C "$RU_PROJECTS_DIR/stashed" stash --quiet
    # Commit not on any remote branch
    create_pushed_orphan "ahead"
    prune_git -C "$RU_PROJECTS_DIR/ahead" commit --quiet --allow-empty -m local
    # Commit on a detached HEAD
    create_pushed_orphan "detached"
    prune_git -C "$RU_PROJECTS_DIR/detached" checkout --quiet --detach
    prune_git -C "$RU_PROJECTS_DIR/detached" commit --quiet --allow-empty -m detached
    # No remote at all, with commits
    create_orphan_repo "local-only"
    prune_git -C "$RU_PROJECTS_DIR/local-only" commit --quiet --allow-empty -m mine
    # Change hidden from git status
    create_pushed_orphan "hidden"
    prune_git -C "$RU_PROJECTS_DIR/hidden" update-index --assume-unchanged README
    printf 'secret\n' | tee -a "$RU_PROJECTS_DIR/hidden/README" >/dev/null
    # Clean itself, but a linked worktree elsewhere depends on it
    create_pushed_orphan "has-worktree"
    prune_git -C "$RU_PROJECTS_DIR/has-worktree" worktree add --quiet -b side "$E2E_TEMP_DIR/side-tree" 2>/dev/null

    local output exit_code
    output=$(prune_delete)
    exit_code=$?

    assert_equals "1" "$exit_code" "Exits with code 1 when orphans are kept"
    assert_contains "$output" "Nothing to prune" "Reports that nothing was pruned"
    local name
    for name in edited untracked stashed ahead detached local-only hidden has-worktree; do
        assert_dir_exists "$RU_PROJECTS_DIR/$name/.git" "$name kept"
    done
    assert_contains "$output" "1 uncommitted change(s)" "Names the uncommitted change"
    assert_contains "$output" "1 untracked path(s)" "Names the untracked path"
    assert_contains "$output" "1 stash(es)" "Names the stash"
    assert_contains "$output" "1 commit(s) not on any remote branch" "Names the unpushed commit"
    assert_contains "$output" "no remote, 1 local commit(s)" "Names the remote-less commits"
    assert_contains "$output" "assume-unchanged or skip-worktree" "Names the hidden change"
    assert_contains "$output" "1 linked worktree(s)" "Names the linked worktree"
    assert_contains "$output" "--force" "Points at --force"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_delete_mixed_keeps_dirty_removes_clean() {
    setup_initialized_env
    configure_placeholder_repo
    create_pushed_orphan "clean-one"
    create_pushed_orphan "dirty-one"
    printf 'x\n' | tee "$RU_PROJECTS_DIR/dirty-one/new.txt" >/dev/null
    # Ignored files are not unsaved work
    create_pushed_orphan "ignored-only"
    printf 'build/\n' | tee -a "$RU_PROJECTS_DIR/ignored-only/.git/info/exclude" >/dev/null
    mkdir -p "$RU_PROJECTS_DIR/ignored-only/build"
    printf 'x\n' | tee "$RU_PROJECTS_DIR/ignored-only/build/out.o" >/dev/null

    local output exit_code
    output=$(prune_delete)
    exit_code=$?

    assert_equals "1" "$exit_code" "Exits with code 1 when some orphans are kept"
    assert_contains "$output" "Deleted 2" "Deletes the two clean orphans"
    assert_dir_not_exists "$RU_PROJECTS_DIR/clean-one" "Clean orphan deleted"
    assert_dir_not_exists "$RU_PROJECTS_DIR/ignored-only" "Orphan with only ignored files deleted"
    assert_dir_exists "$RU_PROJECTS_DIR/dirty-one/.git" "Dirty orphan kept"
    assert_contains "$output" "Skipping $RU_PROJECTS_DIR/dirty-one" "Explains the skip"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_delete_force_overrides_unsaved_work() {
    setup_initialized_env
    configure_placeholder_repo
    create_pushed_orphan "dirty"
    printf 'x\n' | tee "$RU_PROJECTS_DIR/dirty/new.txt" >/dev/null

    local output exit_code
    output=$(prune_delete --force)
    exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_contains "$output" "--force: including" "Says what --force overrides"
    assert_dir_not_exists "$RU_PROJECTS_DIR/dirty" "Dirty orphan deleted with --force"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_delete_keeps_repos_git_cannot_inspect() {
    setup_initialized_env
    configure_placeholder_repo

    # Corrupted: HEAD names no ref or object
    create_pushed_orphan "corrupt"
    printf 'garbage\n' | tee "$RU_PROJECTS_DIR/corrupt/.git/HEAD" >/dev/null
    # Bare-ish: its .git says core.bare = true, so it has no work tree
    create_pushed_orphan "bareish"
    prune_git -C "$RU_PROJECTS_DIR/bareish" config core.bare true
    # Missing object behind a branch
    create_pushed_orphan "lost-objects"
    local obj_dir="$RU_PROJECTS_DIR/lost-objects/.git/objects"
    /usr/bin/find "$obj_dir" -type f -path '*/objects/??/*' -exec chmod 000 {} + 2>/dev/null

    local output exit_code
    output=$(prune_delete)
    exit_code=$?

    assert_equals "1" "$exit_code" "Exits with code 1"
    assert_dir_exists "$RU_PROJECTS_DIR/corrupt/.git" "Corrupted clone kept"
    assert_dir_exists "$RU_PROJECTS_DIR/bareish/.git" "Bare-ish clone kept"
    assert_dir_exists "$RU_PROJECTS_DIR/lost-objects/.git" "Clone with unreadable objects kept"
    assert_contains "$output" "cannot check it for unsaved work" "Explains the inspection failure"

    /usr/bin/find "$obj_dir" -type f -exec chmod 644 {} + 2>/dev/null
    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_inspection_ignores_callers_git_environment() {
    setup_initialized_env
    configure_placeholder_repo
    create_pushed_orphan "dirty"
    printf 'x\n' | tee "$RU_PROJECTS_DIR/dirty/new.txt" >/dev/null
    # A clean repo outside PROJECTS_DIR that GIT_DIR/GIT_WORK_TREE point at
    local elsewhere="$E2E_TEMP_DIR/elsewhere"
    mkdir -p "$elsewhere"
    prune_git init --quiet "$elsewhere"

    local output
    output=$(GIT_DIR="$elsewhere/.git" GIT_WORK_TREE="$elsewhere" prune_delete)

    assert_dir_exists "$RU_PROJECTS_DIR/dirty/.git" "Dirty orphan kept despite GIT_DIR pointing elsewhere"
    assert_contains "$output" "1 untracked path(s)" "Inspected the orphan itself"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_archive_moves_dirty_orphans() {
    setup_initialized_env
    configure_placeholder_repo
    create_pushed_orphan "dirty"
    printf 'x\n' | tee "$RU_PROJECTS_DIR/dirty/new.txt" >/dev/null

    local output exit_code
    output=$("$E2E_RU_SCRIPT" prune --archive 2>&1)
    exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_dir_not_exists "$RU_PROJECTS_DIR/dirty" "Dirty orphan moved (archiving loses nothing)"
    local archived
    archived=$(/usr/bin/find "$XDG_STATE_HOME/ru/archived" -mindepth 2 -maxdepth 2 -name new.txt | wc -l | tr -d ' ')
    assert_equals "1" "$archived" "Untracked file travels with the archive"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_keeps_clone_of_configured_repo_at_old_path() {
    setup_initialized_env
    configure_placeholder_repo
    # Configured as owner/tool (flat layout: $RU_PROJECTS_DIR/tool); an older
    # clone of the same repo sits at another path, remote spelled differently.
    printf '%s\n' "owner/tool" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    create_orphan_repo "tool-old-ssh"
    prune_git -C "$RU_PROJECTS_DIR/tool-old-ssh" remote add origin "git@github.com:Owner/Tool.git"
    create_orphan_repo "tool-old-https"
    prune_git -C "$RU_PROJECTS_DIR/tool-old-https" remote add origin "https://user@GitHub.com/owner/tool.git/"
    create_orphan_repo "tool-old-sshurl"
    prune_git -C "$RU_PROJECTS_DIR/tool-old-sshurl" remote add origin "ssh://git@github.com:22/owner/tool"
    # A different repo with a similar name is a plain orphan
    create_orphan_repo "toolkit"
    prune_git -C "$RU_PROJECTS_DIR/toolkit" remote add origin "git@github.com:owner/toolkit.git"

    local output exit_code
    output=$("$E2E_RU_SCRIPT" prune --archive 2>&1)
    exit_code=$?

    assert_equals "1" "$exit_code" "Exits with code 1 when orphans are kept"
    assert_contains "$output" "clone of configured repo owner/tool (configured at $RU_PROJECTS_DIR/tool) at an old path" "Names the configured repo"
    local name
    for name in tool-old-ssh tool-old-https tool-old-sshurl; do
        assert_dir_exists "$RU_PROJECTS_DIR/$name/.git" "$name kept by --archive"
    done
    assert_dir_not_exists "$RU_PROJECTS_DIR/toolkit" "Unrelated orphan archived"

    output=$(prune_delete)
    exit_code=$?
    assert_equals "1" "$exit_code" "--delete exits with code 1"
    for name in tool-old-ssh tool-old-https tool-old-sshurl; do
        assert_dir_exists "$RU_PROJECTS_DIR/$name/.git" "$name kept by --delete"
    done

    # Listing and JSON explain it too
    output=$("$E2E_RU_SCRIPT" prune 2>&1)
    assert_contains "$output" "clone of configured repo owner/tool" "Dry run notes the clone"
    output=$("$E2E_RU_SCRIPT" --json prune 2>/dev/null)
    assert_contains "$output" '"clone_of":"owner/tool' "JSON carries clone_of"

    output=$("$E2E_RU_SCRIPT" prune --archive --force 2>&1)
    exit_code=$?
    assert_equals "0" "$exit_code" "--force archive exits with code 0"
    for name in tool-old-ssh tool-old-https tool-old-sshurl; do
        assert_dir_not_exists "$RU_PROJECTS_DIR/$name" "$name archived with --force"
    done

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_keeps_clone_left_by_as_rename() {
    setup_initialized_env
    configure_placeholder_repo
    # Now configured under a custom name; the clone at the default name is
    # what an 'as' rename leaves behind.
    printf '%s\n' "https://gitlab.example.com/team/app.git as app-renamed" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    create_pushed_orphan "app"
    prune_git -C "$RU_PROJECTS_DIR/app" remote set-url origin "git@gitlab.example.com:team/app.git"

    local output exit_code
    output=$(prune_delete)
    exit_code=$?

    assert_equals "1" "$exit_code" "Exits with code 1"
    assert_dir_exists "$RU_PROJECTS_DIR/app/.git" "Clean clone at the old name kept"
    assert_contains "$output" "clone of configured repo gitlab.example.com/team/app" "Names the configured repo"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_delete_ignores_tags_on_commits_off_branches() {
    setup_initialized_env
    configure_placeholder_repo
    # The remote has a tag on a commit that no branch contains (a release
    # tagged on a branch that was later deleted); the clone fetched it.
    create_pushed_orphan "tagged"
    local path="$RU_PROJECTS_DIR/tagged"
    prune_git -C "$path" checkout --quiet --detach
    prune_git -C "$path" commit --quiet --allow-empty -m release
    prune_git -C "$path" tag v1
    prune_git -C "$path" push --quiet origin v1 2>/dev/null
    prune_git -C "$path" checkout --quiet main

    local output exit_code
    output=$(prune_delete)
    exit_code=$?

    assert_equals "0" "$exit_code" "Exits with code 0"
    assert_dir_not_exists "$path" "Clone with a fetched off-branch tag deleted"

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_archive_keeps_orphan_with_unreadable_config() {
    setup_initialized_env
    configure_placeholder_repo
    printf '%s\n' "owner/tool" >> "$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    create_orphan_repo "tool-old"
    prune_git -C "$RU_PROJECTS_DIR/tool-old" remote add origin "git@github.com:owner/tool.git"
    # Unreadable config: git would read it as empty, i.e. "no origin"
    chmod 000 "$RU_PROJECTS_DIR/tool-old/.git/config"

    local output exit_code
    output=$("$E2E_RU_SCRIPT" prune --archive 2>&1)
    exit_code=$?
    chmod 644 "$RU_PROJECTS_DIR/tool-old/.git/config"

    if [[ "$(id -u)" == "0" ]]; then
        skip_test "root can read the config anyway"
    else
        assert_equals "1" "$exit_code" "Exits with code 1"
        assert_dir_exists "$RU_PROJECTS_DIR/tool-old/.git" "Orphan with unreadable origin kept"
        assert_contains "$output" "cannot read its origin" "Explains why"
    fi

    e2e_cleanup
    unset RU_LAYOUT
}

test_prune_json_reports_unsaved_work() {
    setup_initialized_env
    configure_placeholder_repo
    create_pushed_orphan "dirty"
    printf 'x\n' | tee "$RU_PROJECTS_DIR/dirty/new.txt" >/dev/null

    local output
    output=$("$E2E_RU_SCRIPT" --json prune 2>/dev/null)
    assert_contains "$output" '"unsaved_work":["1 untracked path(s)"]' "JSON lists unsaved work"
    if command -v python3 >/dev/null 2>&1; then
        if printf '%s' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
            pass "JSON parses"
        else
            fail "JSON does not parse: $output"
        fi
    fi

    e2e_cleanup
    unset RU_LAYOUT
}

#==============================================================================
# Run Tests
#==============================================================================

log_suite_start "ru prune workflow"

# Basic detection
run_test test_prune_detects_orphans
run_test test_prune_no_orphans
run_test test_prune_empty_projects_dir
run_test test_prune_nonexistent_projects_dir

# Archive mode
run_test test_prune_archive_mode
run_test test_prune_archive_multiple
run_test test_prune_archive_same_named_orphans_stay_separate

# Delete mode
run_test test_prune_delete_noninteractive

# Error handling
run_test test_prune_conflicting_options
run_test test_prune_unknown_option

# Layout modes
run_test test_prune_owner_repo_layout
run_test test_prune_full_layout
run_test test_prune_grouped_repos
run_test test_prune_group_does_not_widen_scan
run_test test_prune_never_deletes_repo_containing_configured_repo
run_test test_prune_matches_configured_repo_by_physical_path
run_test test_prune_refuses_destructive_modes_with_unresolvable_specs
run_test test_prune_matches_configured_repo_across_unicode_normalization
run_test test_prune_refuses_destructive_modes_with_unreadable_list
run_test test_prune_refuses_destructive_modes_with_unlistable_list_dir
run_test test_prune_refuses_destructive_modes_with_dangling_list_symlink
run_test test_prune_refuses_destructive_modes_without_configured_repos
run_test test_prune_never_acts_on_newline_split_fragments
run_test test_prune_keeps_clone_of_deduped_repeat

# Custom names
run_test test_prune_respects_custom_names

# JSON output
run_test test_prune_json_output

# Unsaved work and clones of configured repos
run_test test_prune_delete_removes_clean_pushed_clone
run_test test_prune_delete_keeps_orphans_with_unsaved_work
run_test test_prune_delete_mixed_keeps_dirty_removes_clean
run_test test_prune_delete_force_overrides_unsaved_work
run_test test_prune_delete_keeps_repos_git_cannot_inspect
run_test test_prune_inspection_ignores_callers_git_environment
run_test test_prune_archive_moves_dirty_orphans
run_test test_prune_keeps_clone_of_configured_repo_at_old_path
run_test test_prune_keeps_clone_left_by_as_rename
run_test test_prune_json_reports_unsaved_work
run_test test_prune_delete_ignores_tags_on_commits_off_branches
run_test test_prune_archive_keeps_orphan_with_unreadable_config

print_results
