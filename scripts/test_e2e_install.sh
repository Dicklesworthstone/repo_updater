#!/usr/bin/env bash
#
# E2E Test: Installation workflow
# Tests the install.sh script for fresh installation
#
# Test coverage:
#   - Installation to custom directory works
#   - Installed script is executable
#   - --version returns valid version
#   - --help returns usage info
#   - init command works
#   - Script syntax is valid (bash -n)
#
# Note: Uses RU_UNSAFE_MAIN=1 to install from local files rather than
# downloading from GitHub releases (faster, works offline)
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
set -uo pipefail

#==============================================================================
# Source E2E Test Framework
#==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_e2e_framework.sh
source "$SCRIPT_DIR/test_e2e_framework.sh"

INSTALL_SCRIPT="$E2E_PROJECT_DIR/install.sh"

#==============================================================================
# Tests: Installation
#==============================================================================

test_install_to_custom_dir() {
    e2e_setup

    local install_dir="$E2E_TEMP_DIR/bin"

    # Install using local copy
    mkdir -p "$install_dir"
    cp "$E2E_PROJECT_DIR/ru" "$install_dir/ru"
    chmod +x "$install_dir/ru"

    assert_file_exists "$install_dir/ru" "ru script installed to custom directory"

    if [[ -x "$install_dir/ru" ]]; then
        pass "Installed ru is executable"
    else
        fail "Installed ru is executable"
    fi

    e2e_cleanup
}

create_mock_curl_installer_no_releases() {
    mkdir -p "$E2E_MOCK_BIN"

    cat > "$E2E_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

out_file=""
write_out=""
url=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)
            out_file="$2"
            shift 2
            ;;
        -w)
            write_out="$2"
            shift 2
            ;;
        -H|-fsSL|-sS|-S|-L|-f|-s)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done

url_no_query="${url%%\?*}"

if [[ "$url_no_query" == "https://api.github.com/repos/Dicklesworthstone/repo_updater/releases/latest" ]]; then
    echo "mock curl: unexpected GitHub API call: $url" >&2
    exit 22
fi

if [[ "$url_no_query" == "https://github.com/Dicklesworthstone/repo_updater/releases/latest/download/ru" ]]; then
    echo "Not Found" >&2
    exit 22
fi

if [[ "$url_no_query" == "https://github.com/Dicklesworthstone/repo_updater/releases/latest" ]]; then
    if [[ -n "$write_out" ]]; then
        printf '%s' "https://github.com/Dicklesworthstone/repo_updater/releases"
        exit 0
    fi
    printf '%s' ""
    exit 0
fi

if [[ "$url_no_query" == "https://raw.githubusercontent.com/Dicklesworthstone/repo_updater/main/ru" ]]; then
    if [[ "$url" != *"ru_cb="* ]]; then
        echo "mock curl: expected ru_cb cache buster in URL: $url" >&2
        exit 2
    fi
    if [[ -n "$out_file" ]]; then
        cat > "$out_file" <<'RU'
#!/usr/bin/env bash
echo "ru 0.0.0"
RU
    else
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'echo "ru 0.0.0"'
    fi
    exit 0
fi

echo "mock curl: unexpected URL: $url" >&2
exit 22
EOF

    chmod +x "$E2E_MOCK_BIN/curl"
}

test_installer_requires_explicit_main_when_no_releases() {
    e2e_setup

    create_mock_curl_installer_no_releases

    local install_dir="$E2E_TEMP_DIR/bin"
    mkdir -p "$install_dir"

    local output exit_code=0
    output=$(DEST="$install_dir" RU_CACHE_BUST=1 bash "$INSTALL_SCRIPT" </dev/null 2>&1) || exit_code=$?

    assert_equals "1" "$exit_code" "Missing release fails verified installation"
    assert_contains "$output" "No releases found" "installer reports missing releases"
    assert_contains "$output" "RU_UNSAFE_MAIN=1" "Unsafe opt-in is explained"
    assert_file_not_exists "$install_dir/ru" "Default does not install mutable main"

    exit_code=0
    output=$(DEST="$install_dir" RU_UNSAFE_MAIN=1 RU_CACHE_BUST=1 bash "$INSTALL_SCRIPT" </dev/null 2>&1) || exit_code=$?
    assert_equals "0" "$exit_code" "Explicit main opt-in remains available"
    assert_contains "$output" "RU_UNSAFE_MAIN=1" "Unsafe source is visible"
    assert_file_exists "$install_dir/ru" "Explicit unsafe installation succeeds"

    e2e_cleanup
}

create_mock_curl_installer_release() {
    export INSTALL_TEST_RU="$E2E_PROJECT_DIR/ru"
    export INSTALL_TEST_SHA
    INSTALL_TEST_SHA=$(sha256sum "$INSTALL_TEST_RU" | cut -d' ' -f1)
    cat > "$E2E_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
dest="" url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        -w) shift 2 ;;
        -*) shift ;;
        *) url="${1%%\?*}"; shift ;;
    esac
done
case "$url" in
    */releases/latest)
        printf 'https://github.com/Dicklesworthstone/repo_updater/releases/tag/v1.5.0'
        ;;
    */download/ru|*/download/v1.5.0/ru)
        [[ "$INSTALL_TEST_MODE" == asset-error ]] && exit 22
        if [[ "$INSTALL_TEST_MODE" == html ]]; then
            printf '<html>bad download</html>\n' > "$dest"
        else
            cp "$INSTALL_TEST_RU" "$dest"
        fi
        ;;
    */checksums.txt)
        [[ "$INSTALL_TEST_MODE" == missing ]] && exit 22
        case "$INSTALL_TEST_MODE" in
            corrupt) printf '%064d  ru\n' 0 > "$dest" ;;
            absent-entry) printf '%s  other-file\n' "$INSTALL_TEST_SHA" > "$dest" ;;
            *) printf '%s  ru\n' "$INSTALL_TEST_SHA" > "$dest" ;;
        esac
        ;;
    *) printf 'Unexpected installer request: %s\n' "$url" >&2; exit 22 ;;
esac
EOF
    chmod +x "$E2E_MOCK_BIN/curl"
}

test_installer_release_integrity_matrix() {
    e2e_setup
    create_mock_curl_installer_release
    local version mode output rc destination
    for version in '' 1.5.0; do
        for mode in valid missing corrupt absent-entry html asset-error; do
            destination="$E2E_TEMP_DIR/install-${version:-latest}-$mode"
            mkdir -p "$destination"
            rc=0
            output=$(DEST="$destination" RU_VERSION="$version" RU_UNSAFE_MAIN=0 INSTALL_TEST_MODE="$mode" bash "$INSTALL_SCRIPT" </dev/null 2>&1) || rc=$?
            if [[ "$mode" == valid ]]; then
                assert_equals 0 "$rc" "${version:-latest} verified installation succeeds"
                assert_contains "$output" 'Checksum verified' "Verified success is explicit"
                assert_success "Installed bytes exactly match manifest candidate" cmp -s "$INSTALL_TEST_RU" "$destination/ru"
            else
                assert_equals 1 "$rc" "${version:-latest} $mode refuses installation"
                assert_file_not_exists "$destination/ru" "${version:-latest} $mode never publishes unchecked bytes"
                assert_not_contains "$output" 'Installing from main branch' "Failure never selects main implicitly"
            fi
        done
    done
    unset INSTALL_TEST_RU INSTALL_TEST_SHA
    e2e_preserve_on_failure
    e2e_cleanup
}

test_installer_checksum_tool_absence() {
    e2e_setup
    local output rc=0
    # Load the actual verifier while fault-injecting only tool discovery.
    output=$(
        # shellcheck source=../install.sh
        source <(sed -n '/^verify_checksum()/,/^}/p' "$INSTALL_SCRIPT")
        command_exists() { return 1; }
        log_error() { printf '%s\n' "$*" >&2; }
        verify_checksum "$INSTALL_SCRIPT" "$(printf '%064d' 0)" 2>&1
    ) || rc=$?
    assert_equals 1 "$rc" "Missing SHA256 tools refuse verification"
    assert_contains "$output" 'requires sha256sum or shasum' "Missing dependency is actionable"
    e2e_cleanup
}

test_pipeline_env_reaches_installer() {
    e2e_setup
    create_mock_curl_installer_release
    local destination="$E2E_TEMP_DIR/pipeline-bin" output rc=0
    mkdir -p "$destination"
    output=$(cat "$INSTALL_SCRIPT" | DEST="$destination" RU_VERSION=1.5.0 RU_UNSAFE_MAIN=0 RU_INSTALLER_NO_SELF_REFRESH=1 INSTALL_TEST_MODE=valid bash 2>&1) || rc=$?
    assert_equals 0 "$rc" "Documented environment placement works through a pipe"
    assert_contains "$output" 'Installing version: 1.5.0' "Requested version reaches bash"
    assert_file_exists "$destination/ru" "Requested destination reaches bash"
    unset INSTALL_TEST_RU INSTALL_TEST_SHA
    e2e_cleanup
}

test_version_output() {
    e2e_setup

    local install_dir="$E2E_TEMP_DIR/bin"
    mkdir -p "$install_dir"
    cp "$E2E_PROJECT_DIR/ru" "$install_dir/ru"
    chmod +x "$install_dir/ru"

    local output exit_code=0
    output=$("$install_dir/ru" --version 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "Version command exits 0"
    assert_contains "$output" "ru" "Version output contains 'ru'"
    if printf '%s\n' "$output" | grep -qE '[0-9]+\.[0-9]+'; then
        pass "Version output contains version number"
    else
        fail "Version output should contain version number"
    fi

    e2e_cleanup
}

test_help_output() {
    e2e_setup

    local install_dir="$E2E_TEMP_DIR/bin"
    mkdir -p "$install_dir"
    cp "$E2E_PROJECT_DIR/ru" "$install_dir/ru"
    chmod +x "$install_dir/ru"

    local output exit_code=0
    output=$("$install_dir/ru" --help 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "Help command exits 0"
    assert_contains "$output" "USAGE" "Help contains USAGE"
    assert_contains "$output" "COMMANDS" "Help contains COMMANDS"
    assert_contains "$output" "sync" "Help mentions sync command"
    assert_contains "$output" "init" "Help mentions init command"

    e2e_cleanup
}

test_init_command() {
    e2e_setup

    local install_dir="$E2E_TEMP_DIR/bin"
    mkdir -p "$install_dir"
    cp "$E2E_PROJECT_DIR/ru" "$install_dir/ru"
    chmod +x "$install_dir/ru"

    local output exit_code=0
    output=$("$install_dir/ru" init 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "init command exits 0"
    assert_dir_exists "$XDG_CONFIG_HOME/ru" "Config directory created"
    assert_dir_exists "$XDG_CONFIG_HOME/ru/repos.d" "repos.d directory created"

    e2e_cleanup
}

test_script_syntax() {
    local output exit_code=0
    output=$(bash -n "$E2E_PROJECT_DIR/ru" 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "ru script syntax is valid"
}

test_install_script_syntax() {
    local output exit_code=0
    output=$(bash -n "$INSTALL_SCRIPT" 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "install.sh syntax is valid"
}

#==============================================================================
# Run Tests
#==============================================================================

run_test test_install_to_custom_dir
run_test test_installer_requires_explicit_main_when_no_releases
run_test test_installer_release_integrity_matrix
run_test test_installer_checksum_tool_absence
run_test test_pipeline_env_reaches_installer
run_test test_version_output
run_test test_help_output
run_test test_init_command
run_test test_script_syntax
run_test test_install_script_syntax

print_results
exit "$(get_exit_code)"
