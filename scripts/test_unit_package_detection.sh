#!/usr/bin/env bash
#
# Unit tests for package manager detection functions
# Tests: detect_package_managers and dependency scan failure propagation
#
# Covers detection of:
# - npm (package.json, package-lock.json, yarn.lock, pnpm-lock.yaml)
# - pip (pyproject.toml, requirements.txt, setup.py, Pipfile)
# - cargo (Cargo.toml)
# - go (go.mod)
# - composer (composer.json)
# - bundler (Gemfile)
# - maven (pom.xml)
# - gradle (build.gradle, build.gradle.kts)
#
# shellcheck disable=SC2034  # Variables are used by sourced functions from ru
# shellcheck disable=SC1090  # Dynamic sourcing is intentional
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the test framework
source "$SCRIPT_DIR/test_framework.sh"

#==============================================================================
# Environment Setup
#==============================================================================

# Minimal log functions to avoid sourcing all of ru
log_info() { :; }
log_error() { :; }
log_debug() { :; }
log_success() { :; }
log_warn() { :; }

# Extract functions using awk with brace counting
extract_function() {
    local func_name="$1"
    local file="$2"
    awk -v fn="$func_name" '
        $0 ~ "^"fn"\\(\\)" {
            printing=1
            depth=0
        }
        printing {
            print
            for(i=1; i<=length($0); i++) {
                c = substr($0, i, 1)
                if(c == "{") depth++
                if(c == "}") depth--
            }
            if(depth == 0 && /}/) exit
        }
    ' "$file"
}

source <(extract_function "detect_package_managers" "$PROJECT_DIR/ru")
for scan_function in _dep_scan_error _check_outdated_for_manager check_outdated_deps \
    cmd_dep_update _dep_update_skipped_json _filter_outdated_deps _filter_major_updates \
    validate_ai_session_result detect_test_command detect_dep_update_test_command run_test_gate; do
    source_ru_function "$scan_function"
done
# Match the function's complete closing line, not the literal JSON's }'.
source <(sed -n '/^_robot_docs_schemas()/,/^}$/p' "$PROJECT_DIR/ru")

#==============================================================================
# Test Setup/Teardown
#==============================================================================

TEMP_DIR=""

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Helper to create a minimal project structure
create_test_project() {
    local name="$1"
    local project_dir="$TEMP_DIR/$name"
    mkdir -p "$project_dir"
    echo "$project_dir"
}

# Helper to assert JSON contains expected managers
assert_has_manager() {
    local json="$1"
    local manager="$2"
    local msg="${3:-JSON should contain manager '$manager'}"

    if echo "$json" | jq -e ".managers | index(\"$manager\")" &>/dev/null; then
        _tf_pass "$msg"
    else
        _tf_fail "$msg" "Expected manager '$manager' in: $json"
    fi
}

# Helper to assert JSON does not contain a manager
assert_no_manager() {
    local json="$1"
    local manager="$2"
    local msg="${3:-JSON should not contain manager '$manager'}"

    if ! echo "$json" | jq -e ".managers | index(\"$manager\")" &>/dev/null; then
        _tf_pass "$msg"
    else
        _tf_fail "$msg" "Unexpected manager '$manager' in: $json"
    fi
}

# Helper to assert file mapping
assert_file_mapping() {
    local json="$1"
    local manager="$2"
    local expected_file="$3"
    local msg="${4:-File mapping for '$manager' should be '$expected_file'}"

    local actual_file
    actual_file=$(echo "$json" | jq -r ".files.\"$manager\" // empty")

    if [[ "$actual_file" == "$expected_file" ]]; then
        _tf_pass "$msg"
    else
        _tf_fail "$msg" "Expected file '$expected_file', got '$actual_file'"
    fi
}

#==============================================================================
# Test: Invalid input handling
#==============================================================================

test_detect_returns_error_for_empty_path() {
    setup_test_env

    local result
    result=$(detect_package_managers "")
    local exit_code=$?

    assert_equals 1 "$exit_code" "Should return exit code 1 for empty path"
    assert_contains "$result" '"error"' "Output should contain error field"

    cleanup_test_env
}

test_detect_returns_error_for_nonexistent_path() {
    local result
    result=$(detect_package_managers "/nonexistent/path/12345")
    local exit_code=$?

    assert_equals 1 "$exit_code" "Should return exit code 1 for nonexistent path"
    assert_contains "$result" '"error"' "Output should contain error field"
}

test_detect_returns_empty_for_no_managers() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "empty_project")

    local result
    result=$(detect_package_managers "$project_dir")
    local exit_code=$?

    assert_equals 1 "$exit_code" "Should return exit code 1 when no managers found"

    local managers_count
    managers_count=$(echo "$result" | jq '.managers | length')
    assert_equals 0 "$managers_count" "Managers array should be empty"

    cleanup_test_env
}

#==============================================================================
# Test: npm/Node.js detection
#==============================================================================

test_detect_npm_via_package_json() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "npm_project")
    echo '{"name": "test", "version": "1.0.0"}' > "$project_dir/package.json"

    local result
    result=$(detect_package_managers "$project_dir")
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should return exit code 0 for npm project"
    assert_has_manager "$result" "npm" "Should detect npm from package.json"
    assert_file_mapping "$result" "npm" "package.json"

    cleanup_test_env
}

test_detect_npm_via_package_lock() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "npm_lock_project")
    echo '{}' > "$project_dir/package-lock.json"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "npm" "Should detect npm from package-lock.json"
    assert_file_mapping "$result" "npm" "package-lock.json"

    cleanup_test_env
}

test_detect_yarn_via_yarn_lock() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "yarn_project")
    touch "$project_dir/yarn.lock"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "yarn" "Should detect yarn from yarn.lock"
    assert_file_mapping "$result" "yarn" "yarn.lock"

    cleanup_test_env
}

test_detect_pnpm_via_pnpm_lock() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "pnpm_project")
    touch "$project_dir/pnpm-lock.yaml"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "pnpm" "Should detect pnpm from pnpm-lock.yaml"
    assert_file_mapping "$result" "pnpm" "pnpm-lock.yaml"

    cleanup_test_env
}

test_npm_package_json_takes_precedence_over_lock() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "npm_both")
    echo '{"name": "test"}' > "$project_dir/package.json"
    echo '{}' > "$project_dir/package-lock.json"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "npm" "Should detect npm"
    assert_file_mapping "$result" "npm" "package.json" "package.json should take precedence"

    cleanup_test_env
}

#==============================================================================
# Test: Python detection
#==============================================================================

test_detect_pip_via_pyproject() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "python_pyproject")
    echo '[project]' > "$project_dir/pyproject.toml"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "pip" "Should detect pip from pyproject.toml"
    assert_file_mapping "$result" "pip" "pyproject.toml"

    cleanup_test_env
}

test_detect_pip_via_requirements() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "python_requirements")
    echo 'requests==2.28.0' > "$project_dir/requirements.txt"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "pip" "Should detect pip from requirements.txt"
    assert_file_mapping "$result" "pip" "requirements.txt"

    cleanup_test_env
}

test_detect_pip_via_setup_py() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "python_setup")
    echo 'from setuptools import setup; setup()' > "$project_dir/setup.py"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "pip" "Should detect pip from setup.py"
    assert_file_mapping "$result" "pip" "setup.py"

    cleanup_test_env
}

test_detect_pipenv_via_pipfile() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "pipenv_project")
    echo '[[source]]' > "$project_dir/Pipfile"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "pipenv" "Should detect pipenv from Pipfile"
    assert_file_mapping "$result" "pipenv" "Pipfile"

    cleanup_test_env
}

test_pyproject_takes_precedence_over_requirements() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "python_both")
    echo '[project]' > "$project_dir/pyproject.toml"
    echo 'requests' > "$project_dir/requirements.txt"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "pip" "Should detect pip"
    assert_file_mapping "$result" "pip" "pyproject.toml" "pyproject.toml should take precedence"

    cleanup_test_env
}

#==============================================================================
# Test: Rust (cargo) detection
#==============================================================================

test_detect_cargo_via_cargo_toml() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "rust_project")
    echo '[package]' > "$project_dir/Cargo.toml"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "cargo" "Should detect cargo from Cargo.toml"
    assert_file_mapping "$result" "cargo" "Cargo.toml"

    cleanup_test_env
}

#==============================================================================
# Test: Go detection
#==============================================================================

test_detect_go_via_go_mod() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "go_project")
    echo 'module example.com/test' > "$project_dir/go.mod"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "go" "Should detect go from go.mod"
    assert_file_mapping "$result" "go" "go.mod"

    cleanup_test_env
}

#==============================================================================
# Test: PHP (composer) detection
#==============================================================================

test_detect_composer_via_composer_json() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "php_project")
    echo '{"name": "test/test"}' > "$project_dir/composer.json"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "composer" "Should detect composer from composer.json"
    assert_file_mapping "$result" "composer" "composer.json"

    cleanup_test_env
}

#==============================================================================
# Test: Ruby (bundler) detection
#==============================================================================

test_detect_bundler_via_gemfile() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "ruby_project")
    echo 'source "https://rubygems.org"' > "$project_dir/Gemfile"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "bundler" "Should detect bundler from Gemfile"
    assert_file_mapping "$result" "bundler" "Gemfile"

    cleanup_test_env
}

#==============================================================================
# Test: Java (maven) detection
#==============================================================================

test_detect_maven_via_pom_xml() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "maven_project")
    echo '<project></project>' > "$project_dir/pom.xml"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "maven" "Should detect maven from pom.xml"
    assert_file_mapping "$result" "maven" "pom.xml"

    cleanup_test_env
}

#==============================================================================
# Test: Java/Kotlin (gradle) detection
#==============================================================================

test_detect_gradle_via_build_gradle() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "gradle_project")
    echo 'plugins {}' > "$project_dir/build.gradle"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "gradle" "Should detect gradle from build.gradle"
    assert_file_mapping "$result" "gradle" "build.gradle"

    cleanup_test_env
}

test_detect_gradle_via_build_gradle_kts() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "kotlin_gradle_project")
    echo 'plugins {}' > "$project_dir/build.gradle.kts"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "gradle" "Should detect gradle from build.gradle.kts"
    assert_file_mapping "$result" "gradle" "build.gradle.kts"

    cleanup_test_env
}

test_gradle_kts_takes_precedence_over_groovy() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "gradle_both")
    echo 'plugins {}' > "$project_dir/build.gradle"
    echo 'plugins {}' > "$project_dir/build.gradle.kts"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "gradle" "Should detect gradle"
    assert_file_mapping "$result" "gradle" "build.gradle.kts" "Kotlin DSL should take precedence"

    cleanup_test_env
}

#==============================================================================
# Test: Multi-language projects
#==============================================================================

test_detect_multiple_managers_in_polyglot_project() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "polyglot_project")

    # Add multiple package manager files
    echo '{"name": "test"}' > "$project_dir/package.json"
    echo '[project]' > "$project_dir/pyproject.toml"
    echo 'module test' > "$project_dir/go.mod"

    local result
    result=$(detect_package_managers "$project_dir")
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should return exit code 0"
    assert_has_manager "$result" "npm" "Should detect npm"
    assert_has_manager "$result" "pip" "Should detect pip"
    assert_has_manager "$result" "go" "Should detect go"

    local managers_count
    managers_count=$(echo "$result" | jq '.managers | length')
    assert_equals 3 "$managers_count" "Should detect exactly 3 managers"

    cleanup_test_env
}

test_detect_all_supported_managers() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "all_managers")

    # Add all supported package manager files
    echo '{"name": "test"}' > "$project_dir/package.json"
    echo '[project]' > "$project_dir/pyproject.toml"
    echo '[package]' > "$project_dir/Cargo.toml"
    echo 'module test' > "$project_dir/go.mod"
    echo '{"name": "test/test"}' > "$project_dir/composer.json"
    echo 'source "https://rubygems.org"' > "$project_dir/Gemfile"
    echo '<project></project>' > "$project_dir/pom.xml"
    echo 'plugins {}' > "$project_dir/build.gradle"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_has_manager "$result" "npm"
    assert_has_manager "$result" "pip"
    assert_has_manager "$result" "cargo"
    assert_has_manager "$result" "go"
    assert_has_manager "$result" "composer"
    assert_has_manager "$result" "bundler"
    assert_has_manager "$result" "maven"
    assert_has_manager "$result" "gradle"

    local managers_count
    managers_count=$(echo "$result" | jq '.managers | length')
    assert_equals 8 "$managers_count" "Should detect all 8 managers"

    cleanup_test_env
}

#==============================================================================
# Test: JSON output format
#==============================================================================

test_output_is_valid_json() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "json_test")
    echo '{"name": "test"}' > "$project_dir/package.json"

    local result
    result=$(detect_package_managers "$project_dir")

    if echo "$result" | jq . &>/dev/null; then
        _tf_pass "Output should be valid JSON"
    else
        _tf_fail "Output should be valid JSON" "Got: $result"
    fi

    cleanup_test_env
}

test_output_has_required_fields() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "fields_test")
    echo '{"name": "test"}' > "$project_dir/package.json"

    local result
    result=$(detect_package_managers "$project_dir")

    assert_contains "$result" '"managers"' "Output should contain 'managers' field"
    assert_contains "$result" '"files"' "Output should contain 'files' field"

    cleanup_test_env
}

#==============================================================================
# Dependency scan contracts. Controlled commands prove status/JSON handling,
# not registry availability, installed project dependencies, or AI updates.
# These cases need no temporary files and isolate command doubles in subshells.
#==============================================================================

assert_dep_scan_result() {
    local result="$1" actual_rc="$2" expected_rc="$3" predicate="$4" message="$5"
    assert_equals "$expected_rc" "$actual_rc" "$message: exit status"
    # Stream to a concurrent reader: a here-string can block in Bash's
    # pre-exec heredoc write on this host even for a modest caller result.
    if printf '%s\n' "$result" | jq -se "length == 1 and (.[0] | $predicate)" >/dev/null; then
        _tf_pass "$message: result"
    else
        _tf_fail "$message: result" "Got: $result"
    fi
}

test_dep_scan_npm_contract() {
    (
        local scan_failures_before=$TF_ASSERTIONS_FAILED
        npm() {
            [[ "$PWD" == "$PROJECT_DIR" && "$*" == 'outdated --json' ]] || return 91
            printf '%s' "$scan_payload"
            return "$scan_tool_rc"
        }
        local scan_payload='{}' scan_tool_rc=0 result rc
        result=$(check_outdated_deps "$PROJECT_DIR" npm); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.status == "ok" and .total_outdated == 0 and .failed_managers == 0' "npm verified current"

        scan_payload='{"example":{"current":"1.0.0","wanted":"1.1.0","latest":"1.1.0"}}'
        scan_tool_rc=1
        result=$(check_outdated_deps "$PROJECT_DIR" npm); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.total_outdated == 1 and .results[0].outdated[0].name == "example"' "npm outdated exit 1"

        scan_payload='{"error":[{"current":"1.0.0","wanted":"1.1.0","latest":"1.1.0"},{"wanted":"1.2.0","latest":"1.2.0"}]}'
        result=$(check_outdated_deps "$PROJECT_DIR" npm); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.total_outdated == 2 and .results[0].outdated[1].current == "MISSING"' "npm workspace duplicates and missing install"

        local bad_payload
        for bad_payload in '' '{' '[]' '{} {}' \
            '{"error":{"code":"E403","summary":"registry refused"}}' \
            '{"example":{"current":"1","wanted":"2","latest":null}}' '{"example":[]}'; do
            scan_payload="$bad_payload"
            result=$(check_outdated_deps "$PROJECT_DIR" npm); rc=$?
            assert_dep_scan_result "$result" "$rc" 3 \
                '.status == "error" and .failed_managers == 1 and .results[0].error_code == "invalid_output"' \
                "npm refuses invalid payload $bad_payload"
        done
        scan_payload='{}'
        result=$(check_outdated_deps "$PROJECT_DIR" npm); rc=$?
        assert_dep_scan_result "$result" "$rc" 3 \
            '.results[0].error_code == "command_failed"' "npm exit 1 requires outdated records"

        scan_tool_rc=2
        scan_payload='{"example":{"current":"1","wanted":"2","latest":"2"}}'
        result=$(check_outdated_deps "$PROJECT_DIR" npm); rc=$?
        assert_dep_scan_result "$result" "$rc" 3 \
            '.results[0].error_code == "command_failed"' "npm partial output with command failure"
        [[ "$TF_ASSERTIONS_FAILED" -eq "$scan_failures_before" ]]
    )
}

test_dep_scan_other_manager_contracts() {
    (
        local scan_failures_before=$TF_ASSERTIONS_FAILED
        cargo-outdated() { return 0; }
        cargo() { printf '%s' "$scan_payload"; return "$scan_tool_rc"; }
        go() { printf '%s' "$scan_payload"; return "$scan_tool_rc"; }
        composer() { printf '%s' "$scan_payload"; return "$scan_tool_rc"; }
        # Also contain historical adapters when running these same controls
        # against a prior ru revision. They must never reach a real tool.
        npm() { return 42; }
        pip() { return 42; }
        bundle() { return 42; }
        mvn() { return 42; }
        local scan_payload scan_tool_rc=0 result rc manager
        for manager in cargo go composer; do
            case "$manager" in
                cargo) scan_payload='{"crate_name":"app","dependencies":[{"name":"example","project":"1.0.0","compat":"1.1.0","latest":"1.1.0","kind":"Normal","platform":null}]}' ;;
                go) scan_payload=$'{"Path":"example/main","Main":true}\n{"Path":"example/dep","Version":"v1.0.0","Update":{"Version":"v1.1.0"}}' ;;
                composer) scan_payload='{"installed":[{"name":"example/pkg","version":"1.0.0","latest":"1.1.0"}]}' ;;
            esac
            scan_tool_rc=0
            result=$(check_outdated_deps "$PROJECT_DIR" "$manager"); rc=$?
            assert_dep_scan_result "$result" "$rc" 0 \
                '.status == "ok" and .total_outdated == 1' "$manager valid outdated"
            scan_tool_rc=42
            result=$(check_outdated_deps "$PROJECT_DIR" "$manager"); rc=$?
            assert_dep_scan_result "$result" "$rc" 3 \
                '.results[0].error_code == "command_failed"' "$manager partial output refused"
            scan_tool_rc=0 scan_payload='{}'
            result=$(check_outdated_deps "$PROJECT_DIR" "$manager"); rc=$?
            assert_dep_scan_result "$result" "$rc" 3 \
                '.results[0].error_code == "invalid_output"' "$manager wrong schema refused"
            case "$manager" in
                cargo) scan_payload='{"crate_name":"app","dependencies":[]}' ;;
                go) scan_payload='{"Path":"example/main","Main":true}' ;;
                composer) scan_payload='{"installed":[]}' ;;
            esac
            result=$(check_outdated_deps "$PROJECT_DIR" "$manager"); rc=$?
            assert_dep_scan_result "$result" "$rc" 1 \
                '.status == "ok" and .total_outdated == 0' "$manager valid current"
        done
        scan_payload='{"Path":"example/dep","Version":"v1.0.0","Error":{"Err":"registry unavailable"}}'
        result=$(check_outdated_deps "$PROJECT_DIR" go); rc=$?
        assert_dep_scan_result "$result" "$rc" 3 \
            '.results[0].error_code == "invalid_output"' "Go embedded registry error"

        for manager in pip pipenv yarn pnpm bundler maven gradle unknown; do
            result=$(check_outdated_deps "$PROJECT_DIR" "$manager"); rc=$?
            assert_dep_scan_result "$result" "$rc" 3 \
                '.status == "error" and .failed_managers == 1 and (.results[0].error | length > 0)' \
                "$manager is an explicit limitation"
        done
        [[ "$TF_ASSERTIONS_FAILED" -eq "$scan_failures_before" ]]
    )
}

test_dep_scan_cargo_workspace_contract() {
    (
        local scan_failures_before=$TF_ASSERTIONS_FAILED result rc bad_payload
        local scan_tool_rc=0 scan_check_args=false
        cargo-outdated() { return 0; }
        cargo() {
            if [[ "$scan_check_args" == true &&
                ( "$PWD" != "$PROJECT_DIR" || "$*" != 'outdated --workspace --root-deps-only --format json' ) ]]; then
                return 91
            fi
            printf '%s' "$scan_payload"
            return "$scan_tool_rc"
        }
        local current='{"crate_name":"gamma","dependencies":[]}'
        local alpha='{"crate_name":"alpha","dependencies":[{"name":"shared","project":"1.0.0","compat":"---","latest":"1.2.0","kind":"Normal","platform":null},{"name":"major_dep","project":"1.0.0","compat":"1.5.0","latest":"2.0.0","kind":"Development","platform":"cfg(windows)"}]}'
        local beta='{"crate_name":"beta","dependencies":[{"name":"shared","project":"2.0.0","compat":"2.1.0","latest":"2.1.0","kind":"Build","platform":"cfg(unix)"}]}'
        local workspace="$alpha"$'\n'"$beta"$'\n'"$current"
        local scan_payload="$current"
        result=$(check_outdated_deps "$PROJECT_DIR" cargo); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.status == "ok" and .total_outdated == 0' "Cargo single member current"
        scan_payload="$beta"
        result=$(check_outdated_deps "$PROJECT_DIR" cargo); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.total_outdated == 1 and .results[0].outdated[0] == {name:"shared",current:"2.0.0",latest:"2.1.0",compat:"2.1.0",kind:"Build",platform:"cfg(unix)",crate_name:"beta"}' \
            "Cargo single member retains complete context"
        scan_payload="$current"$'\n''{"crate_name":"delta","dependencies":[]}'
        result=$(check_outdated_deps "$PROJECT_DIR" cargo); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.status == "ok" and .total_outdated == 0' "Cargo multiple current members"
        scan_payload="$workspace"
        result=$(check_outdated_deps "$PROJECT_DIR" cargo); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.total_outdated == 3 and (.results[0].outdated | map(.crate_name)) == ["alpha","alpha","beta"]
             and (.results[0].outdated | map(select(.name == "shared")) | length) == 2
             and .results[0].outdated[0].compat == "---" and .results[0].outdated[0].platform == null
             and .results[0].outdated[1].kind == "Development" and .results[0].outdated[1].platform == "cfg(windows)"' \
            "Cargo workspace preserves duplicate names and member contexts"
        scan_payload=$(jq -c '.dependencies[0].project="2.0.0-rc.1+b.5" | .dependencies[0].latest="2.1.0-rc.2+b.6"' <<< "$beta")
        result=$(check_outdated_deps "$PROJECT_DIR" cargo); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.total_outdated == 1 and .results[0].outdated[0].latest == "2.1.0-rc.2+b.6"' "Cargo prerelease plus build metadata"
        scan_payload=$(jq -c '.crate_name="résumé_app" | .dependencies[0].name="résumé_crate" | .dependencies[0].latest="2.1.0-0.3a+001"' <<< "$beta")
        result=$(check_outdated_deps "$PROJECT_DIR" cargo); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.total_outdated == 1 and .results[0].outdated[0].name == "résumé_crate"
             and .results[0].outdated[0].crate_name == "résumé_app" and .results[0].outdated[0].latest == "2.1.0-0.3a+001"' \
            "Cargo Unicode names and numeric build metadata remain usable"

        local scan_bad_case=0
        for bad_payload in '' '{}' '[]' '{"crate_name":"","dependencies":[]}' \
            '{"crate_name":"app","dependencies":null}' \
            "$current"$'\n''{"crate_name":"broken","dependencies":[{}]}' \
            "$current"$'\n''{"crate_name":"truncated"' \
            "$current"$'\n'"$current" \
            "$(jq -c '.dependencies[0].latest="---"' <<< "$beta")" \
            "$(jq -c '.dependencies[0].latest="Removed"' <<< "$beta")" \
            "$(jq -c '.dependencies[0].compat=null' <<< "$beta")" \
            "$(jq -c '.dependencies[0].kind={}' <<< "$beta")" \
            "$(jq -c '.dependencies[0].platform=[]' <<< "$beta")" \
            "$(jq -c '.dependencies[0].name="parent->child"' <<< "$beta")" \
            "$(jq -c '.dependencies[0].name="bad name"' <<< "$beta")" \
            "$(jq -c '.dependencies[0].name="bad\nname"' <<< "$beta")" \
            "$(jq -c '.dependencies[0].project="01.2.3"' <<< "$beta")" \
            "$(jq -c '.dependencies[0].latest="1.2.3-01"' <<< "$beta")" \
            "$(jq -c '.dependencies[0].latest="1.2.3\n"' <<< "$beta")"; do
            ((scan_bad_case+=1))
            scan_payload="$bad_payload"
            result=$(check_outdated_deps "$PROJECT_DIR" cargo); rc=$?
            assert_dep_scan_result "$result" "$rc" 3 \
                '.status == "error" and .results[0].error_code == "invalid_output"' "Cargo invalid stream $scan_bad_case refused"
        done
        scan_payload="$beta" scan_tool_rc=42
        result=$(check_outdated_deps "$PROJECT_DIR" cargo); rc=$?
        assert_dep_scan_result "$result" "$rc" 3 \
            '.results[0].error_code == "command_failed"' "Cargo valid partial member on failure"
        scan_tool_rc=0 scan_check_args=true
        result=$(check_outdated_deps "$PROJECT_DIR" cargo); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.total_outdated == 1' "Cargo executes workspace direct-dependency scan in repository"
        scan_check_args=false

        # Exercise the real caller and filters, with only tool/agent boundaries
        # controlled. No dependency update, Cargo execution or AI proof claimed.
        detect_package_managers() { printf '%s\n' '{"managers":["cargo"]}'; }
        ntm() { return 92; }
        claude() { return 93; }
        run_dep_update_transactions() { printf 'UNEXPECTED transaction\n' >&2; return 94; }
        local JSON_OUTPUT=true ARGS=(--dry-run "--repo=$PROJECT_DIR")
        scan_payload="$workspace"
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.processed == 1 and .failed == 0 and .results[0].outdated.total_outdated == 2
             and (.results[0].outdated.results[0].outdated | map(.crate_name)) == ["alpha","beta"]' \
            "Cargo caller retains both members through default minor filter"
        ARGS=(--dry-run --major "--repo=$PROJECT_DIR")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.results[0].outdated.total_outdated == 3 and .results[0].outdated.results[0].outdated[1].platform == "cfg(windows)"' \
            "Cargo caller major opt-in preserves target context"
        ARGS=(--dry-run --major '--include=^major_dep$' "--repo=$PROJECT_DIR")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.results[0].outdated.total_outdated == 1 and .results[0].outdated.results[0].outdated[0].crate_name == "alpha"' \
            "Cargo caller name filter retains member identity"
        ARGS=(--dry-run --major '--exclude=.' "--repo=$PROJECT_DIR")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.processed == 0 and .skipped == 1 and .failed == 0' "Cargo caller all updates explicitly excluded"
        ARGS=(--dry-run --major "--repo=$PROJECT_DIR")
        scan_payload="$current"$'\n''{"crate_name":"delta","dependencies":[]}'
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.processed == 0 and .skipped == 1 and .failed == 0 and .results[0].reason == "no outdated dependencies"' \
            "Cargo caller skips current multi-member scan"
        scan_payload="$beta" scan_tool_rc=42
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .processed == 0 and .results[0].scan.results[0].error_code == "command_failed"' \
            "Cargo caller refuses partial member result"
        scan_tool_rc=0
        scan_payload=$(jq -c '.dependencies[0].latest="---"' <<< "$beta")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .processed == 0 and .results[0].scan.results[0].error_code == "invalid_output"' \
            "Cargo caller major opt-in cannot pass status marker to an update"
        scan_payload=$(jq -c '.dependencies[0].name="parent->child"' <<< "$beta")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .processed == 0 and .results[0].scan.results[0].error_code == "invalid_output"' \
            "Cargo caller cannot pass transitive label to a manifest update"
        [[ "$TF_ASSERTIONS_FAILED" -eq "$scan_failures_before" ]]
    )
}

# Real manifest reads, caller selection and host gate execution; Cargo and AI
# remain controlled boundaries. A supplied root retains every generated file.
test_cargo_workspace_test_command() {
    local retained_root="${1:-}" fixture_root created_fixture=false
    if [[ -n "$retained_root" ]]; then
        fixture_root=$(mktemp -d "$retained_root/cargo-test-scope.XXXXXX") || return 1
    else
        setup_test_env
        fixture_root="$TEMP_DIR"
        created_fixture=true
    fi
    mkdir -p "$fixture_root/standalone/src" "$fixture_root/rooted/member/src" \
        "$fixture_root/rooted/src" "$fixture_root/virtual/member/src" \
        "$fixture_root/virtual/primary/src" "$fixture_root/npm-mixed/src" \
        "$fixture_root/make-mixed/src" "$fixture_root/empty" || return 1
    printf '[package]\nname="app"\nversion="0.1.0"\n' > "$fixture_root/standalone/Cargo.toml"
    printf '[package]\nname="app"\nversion="0.1.0"\n[workspace]\nmembers=["member"]\ndefault-members=["."]\n' > "$fixture_root/rooted/Cargo.toml"
    printf '[workspace]\nmembers=["primary","member"]\ndefault-members=["primary"]\n' > "$fixture_root/virtual/Cargo.toml"
    printf '[package]\nname="member"\nversion="0.1.0"\n' > "$fixture_root/rooted/member/Cargo.toml"
    printf '[package]\nname="member"\nversion="0.1.0"\n' > "$fixture_root/virtual/member/Cargo.toml"
    printf '[package]\nname="primary"\nversion="0.1.0"\n' > "$fixture_root/virtual/primary/Cargo.toml"
    printf '[package]\nname="app"\nversion="0.1.0"\n' > "$fixture_root/npm-mixed/Cargo.toml"
    printf '[package]\nname="app"\nversion="0.1.0"\n' > "$fixture_root/make-mixed/Cargo.toml"
    printf '{"scripts":{"test":"echo node-test"}}\n' > "$fixture_root/npm-mixed/package.json"
    printf 'test:\n\ttrue\n' > "$fixture_root/make-mixed/Makefile"
    local package_path
    for package_path in standalone rooted rooted/member virtual/primary virtual/member npm-mixed make-mixed; do
        printf '#[test]\nfn sample() { assert_eq!(2 + 2, 4); }\n' > "$fixture_root/$package_path/src/lib.rs"
    done
    (
        local scan_failures_before=$TF_ASSERTIONS_FAILED kind result rc
        local JSON_OUTPUT=true ARGS=()
        log_warn() { :; }
        log_success() { :; }
        log_verbose() { :; }
        cargo-outdated() { return 0; }
        cargo() {
            if [[ "${1:-}" == outdated ]]; then
                printf '{"crate_name":"app","dependencies":[{"name":"example","project":"1.0.0","compat":"1.1.0","latest":"1.1.0","kind":"Normal","platform":null}]}\n'
            else
                { pwd -P; printf '%s\n' "$@"; } > "$RU_SCOPE_TRACE"
                printf 'controlled Cargo argv: %s\n' "$*"
                printf 'controlled Cargo boundary\n' >&2
                return "$RU_SCOPE_CARGO_RC"
            fi
        }
        ntm() { return 92; }
        claude() { return 93; }
        run_dep_update_transactions() {
            local repo="$1" plan="$2" command="$3" no_push="$6"
            # Stop at this boundary; never fabricate completed work or tests.
            jq -cn --arg repo "$(cd "$repo" && pwd -P)" --arg command "$command" \
                --argjson plan "$plan" --argjson no_push "$no_push" \
                '{repo:$repo,status:"failed",exit_code:2,deps_updated:0,dependencies:[],
                  deps_outdated_before:$plan.total_outdated,
                  publication:{no_push:$no_push,status:"not_requested"},
                  error:"Controlled transaction boundary",observed_command:$command,observed_plan:$plan}'
            return 2
        }
        for kind in standalone rooted virtual rooted/member; do
            result=$(detect_test_command "$fixture_root/$kind"); rc=$?
            assert_equals 0 "$rc" "$kind detects Rust tests"
            assert_equals 'cargo test --workspace' "$result" "$kind selects every workspace member"
            ARGS=(--major --no-push "--repo=$fixture_root/$kind")
            result=$(cmd_dep_update); rc=$?
            assert_dep_scan_result "$result" "$rc" 1 \
                '.failed == 1 and .updated == 0 and .results[0].error == "Controlled transaction boundary"
                 and .results[0].observed_command == "cargo test --workspace"
                 and .results[0].observed_plan.total_outdated == 1
                 and .results[0].observed_plan.results[0].manager == "cargo"
                 and .results[0].publication.no_push == true' "$kind caller forwards automatic command"
        done
        result=$(detect_test_command "$fixture_root/npm-mixed"); rc=$?
        assert_equals 0 "$rc" "mixed npm manifest detects tests"
        assert_equals 'npm test' "$result" "npm test retains precedence over Cargo"
        result=$(detect_test_command "$fixture_root/make-mixed"); rc=$?
        assert_equals 0 "$rc" "Cargo plus Makefile detects tests"
        assert_equals 'cargo test --workspace' "$result" "Cargo retains precedence over Makefile"
        result=$(detect_test_command "$fixture_root/empty"); rc=$?
        assert_equals 1 "$rc" "empty project still has no detected tests"
        assert_equals '' "$result" "empty project does not fabricate a command"
        ARGS=(--major --no-push '--test-cmd=printf explicit-test' "--repo=$fixture_root/rooted")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.results[0].error == "Controlled transaction boundary" and .results[0].observed_command == "printf explicit-test"
             and .results[0].observed_plan.total_outdated == 1' "explicit command overrides automatic workspace command"
        ARGS=(--major --no-push --test-cmd= "--repo=$fixture_root/rooted")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .results[0].error_code == "test_command_unavailable"' "explicit blank command still fails"

        # Execute the actual standalone host gate. The child Cargo function is
        # a command-boundary double, not a compiler or workspace-test simulator.
        export -f cargo
        export RU_SCOPE_TRACE RU_SCOPE_CARGO_RC
        for RU_SCOPE_CARGO_RC in 0 7; do
            RU_SCOPE_TRACE="$fixture_root/gate-$RU_SCOPE_CARGO_RC.trace"
            result=$(run_test_gate "$fixture_root/rooted" '' 10); rc=$?
            assert_dep_scan_result "$result" "$rc" "$RU_SCOPE_CARGO_RC" \
                ".ran == true and .exit_code == $RU_SCOPE_CARGO_RC and .ok == ($RU_SCOPE_CARGO_RC == 0)
                 and .command == \"cargo test --workspace\"" "host gate preserves command and actual child exit $RU_SCOPE_CARGO_RC"
            assert_equals $'test\n--workspace' "$(tail -n +2 "$RU_SCOPE_TRACE")" "host gate child receives both Cargo arguments ($RU_SCOPE_CARGO_RC)"
            assert_equals "$(cd "$fixture_root/rooted" && pwd -P)" "$(head -n 1 "$RU_SCOPE_TRACE")" "host gate child runs in repository ($RU_SCOPE_CARGO_RC)"
        done
        [[ "$TF_ASSERTIONS_FAILED" -eq "$scan_failures_before" ]]
    )
    local result_rc=$?
    if [[ "$created_fixture" == true ]]; then cleanup_test_env; fi
    return "$result_rc"
}

# Real manifest selection and shell command chaining with controlled tool/AI
# boundaries. No package manager, compiler, registry or AI work is exercised.
test_dep_update_manager_test_selection() {
    local retained_root="${1:-}" fixture_root created_fixture=false
    if [[ -n "$retained_root" ]]; then
        fixture_root=$(mktemp -d "$retained_root/manager-tests.XXXXXX") || return 1
    else
        setup_test_env
        fixture_root="$TEMP_DIR"
        created_fixture=true
    fi
    mkdir -p "$fixture_root/project/src" "$fixture_root/no-npm-tests" "$fixture_root/no-go-tests" || return 1
    printf '{"scripts":{"test":"echo node-test"}}\n' > "$fixture_root/project/package.json"
    printf '[package]\nname="app"\nversion="0.1.0"\n' > "$fixture_root/project/Cargo.toml"
    printf '#[test]\nfn sample() { assert_eq!(2 + 2, 4); }\n' > "$fixture_root/project/src/lib.rs"
    printf 'module example.test/app\ngo 1.24\n' > "$fixture_root/project/go.mod"
    printf 'package app\nimport "testing"\nfunc TestExample(t *testing.T) {}\n' > "$fixture_root/project/example_test.go"
    printf '{"scripts":{"test":"echo php-test"}}\n' > "$fixture_root/project/composer.json"
    printf '{}\n' > "$fixture_root/no-npm-tests/package.json"
    printf '[package]\nname="fallback"\nversion="0.1.0"\n' > "$fixture_root/no-npm-tests/Cargo.toml"
    printf '{"scripts":{"test":"echo node-test"}}\n' > "$fixture_root/no-go-tests/package.json"
    printf 'module example.test/no_tests\ngo 1.24\n' > "$fixture_root/no-go-tests/go.mod"
    (
        local scan_failures_before=$TF_ASSERTIONS_FAILED result rc manager expected scan bad_scan
        local planned_managers='npm cargo go composer' compound npm_latest=1.1.0
        local JSON_OUTPUT=true ARGS=()
        log_warn() { :; }
        log_success() { :; }
        log_verbose() { :; }
        record_manager_test() {
            local tool="$1"
            shift
            printf '%s:%s\n' "$tool" "$*" >> "$RU_MANAGER_TEST_TRACE"
            printf 'controlled %s test child\n' "$tool"
            printf 'controlled %s stderr\n' "$tool" >&2
            [[ "$RU_MANAGER_FAIL" != "$tool" ]] || return 7
        }
        npm() {
            if [[ "${1:-}" == outdated ]]; then
                if [[ " $planned_managers " == *' npm '* ]]; then
                    printf '{"node_dep":{"current":"1.0.0","wanted":"%s","latest":"%s"}}\n' "$npm_latest" "$npm_latest"; return 1
                fi
                printf '{}\n'
            else record_manager_test npm "$@"; fi
        }
        cargo-outdated() { return 0; }
        cargo() {
            if [[ "${1:-}" == outdated ]]; then
                if [[ " $planned_managers " == *' cargo '* ]]; then
                    printf '{"crate_name":"app","dependencies":[{"name":"rust_dep","project":"1.0.0","compat":"1.1.0","latest":"1.1.0","kind":"Normal","platform":null}]}\n'
                else printf '{"crate_name":"app","dependencies":[]}\n'; fi
            else record_manager_test cargo "$@"; fi
        }
        go() {
            if [[ "${1:-}" == list ]]; then
                if [[ " $planned_managers " == *' go '* ]]; then
                    printf '{"Path":"example.test/dep","Version":"v1.0.0","Update":{"Version":"v1.1.0"}}\n'
                else printf '{"Path":"example.test/app","Main":true}\n'; fi
            else record_manager_test go "$@"; fi
        }
        composer() {
            if [[ "${1:-}" == outdated ]]; then
                if [[ " $planned_managers " == *' composer '* ]]; then
                    printf '{"installed":[{"name":"example/vendor","version":"1.0.0","latest":"1.1.0"}]}\n'
                else printf '{"installed":[]}\n'; fi
            else record_manager_test composer "$@"; fi
        }
        ntm() { return 92; }
        claude() { return 93; }
        run_dep_update_transactions() {
            local repo="$1" plan="$2" command="$3" no_push="$6"
            jq -cn --arg repo "$(cd "$repo" && pwd -P)" --arg command "$command" \
                --argjson plan "$plan" --argjson no_push "$no_push" \
                '{repo:$repo,status:"failed",exit_code:2,deps_updated:0,dependencies:[],
                  deps_outdated_before:$plan.total_outdated,
                  publication:{no_push:$no_push,status:"not_requested"},
                  error:"Controlled transaction boundary",observed_command:$command,observed_plan:$plan}'
            return 2
        }
        result=$(detect_test_command "$fixture_root/project"); rc=$?
        assert_equals 0 "$rc" "general mixed-project detection succeeds"
        assert_equals 'npm test' "$result" "general callers retain npm precedence"
        for manager in npm cargo go composer; do
            case "$manager" in
                npm) expected='npm test' ;;
                cargo) expected='cargo test --workspace' ;;
                go) expected='go test ./...' ;;
                composer) expected='composer test' ;;
            esac
            result=$(detect_test_command "$fixture_root/project" "$manager"); rc=$?
            assert_equals 0 "$rc" "$manager-specific detection succeeds"
            assert_equals "$expected" "$result" "$manager-specific detection ignores unrelated manifests"
        done
        result=$(detect_test_command "$fixture_root/project" unknown); rc=$?
        assert_equals 1 "$rc" "unknown manager cannot use a generic runner"
        assert_equals '' "$result" "unknown manager emits no test command"

        ARGS=(--major --no-push "--repo=$fixture_root/project")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .updated == 0 and .results[0].observed_command == "npm test && cargo test --workspace && go test ./... && composer test"
             and .results[0].observed_plan.total_outdated == 4
             and .results[0].publication.no_push == true' "mixed updates forward all four suites once"
        compound=$(printf '%s\n' "$result" | jq -r '.results[0].observed_command')
        ARGS=(--major --no-push --manager=cargo "--repo=$fixture_root/project")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.results[0].observed_command == "cargo test --workspace"' "Cargo-only manager filter selects Cargo tests in mixed project"
        ARGS=(--major --no-push "--repo=$fixture_root/project")
        planned_managers=cargo
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.results[0].observed_command == "cargo test --workspace"' "current managers do not select unrelated suites"
        planned_managers='npm cargo go composer'
        ARGS=(--major --no-push '--include=^rust_dep$' "--repo=$fixture_root/project")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.results[0].observed_command == "cargo test --workspace"' "name filtering removes unrelated managers from test selection"
        npm_latest=2.0.0
        ARGS=(--no-push "--repo=$fixture_root/project")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.results[0].observed_command == "cargo test --workspace && go test ./... && composer test"' "major filtering removes managers without remaining updates"
        npm_latest=1.1.0
        scan=$(check_outdated_deps "$fixture_root/project")
        scan=$(printf '%s\n' "$scan" | jq -c '.results += [.results[] | select(.manager == "cargo")]')
        result=$(detect_dep_update_test_command "$fixture_root/project" "$scan"); rc=$?
        assert_equals 0 "$rc" "repeated manager records remain usable"
        assert_equals 'npm test && cargo test --workspace && go test ./... && composer test' "$result" "repeated manager records select one suite"
        for bad_scan in '{"status":"error"}' \
            '{"status":"ok","failed_managers":0,"results":[{"status":"ok","manager":"","outdated":[{}]}]}' \
            '{"status":"ok","failed_managers":0,"results":[{"status":"ok","manager":"unknown","outdated":[{}]}]}' \
            '{"status":"ok","failed_managers":0,"results":[]}' \
            "$scan"$'\n'"$scan"; do
            result=$(detect_dep_update_test_command "$fixture_root/project" "$bad_scan"); rc=$?
            assert_equals 1 "$rc" "invalid or empty manager plan cannot select tests"
            assert_equals '' "$result" "invalid plan emits no partial command"
        done
        ARGS=(--major --no-push --manager=npm "--repo=$fixture_root/no-npm-tests")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .results[0].error_code == "test_command_unavailable"' "missing npm suite cannot fall back to Cargo tests"
        ARGS=(--major --no-push --manager=go "--repo=$fixture_root/no-go-tests")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .results[0].error_code == "test_command_unavailable"' "missing Go suite cannot fall back to npm tests"
        ARGS=(--major --no-push --manager=go '--test-cmd=printf custom-test' "--repo=$fixture_root/no-go-tests")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.results[0].observed_command == "printf custom-test"' "explicit project suite replaces automatic manager selection"
        ARGS=(--major --no-push --test-cmd= "--repo=$fixture_root/project")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .results[0].error_code == "test_command_unavailable"' "blank explicit command still blocks update"

        export -f record_manager_test npm cargo go composer
        export RU_MANAGER_TEST_TRACE RU_MANAGER_FAIL
        for RU_MANAGER_FAIL in '' npm cargo go composer; do
            RU_MANAGER_TEST_TRACE="$fixture_root/child-${RU_MANAGER_FAIL:-none}.trace"
            case "$RU_MANAGER_FAIL" in
                '') expected=$'npm:test\ncargo:test --workspace\ngo:test ./...\ncomposer:test' ;;
                npm) expected='npm:test' ;;
                cargo) expected=$'npm:test\ncargo:test --workspace' ;;
                go) expected=$'npm:test\ncargo:test --workspace\ngo:test ./...' ;;
                composer) expected=$'npm:test\ncargo:test --workspace\ngo:test ./...\ncomposer:test' ;;
            esac
            result=$(run_test_gate "$fixture_root/project" "$compound" 10); rc=$?
            if [[ -z "$RU_MANAGER_FAIL" ]]; then
                assert_dep_scan_result "$result" "$rc" 0 '.ran == true and .ok == true and .exit_code == 0' "all selected tool boundaries execute successfully"
            else
                assert_dep_scan_result "$result" "$rc" 7 '.ran == true and .ok == false and .exit_code == 7' "$RU_MANAGER_FAIL failure survives the actual host gate"
            fi
            assert_equals "$expected" "$(cat "$RU_MANAGER_TEST_TRACE")" "actual child order stops at ${RU_MANAGER_FAIL:-no failure}"
        done
        [[ "$TF_ASSERTIONS_FAILED" -eq "$scan_failures_before" ]]
    )
    local result_rc=$?
    if [[ "$created_fixture" == true ]]; then cleanup_test_env; fi
    return "$result_rc"
}

test_dep_scan_missing_tools_and_partial_results() {
    (
        local scan_failures_before=$TF_ASSERTIONS_FAILED
        local scan_missing=jq result rc
        npm() { return 42; }
        cargo() { return 42; }
        command() {
            if [[ "$1" == -v && "${2:-}" == "$scan_missing" ]]; then return 1; fi
            builtin command "$@"
        }
        result=$(check_outdated_deps "$PROJECT_DIR" npm); rc=$?
        assert_dep_scan_result "$result" "$rc" 3 '.error_code == "missing_tool"' "missing jq"
        scan_missing=npm
        result=$(check_outdated_deps "$PROJECT_DIR" npm); rc=$?
        assert_dep_scan_result "$result" "$rc" 3 '.results[0].error_code == "missing_tool"' "missing npm"
        scan_missing=cargo-outdated
        result=$(check_outdated_deps "$PROJECT_DIR" cargo); rc=$?
        assert_dep_scan_result "$result" "$rc" 3 '.results[0].error_code == "missing_tool"' "missing cargo-outdated"
        scan_missing=''
        npm() { printf '%s\n' '{"example":{"current":"1","wanted":"2","latest":"2"}}'; return 1; }
        detect_package_managers() { printf '%s\n' '{"managers":["npm","gradle"]}'; }
        local manager=outer-sentinel
        result=$(check_outdated_deps "$PROJECT_DIR"); rc=$?
        assert_dep_scan_result "$result" "$rc" 3 \
            '.total_outdated == 1 and .failed_managers == 1 and (.results | length == 2)' "mixed-manager failure preserves partial results"
        # Command substitution isolates variables even in a broken scanner.
        # Call directly so this assertion can actually detect the old leak.
        check_outdated_deps "$PROJECT_DIR" >/dev/null; rc=$?
        assert_equals outer-sentinel "$manager" "scanner does not leak its loop variable"
        detect_package_managers() { printf '%s\n' '{"managers":["npm"]}'; return 42; }
        result=$(check_outdated_deps "$PROJECT_DIR"); rc=$?
        assert_dep_scan_result "$result" "$rc" 3 '.error_code == "detection_failed"' "partial detection failure"
        detect_package_managers() { printf '%s\n' '{"managers":[]}'; return 1; }
        result=$(check_outdated_deps "$PROJECT_DIR"); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 '.status == "ok" and .total_outdated == 0' "no detected managers"
        detect_package_managers() { printf '%s\n' '{"managers":null}'; }
        result=$(check_outdated_deps "$PROJECT_DIR"); rc=$?
        assert_dep_scan_result "$result" "$rc" 3 '.error_code == "detection_failed"' "malformed detection result"
        result=$(check_outdated_deps "${PROJECT_DIR}/does-not-exist-scan-fixture" npm); rc=$?
        assert_dep_scan_result "$result" "$rc" 3 '.error_code == "invalid_repo"' "invalid repository"
        [[ "$TF_ASSERTIONS_FAILED" -eq "$scan_failures_before" ]]
    )
}

test_dep_update_counts_scan_failure() {
    (
        local scan_failures_before=$TF_ASSERTIONS_FAILED
        ntm() { printf 'UNEXPECTED ntm execution\n' >&2; return 92; }
        claude() { printf 'UNEXPECTED agent execution\n' >&2; return 93; }
        run_dep_update_transactions() { printf 'UNEXPECTED transaction\n' >&2; return 94; }
        detect_package_managers() { printf '%s\n' '{"managers":["npm"]}'; }
        npm() { printf '%s' "$scan_payload"; return "$scan_tool_rc"; }
        local JSON_OUTPUT=true ARGS=(--dry-run --major "--repo=$PROJECT_DIR")
        local scan_payload='{"error":{"code":"E403"}}' scan_tool_rc=1 result rc
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .skipped == 0 and .processed == 0 and .results[0].status == "failed"
             and .results[0].scan.results[0].error_code == "invalid_output"' "dep-update counts scanner failure"
        scan_payload='{}' scan_tool_rc=0
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.failed == 0 and .skipped == 1 and .results[0].reason == "no outdated dependencies"' "dep-update skips verified current"
        scan_payload='{"example":{"current":"1.0.0","wanted":"1.1.0","latest":"1.1.0"}}' scan_tool_rc=1
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.failed == 0 and .processed == 1 and .results[0].status == "pending"' "dep-update valid dry-run"
        ARGS=(--dry-run "--repo=$PROJECT_DIR")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.processed == 1 and .results[0].outdated.total_outdated == 1' "default filter keeps minor update"
        scan_payload='{"example":{"current":"1.0.0","wanted":"2.0.0","latest":"2.0.0"}}'
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.skipped == 1 and .processed == 0 and (.results[0].reason | contains("only major"))' "default filter excludes major update"
        scan_payload='{"example":{"current":"1.0.0-rc.1+b.5","wanted":"1.1.0-rc.2+b.6","latest":"1.1.0-rc.2+b.6"}}'
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.processed == 1 and .results[0].outdated.total_outdated == 1' "prerelease and build metadata are classifiable"
        ARGS=(--dry-run --major '--include=[' "--repo=$PROJECT_DIR")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .processed == 0 and .results[0].error == "Dependency filtering failed"' "invalid regex does not fail open"
        ARGS=(--dry-run "--repo=$PROJECT_DIR")
        scan_payload='{"example":{"wanted":"1.1.0","latest":"1.1.0"}}'
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .processed == 0 and .results[0].error == "Dependency version classification failed"' "unknown current version cannot be skipped as major"
        command() {
            if [[ "$1" == -v && "${2:-}" == jq ]]; then return 1; fi
            builtin command "$@"
        }
        result=$(cmd_dep_update); rc=$?
        assert_equals 3 "$rc" "dep-update missing jq returns dependency error"
        assert_equals '' "$result" "dep-update emits no malformed payload without jq"
        [[ "$TF_ASSERTIONS_FAILED" -eq "$scan_failures_before" ]]
    )
}

# Optional argument supplies retained read-only fixtures to the focused helper
# runner. The stock suite creates and cleans its own fixtures as usual.
test_dep_scan_npm_lockfile_contract() {
    local fixture_root="${1:-}" created_fixture=false
    if [[ -z "$fixture_root" ]]; then
        setup_test_env
        fixture_root="$TEMP_DIR"
        created_fixture=true
        mkdir -p "$fixture_root/yarn" "$fixture_root/pnpm" "$fixture_root/npm"
        printf '{}\n' > "$fixture_root/yarn/package.json"
        printf '{}\n' > "$fixture_root/pnpm/package.json"
        printf '{}\n' > "$fixture_root/npm/package.json"
        touch "$fixture_root/yarn/yarn.lock" "$fixture_root/pnpm/pnpm-lock.yaml"
    fi
    (
        local scan_failures_before=$TF_ASSERTIONS_FAILED result rc project_kind
        npm() { printf '{}\n'; }
        ntm() { return 92; }
        claude() { return 93; }
        run_dep_update_transactions() { printf 'UNEXPECTED transaction\n' >&2; return 94; }
        local JSON_OUTPUT=true
        for project_kind in yarn pnpm; do
            local ARGS=(--dry-run --major "--repo=$fixture_root/$project_kind")
            result=$(cmd_dep_update); rc=$?
            assert_dep_scan_result "$result" "$rc" 1 \
                '.failed == 1 and .skipped == 0 and .processed == 0
                 and .results[0].scan.results[0].error_code == "unsupported_scan"' \
                "$project_kind lockfile cannot use npm current result"
        done
        local ARGS=(--dry-run --major "--repo=$fixture_root/npm")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.failed == 0 and .skipped == 1 and .results[0].reason == "no outdated dependencies"' \
            "plain npm project still accepts current result"
        [[ "$TF_ASSERTIONS_FAILED" -eq "$scan_failures_before" ]]
    )
    local result_rc=$?
    if [[ "$created_fixture" == true ]]; then cleanup_test_env; fi
    return "$result_rc"
}

# The actual caller runs. Discovery and the transaction boundary are controlled;
# no project test, completed update or AI session is fabricated.
test_dep_update_requires_test_command() {
    (
        local scan_failures_before=$TF_ASSERTIONS_FAILED result rc
        local detection_output='' detection_exit=1 expected_test_command="echo 'No tests configured'"
        local JSON_OUTPUT=true ARGS=(--major --no-push "--repo=$PROJECT_DIR")
        ntm() { return 92; }
        claude() { return 93; }
        log_warn() { :; }
        log_success() { :; }
        detect_package_managers() { printf '{"managers":["npm"]}\n'; }
        npm() {
            printf '{"example":{"current":"1.0.0","wanted":"1.1.0","latest":"1.1.0"}}\n'
            return 1
        }
        detect_test_command() { printf '%s' "$detection_output"; return "$detection_exit"; }
        run_dep_update_transactions() {
            [[ "$6" == true ]] || return 74
            [[ "$3" == "$expected_test_command" ]] || return 75
            jq -cn --arg repo "$(cd "$1" && pwd -P)" --arg command "$3" --argjson plan "$2" \
                '{repo:$repo,status:"failed",exit_code:2,deps_updated:0,dependencies:[],
                  deps_outdated_before:$plan.total_outdated,
                  publication:{no_push:true,status:"not_requested"},
                  error:"Controlled transaction boundary",observed_command:$command,observed_plan:$plan}'
            return 2
        }

        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .updated == 0 and .results[0].error_code == "test_command_unavailable"
             and .results[0].test_detection_exit == 1' "missing test command blocks updates"

        detection_output='npm test' detection_exit=42 expected_test_command='npm test'
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .results[0].error_code == "test_command_unavailable"
             and .results[0].test_detection_exit == 42' "failed detection cannot supply a test command"

        detection_output='   ' detection_exit=0 expected_test_command='   '
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .results[0].error_code == "test_command_unavailable"' "blank detected test command blocks updates"

        ARGS+=("--test-cmd=   ")
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .results[0].error_code == "test_command_unavailable"' "blank explicit test command blocks updates"

        ARGS=(--major --no-push --test-cmd= "--repo=$PROJECT_DIR")
        detection_output='npm test' detection_exit=0 expected_test_command='npm test'
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.failed == 1 and .results[0].error_code == "test_command_unavailable"' "empty explicit command does not fall back to detection"

        ARGS=(--major --no-push "--repo=$PROJECT_DIR")
        detection_output='npm test' detection_exit=0
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.updated == 0 and .failed == 1 and .results[0].publication.no_push == true
             and .results[0].observed_command == "npm test"
             and .results[0].error == "Controlled transaction boundary"' "detected command reaches the transaction boundary"
        assert_dep_scan_result "$result" "$rc" 1 \
            '.results[0].deps_outdated_before == 1 and .results[0].deps_updated == 0' \
            "discovery is not counted as a verified update"

        detection_output='' detection_exit=42 expected_test_command='make check'
        ARGS+=(--test-cmd=make\ check)
        result=$(cmd_dep_update); rc=$?
        assert_dep_scan_result "$result" "$rc" 1 \
            '.updated == 0 and .failed == 1 and .results[0].deps_outdated_before == 1
             and .results[0].deps_updated == 0 and .results[0].observed_command == "make check"' "explicit command overrides failed automatic detection"
        result=$(_robot_docs_schemas); rc=$?
        assert_dep_scan_result "$result" "$rc" 0 \
            '.commands["dep-update"].data_schema.properties.results.items.properties |
             .deps_outdated_before.type == "integer" and .deps_updated.type == "integer"' \
            "advertised schema distinguishes discovery and verified update counts"
        [[ "$TF_ASSERTIONS_FAILED" -eq "$scan_failures_before" ]]
    )
}

#==============================================================================
# Main Test Runner
#==============================================================================

main() {
    echo "Running package manager detection tests..."
    echo ""

    # Invalid input tests
    run_test test_detect_returns_error_for_empty_path
    run_test test_detect_returns_error_for_nonexistent_path
    run_test test_detect_returns_empty_for_no_managers

    # npm/Node.js tests
    run_test test_detect_npm_via_package_json
    run_test test_detect_npm_via_package_lock
    run_test test_detect_yarn_via_yarn_lock
    run_test test_detect_pnpm_via_pnpm_lock
    run_test test_npm_package_json_takes_precedence_over_lock

    # Python tests
    run_test test_detect_pip_via_pyproject
    run_test test_detect_pip_via_requirements
    run_test test_detect_pip_via_setup_py
    run_test test_detect_pipenv_via_pipfile
    run_test test_pyproject_takes_precedence_over_requirements

    # Rust tests
    run_test test_detect_cargo_via_cargo_toml

    # Go tests
    run_test test_detect_go_via_go_mod

    # PHP tests
    run_test test_detect_composer_via_composer_json

    # Ruby tests
    run_test test_detect_bundler_via_gemfile

    # Java tests
    run_test test_detect_maven_via_pom_xml
    run_test test_detect_gradle_via_build_gradle
    run_test test_detect_gradle_via_build_gradle_kts
    run_test test_gradle_kts_takes_precedence_over_groovy

    # Multi-language tests
    run_test test_detect_multiple_managers_in_polyglot_project
    run_test test_detect_all_supported_managers

    # JSON format tests
    run_test test_output_is_valid_json
    run_test test_output_has_required_fields

    run_test test_dep_scan_npm_contract
    run_test test_dep_scan_other_manager_contracts
    run_test test_dep_scan_cargo_workspace_contract
    run_test test_cargo_workspace_test_command
    run_test test_dep_update_manager_test_selection
    run_test test_dep_scan_missing_tools_and_partial_results
    run_test test_dep_update_counts_scan_failure
    run_test test_dep_scan_npm_lockfile_contract
    run_test test_dep_update_requires_test_command

    echo ""
    print_results
}

main "$@"
