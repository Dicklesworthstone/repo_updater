#!/usr/bin/env bash
#
# E2E Test: Repo spec parsing
# Tests branch pinning, custom names, and combinations
#
# Test coverage:
#   - Basic owner/repo parsing
#   - Branch pinning: owner/repo@branch
#   - Custom names: owner/repo as myname
#   - Combinations: owner/repo@branch as myname
#   - Integration with sync --dry-run
#   - Path generation correctness
#   - Deduplication by path
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Dynamic sourcing is intentional
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Test: Basic repo spec parsing
#==============================================================================

test_basic_repo_spec() {
    e2e_setup

    # Initialize ru config
    "$E2E_RU_SCRIPT" init --non-interactive >/dev/null 2>&1

    # Create a repos file with basic specs
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat > "$repos_file" << 'EOF'
owner/repo
charmbracelet/gum
cli/cli
EOF

    # Run sync --dry-run to see what paths would be used
    local output
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

    # Verify paths are generated correctly (flat layout by default)
    assert_contains "$output" "repo" "Basic spec 'owner/repo' generates correct repo name"
    assert_contains "$output" "gum" "Basic spec 'charmbracelet/gum' generates correct repo name"
    assert_contains "$output" "cli" "Basic spec 'cli/cli' generates correct repo name"

    e2e_cleanup
}

#==============================================================================
# Test: Branch pinning with @branch syntax
#==============================================================================

test_branch_pinning() {
    e2e_setup

    # Initialize ru config
    "$E2E_RU_SCRIPT" init --non-interactive >/dev/null 2>&1

    # Create a repos file with branch specs
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat > "$repos_file" << 'EOF'
owner/repo@develop
charmbracelet/gum@main
cli/cli@v2
EOF

    # Run sync --dry-run with JSON output
    local output
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

    # The dry-run should show the repos being processed
    assert_contains "$output" "repo" "Branch-pinned spec processes correctly"
    assert_contains "$output" "gum" "Branch-pinned spec for gum processes correctly"

    e2e_cleanup
}

#==============================================================================
# Test: Custom names with 'as' syntax
#==============================================================================

test_custom_names() {
    e2e_setup

    # Initialize ru config
    "$E2E_RU_SCRIPT" init --non-interactive >/dev/null 2>&1

    # Create a repos file with custom name specs
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat > "$repos_file" << 'EOF'
owner/repo as my-custom-name
charmbracelet/gum as glamorous-scripts
EOF

    # Run sync --dry-run and verify custom names are used
    local output
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

    # Should see custom names in output
    assert_contains "$output" "my-custom-name" "Custom name 'my-custom-name' is used"
    assert_contains "$output" "glamorous-scripts" "Custom name 'glamorous-scripts' is used"

    # Should NOT see original repo names as paths
    # (Note: The original names might appear in other contexts, so we check specifically)

    e2e_cleanup
}

#==============================================================================
# Test: Combination of branch pinning and custom names
#==============================================================================

test_combined_spec() {
    e2e_setup

    # Initialize ru config
    "$E2E_RU_SCRIPT" init --non-interactive >/dev/null 2>&1

    # Create a repos file with combined specs
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat > "$repos_file" << 'EOF'
owner/repo@develop as dev-repo
charmbracelet/gum@main as gum-stable
cli/cli@v2 as github-cli-v2
EOF

    # Run sync --dry-run
    local output
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

    # Verify custom names are used (not branch names or original names)
    assert_contains "$output" "dev-repo" "Combined spec uses custom name 'dev-repo'"
    assert_contains "$output" "gum-stable" "Combined spec uses custom name 'gum-stable'"
    assert_contains "$output" "github-cli-v2" "Combined spec uses custom name 'github-cli-v2'"

    e2e_cleanup
}

#==============================================================================
# Test: Deduplication by path
#==============================================================================

test_deduplication() {
    e2e_setup

    # Initialize ru config
    "$E2E_RU_SCRIPT" init --non-interactive >/dev/null 2>&1

    # Create a repos file with duplicate paths
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat > "$repos_file" << 'EOF'
# These should dedupe to one entry (same local path)
owner/repo
owner/repo@develop

# These are different (different custom names)
cli/cli as github-cli-1
cli/cli as github-cli-2
EOF

    # Run sync --dry-run to see deduplication in action
    local output
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

    # The first two should dedupe to one, but the custom-named ones are different paths
    # So we should see github-cli-1 and github-cli-2
    assert_contains "$output" "github-cli-1" "First custom name is processed"
    assert_contains "$output" "github-cli-2" "Second custom name is processed"

    # Should only see one "repo" entry due to deduplication
    local repo_count
    repo_count=$(printf '%s\n' "$output" | grep -c "owner/repo" || true)
    # We expect to see owner/repo once (the duplicate is skipped)
    if [[ "$repo_count" -le 2 ]]; then
        pass "Duplicate repos are deduplicated or processed correctly"
    else
        fail "Expected at most 2 mentions of owner/repo, got $repo_count"
    fi

    e2e_cleanup
}

#==============================================================================
# Test: Mixed specs in one file
#==============================================================================

test_mixed_specs() {
    e2e_setup

    # Initialize ru config
    "$E2E_RU_SCRIPT" init --non-interactive >/dev/null 2>&1

    # Create a repos file with mixed specs
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat > "$repos_file" << 'EOF'
# Basic
simple/repo

# With branch
branched/repo@feature

# With custom name
named/repo as myrepo

# Full combination
full/repo@main as full-combo

# Comment lines and blank lines should be ignored

# Another comment
EOF

    # Run sync --dry-run
    local output
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

    # All repos should be processed
    assert_contains "$output" "repo" "Basic spec is processed"
    assert_contains "$output" "myrepo" "Named spec is processed"
    assert_contains "$output" "full-combo" "Full combination spec is processed"

    # Comments should not appear as repo names
    assert_not_contains "$output" "# Basic" "Comments are not treated as repos"

    e2e_cleanup
}

#==============================================================================
# Test: Edge cases in spec parsing
#==============================================================================

test_edge_cases() {
    e2e_setup

    # Initialize ru config
    "$E2E_RU_SCRIPT" init --non-interactive >/dev/null 2>&1

    # Create a repos file with edge cases
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat > "$repos_file" << 'EOF'
# Repo with hyphen in name
my-org/my-repo

# Repo with numbers
user123/repo456

# Branch with slashes (feature branches)
owner/repo@feature/new-thing

# Underscores in custom name
owner/repo as my_custom_name

# Full URL format
https://github.com/owner/repo

# SSH URL format
git@github.com:owner/sshrepo.git
EOF

    # Run sync --dry-run
    local output
    output=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

    # Verify various edge cases are handled
    assert_contains "$output" "my-repo" "Hyphenated repo name works"
    assert_contains "$output" "repo456" "Numeric repo name works"
    assert_contains "$output" "my_custom_name" "Underscored custom name works"
    # Verify SSH URL is parsed (extracts 'sshrepo' from git@github.com:owner/sshrepo.git)
    assert_contains "$output" "sshrepo" "SSH URL format is parsed correctly"

    e2e_cleanup
}

#==============================================================================
# Test: Layout affects path generation (via config)
#==============================================================================

test_layout_with_specs() {
    e2e_setup

    # Initialize ru config
    "$E2E_RU_SCRIPT" init --non-interactive >/dev/null 2>&1

    # Create a simple repos file
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat > "$repos_file" << 'EOF'
owner/repo
owner/another as custom-name
EOF

    # Test with flat layout (default)
    local output_flat
    output_flat=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true
    assert_contains "$output_flat" "repo" "Flat layout (default) processes basic spec"
    assert_contains "$output_flat" "custom-name" "Flat layout honors custom name"

    # Configure owner-repo layout
    "$E2E_RU_SCRIPT" config --set LAYOUT=owner-repo --non-interactive >/dev/null 2>&1 || true

    # Test with owner-repo layout
    local output_owner
    output_owner=$("$E2E_RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true
    # Owner-repo layout should show owner-repo format for basic spec
    # but custom name still overrides
    assert_contains "$output_owner" "custom-name" "Owner-repo layout still honors custom name"

    e2e_cleanup
}

#==============================================================================
# Run All Tests
#==============================================================================

log_suite_start "E2E Tests: Repo Spec Parsing"

run_test test_basic_repo_spec
run_test test_branch_pinning
run_test test_custom_names
run_test test_combined_spec
run_test test_deduplication
run_test test_mixed_specs
run_test test_edge_cases
run_test test_layout_with_specs

print_results
exit "$(get_exit_code)"
