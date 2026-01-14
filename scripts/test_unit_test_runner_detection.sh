#!/usr/bin/env bash
#
# Unit tests for test runner detection functions
# Tests: detect_test_command
#
# Covers detection of test commands for:
# - npm (package.json scripts.test, jest, vitest)
# - cargo (Cargo.toml)
# - go (go.mod with *_test.go files)
# - pytest (pytest.ini, conftest.py, pyproject.toml)
# - Ruby (Gemfile with rspec, Rakefile)
# - Maven (pom.xml)
# - Gradle (build.gradle, gradlew)
# - Makefile (test target)
# - PHP (composer.json, phpunit)
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

source <(extract_function "detect_test_command" "$PROJECT_DIR/ru")

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

#==============================================================================
# Test: Invalid input handling
#==============================================================================

test_detect_returns_error_for_empty_path() {
    local result
    result=$(detect_test_command "")
    local exit_code=$?

    assert_equals 1 "$exit_code" "Should return exit code 1 for empty path"
    assert_equals "" "$result" "Should return empty string for empty path"
}

test_detect_returns_error_for_nonexistent_path() {
    local result
    result=$(detect_test_command "/nonexistent/path/12345")
    local exit_code=$?

    assert_equals 1 "$exit_code" "Should return exit code 1 for nonexistent path"
    assert_equals "" "$result" "Should return empty string for nonexistent path"
}

test_detect_returns_error_for_no_test_setup() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "empty_project")

    local result
    result=$(detect_test_command "$project_dir")
    local exit_code=$?

    assert_equals 1 "$exit_code" "Should return exit code 1 when no test setup found"
    assert_equals "" "$result" "Should return empty string when no test setup"

    cleanup_test_env
}

#==============================================================================
# Test: npm/Node.js detection
#==============================================================================

test_detect_npm_test_from_package_json() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "npm_project")
    cat > "$project_dir/package.json" <<'JSON'
{
  "name": "test-project",
  "scripts": {
    "test": "jest"
  }
}
JSON

    local result
    result=$(detect_test_command "$project_dir")
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should return exit code 0 for npm project with test script"
    assert_equals "npm test" "$result" "Should return 'npm test' for package.json with scripts.test"

    cleanup_test_env
}

test_detect_npm_test_ignores_empty_test_script() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "npm_no_test")
    cat > "$project_dir/package.json" <<'JSON'
{
  "name": "test-project",
  "scripts": {
    "build": "tsc"
  }
}
JSON

    local result
    result=$(detect_test_command "$project_dir")
    local exit_code=$?

    assert_equals 1 "$exit_code" "Should return exit code 1 when no test script defined"

    cleanup_test_env
}

test_detect_jest_config_js() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "jest_project")
    echo '{"name": "test"}' > "$project_dir/package.json"
    echo 'module.exports = {};' > "$project_dir/jest.config.js"

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "npx jest" "$result" "Should return 'npx jest' for jest.config.js"

    cleanup_test_env
}

test_detect_jest_config_ts() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "jest_ts_project")
    echo '{"name": "test"}' > "$project_dir/package.json"
    echo 'export default {};' > "$project_dir/jest.config.ts"

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "npx jest" "$result" "Should return 'npx jest' for jest.config.ts"

    cleanup_test_env
}

test_detect_vitest_config() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "vitest_project")
    echo '{"name": "test"}' > "$project_dir/package.json"
    echo 'export default {};' > "$project_dir/vitest.config.ts"

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "npx vitest run" "$result" "Should return 'npx vitest run' for vitest.config.ts"

    cleanup_test_env
}

test_npm_test_takes_precedence_over_jest_config() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "npm_with_jest")
    cat > "$project_dir/package.json" <<'JSON'
{
  "name": "test",
  "scripts": { "test": "jest --coverage" }
}
JSON
    echo 'module.exports = {};' > "$project_dir/jest.config.js"

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "npm test" "$result" "scripts.test should take precedence over jest.config.js"

    cleanup_test_env
}

#==============================================================================
# Test: Rust (cargo) detection
#==============================================================================

test_detect_cargo_test() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "rust_project")
    cat > "$project_dir/Cargo.toml" <<'TOML'
[package]
name = "test"
version = "0.1.0"
TOML

    local result
    result=$(detect_test_command "$project_dir")
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should return exit code 0 for Rust project"
    assert_equals "cargo test" "$result" "Should return 'cargo test' for Cargo.toml"

    cleanup_test_env
}

#==============================================================================
# Test: Go detection
#==============================================================================

test_detect_go_test_with_test_files() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "go_project")
    echo 'module example.com/test' > "$project_dir/go.mod"
    echo 'package main' > "$project_dir/main.go"
    echo 'package main' > "$project_dir/main_test.go"

    local result
    result=$(detect_test_command "$project_dir")
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should return exit code 0 for Go project with tests"
    assert_equals "go test ./..." "$result" "Should return 'go test ./...' for Go project"

    cleanup_test_env
}

test_detect_go_no_test_files() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "go_no_tests")
    echo 'module example.com/test' > "$project_dir/go.mod"
    echo 'package main' > "$project_dir/main.go"

    local result
    result=$(detect_test_command "$project_dir")
    local exit_code=$?

    # Should not detect go test if no test files exist
    assert_not_equals "go test ./..." "$result" "Should not return 'go test ./...' without test files"

    cleanup_test_env
}

#==============================================================================
# Test: Python (pytest) detection
#==============================================================================

test_detect_pytest_from_pytest_ini() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "pytest_ini_project")
    echo '[pytest]' > "$project_dir/pytest.ini"

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "pytest" "$result" "Should return 'pytest' for pytest.ini"

    cleanup_test_env
}

test_detect_pytest_from_conftest() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "conftest_project")
    echo 'import pytest' > "$project_dir/conftest.py"

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "pytest" "$result" "Should return 'pytest' for conftest.py"

    cleanup_test_env
}

test_detect_pytest_from_pyproject_toml() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "pyproject_pytest")
    cat > "$project_dir/pyproject.toml" <<'TOML'
[project]
name = "test"

[tool.pytest.ini_options]
testpaths = ["tests"]
TOML

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "pytest" "$result" "Should return 'pytest' for pyproject.toml with pytest config"

    cleanup_test_env
}

test_detect_pytest_from_tests_directory() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "tests_dir_project")
    mkdir -p "$project_dir/tests"
    echo 'def test_example(): pass' > "$project_dir/tests/test_example.py"

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "pytest" "$result" "Should return 'pytest' for tests/ directory with test_*.py"

    cleanup_test_env
}

#==============================================================================
# Test: Ruby detection
#==============================================================================

test_detect_rspec_from_gemfile() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "ruby_rspec")
    cat > "$project_dir/Gemfile" <<'RUBY'
source 'https://rubygems.org'
gem 'rspec'
RUBY

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "bundle exec rspec" "$result" "Should return 'bundle exec rspec' for Gemfile with rspec"

    cleanup_test_env
}

test_detect_rake_test_from_rakefile() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "ruby_rake")
    echo 'source "https://rubygems.org"' > "$project_dir/Gemfile"
    cat > "$project_dir/Rakefile" <<'RUBY'
task :test do
  puts "running tests"
end
RUBY

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "bundle exec rake test" "$result" "Should return 'bundle exec rake test' for Rakefile with test task"

    cleanup_test_env
}

#==============================================================================
# Test: Maven detection
#==============================================================================

test_detect_mvn_test() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "maven_project")
    cat > "$project_dir/pom.xml" <<'XML'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.test</groupId>
  <artifactId>test</artifactId>
</project>
XML

    local result
    result=$(detect_test_command "$project_dir")
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should return exit code 0 for Maven project"
    assert_equals "mvn test" "$result" "Should return 'mvn test' for pom.xml"

    cleanup_test_env
}

#==============================================================================
# Test: Gradle detection
#==============================================================================

test_detect_gradle_test() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "gradle_project")
    echo 'plugins { id "java" }' > "$project_dir/build.gradle"

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "gradle test" "$result" "Should return 'gradle test' for build.gradle"

    cleanup_test_env
}

test_detect_gradle_with_wrapper() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "gradle_wrapper_project")
    echo 'plugins { id "java" }' > "$project_dir/build.gradle"
    touch "$project_dir/gradlew"
    chmod +x "$project_dir/gradlew"

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "./gradlew test" "$result" "Should return './gradlew test' when gradlew exists"

    cleanup_test_env
}

test_detect_gradle_kts() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "kotlin_gradle_project")
    echo 'plugins { kotlin("jvm") }' > "$project_dir/build.gradle.kts"

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "gradle test" "$result" "Should return 'gradle test' for build.gradle.kts"

    cleanup_test_env
}

#==============================================================================
# Test: Makefile detection
#==============================================================================

test_detect_make_test() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "makefile_project")
    cat > "$project_dir/Makefile" <<'MAKE'
.PHONY: test build

build:
	echo "building"

test:
	echo "testing"
MAKE

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "make test" "$result" "Should return 'make test' for Makefile with test target"

    cleanup_test_env
}

test_detect_makefile_without_test_target() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "makefile_no_test")
    cat > "$project_dir/Makefile" <<'MAKE'
.PHONY: build

build:
	echo "building"
MAKE

    local result
    result=$(detect_test_command "$project_dir")
    local exit_code=$?

    assert_equals 1 "$exit_code" "Should return exit code 1 for Makefile without test target"

    cleanup_test_env
}

#==============================================================================
# Test: PHP/Composer detection
#==============================================================================

test_detect_composer_test() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "php_composer")
    cat > "$project_dir/composer.json" <<'JSON'
{
  "name": "test/test",
  "scripts": {
    "test": "phpunit"
  }
}
JSON

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "composer test" "$result" "Should return 'composer test' for composer.json with scripts.test"

    cleanup_test_env
}

test_detect_phpunit_xml() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "php_phpunit")
    echo '{"name": "test/test"}' > "$project_dir/composer.json"
    echo '<phpunit/>' > "$project_dir/phpunit.xml"

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "vendor/bin/phpunit" "$result" "Should return 'vendor/bin/phpunit' for phpunit.xml"

    cleanup_test_env
}

test_detect_phpunit_xml_dist() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "php_phpunit_dist")
    echo '{"name": "test/test"}' > "$project_dir/composer.json"
    echo '<phpunit/>' > "$project_dir/phpunit.xml.dist"

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "vendor/bin/phpunit" "$result" "Should return 'vendor/bin/phpunit' for phpunit.xml.dist"

    cleanup_test_env
}

#==============================================================================
# Test: Priority/precedence
#==============================================================================

test_npm_takes_precedence_over_makefile() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "npm_and_makefile")
    cat > "$project_dir/package.json" <<'JSON'
{
  "name": "test",
  "scripts": { "test": "jest" }
}
JSON
    cat > "$project_dir/Makefile" <<'MAKE'
test:
	echo "make test"
MAKE

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "npm test" "$result" "npm test should take precedence over make test"

    cleanup_test_env
}

test_cargo_takes_precedence_over_makefile() {
    setup_test_env

    local project_dir
    project_dir=$(create_test_project "cargo_and_makefile")
    echo '[package]' > "$project_dir/Cargo.toml"
    cat > "$project_dir/Makefile" <<'MAKE'
test:
	echo "make test"
MAKE

    local result
    result=$(detect_test_command "$project_dir")

    assert_equals "cargo test" "$result" "cargo test should take precedence over make test"

    cleanup_test_env
}

#==============================================================================
# Main Test Runner
#==============================================================================

main() {
    echo "Running test runner detection tests..."
    echo ""

    # Invalid input tests
    run_test test_detect_returns_error_for_empty_path
    run_test test_detect_returns_error_for_nonexistent_path
    run_test test_detect_returns_error_for_no_test_setup

    # npm/Node.js tests
    run_test test_detect_npm_test_from_package_json
    run_test test_detect_npm_test_ignores_empty_test_script
    run_test test_detect_jest_config_js
    run_test test_detect_jest_config_ts
    run_test test_detect_vitest_config
    run_test test_npm_test_takes_precedence_over_jest_config

    # Rust tests
    run_test test_detect_cargo_test

    # Go tests
    run_test test_detect_go_test_with_test_files
    run_test test_detect_go_no_test_files

    # Python tests
    run_test test_detect_pytest_from_pytest_ini
    run_test test_detect_pytest_from_conftest
    run_test test_detect_pytest_from_pyproject_toml
    run_test test_detect_pytest_from_tests_directory

    # Ruby tests
    run_test test_detect_rspec_from_gemfile
    run_test test_detect_rake_test_from_rakefile

    # Maven tests
    run_test test_detect_mvn_test

    # Gradle tests
    run_test test_detect_gradle_test
    run_test test_detect_gradle_with_wrapper
    run_test test_detect_gradle_kts

    # Makefile tests
    run_test test_detect_make_test
    run_test test_detect_makefile_without_test_target

    # PHP tests
    run_test test_detect_composer_test
    run_test test_detect_phpunit_xml
    run_test test_detect_phpunit_xml_dist

    # Precedence tests
    run_test test_npm_takes_precedence_over_makefile
    run_test test_cargo_takes_precedence_over_makefile

    echo ""
    print_results
}

main "$@"
