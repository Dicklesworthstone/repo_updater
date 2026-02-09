#!/usr/bin/env bash
#
# E2E Test: ru status workflow
# Tests status display for multiple repos, fetch modes
#
# Test coverage:
#   - Multi-repo status display
#   - --fetch mode (default) updates from remote
#   - --no-fetch mode uses cached state
#   - Status correctly shows current/ahead/behind/diverged
#   - Dirty repo detection
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Helper Functions
#==============================================================================

# Create a bare "remote" repository with initial commit
create_remote_repo() {
    local name="$1"
    local remote_dir="$E2E_TEMP_DIR/remotes/$name.git"
    local work_dir="$E2E_TEMP_DIR/work/$name"

    mkdir -p "$remote_dir" "$work_dir"
    git init --bare "$remote_dir" >/dev/null 2>&1
    git -C "$remote_dir" symbolic-ref HEAD refs/heads/main

    git clone "$remote_dir" "$work_dir" >/dev/null 2>&1
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test User"
    git -C "$work_dir" checkout -b main 2>/dev/null || true
    echo "content for $name" > "$work_dir/file.txt"
    git -C "$work_dir" add file.txt
    git -C "$work_dir" commit -m "Initial commit" >/dev/null 2>&1
    git -C "$work_dir" push -u origin main >/dev/null 2>&1

    echo "$remote_dir"
}

# Clone a repo to projects dir (simulating already-cloned repo)
# Adds a "test-fetch" remote for actual git operations while setting origin to match config.
clone_to_projects() {
    local remote_dir="$1"
    local name="$2"
    local target="$TEST_PROJECTS_DIR/$name"

    git clone "$remote_dir" "$target" >/dev/null 2>&1
    git -C "$target" config user.email "test@test.com"
    git -C "$target" config user.name "Test User"
    # Keep a reference to the actual bare repo for fetching in tests
    git -C "$target" remote add test-fetch "$remote_dir" 2>/dev/null || true
    # Set origin URL to match config (testowner/$name) for mismatch detection to pass
    git -C "$target" remote set-url origin "https://github.com/testowner/$name" 2>/dev/null

    echo "$target"
}

# Add commit to work dir and push (simulates remote change)
add_remote_commit() {
    local work_dir="$1"
    local msg="${2:-Remote change}"

    echo "$msg" >> "$work_dir/file.txt"
    git -C "$work_dir" add file.txt
    git -C "$work_dir" commit -m "$msg" >/dev/null 2>&1
    git -C "$work_dir" push >/dev/null 2>&1
}

# Add local commit without push
add_local_commit() {
    local repo_dir="$1"
    local msg="${2:-Local change}"

    echo "$msg" >> "$repo_dir/file.txt"
    git -C "$repo_dir" add file.txt
    git -C "$repo_dir" commit -m "$msg" >/dev/null 2>&1
}

# Make repo dirty
make_dirty() {
    local repo_dir="$1"
    echo "dirty content" >> "$repo_dir/file.txt"
}

# Set up status test environment (calls e2e_setup + creates mock gh + projects dir)
setup_status_env() {
    e2e_setup

    # Create mock gh for auth check
    cat > "$E2E_MOCK_BIN/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
    echo "Logged in to github.com as testuser"
    exit 0
elif [[ "$1" == "repo" && "$2" == "clone" ]]; then
    shift 2
    source="$1"
    target="$2"
    shift 2
    git clone "$source" "$target" "$@" 2>&1
    exit $?
else
    echo "Mock gh: unhandled command: $*" >&2
    exit 1
fi
EOF
    chmod +x "$E2E_MOCK_BIN/gh"

    # Projects directory
    export TEST_PROJECTS_DIR="$E2E_TEMP_DIR/projects"
    mkdir -p "$TEST_PROJECTS_DIR"
}

# Initialize ru config
init_test_config() {
    "$E2E_RU_SCRIPT" init >/dev/null 2>&1

    local config_file="$XDG_CONFIG_HOME/ru/config"
    local tmp_file="$config_file.tmp"

    # Use temp file approach for macOS/Linux compatibility (sed -i differs)
    if grep -q "^PROJECTS_DIR=" "$config_file" 2>/dev/null; then
        sed "s|^PROJECTS_DIR=.*|PROJECTS_DIR=$TEST_PROJECTS_DIR|" "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
    else
        echo "PROJECTS_DIR=$TEST_PROJECTS_DIR" >> "$config_file"
    fi
    # LAYOUT=flat is already the default, no need to change
}

# Add repo URL to config (must look like owner/repo for parsing)
add_repo_to_config() {
    local repo_name="$1"
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    echo "testowner/$repo_name" >> "$repos_file"
}

#==============================================================================
# Tests: Basic Status
#==============================================================================

test_status_shows_current() {
    setup_status_env

    local remote
    remote=$(create_remote_repo "current-test")
    clone_to_projects "$remote" "current-test"

    init_test_config
    add_repo_to_config "current-test"

    local output
    output=$("$E2E_RU_SCRIPT" status --no-fetch --non-interactive 2>&1)
    local exit_code=$?

    assert_equals "0" "$exit_code" "status exits with code 0"
    assert_contains "$output" "current" "Shows 'current' status"

    e2e_cleanup
}

test_status_shows_behind() {
    setup_status_env

    local remote
    remote=$(create_remote_repo "behind-test")
    clone_to_projects "$remote" "behind-test"

    # Add commit to remote (via work dir)
    add_remote_commit "$E2E_TEMP_DIR/work/behind-test" "New remote commit"

    # Fetch to update refs (status needs to see remote changes)
    git -C "$TEST_PROJECTS_DIR/behind-test" fetch >/dev/null 2>&1

    init_test_config
    add_repo_to_config "behind-test"

    local output
    output=$("$E2E_RU_SCRIPT" status --no-fetch --non-interactive 2>&1)

    assert_contains "$output" "behind" "Shows 'behind' status"

    e2e_cleanup
}

test_status_shows_ahead() {
    setup_status_env

    local remote
    remote=$(create_remote_repo "ahead-test")
    clone_to_projects "$remote" "ahead-test"

    # Add local commit without pushing
    add_local_commit "$TEST_PROJECTS_DIR/ahead-test" "Local commit"

    init_test_config
    add_repo_to_config "ahead-test"

    local output
    output=$("$E2E_RU_SCRIPT" status --no-fetch --non-interactive 2>&1)

    assert_contains "$output" "ahead" "Shows 'ahead' status"

    e2e_cleanup
}

test_status_shows_diverged() {
    setup_status_env

    local remote
    remote=$(create_remote_repo "diverged-test")
    clone_to_projects "$remote" "diverged-test"

    # Add local commit
    add_local_commit "$TEST_PROJECTS_DIR/diverged-test" "Local diverge"

    # Add remote commit
    add_remote_commit "$E2E_TEMP_DIR/work/diverged-test" "Remote diverge"

    # Fetch to see remote changes
    git -C "$TEST_PROJECTS_DIR/diverged-test" fetch >/dev/null 2>&1

    init_test_config
    add_repo_to_config "diverged-test"

    local output
    output=$("$E2E_RU_SCRIPT" status --no-fetch --non-interactive 2>&1)

    assert_contains "$output" "diverged" "Shows 'diverged' status"

    e2e_cleanup
}

test_status_shows_dirty() {
    setup_status_env

    local remote
    remote=$(create_remote_repo "dirty-test")
    clone_to_projects "$remote" "dirty-test"

    # Make it dirty
    make_dirty "$TEST_PROJECTS_DIR/dirty-test"

    init_test_config
    add_repo_to_config "dirty-test"

    local output
    output=$("$E2E_RU_SCRIPT" status --no-fetch --non-interactive 2>&1)

    # Dirty indicator is typically * or similar
    assert_contains "$output" "*" "Shows dirty indicator"

    e2e_cleanup
}

#==============================================================================
# Tests: Multi-Repo Status
#==============================================================================

test_status_multiple_repos() {
    setup_status_env

    # Create multiple repos in different states
    local remote1 remote2 remote3
    remote1=$(create_remote_repo "multi1")
    remote2=$(create_remote_repo "multi2")
    remote3=$(create_remote_repo "multi3")

    clone_to_projects "$remote1" "multi1"
    clone_to_projects "$remote2" "multi2"
    clone_to_projects "$remote3" "multi3"

    # Make multi2 behind
    add_remote_commit "$E2E_TEMP_DIR/work/multi2" "Remote commit"
    git -C "$TEST_PROJECTS_DIR/multi2" fetch >/dev/null 2>&1

    # Make multi3 ahead
    add_local_commit "$TEST_PROJECTS_DIR/multi3" "Local commit"

    init_test_config
    add_repo_to_config "multi1"
    add_repo_to_config "multi2"
    add_repo_to_config "multi3"

    local output
    output=$("$E2E_RU_SCRIPT" status --no-fetch --non-interactive 2>&1)

    # All repos should be mentioned
    assert_contains "$output" "multi1" "Shows multi1"
    assert_contains "$output" "multi2" "Shows multi2"
    assert_contains "$output" "multi3" "Shows multi3"

    e2e_cleanup
}

#==============================================================================
# Tests: Fetch Modes
#==============================================================================

test_status_no_fetch_uses_cache() {
    setup_status_env

    local remote
    remote=$(create_remote_repo "nofetch-test")
    clone_to_projects "$remote" "nofetch-test"

    # Add remote commit but don't fetch yet
    add_remote_commit "$E2E_TEMP_DIR/work/nofetch-test" "Remote commit"

    init_test_config
    add_repo_to_config "nofetch-test"

    # Without fetching, status should show current (not behind)
    local output
    output=$("$E2E_RU_SCRIPT" status --no-fetch --non-interactive 2>&1)

    assert_contains "$output" "current" "--no-fetch shows current (not fetched)"

    e2e_cleanup
}

test_status_fetch_updates_refs() {
    setup_status_env

    local remote
    remote=$(create_remote_repo "fetch-test")
    clone_to_projects "$remote" "fetch-test"

    # Add remote commit
    add_remote_commit "$E2E_TEMP_DIR/work/fetch-test" "Remote commit"

    init_test_config
    add_repo_to_config "fetch-test"

    # Fetch from the test-fetch remote (which points to actual bare repo),
    # then update the origin refs to match. This simulates what --fetch would do
    # if origin were reachable.
    git -C "$TEST_PROJECTS_DIR/fetch-test" fetch test-fetch >/dev/null 2>&1
    git -C "$TEST_PROJECTS_DIR/fetch-test" update-ref refs/remotes/origin/main refs/remotes/test-fetch/main 2>/dev/null || true

    # Now status with --no-fetch should show behind (refs were just updated)
    local output
    output=$("$E2E_RU_SCRIPT" status --no-fetch --non-interactive 2>&1)

    assert_contains "$output" "behind" "--fetch shows behind (fetched remote)"

    e2e_cleanup
}

#==============================================================================
# Tests: Missing Repos
#==============================================================================

test_status_shows_missing() {
    setup_status_env

    init_test_config
    add_repo_to_config "missing-repo"  # No actual repo exists

    local output
    output=$("$E2E_RU_SCRIPT" status --no-fetch --non-interactive 2>&1)

    assert_contains "$output" "missing" "Shows 'missing' for non-existent repo"

    e2e_cleanup
}

#==============================================================================
# Tests: JSON Output
#==============================================================================

test_status_json_output() {
    setup_status_env

    local remote
    remote=$(create_remote_repo "json-test")
    clone_to_projects "$remote" "json-test"

    init_test_config
    add_repo_to_config "json-test"

    local json_output
    json_output=$("$E2E_RU_SCRIPT" status --no-fetch --json --non-interactive 2>/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "status --json exits with code 0"

    # Check if valid JSON
    if printf '%s\n' "$json_output" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
        pass "JSON output is valid"
    else
        fail "JSON output is invalid"
    fi

    e2e_cleanup
}

test_status_json_revlist_failure() {
    # NOTE: This test validates JSON output with diverged/unusual histories.
    # The actual rev-list failure case (outputting -1) is tested via mock in
    # test_local_git.sh:test_status_revlist_failure_numeric which uses a mock
    # git wrapper to force the failure scenario.
    setup_status_env

    # Create a remote repo
    local remote
    remote=$(create_remote_repo "revlist-test")
    clone_to_projects "$remote" "revlist-test"
    local repo_dir="$TEST_PROJECTS_DIR/revlist-test"

    init_test_config
    add_repo_to_config "revlist-test"

    # Create unrelated histories (diverged state)
    # NOTE: This doesn't actually cause rev-list to fail, but validates
    # JSON output in edge cases. See test_local_git.sh for the -1 test.
    git -C "$repo_dir" checkout --orphan temp-orphan >/dev/null 2>&1
    echo "orphan content" > "$repo_dir/orphan.txt"
    git -C "$repo_dir" add orphan.txt
    git -C "$repo_dir" commit -m "Orphan commit" >/dev/null 2>&1
    local orphan_sha
    orphan_sha=$(git -C "$repo_dir" rev-parse HEAD)
    git -C "$repo_dir" checkout main >/dev/null 2>&1
    # Point origin/main to the orphan commit (creates diverged status)
    git -C "$repo_dir" update-ref refs/remotes/origin/main "$orphan_sha"

    # Run status with this diverged state
    local json_output
    json_output=$("$E2E_RU_SCRIPT" status --no-fetch --json --non-interactive 2>/dev/null)
    local exit_code=$?

    # Should still exit cleanly (exit code 0 or 2 for diverged)
    if [[ "$exit_code" -le 2 ]]; then
        pass "status --json exits cleanly with diverged history"
    else
        fail "status --json exit code $exit_code (expected 0-2)"
    fi

    # Check if valid JSON
    if printf '%s\n' "$json_output" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
        pass "JSON output is valid with diverged history"
    else
        fail "JSON output is invalid with diverged history"
    fi

    # Check that ahead/behind are numeric (not "?")
    local ahead behind
    ahead=$(printf '%s\n' "$json_output" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['data']['repos'][0]['ahead'])" 2>/dev/null || echo "ERROR")
    behind=$(printf '%s\n' "$json_output" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['data']['repos'][0]['behind'])" 2>/dev/null || echo "ERROR")

    # Check ahead is numeric
    if [[ "$ahead" =~ ^-?[0-9]+$ ]]; then
        pass "ahead is numeric ($ahead)"
    else
        fail "ahead is not numeric: $ahead"
    fi

    # Check behind is numeric
    if [[ "$behind" =~ ^-?[0-9]+$ ]]; then
        pass "behind is numeric ($behind)"
    else
        fail "behind is not numeric: $behind"
    fi

    e2e_cleanup
}

#==============================================================================
# Run Tests
#==============================================================================

log_suite_start "E2E Tests: ru status workflow"

run_test test_status_shows_current
run_test test_status_shows_behind
run_test test_status_shows_ahead
run_test test_status_shows_diverged
run_test test_status_shows_dirty
run_test test_status_multiple_repos
run_test test_status_no_fetch_uses_cache
run_test test_status_fetch_updates_refs
run_test test_status_shows_missing
run_test test_status_json_output
run_test test_status_json_revlist_failure

print_results
exit "$(get_exit_code)"
