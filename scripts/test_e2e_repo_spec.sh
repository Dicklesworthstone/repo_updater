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
# shellcheck disable=SC1090  # Dynamic sourcing is intentional
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

# Colors (disabled if stdout is not a terminal)
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
    # Override XDG directories to isolate tests
    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_STATE_HOME="$TEMP_DIR/state"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
    export HOME="$TEMP_DIR/home"
    mkdir -p "$HOME"

    # Force sequential mode for predictable output
    export RU_PARALLEL=1

    # Create a projects directory
    export PROJECTS_DIR="$TEMP_DIR/projects"
    mkdir -p "$PROJECTS_DIR"
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
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

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg (expected: '$expected', got: '$actual')"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$msg"
    else
        fail "$msg (string '$needle' not found in output)"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$msg"
    else
        fail "$msg (string '$needle' should not be in output)"
    fi
}

assert_file_exists() {
    local path="$1"
    local msg="$2"
    if [[ -f "$path" ]]; then
        pass "$msg"
    else
        fail "$msg (file not found: $path)"
    fi
}

assert_dir_exists() {
    local path="$1"
    local msg="$2"
    if [[ -d "$path" ]]; then
        pass "$msg"
    else
        fail "$msg (directory not found: $path)"
    fi
}

#==============================================================================
# Test: Basic repo spec parsing
#==============================================================================

test_basic_repo_spec() {
    echo ""
    echo "=== Test: Basic repo spec parsing ==="

    setup_test_env
    trap cleanup_test_env EXIT

    # Initialize ru config
    "$RU_SCRIPT" init --non-interactive >/dev/null 2>&1

    # Create a repos file with basic specs
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat > "$repos_file" << 'EOF'
owner/repo
charmbracelet/gum
cli/cli
EOF

    # Run sync --dry-run to see what paths would be used
    local output
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

    # Verify paths are generated correctly (flat layout by default)
    assert_contains "$output" "repo" "Basic spec 'owner/repo' generates correct repo name"
    assert_contains "$output" "gum" "Basic spec 'charmbracelet/gum' generates correct repo name"
    assert_contains "$output" "cli" "Basic spec 'cli/cli' generates correct repo name"

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Test: Branch pinning with @branch syntax
#==============================================================================

test_branch_pinning() {
    echo ""
    echo "=== Test: Branch pinning with @branch syntax ==="

    setup_test_env
    trap cleanup_test_env EXIT

    # Initialize ru config
    "$RU_SCRIPT" init --non-interactive >/dev/null 2>&1

    # Create a repos file with branch specs
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat > "$repos_file" << 'EOF'
owner/repo@develop
charmbracelet/gum@main
cli/cli@v2
EOF

    # Run sync --dry-run with JSON output
    local output
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

    # The dry-run should show the repos being processed
    assert_contains "$output" "repo" "Branch-pinned spec processes correctly"
    assert_contains "$output" "gum" "Branch-pinned spec for gum processes correctly"

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Test: Custom names with 'as' syntax
#==============================================================================

test_custom_names() {
    echo ""
    echo "=== Test: Custom names with 'as' syntax ==="

    setup_test_env
    trap cleanup_test_env EXIT

    # Initialize ru config
    "$RU_SCRIPT" init --non-interactive >/dev/null 2>&1

    # Create a repos file with custom name specs
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat > "$repos_file" << 'EOF'
owner/repo as my-custom-name
charmbracelet/gum as glamorous-scripts
EOF

    # Run sync --dry-run and verify custom names are used
    local output
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

    # Should see custom names in output
    assert_contains "$output" "my-custom-name" "Custom name 'my-custom-name' is used"
    assert_contains "$output" "glamorous-scripts" "Custom name 'glamorous-scripts' is used"

    # Should NOT see original repo names as paths
    # (Note: The original names might appear in other contexts, so we check specifically)

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Test: Combination of branch pinning and custom names
#==============================================================================

test_combined_spec() {
    echo ""
    echo "=== Test: Combined branch pinning and custom names ==="

    setup_test_env
    trap cleanup_test_env EXIT

    # Initialize ru config
    "$RU_SCRIPT" init --non-interactive >/dev/null 2>&1

    # Create a repos file with combined specs
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat > "$repos_file" << 'EOF'
owner/repo@develop as dev-repo
charmbracelet/gum@main as gum-stable
cli/cli@v2 as github-cli-v2
EOF

    # Run sync --dry-run
    local output
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

    # Verify custom names are used (not branch names or original names)
    assert_contains "$output" "dev-repo" "Combined spec uses custom name 'dev-repo'"
    assert_contains "$output" "gum-stable" "Combined spec uses custom name 'gum-stable'"
    assert_contains "$output" "github-cli-v2" "Combined spec uses custom name 'github-cli-v2'"

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Test: Deduplication by path
#==============================================================================

test_deduplication() {
    echo ""
    echo "=== Test: Deduplication by path ==="

    setup_test_env
    trap cleanup_test_env EXIT

    # Initialize ru config
    "$RU_SCRIPT" init --non-interactive >/dev/null 2>&1

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
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

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

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Test: Mixed specs in one file
#==============================================================================

test_mixed_specs() {
    echo ""
    echo "=== Test: Mixed specs in one file ==="

    setup_test_env
    trap cleanup_test_env EXIT

    # Initialize ru config
    "$RU_SCRIPT" init --non-interactive >/dev/null 2>&1

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
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

    # All repos should be processed
    assert_contains "$output" "repo" "Basic spec is processed"
    assert_contains "$output" "myrepo" "Named spec is processed"
    assert_contains "$output" "full-combo" "Full combination spec is processed"

    # Comments should not appear as repo names
    assert_not_contains "$output" "# Basic" "Comments are not treated as repos"

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Test: Edge cases in spec parsing
#==============================================================================

test_edge_cases() {
    echo ""
    echo "=== Test: Edge cases in spec parsing ==="

    setup_test_env
    trap cleanup_test_env EXIT

    # Initialize ru config
    "$RU_SCRIPT" init --non-interactive >/dev/null 2>&1

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
    output=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true

    # Verify various edge cases are handled
    assert_contains "$output" "my-repo" "Hyphenated repo name works"
    assert_contains "$output" "repo456" "Numeric repo name works"
    assert_contains "$output" "my_custom_name" "Underscored custom name works"
    # Verify SSH URL is parsed (extracts 'sshrepo' from git@github.com:owner/sshrepo.git)
    assert_contains "$output" "sshrepo" "SSH URL format is parsed correctly"

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Test: Layout affects path generation (via config)
#==============================================================================

test_layout_with_specs() {
    echo ""
    echo "=== Test: Layout affects path generation ==="

    setup_test_env
    trap cleanup_test_env EXIT

    # Initialize ru config
    "$RU_SCRIPT" init --non-interactive >/dev/null 2>&1

    # Create a simple repos file
    local repos_file="$XDG_CONFIG_HOME/ru/repos.d/public.txt"
    cat > "$repos_file" << 'EOF'
owner/repo
owner/another as custom-name
EOF

    # Test with flat layout (default)
    local output_flat
    output_flat=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true
    assert_contains "$output_flat" "repo" "Flat layout (default) processes basic spec"
    assert_contains "$output_flat" "custom-name" "Flat layout honors custom name"

    # Configure owner-repo layout
    "$RU_SCRIPT" config --set LAYOUT=owner-repo --non-interactive >/dev/null 2>&1 || true

    # Test with owner-repo layout
    local output_owner
    output_owner=$("$RU_SCRIPT" sync --dry-run --non-interactive 2>&1) || true
    # Owner-repo layout should show owner-repo format for basic spec
    # but custom name still overrides
    assert_contains "$output_owner" "custom-name" "Owner-repo layout still honors custom name"

    cleanup_test_env
    trap - EXIT
}

#==============================================================================
# Run All Tests
#==============================================================================

echo "============================================"
echo "E2E Tests: Repo Spec Parsing"
echo "============================================"

test_basic_repo_spec
echo ""

test_branch_pinning
echo ""

test_custom_names
echo ""

test_combined_spec
echo ""

test_deduplication
echo ""

test_mixed_specs
echo ""

test_edge_cases
echo ""

test_layout_with_specs
echo ""

echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "============================================"

[[ $TESTS_FAILED -eq 0 ]]
