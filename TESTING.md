# Testing Guide

This document covers how to run, write, and debug tests for `ru`.

## Running Tests

### Quick Start

```bash
# Run all tests
./scripts/run_all_tests.sh

# Run specific test file
./scripts/test_unit_config.sh

# Run with TAP output (for CI)
./scripts/run_all_tests.sh --tap

# Run E2E tests only
for f in scripts/test_e2e_*.sh; do "$f"; done

# Run unit tests only
for f in scripts/test_unit_*.sh; do "$f"; done
```

### Test Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TF_LOG_LEVEL` | `warn` | Log verbosity: `debug`, `info`, `warn`, `error`, `none` |
| `TF_LOG_FILE` | (none) | Write logs to file (human-readable) |
| `TF_JSON_LOG_FILE` | (none) | Write logs to file (JSON lines) |
| `TF_SKIP_GH_AUTH` | (unset) | Skip tests requiring GitHub authentication |
| `TF_FAILED_ARTIFACTS_DIR` | `/tmp/ru-test-failures` | Directory for failed test artifacts |

## Test Tiers

### Unit Tests (`test_unit_*.sh`)

Test individual functions in isolation using `source_ru_function`:

```bash
#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

# Source specific functions from ru
source_ru_function "parse_repo_url"
source_ru_function "normalize_url"

# Stub logging (these functions are often called by sourced code)
log_warn() { :; }
log_error() { :; }

test_parse_github_url() {
    log_test_start "parse_repo_url handles github.com"

    local host owner repo
    parse_repo_url "https://github.com/user/repo" host owner repo

    assert_equals "github.com" "$host" "host"
    assert_equals "user" "$owner" "owner"
    assert_equals "repo" "$repo" "repo"

    log_test_pass "parse_repo_url handles github.com"
}

run_test test_parse_github_url
print_results
exit "$(get_exit_code)"
```

**Key patterns:**
- Use `source_ru_function "func_name"` to extract functions from `ru`
- Stub `log_*` functions to avoid output noise
- Use `assert_equals`, `assert_contains`, `assert_file_exists`, etc.
- Wrap tests in `run_test test_function_name`

### Integration Tests (`test_local_git.sh`, `test_parsing.sh`)

Test real git operations using local bare repos:

```bash
#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_framework.sh"

test_clone_and_pull() {
    log_test_start "clone and pull workflow"

    # Create test environment with local repos
    local info repo_dir remote_dir dev_dir
    info=$(create_real_git_repo_with_remote "test-repo" 3)
    repo_dir="${info%|*}"
    remote_dir="${info#*|}"

    # Create a "dev" clone to simulate another developer pushing
    # (Can't commit directly to bare repo - must push from a working copy)
    dev_dir=$(mktemp -d)
    git clone "$remote_dir" "$dev_dir" >/dev/null 2>&1
    git -C "$dev_dir" config user.name "Other Dev"
    git -C "$dev_dir" config user.email "dev@test.local"
    git -C "$dev_dir" commit --allow-empty -m "Remote commit"
    git -C "$dev_dir" push >/dev/null 2>&1

    # Test ru function
    source_ru_function "do_pull"
    local pull_exit=0
    do_pull "$repo_dir" "ff-only" "false" || pull_exit=$?

    # Verify
    assert_equals "0" "$pull_exit" "pull succeeds"

    log_test_pass "clone and pull workflow"
}
```

**Git harness helpers:**
- `create_mock_repo "name"` - Basic git init
- `create_bare_repo "name"` - Bare repository (for remotes)
- `create_real_git_repo "name" [commits] [branch]` - Repo with commits
- `create_real_git_repo_with_remote "name" [commits]` - Returns `repo_dir|remote_dir`

### E2E Tests (`test_e2e_*.sh`)

Test full CLI workflows in isolated environments:

```bash
#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_e2e_framework.sh"

test_sync_command() {
    e2e_setup "sync_command"

    # Set up isolated XDG environment
    export RU_CONFIG_DIR="$E2E_TEMP_DIR/config/ru"
    export RU_STATE_DIR="$E2E_TEMP_DIR/state/ru"
    mkdir -p "$RU_CONFIG_DIR/repos.d"

    # Create test repo
    local remote_dir
    remote_dir=$(create_test_repo "myrepo")
    echo "https://github.com/test/myrepo" > "$RU_CONFIG_DIR/repos.d/public.txt"

    # Run ru command
    local output exit_code=0
    output=$("$RU_SCRIPT" sync 2>&1) || exit_code=$?

    # Verify
    e2e_assert_success "$exit_code" "sync succeeds"
    e2e_assert_contains "$output" "myrepo" "output mentions repo"

    e2e_cleanup
}

run_e2e_test test_sync_command
e2e_summary
```

**E2E framework functions:**
- `e2e_setup "test_name"` - Create temp directory, set up logging
- `e2e_cleanup` - Clean up temp directories
- `e2e_assert_success`, `e2e_assert_fails` - Exit code assertions
- `e2e_assert_contains`, `e2e_assert_not_contains` - Output assertions
- `e2e_log_operation`, `e2e_log_result` - Structured logging

## When to Mock vs Use Real Operations

### Use Real Operations (Preferred)

- Git operations with local bare repos
- File system operations in temp directories
- Config file parsing and writing
- URL parsing and normalization

```bash
# Real git operations
local repo_dir
repo_dir=$(create_real_git_repo "test" 5)
git -C "$repo_dir" status  # Real git command
```

### Use Stubs/Mocks

- Network calls (GitHub API, `curl`)
- Interactive prompts (`gum`, `read`)
- Logging functions (to reduce noise)
- External tools when not testing them (`gh`, `jq`)

```bash
# Stub logging
log_warn() { :; }
log_info() { :; }

# Stub gum (for non-interactive tests)
gum() { echo "mocked"; }
export -f gum

# Stub GitHub API
gh() {
    case "$*" in
        *"api repos"*) echo '{"private": false}' ;;
        *) return 1 ;;
    esac
}
export -f gh
```

## Logging and Artifacts

### Test Framework Logging

```bash
# In your test
log_test_start "My test description"

# Debug output (only shown with TF_LOG_LEVEL=debug)
log_debug "Variable value: $var"

# Always shown
log_info "Important info"
log_warn "Warning message"

log_test_pass "My test description"
# or
log_test_fail "My test description" "expected X, got Y"
```

### Artifact Capture

Failed tests automatically capture artifacts to `TF_FAILED_ARTIFACTS_DIR`:
- stdout/stderr captures
- Temp directory contents
- Git repository states

To preserve artifacts for debugging:

```bash
# Set before running tests
export TF_FAILED_ARTIFACTS_DIR="$HOME/test-debug"
./scripts/test_unit_config.sh

# Artifacts available at:
ls "$HOME/test-debug/test_unit_config/"
```

### JSON Event Logging

For machine-readable test output:

```bash
export TF_JSON_LOG_FILE="/tmp/tests.jsonl"
./scripts/run_all_tests.sh

# Parse results
jq -s 'map(select(.type == "test_result"))' /tmp/tests.jsonl
```

## CI Integration

Tests run automatically on every push/PR via GitHub Actions:

- ShellCheck linting
- Bash syntax validation
- Full test suite on Ubuntu and macOS
- Test artifacts uploaded on failure (14-day retention)

See `.github/workflows/ci.yml` for details.

## Common Patterns

### Testing Exit Codes

```bash
test_error_handling() {
    log_test_start "function returns error on invalid input"

    local exit_code=0
    some_function "invalid" 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "returns error code 1"

    log_test_pass "function returns error on invalid input"
}
```

### Testing File Contents

```bash
test_config_written() {
    log_test_start "config file contains expected values"

    write_config "/tmp/test-config"

    assert_file_exists "/tmp/test-config" "config created"
    assert_file_contains "/tmp/test-config" "PROJECTS_DIR=" "has PROJECTS_DIR"
    assert_file_not_contains "/tmp/test-config" "SECRET" "no secrets"

    log_test_pass "config file contains expected values"
}
```

### Testing Git State

```bash
test_repo_state() {
    log_test_start "repo is ahead after local commit"

    local info repo_dir
    info=$(create_real_git_repo_with_remote "test" 2)
    repo_dir="${info%|*}"

    # Add local commit
    echo "new" > "$repo_dir/new.txt"
    git -C "$repo_dir" add new.txt
    git -C "$repo_dir" commit -m "Local commit"

    # Check state
    git -C "$repo_dir" fetch
    local ahead
    ahead=$(git -C "$repo_dir" rev-list --count origin/main..HEAD)

    assert_equals "1" "$ahead" "local is 1 commit ahead"

    log_test_pass "repo is ahead after local commit"
}
```

## Debugging Failed Tests

1. **Run single test with debug logging:**
   ```bash
   TF_LOG_LEVEL=debug ./scripts/test_unit_config.sh
   ```

2. **Preserve artifacts:**
   ```bash
   export TF_FAILED_ARTIFACTS_DIR="$HOME/debug"
   ./scripts/test_unit_config.sh
   ls -la "$HOME/debug/"
   ```

3. **Run test interactively:**
   ```bash
   # Source framework in interactive shell
   source scripts/test_framework.sh

   # Source the function you're testing
   source_ru_function "parse_repo_url"

   # Call it directly
   parse_repo_url "https://github.com/user/repo" host owner repo
   echo "host=$host owner=$owner repo=$repo"
   ```

4. **Check test framework itself:**
   ```bash
   ./scripts/test_framework_selftest.sh
   ```
