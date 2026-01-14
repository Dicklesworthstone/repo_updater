#!/usr/bin/env bash
#
# Unit tests: Quality Gates (bd-px9e)
#
# Covers:
# - detect_test_command
# - detect_lint_command
# - run_test_gate
# - run_lint_gate
# - run_secret_scan
# - run_quality_gates
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

source_ru_function "detect_test_command"
source_ru_function "detect_lint_command"
source_ru_function "run_test_gate"
source_ru_function "run_lint_gate"
source_ru_function "run_secret_scan"
source_ru_function "run_quality_gates"
source_ru_function "load_policy_for_repo"
source_ru_function "get_review_policy_dir"
source_ru_function "ensure_dir"
source_ru_function "json_escape"

# Mock logging (avoid noisy output on error paths)
log_error() { :; }
log_warn() { :; }
log_info() { :; }
log_verbose() { :; }

require_jq_or_skip() {
    if ! command -v jq &>/dev/null; then
        skip_test "jq not installed"
        return 1
    fi
    return 0
}

#==============================================================================
# Helpers
#==============================================================================

# Create a minimal fake project of a given type
_create_fake_project() {
    local project_type="$1"
    local project_dir="$2"

    mkdir -p "$project_dir"

    case "$project_type" in
        makefile)
            cat > "$project_dir/Makefile" <<'EOF'
test:
	@echo "Running tests..."
	@exit 0
EOF
            ;;
        npm)
            cat > "$project_dir/package.json" <<'EOF'
{
  "name": "test-project",
  "scripts": {
    "test": "echo 'npm test passed'",
    "lint": "echo 'npm lint passed'"
  }
}
EOF
            ;;
        cargo)
            cat > "$project_dir/Cargo.toml" <<'EOF'
[package]
name = "test-project"
version = "0.1.0"
EOF
            ;;
        python)
            cat > "$project_dir/pyproject.toml" <<'EOF'
[project]
name = "test-project"
EOF
            mkdir -p "$project_dir/tests"
            ;;
        go)
            cat > "$project_dir/go.mod" <<'EOF'
module test-project

go 1.21
EOF
            ;;
        shell)
            mkdir -p "$project_dir/scripts"
            cat > "$project_dir/scripts/run_all_tests.sh" <<'EOF'
#!/usr/bin/env bash
echo "All tests passed"
exit 0
EOF
            chmod +x "$project_dir/scripts/run_all_tests.sh"
            ;;
        empty)
            # No special files, just empty directory
            ;;
    esac
}

# Create a passing test script
_create_passing_test() {
    local project_dir="$1"
    mkdir -p "$project_dir"
    cat > "$project_dir/run_tests.sh" <<'EOF'
#!/usr/bin/env bash
echo "Test 1: PASS"
echo "Test 2: PASS"
echo "All tests passed"
exit 0
EOF
    chmod +x "$project_dir/run_tests.sh"
}

# Create a failing test script
_create_failing_test() {
    local project_dir="$1"
    mkdir -p "$project_dir"
    cat > "$project_dir/run_tests.sh" <<'EOF'
#!/usr/bin/env bash
echo "Test 1: PASS"
echo "Test 2: FAIL"
echo "Tests failed"
exit 1
EOF
    chmod +x "$project_dir/run_tests.sh"
}

# Create a passing lint script
_create_passing_lint() {
    local project_dir="$1"
    mkdir -p "$project_dir"
    cat > "$project_dir/run_lint.sh" <<'EOF'
#!/usr/bin/env bash
echo "Lint check passed"
exit 0
EOF
    chmod +x "$project_dir/run_lint.sh"
}

# Create a failing lint script
_create_failing_lint() {
    local project_dir="$1"
    mkdir -p "$project_dir"
    cat > "$project_dir/run_lint.sh" <<'EOF'
#!/usr/bin/env bash
echo "error: unused variable 'foo'"
echo "Lint check failed"
exit 1
EOF
    chmod +x "$project_dir/run_lint.sh"
}

#==============================================================================
# Tests: detect_test_command
#==============================================================================

test_detect_test_command_makefile() {
    local test_name="detect_test_command: detects Makefile test target"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_fake_project "makefile" "$project_dir"

    local result
    result=$(detect_test_command "$project_dir")
    local rc=$?

    assert_equals 0 "$rc" "Should return success"
    assert_equals "make test" "$result" "Should detect make test"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_detect_test_command_npm() {
    local test_name="detect_test_command: detects npm test script"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_fake_project "npm" "$project_dir"

    local result
    result=$(detect_test_command "$project_dir")
    local rc=$?

    assert_equals 0 "$rc" "Should return success"
    assert_equals "npm test" "$result" "Should detect npm test"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_detect_test_command_cargo() {
    local test_name="detect_test_command: detects Cargo.toml"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_fake_project "cargo" "$project_dir"

    local result
    result=$(detect_test_command "$project_dir")
    local rc=$?

    assert_equals 0 "$rc" "Should return success"
    assert_equals "cargo test" "$result" "Should detect cargo test"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_detect_test_command_python() {
    local test_name="detect_test_command: detects Python with tests dir"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_fake_project "python" "$project_dir"

    local result
    result=$(detect_test_command "$project_dir")
    local rc=$?

    assert_equals 0 "$rc" "Should return success"
    assert_equals "pytest" "$result" "Should detect pytest"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_detect_test_command_go() {
    local test_name="detect_test_command: detects go.mod"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_fake_project "go" "$project_dir"

    local result
    result=$(detect_test_command "$project_dir")
    local rc=$?

    assert_equals 0 "$rc" "Should return success"
    assert_equals "go test ./..." "$result" "Should detect go test"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_detect_test_command_shell_script() {
    local test_name="detect_test_command: detects run_all_tests.sh"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_fake_project "shell" "$project_dir"

    local result
    result=$(detect_test_command "$project_dir")
    local rc=$?

    assert_equals 0 "$rc" "Should return success"
    assert_equals "./scripts/run_all_tests.sh" "$result" "Should detect shell test script"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_detect_test_command_empty_returns_failure() {
    local test_name="detect_test_command: returns 1 for empty project"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_fake_project "empty" "$project_dir"

    local result
    result=$(detect_test_command "$project_dir")
    local rc=$?

    assert_equals 1 "$rc" "Should return failure for empty project"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: detect_lint_command
#==============================================================================

test_detect_lint_command_npm() {
    local test_name="detect_lint_command: detects npm lint script"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_fake_project "npm" "$project_dir"

    local result
    result=$(detect_lint_command "$project_dir")
    local rc=$?

    assert_equals 0 "$rc" "Should return success"
    assert_equals "npm run lint" "$result" "Should detect npm run lint"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_detect_lint_command_go() {
    local test_name="detect_lint_command: detects go vet"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_fake_project "go" "$project_dir"

    local result
    result=$(detect_lint_command "$project_dir")
    local rc=$?

    assert_equals 0 "$rc" "Should return success"
    assert_equals "go vet ./..." "$result" "Should detect go vet"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_detect_lint_command_empty_returns_failure() {
    local test_name="detect_lint_command: returns 1 for empty project"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_fake_project "empty" "$project_dir"

    local result
    result=$(detect_lint_command "$project_dir")
    local rc=$?

    assert_equals 1 "$rc" "Should return failure for empty project"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: run_test_gate
#==============================================================================

test_run_test_gate_success() {
    local test_name="run_test_gate: returns success JSON for passing tests"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_passing_test "$project_dir"

    local result
    result=$(run_test_gate "$project_dir" "./run_tests.sh" 30)
    local rc=$?

    assert_equals 0 "$rc" "Should return success exit code"

    local ran ok
    ran=$(echo "$result" | jq -r '.ran')
    ok=$(echo "$result" | jq -r '.ok')

    assert_equals "true" "$ran" "ran should be true"
    assert_equals "true" "$ok" "ok should be true"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_run_test_gate_failure() {
    local test_name="run_test_gate: returns failure JSON for failing tests"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_failing_test "$project_dir"

    local result
    result=$(run_test_gate "$project_dir" "./run_tests.sh" 30)
    local rc=$?

    assert_equals 1 "$rc" "Should return failure exit code"

    local ran ok exit_code
    ran=$(echo "$result" | jq -r '.ran')
    ok=$(echo "$result" | jq -r '.ok')
    exit_code=$(echo "$result" | jq -r '.exit_code')

    assert_equals "true" "$ran" "ran should be true"
    assert_equals "false" "$ok" "ok should be false"
    assert_equals "1" "$exit_code" "exit_code should be 1"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_run_test_gate_no_tests_found() {
    local test_name="run_test_gate: returns code 2 when no tests found"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_fake_project "empty" "$project_dir"

    local result
    result=$(run_test_gate "$project_dir" "" 30)
    local rc=$?

    assert_equals 2 "$rc" "Should return code 2 for no tests"

    local ran reason
    ran=$(echo "$result" | jq -r '.ran')
    reason=$(echo "$result" | jq -r '.reason')

    assert_equals "false" "$ran" "ran should be false"
    assert_equals "no_tests_found" "$reason" "reason should be no_tests_found"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_run_test_gate_captures_output_summary() {
    local test_name="run_test_gate: captures output summary"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_passing_test "$project_dir"

    local result
    result=$(run_test_gate "$project_dir" "./run_tests.sh" 30)

    local output_summary
    output_summary=$(echo "$result" | jq -r '.output_summary')

    assert_contains "$output_summary" "passed" "Output summary should contain test output"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_run_test_gate_records_duration() {
    local test_name="run_test_gate: records duration_seconds"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_passing_test "$project_dir"

    local result
    result=$(run_test_gate "$project_dir" "./run_tests.sh" 30)

    local duration
    duration=$(echo "$result" | jq -r '.duration_seconds')

    # Duration should be a number >= 0
    if [[ "$duration" =~ ^[0-9]+$ ]] && [[ "$duration" -ge 0 ]]; then
        pass "Duration should be a non-negative integer"
    else
        fail "Duration should be a non-negative integer (got: $duration)"
    fi

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: run_lint_gate
#==============================================================================

test_run_lint_gate_success() {
    local test_name="run_lint_gate: returns success JSON for passing lint"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_passing_lint "$project_dir"

    local result
    result=$(run_lint_gate "$project_dir" "./run_lint.sh")
    local rc=$?

    assert_equals 0 "$rc" "Should return success exit code"

    local ran ok
    ran=$(echo "$result" | jq -r '.ran')
    ok=$(echo "$result" | jq -r '.ok')

    assert_equals "true" "$ran" "ran should be true"
    assert_equals "true" "$ok" "ok should be true"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_run_lint_gate_failure() {
    local test_name="run_lint_gate: returns failure JSON for failing lint"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_failing_lint "$project_dir"

    local result
    result=$(run_lint_gate "$project_dir" "./run_lint.sh")
    local rc=$?

    assert_equals 1 "$rc" "Should return failure exit code"

    local ran ok
    ran=$(echo "$result" | jq -r '.ran')
    ok=$(echo "$result" | jq -r '.ok')

    assert_equals "true" "$ran" "ran should be true"
    assert_equals "false" "$ok" "ok should be false"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_run_lint_gate_no_linter_found() {
    local test_name="run_lint_gate: returns code 2 when no linter found"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    _create_fake_project "empty" "$project_dir"

    local result
    result=$(run_lint_gate "$project_dir" "")
    local rc=$?

    assert_equals 2 "$rc" "Should return code 2 for no linter"

    local ran reason
    ran=$(echo "$result" | jq -r '.ran')
    reason=$(echo "$result" | jq -r '.reason')

    assert_equals "false" "$ran" "ran should be false"
    assert_equals "no_linter_found" "$reason" "reason should be no_linter_found"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: run_secret_scan
#==============================================================================

test_run_secret_scan_clean_project() {
    local test_name="run_secret_scan: returns success for clean project"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    mkdir -p "$project_dir"
    git -C "$project_dir" init -q
    echo "# Clean file" > "$project_dir/README.md"
    git -C "$project_dir" add .
    git -C "$project_dir" commit -q -m "Initial"

    local result
    result=$(run_secret_scan "$project_dir")
    local rc=$?

    assert_equals 0 "$rc" "Should return success for clean project"

    local ran ok
    ran=$(echo "$result" | jq -r '.ran')
    ok=$(echo "$result" | jq -r '.ok')

    assert_equals "true" "$ran" "ran should be true"
    assert_equals "true" "$ok" "ok should be true"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_run_secret_scan_detects_potential_secret() {
    local test_name="run_secret_scan: detects potential secret patterns"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    # Skip if gitleaks is installed (it may have different behavior)
    if command -v gitleaks &>/dev/null; then
        skip_test "gitleaks installed, testing regex fallback"
        return 0
    fi

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    mkdir -p "$project_dir"
    git -C "$project_dir" init -q
    echo "Clean initial" > "$project_dir/README.md"
    git -C "$project_dir" add .
    git -C "$project_dir" commit -q -m "Initial"

    # Add a file with potential secret pattern
    echo 'API_KEY = "sk-abc123"' > "$project_dir/config.txt"
    git -C "$project_dir" add .

    local result
    result=$(run_secret_scan "$project_dir" "staged")
    local rc=$?

    # Should return 2 (warning) for regex fallback
    assert_equals 2 "$rc" "Should return warning code for potential secret"

    local warning findings_count
    warning=$(echo "$result" | jq -r '.warning')
    findings_count=$(echo "$result" | jq '.findings | length')

    assert_equals "true" "$warning" "warning should be true"
    if [[ "$findings_count" -gt 0 ]]; then
        pass "Should have findings"
    else
        fail "Should have findings"
    fi

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_run_secret_scan_reports_tool_used() {
    local test_name="run_secret_scan: reports which tool was used"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local project_dir="$env_root/project"

    mkdir -p "$project_dir"
    git -C "$project_dir" init -q
    echo "Clean" > "$project_dir/README.md"
    git -C "$project_dir" add .
    git -C "$project_dir" commit -q -m "Initial"

    local result
    result=$(run_secret_scan "$project_dir")

    local tool
    tool=$(echo "$result" | jq -r '.tool')

    # Should be one of the supported tools: gitleaks, detect-secrets, or heuristic
    if [[ "$tool" == "gitleaks" ]] || [[ "$tool" == "detect-secrets" ]] || [[ "$tool" == "heuristic" ]]; then
        pass "Tool should be gitleaks, detect-secrets, or heuristic"
    else
        fail "Tool should be gitleaks, detect-secrets, or heuristic (got: $tool)"
    fi

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

#==============================================================================
# Tests: run_quality_gates (integration)
#==============================================================================

test_run_quality_gates_all_pass() {
    local test_name="run_quality_gates: all gates pass"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local wt_path="$env_root/worktree"
    local plan_file="$env_root/review-plan.json"

    # Set up minimal worktree with passing tests and lint
    mkdir -p "$wt_path"
    git -C "$wt_path" init -q
    echo "Clean" > "$wt_path/README.md"
    git -C "$wt_path" add .
    git -C "$wt_path" commit -q -m "Initial"

    _create_passing_test "$wt_path"
    _create_passing_lint "$wt_path"

    # Create minimal plan file
    echo '{"repo":"test/repo"}' > "$plan_file"

    # Set up RU_CONFIG_DIR for load_policy_for_repo
    export RU_CONFIG_DIR="$env_root/config"
    mkdir -p "$RU_CONFIG_DIR/review-policies.d"

    # Create policy file with test/lint commands
    cat > "$RU_CONFIG_DIR/review-policies.d/test_repo" <<'EOF'
TEST_COMMAND=./run_tests.sh
LINT_COMMAND=./run_lint.sh
EOF

    local result
    result=$(run_quality_gates "$wt_path" "$plan_file")
    local rc=$?

    assert_equals 0 "$rc" "Should return success when all gates pass"

    local overall_ok has_warning
    overall_ok=$(echo "$result" | jq -r '.overall_ok')
    has_warning=$(echo "$result" | jq -r '.has_warning')

    assert_equals "true" "$overall_ok" "overall_ok should be true"
    assert_equals "false" "$has_warning" "has_warning should be false"

    # Verify structure
    local has_tests has_lint has_secrets
    has_tests=$(echo "$result" | jq 'has("tests")')
    has_lint=$(echo "$result" | jq 'has("lint")')
    has_secrets=$(echo "$result" | jq 'has("secrets")')

    assert_equals "true" "$has_tests" "Result should have tests field"
    assert_equals "true" "$has_lint" "Result should have lint field"
    assert_equals "true" "$has_secrets" "Result should have secrets field"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_run_quality_gates_test_failure() {
    local test_name="run_quality_gates: returns failure when tests fail"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local wt_path="$env_root/worktree"
    local plan_file="$env_root/review-plan.json"

    mkdir -p "$wt_path"
    git -C "$wt_path" init -q
    echo "Clean" > "$wt_path/README.md"
    git -C "$wt_path" add .
    git -C "$wt_path" commit -q -m "Initial"

    _create_failing_test "$wt_path"
    _create_passing_lint "$wt_path"

    echo '{"repo":"test/repo"}' > "$plan_file"

    export RU_CONFIG_DIR="$env_root/config"
    mkdir -p "$RU_CONFIG_DIR/review-policies.d"

    # Create policy file with test/lint commands
    cat > "$RU_CONFIG_DIR/review-policies.d/test_repo" <<'EOF'
TEST_COMMAND=./run_tests.sh
LINT_COMMAND=./run_lint.sh
EOF

    local result
    result=$(run_quality_gates "$wt_path" "$plan_file")
    local rc=$?

    assert_equals 1 "$rc" "Should return failure when tests fail"

    local overall_ok tests_ok
    overall_ok=$(echo "$result" | jq -r '.overall_ok')
    tests_ok=$(echo "$result" | jq -r '.tests.ok')

    assert_equals "false" "$overall_ok" "overall_ok should be false"
    assert_equals "false" "$tests_ok" "tests.ok should be false"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_run_quality_gates_lint_failure() {
    local test_name="run_quality_gates: returns failure when lint fails"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local wt_path="$env_root/worktree"
    local plan_file="$env_root/review-plan.json"

    mkdir -p "$wt_path"
    git -C "$wt_path" init -q
    echo "Clean" > "$wt_path/README.md"
    git -C "$wt_path" add .
    git -C "$wt_path" commit -q -m "Initial"

    _create_passing_test "$wt_path"
    _create_failing_lint "$wt_path"

    echo '{"repo":"test/repo"}' > "$plan_file"

    export RU_CONFIG_DIR="$env_root/config"
    mkdir -p "$RU_CONFIG_DIR/review-policies.d"

    # Create policy file with test/lint commands
    cat > "$RU_CONFIG_DIR/review-policies.d/test_repo" <<'EOF'
TEST_COMMAND=./run_tests.sh
LINT_COMMAND=./run_lint.sh
EOF

    local result
    result=$(run_quality_gates "$wt_path" "$plan_file")
    local rc=$?

    assert_equals 1 "$rc" "Should return failure when lint fails"

    local overall_ok lint_ok
    overall_ok=$(echo "$result" | jq -r '.overall_ok')
    lint_ok=$(echo "$result" | jq -r '.lint.ok')

    assert_equals "false" "$overall_ok" "overall_ok should be false"
    assert_equals "false" "$lint_ok" "lint.ok should be false"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

test_run_quality_gates_uses_policy_commands() {
    local test_name="run_quality_gates: uses commands from policy"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    local wt_path="$env_root/worktree"
    local plan_file="$env_root/review-plan.json"

    mkdir -p "$wt_path"
    git -C "$wt_path" init -q
    echo "Clean" > "$wt_path/README.md"
    git -C "$wt_path" add .
    git -C "$wt_path" commit -q -m "Initial"

    # Create custom test/lint scripts
    cat > "$wt_path/custom_test.sh" <<'EOF'
#!/usr/bin/env bash
echo "Custom test ran"
exit 0
EOF
    chmod +x "$wt_path/custom_test.sh"

    cat > "$wt_path/custom_lint.sh" <<'EOF'
#!/usr/bin/env bash
echo "Custom lint ran"
exit 0
EOF
    chmod +x "$wt_path/custom_lint.sh"

    # Repo ID in plan: custom/repo -> policy filename: custom_repo
    echo '{"repo":"custom/repo"}' > "$plan_file"

    # Set up policy file with custom commands in correct directory structure
    export RU_CONFIG_DIR="$env_root/config"
    mkdir -p "$RU_CONFIG_DIR/review-policies.d"

    # Policy file name: repo id with / replaced by _
    cat > "$RU_CONFIG_DIR/review-policies.d/custom_repo" <<'EOF'
TEST_COMMAND=./custom_test.sh
LINT_COMMAND=./custom_lint.sh
EOF

    local result
    result=$(run_quality_gates "$wt_path" "$plan_file")

    local test_cmd lint_cmd
    test_cmd=$(echo "$result" | jq -r '.tests.command')
    lint_cmd=$(echo "$result" | jq -r '.lint.command')

    assert_equals "./custom_test.sh" "$test_cmd" "Should use custom test command from policy"
    assert_equals "./custom_lint.sh" "$lint_cmd" "Should use custom lint command from policy"

    cleanup_temp_dirs
    log_test_pass "$test_name"
}

#==============================================================================
# Main
#==============================================================================

run_all_tests() {
    log_suite_start "Quality Gates"

    # detect_test_command tests
    run_test test_detect_test_command_makefile
    run_test test_detect_test_command_npm
    run_test test_detect_test_command_cargo
    run_test test_detect_test_command_python
    run_test test_detect_test_command_go
    run_test test_detect_test_command_shell_script
    run_test test_detect_test_command_empty_returns_failure

    # detect_lint_command tests
    run_test test_detect_lint_command_npm
    run_test test_detect_lint_command_go
    run_test test_detect_lint_command_empty_returns_failure

    # run_test_gate tests
    run_test test_run_test_gate_success
    run_test test_run_test_gate_failure
    run_test test_run_test_gate_no_tests_found
    run_test test_run_test_gate_captures_output_summary
    run_test test_run_test_gate_records_duration

    # run_lint_gate tests
    run_test test_run_lint_gate_success
    run_test test_run_lint_gate_failure
    run_test test_run_lint_gate_no_linter_found

    # run_secret_scan tests
    run_test test_run_secret_scan_clean_project
    run_test test_run_secret_scan_detects_potential_secret
    run_test test_run_secret_scan_reports_tool_used

    # run_quality_gates integration tests
    run_test test_run_quality_gates_all_pass
    run_test test_run_quality_gates_test_failure
    run_test test_run_quality_gates_lint_failure
    run_test test_run_quality_gates_uses_policy_commands

    print_results
    return "$(get_exit_code)"
}

run_all_tests
