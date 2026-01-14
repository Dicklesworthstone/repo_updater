#!/usr/bin/env bash
#
# Unit tests for package manager detection functions
# Tests: detect_package_managers
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

    echo ""
    print_results
}

main "$@"
