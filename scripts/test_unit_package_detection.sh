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
    cmd_dep_update _dep_update_skipped_json _filter_outdated_deps _filter_major_updates; do
    source_ru_function "$scan_function"
done

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
    if jq -se "length == 1 and (.[0] | $predicate)" <<< "$result" >/dev/null; then
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
                cargo) scan_payload='{"dependencies":[{"name":"example","project":"1.0.0","latest":"1.1.0"}]}' ;;
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
                cargo) scan_payload='{"dependencies":[]}' ;;
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
        spawn_ai_session() { printf 'UNEXPECTED session\n' >&2; return 94; }
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
        spawn_ai_session() { printf 'UNEXPECTED session\n' >&2; return 94; }
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
    run_test test_dep_scan_missing_tools_and_partial_results
    run_test test_dep_update_counts_scan_failure
    run_test test_dep_scan_npm_lockfile_contract

    echo ""
    print_results
}

main "$@"
