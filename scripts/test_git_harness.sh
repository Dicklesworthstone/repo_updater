#!/usr/bin/env bash
#
# test_git_harness.sh - Local git repository harness for offline integration tests
#
# Provides helpers to create temporary git repositories with various states for testing
# WITHOUT network access. Uses bare repos as "remotes" in /tmp.
#
# Features:
#   - Creates bare "remote" repositories
#   - Creates working repos with tracking branches
#   - Supports various scenarios: ahead, behind, diverged, dirty, shallow, detached HEAD
#   - Auto-cleanup via trap
#   - Simple, composable API
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/test_git_harness.sh"
#
#   git_harness_setup
#   local repo=$(git_harness_create_repo "myrepo" --ahead=1 --behind=2)
#   # ... run tests using $repo ...
#   git_harness_cleanup
#
# API:
#   git_harness_setup                          - Initialize harness temp directory
#   git_harness_cleanup                        - Clean up all temp resources
#   git_harness_create_repo NAME [options]     - Create repo with specified state
#   git_harness_get_remote NAME                - Get path to bare remote for repo
#   git_harness_add_commit PATH [msg]          - Add commit to repo (local only)
#   git_harness_add_commit_and_push PATH [msg] - Add commit and push to remote
#   git_harness_make_dirty PATH                - Add uncommitted changes
#
# Options for git_harness_create_repo:
#   --ahead=N      Create N unpushed local commits
#   --behind=N     Create N commits on remote not in local
#   --diverged     Alias for --ahead=1 --behind=1
#   --dirty        Add uncommitted changes to working tree
#   --shallow=N    Create shallow clone with depth N
#   --detached     Checkout detached HEAD
#   --no-remote    Create repo without remote (local-only)
#   --branch=NAME  Use NAME instead of 'main' as default branch
#
# shellcheck disable=SC2034  # Variables used by sourcing scripts
set -uo pipefail

#==============================================================================
# Configuration
#==============================================================================

# Harness temp directory (created by git_harness_setup)
GIT_HARNESS_TEMP_DIR=""

# Array of temp directories for cleanup
declare -a GIT_HARNESS_TEMP_DIRS=()

# Git author/committer config for tests
GIT_HARNESS_AUTHOR_NAME="${GIT_HARNESS_AUTHOR_NAME:-Test User}"
GIT_HARNESS_AUTHOR_EMAIL="${GIT_HARNESS_AUTHOR_EMAIL:-test@test.local}"

#==============================================================================
# Internal Helpers
#==============================================================================

_git_harness_log() {
    if [[ "${GIT_HARNESS_VERBOSE:-}" == "true" ]]; then
        echo "[git-harness] $*" >&2
    fi
}

_git_harness_error() {
    echo "[git-harness] ERROR: $*" >&2
    return 1
}

# Configure git user for a repo
_git_harness_configure_repo() {
    local repo_dir="$1"
    git -C "$repo_dir" config user.name "$GIT_HARNESS_AUTHOR_NAME"
    git -C "$repo_dir" config user.email "$GIT_HARNESS_AUTHOR_EMAIL"
}

#==============================================================================
# Core API
#==============================================================================

# Initialize the harness - creates temp directory structure
# Usage: git_harness_setup
git_harness_setup() {
    if [[ -n "$GIT_HARNESS_TEMP_DIR" && -d "$GIT_HARNESS_TEMP_DIR" ]]; then
        _git_harness_log "Harness already initialized at $GIT_HARNESS_TEMP_DIR"
        return 0
    fi

    GIT_HARNESS_TEMP_DIR=$(mktemp -d)
    GIT_HARNESS_TEMP_DIRS+=("$GIT_HARNESS_TEMP_DIR")

    mkdir -p "$GIT_HARNESS_TEMP_DIR/remotes"
    mkdir -p "$GIT_HARNESS_TEMP_DIR/repos"
    mkdir -p "$GIT_HARNESS_TEMP_DIR/dev"  # For simulating "other developer" repos

    _git_harness_log "Initialized harness at $GIT_HARNESS_TEMP_DIR"
}

# Clean up all harness resources
# Usage: git_harness_cleanup
git_harness_cleanup() {
    local dir
    # Use ${array[@]+"${array[@]}"} pattern to safely handle empty arrays with set -u
    for dir in ${GIT_HARNESS_TEMP_DIRS[@]+"${GIT_HARNESS_TEMP_DIRS[@]}"}; do
        if [[ -n "$dir" && -d "$dir" ]]; then
            rm -rf "$dir"
            _git_harness_log "Cleaned up $dir"
        fi
    done
    GIT_HARNESS_TEMP_DIRS=()
    GIT_HARNESS_TEMP_DIR=""
}

# Get the harness temp directory
# Usage: local temp=$(git_harness_get_temp_dir)
git_harness_get_temp_dir() {
    echo "$GIT_HARNESS_TEMP_DIR"
}

#==============================================================================
# Repository Creation
#==============================================================================

# Create a bare "remote" repository
# Usage: local remote=$(git_harness_create_remote "name" [branch])
# Returns: Path to bare remote repository
git_harness_create_remote() {
    local name="$1"
    local branch="${2:-main}"
    local remote_dir="$GIT_HARNESS_TEMP_DIR/remotes/${name}.git"

    if [[ -z "$GIT_HARNESS_TEMP_DIR" ]]; then
        _git_harness_error "Harness not initialized. Call git_harness_setup first."
        return 1
    fi

    mkdir -p "$remote_dir"
    git init --bare "$remote_dir" >/dev/null 2>&1
    git -C "$remote_dir" symbolic-ref HEAD "refs/heads/$branch"

    _git_harness_log "Created bare remote: $remote_dir"
    echo "$remote_dir"
}

# Get path to remote for a repo name
# Usage: local remote=$(git_harness_get_remote "name")
git_harness_get_remote() {
    local name="$1"
    echo "$GIT_HARNESS_TEMP_DIR/remotes/${name}.git"
}

# Create a working repository with various states
# Usage: local repo=$(git_harness_create_repo "name" [options])
# Options: --ahead=N, --behind=N, --diverged, --dirty, --shallow=N, --detached, --no-remote, --branch=NAME
# Returns: Path to working repository
git_harness_create_repo() {
    local name="$1"
    shift

    if [[ -z "$GIT_HARNESS_TEMP_DIR" ]]; then
        _git_harness_error "Harness not initialized. Call git_harness_setup first."
        return 1
    fi

    # Parse options
    local ahead=0
    local behind=0
    local dirty="false"
    local shallow=0
    local detached="false"
    local no_remote="false"
    local branch="main"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ahead=*)
                ahead="${1#*=}"
                ;;
            --behind=*)
                behind="${1#*=}"
                ;;
            --diverged)
                ahead=1
                behind=1
                ;;
            --dirty)
                dirty="true"
                ;;
            --shallow=*)
                shallow="${1#*=}"
                ;;
            --detached)
                detached="true"
                ;;
            --no-remote)
                no_remote="true"
                ;;
            --branch=*)
                branch="${1#*=}"
                ;;
            *)
                _git_harness_error "Unknown option: $1"
                return 1
                ;;
        esac
        shift
    done

    local repo_dir="$GIT_HARNESS_TEMP_DIR/repos/$name"
    local remote_dir="$GIT_HARNESS_TEMP_DIR/remotes/${name}.git"
    local dev_dir="$GIT_HARNESS_TEMP_DIR/dev/$name"

    # Create remote (unless --no-remote)
    if [[ "$no_remote" != "true" ]]; then
        git_harness_create_remote "$name" "$branch" >/dev/null
    fi

    # Create working repo
    if [[ "$no_remote" == "true" ]]; then
        # Initialize without remote
        mkdir -p "$repo_dir"
        git init "$repo_dir" >/dev/null 2>&1
        git -C "$repo_dir" checkout -b "$branch" 2>/dev/null || true
        _git_harness_configure_repo "$repo_dir"

        # Initial commit
        echo "initial content" > "$repo_dir/README.md"
        git -C "$repo_dir" add README.md
        git -C "$repo_dir" commit -m "Initial commit" >/dev/null 2>&1
    elif [[ "$shallow" -gt 0 ]]; then
        # For shallow clone, need content in remote first
        # Create a dev clone, add commits, push, then shallow clone
        mkdir -p "$dev_dir"
        git clone "$remote_dir" "$dev_dir" >/dev/null 2>&1
        _git_harness_configure_repo "$dev_dir"
        git -C "$dev_dir" checkout -b "$branch" 2>/dev/null || true

        # Add enough commits for shallow to matter
        local i
        for ((i=1; i<=shallow+2; i++)); do
            echo "commit $i" >> "$dev_dir/history.txt"
            git -C "$dev_dir" add history.txt
            git -C "$dev_dir" commit -m "History commit $i" >/dev/null 2>&1
        done
        git -C "$dev_dir" push -u origin "$branch" >/dev/null 2>&1

        # Now do shallow clone (use file:// URL to force network-style clone, not local hardlinks)
        git clone --depth="$shallow" "file://$remote_dir" "$repo_dir" >/dev/null 2>&1
        _git_harness_configure_repo "$repo_dir"
    else
        # Normal clone, but remote is empty so we need to bootstrap
        mkdir -p "$dev_dir"
        git clone "$remote_dir" "$dev_dir" >/dev/null 2>&1
        _git_harness_configure_repo "$dev_dir"
        git -C "$dev_dir" checkout -b "$branch" 2>/dev/null || true
        echo "initial content" > "$dev_dir/README.md"
        git -C "$dev_dir" add README.md
        git -C "$dev_dir" commit -m "Initial commit" >/dev/null 2>&1
        git -C "$dev_dir" push -u origin "$branch" >/dev/null 2>&1

        # Clone to actual repo location
        git clone "$remote_dir" "$repo_dir" >/dev/null 2>&1
        _git_harness_configure_repo "$repo_dir"
    fi

    # Handle --behind: add commits to remote that aren't in local
    if [[ "$behind" -gt 0 && "$no_remote" != "true" ]]; then
        # Make sure dev_dir exists and is configured
        if [[ ! -d "$dev_dir/.git" ]]; then
            git clone "$remote_dir" "$dev_dir" >/dev/null 2>&1
            _git_harness_configure_repo "$dev_dir"
        else
            git -C "$dev_dir" pull >/dev/null 2>&1 || true
        fi

        local i
        for ((i=1; i<=behind; i++)); do
            echo "remote commit $i" >> "$dev_dir/remote_changes.txt"
            git -C "$dev_dir" add remote_changes.txt
            git -C "$dev_dir" commit -m "Remote commit $i" >/dev/null 2>&1
        done
        git -C "$dev_dir" push >/dev/null 2>&1

        # Fetch so local knows about remote commits
        git -C "$repo_dir" fetch >/dev/null 2>&1
    fi

    # Handle --ahead: add local commits that aren't pushed
    if [[ "$ahead" -gt 0 ]]; then
        local i
        for ((i=1; i<=ahead; i++)); do
            echo "local commit $i" >> "$repo_dir/local_changes.txt"
            git -C "$repo_dir" add local_changes.txt
            git -C "$repo_dir" commit -m "Local commit $i" >/dev/null 2>&1
        done
    fi

    # Handle --dirty: add uncommitted changes
    if [[ "$dirty" == "true" ]]; then
        echo "dirty changes" >> "$repo_dir/dirty.txt"
    fi

    # Handle --detached: checkout specific commit
    if [[ "$detached" == "true" ]]; then
        local head_sha
        head_sha=$(git -C "$repo_dir" rev-parse HEAD)
        git -C "$repo_dir" checkout "$head_sha" >/dev/null 2>&1
    fi

    _git_harness_log "Created repo: $repo_dir (ahead=$ahead, behind=$behind, dirty=$dirty, shallow=$shallow, detached=$detached)"
    echo "$repo_dir"
}

#==============================================================================
# Repository Manipulation
#==============================================================================

# Add a commit to a repo (local only, not pushed)
# Usage: git_harness_add_commit PATH [message]
git_harness_add_commit() {
    local repo_dir="$1"
    local msg="${2:-Test commit}"

    echo "$msg - $(date +%s)" >> "$repo_dir/commits.txt"
    git -C "$repo_dir" add commits.txt
    git -C "$repo_dir" commit -m "$msg" >/dev/null 2>&1

    _git_harness_log "Added local commit to $repo_dir: $msg"
}

# Add a commit and push to remote
# Usage: git_harness_add_commit_and_push PATH [message]
git_harness_add_commit_and_push() {
    local repo_dir="$1"
    local msg="${2:-Test commit}"

    git_harness_add_commit "$repo_dir" "$msg"
    git -C "$repo_dir" push >/dev/null 2>&1

    _git_harness_log "Pushed commit to remote: $msg"
}

# Add uncommitted changes (make dirty)
# Usage: git_harness_make_dirty PATH [file]
git_harness_make_dirty() {
    local repo_dir="$1"
    local file="${2:-dirty.txt}"

    echo "dirty - $(date +%s)" >> "$repo_dir/$file"

    _git_harness_log "Made $repo_dir dirty"
}

# Add staged but uncommitted changes
# Usage: git_harness_make_staged PATH [file]
git_harness_make_staged() {
    local repo_dir="$1"
    local file="${2:-staged.txt}"

    echo "staged - $(date +%s)" >> "$repo_dir/$file"
    git -C "$repo_dir" add "$file"

    _git_harness_log "Made $repo_dir staged"
}

# Add untracked file
# Usage: git_harness_add_untracked PATH [file]
git_harness_add_untracked() {
    local repo_dir="$1"
    local file="${2:-untracked.txt}"

    echo "untracked - $(date +%s)" > "$repo_dir/$file"

    _git_harness_log "Added untracked file to $repo_dir"
}

# Simulate rebase in progress
# Usage: git_harness_simulate_rebase PATH
git_harness_simulate_rebase() {
    local repo_dir="$1"

    mkdir -p "$repo_dir/.git/rebase-apply"
    echo "1" > "$repo_dir/.git/rebase-apply/next"

    _git_harness_log "Simulated rebase in progress at $repo_dir"
}

# Simulate merge in progress
# Usage: git_harness_simulate_merge PATH
git_harness_simulate_merge() {
    local repo_dir="$1"

    # Create MERGE_HEAD to simulate merge in progress
    local head_sha
    head_sha=$(git -C "$repo_dir" rev-parse HEAD)
    echo "$head_sha" > "$repo_dir/.git/MERGE_HEAD"

    _git_harness_log "Simulated merge in progress at $repo_dir"
}

#==============================================================================
# Query Helpers
#==============================================================================

# Get repo status (current, ahead, behind, diverged)
# Usage: local status=$(git_harness_get_status PATH)
git_harness_get_status() {
    local repo_dir="$1"

    local ahead behind
    ahead=$(git -C "$repo_dir" rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo "0")
    behind=$(git -C "$repo_dir" rev-list --count "HEAD..@{upstream}" 2>/dev/null || echo "0")

    if [[ "$ahead" -gt 0 && "$behind" -gt 0 ]]; then
        echo "diverged"
    elif [[ "$ahead" -gt 0 ]]; then
        echo "ahead"
    elif [[ "$behind" -gt 0 ]]; then
        echo "behind"
    else
        echo "current"
    fi
}

# Check if repo is dirty
# Usage: if git_harness_is_dirty PATH; then ...
git_harness_is_dirty() {
    local repo_dir="$1"
    ! git -C "$repo_dir" diff --quiet 2>/dev/null || \
    ! git -C "$repo_dir" diff --cached --quiet 2>/dev/null || \
    [[ -n "$(git -C "$repo_dir" ls-files --others --exclude-standard 2>/dev/null)" ]]
}

# Check if repo is shallow
# Usage: if git_harness_is_shallow PATH; then ...
# Note: Uses git plumbing (rev-parse --is-shallow-repository) per AGENTS.md
git_harness_is_shallow() {
    local repo_dir="$1"
    [[ "$(git -C "$repo_dir" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]
}

# Check if HEAD is detached
# Usage: if git_harness_is_detached PATH; then ...
git_harness_is_detached() {
    local repo_dir="$1"
    ! git -C "$repo_dir" symbolic-ref -q HEAD >/dev/null 2>&1
}

#==============================================================================
# Cleanup Trap (optional - use if framework doesn't provide one)
#==============================================================================

# Set up cleanup trap
# Usage: git_harness_set_cleanup_trap
git_harness_set_cleanup_trap() {
    trap 'git_harness_cleanup' EXIT
}

#==============================================================================
# Exports
#==============================================================================

export GIT_HARNESS_TEMP_DIR
export GIT_HARNESS_AUTHOR_NAME GIT_HARNESS_AUTHOR_EMAIL

export -f git_harness_setup git_harness_cleanup git_harness_get_temp_dir
export -f git_harness_create_remote git_harness_get_remote git_harness_create_repo
export -f git_harness_add_commit git_harness_add_commit_and_push
export -f git_harness_make_dirty git_harness_make_staged git_harness_add_untracked
export -f git_harness_simulate_rebase git_harness_simulate_merge
export -f git_harness_get_status git_harness_is_dirty git_harness_is_shallow git_harness_is_detached
export -f git_harness_set_cleanup_trap
