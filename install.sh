#!/usr/bin/env bash
#
# ru installer
# Downloads and installs ru (Repo Updater) to your system
#
# DEFAULT: Downloads from GitHub Release with checksum verification
#
# Usage:
#   curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/repo_updater/main/install.sh?ru_cb=$(date +%s)" | bash
#
# Options (via environment variables):
#   DEST=/path/to/dir      Install directory (default: ~/.local/bin)
#   RU_SYSTEM=1            Install to /usr/local/bin (requires sudo)
#   RU_VERSION=x.y.z       Install specific version (default: latest release)
#   RU_UNSAFE_MAIN=1       Install from main branch (NOT RECOMMENDED)
#   RU_CACHE_BUST=1        Append cache-busting query params to GitHub downloads (default: 1)
#   RU_CACHE_BUST_TOKEN=... Cache-bust token override (default: current epoch seconds)
#   RU_INSTALLER_NO_SELF_REFRESH=1 Disable installer self-refresh when piped (default: 0)
#
# Examples:
#   # Standard installation (recommended)
#   curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/repo_updater/main/install.sh?ru_cb=$(date +%s)" | bash
#
#   # Install specific version
#   RU_VERSION=1.0.0 curl -fsSL .../install.sh | bash
#
#   # System-wide installation
#   RU_SYSTEM=1 curl -fsSL .../install.sh | bash
#
#   # Custom directory
#   DEST=/opt/bin curl -fsSL .../install.sh | bash
#
# Security:
#   - Default: Downloads from GitHub Release with SHA256 checksum verification
#   - RU_UNSAFE_MAIN=1 required to install from main branch (for development only)
#
# Repository: https://github.com/Dicklesworthstone/repo_updater
# License: MIT
#
#==============================================================================

set -uo pipefail

#==============================================================================
# CONSTANTS
#==============================================================================

REPO_OWNER="Dicklesworthstone"
REPO_NAME="repo_updater"
SCRIPT_NAME="ru"
GITHUB_RAW="https://raw.githubusercontent.com"
GITHUB_RELEASE_HOST="https://github.com"

# Cache-bust token used for GitHub downloads (reduces stale CDN caching)
RU_CACHE_BUST_TOKEN="${RU_CACHE_BUST_TOKEN:-$(date +%s)}"

# Temp dir path for cleanup trap (kept global to avoid set -u issues with local vars)
RU_INSTALLER_TEMP_DIR=""

#==============================================================================
# COLORS (disabled if stderr is not a terminal or NO_COLOR is set)
# We check -t 2 (stderr) because all log functions output to stderr
#==============================================================================

if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

#==============================================================================
# LOGGING FUNCTIONS
#==============================================================================

log_info() {
    printf '%b\n' "${BLUE}ℹ${RESET} $*" >&2
}

log_success() {
    printf '%b\n' "${GREEN}✓${RESET} $*" >&2
}

log_warn() {
    printf '%b\n' "${YELLOW}⚠${RESET} $*" >&2
}

log_error() {
    printf '%b\n' "${RED}✗${RESET} $*" >&2
}

log_step() {
    printf '%b\n' "${BLUE}→${RESET} $*" >&2
}

#==============================================================================
# UTILITY FUNCTIONS
#==============================================================================

# Check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

cleanup_temp_dir() {
    local dir="$RU_INSTALLER_TEMP_DIR"
    if [[ -z "$dir" ]] || [[ "$dir" == "/" ]]; then
        return 0
    fi
    if [[ -d "$dir" ]]; then
        rm -rf "$dir" 2>/dev/null || true
    fi
}

mktemp_dir() {
    local dir=""

    # GNU coreutils mktemp
    if dir=$(mktemp -d 2>/dev/null); then
        printf '%s\n' "$dir"
        return 0
    fi

    # BSD mktemp (macOS) typically requires -t (template)
    if dir=$(mktemp -d -t ru 2>/dev/null); then
        printf '%s\n' "$dir"
        return 0
    fi
    if dir=$(mktemp -d -t ru.XXXXXXXXXX 2>/dev/null); then
        printf '%s\n' "$dir"
        return 0
    fi

    return 1
}

append_query_param() {
    local url="$1"
    local key="$2"
    local value="$3"

    local sep='?'
    [[ "$url" == *\?* ]] && sep='&'
    printf '%s%s%s=%s' "$url" "$sep" "$key" "$value"
}

maybe_cache_bust_url() {
    local url="$1"

    if [[ "${RU_CACHE_BUST:-1}" != "1" ]]; then
        printf '%s' "$url"
        return 0
    fi

    case "$url" in
        "$GITHUB_RAW"/*|"$GITHUB_RELEASE_HOST"/*)
            append_query_param "$url" "ru_cb" "$RU_CACHE_BUST_TOKEN"
            ;;
        *)
            printf '%s' "$url"
            ;;
    esac
}

#==============================================================================
# NTM INTEGRATION
# Optional installation of ntm (Named Tmux Manager) for agent-sweep support
#==============================================================================

# Check if ntm is installed
check_ntm_installed() {
    command -v ntm &>/dev/null
}

# Get ntm version
get_ntm_version() {
    ntm --version 2>/dev/null | head -1
}

# Check if tmux is installed (required for ntm)
check_tmux_installed() {
    command -v tmux &>/dev/null
}

# Prompt user for ntm installation
# Returns: 0 if user wants to install, 1 if skip
prompt_ntm_install() {
    # Non-interactive mode: skip prompt
    [[ "${RU_NON_INTERACTIVE:-}" == "1" ]] && return 1

    # Explicit yes: install
    [[ "${RU_INSTALL_NTM:-}" == "yes" ]] && return 0

    # Explicit no: skip
    [[ "${RU_INSTALL_NTM:-}" == "no" ]] && return 1

    # Not a terminal: skip
    [[ ! -t 0 ]] && return 1

    printf '\n' >&2
    printf '%b\n' "${BOLD}Optional: ntm Integration${RESET}" >&2
    printf '%s\n' "────────────────────────────" >&2
    printf '\n' >&2
    printf '%b\n' "ntm (Named Tmux Manager) enables the ${BOLD}ru agent-sweep${RESET} command:" >&2
    printf '%s\n' "  • AI-assisted commit and release automation" >&2
    printf '%s\n' "  • Automated code review across multiple repos" >&2
    printf '%s\n' "  • Structured commit plan generation" >&2
    printf '\n' >&2

    if ! check_tmux_installed; then
        log_warn "tmux is required for ntm but not found."
        log_info "Install tmux first: apt install tmux (or brew install tmux)"
        return 1
    fi

    printf 'Install ntm? [y/N] ' >&2
    IFS= read -r response
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Install ntm
install_ntm() {
    if check_ntm_installed; then
        log_info "ntm already installed: $(get_ntm_version)"
        return 0
    fi

    log_step "Installing ntm..."

    # Download and run ntm installer with validation
    local ntm_install_url="https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/install.sh"
    local temp_ntm_script=""

    # Create temp file for validation
    if ! temp_ntm_script=$(mktemp 2>/dev/null); then
        log_error "Failed to create temp file for ntm installer"
        return 1
    fi

    # Download the installer
    local download_ok=0
    if command_exists curl; then
        curl -fsSL "$ntm_install_url" -o "$temp_ntm_script" 2>/dev/null && download_ok=1
    elif command_exists wget; then
        wget -q "$ntm_install_url" -O "$temp_ntm_script" 2>/dev/null && download_ok=1
    fi

    if [[ "$download_ok" -ne 1 ]]; then
        rm -f "$temp_ntm_script" 2>/dev/null
        log_warn "Failed to download ntm installer"
        log_info "  You can install it manually: curl -fsSL $ntm_install_url | bash"
        return 1
    fi

    # Validate it looks like a bash script (security check)
    local first_line=""
    IFS= read -r first_line < "$temp_ntm_script" 2>/dev/null || true
    if [[ "$first_line" != "#!/usr/bin/env bash" && "$first_line" != "#!/bin/bash" ]]; then
        rm -f "$temp_ntm_script" 2>/dev/null
        log_warn "ntm installer validation failed (unexpected content)"
        log_info "  You can install it manually: curl -fsSL $ntm_install_url | bash"
        return 1
    fi

    # Run the validated installer
    if bash "$temp_ntm_script"; then
        rm -f "$temp_ntm_script" 2>/dev/null
        log_success "ntm installed successfully"
        return 0
    fi

    rm -f "$temp_ntm_script" 2>/dev/null
    log_warn "Failed to install ntm. You can install it manually later:"
    log_info "  curl -fsSL $ntm_install_url | bash"
    return 1
}

# Run ntm integration (check, prompt, install)
maybe_install_ntm() {
    # Skip if already installed
    if check_ntm_installed; then
        log_info "ntm detected: $(get_ntm_version)"
        log_info "ru agent-sweep is available"
        return 0
    fi

    # Prompt user
    if prompt_ntm_install; then
        install_ntm
    else
        log_info "Skipped ntm installation"
        log_info "You can install it later to enable: ru agent-sweep"
    fi
}

# Self-refresh the installer when executed from a pipe (/dev/fd/*), to avoid
# stale CDN/proxy caches when users run:
#   curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash
#
# Behavior:
# - If refresh succeeds, runs the refreshed installer and exits with its code.
# - If refresh fails, continues with the current script.
maybe_self_refresh_installer() {
    # Opt-out for debugging / pinned installs.
    if [[ "${RU_INSTALLER_NO_SELF_REFRESH:-}" == "1" ]]; then
        return 0
    fi
    # Prevent recursion when the refreshed script calls main().
    if [[ "${RU_INSTALLER_REFRESHED:-}" == "1" ]]; then
        return 0
    fi

    local src="${BASH_SOURCE[0]-}"
    if [[ -z "$src" ]]; then
        # When bash executes a script from stdin (e.g. `curl ... | bash`), BASH_SOURCE[0]
        # can be empty. In that case, only attempt self-refresh when stdin isn't a TTY
        # (i.e. this looks piped/redirected).
        if [[ -t 0 ]]; then
            return 0
        fi
        src="/dev/stdin"
    fi

    case "$src" in
        /dev/fd/*|/proc/self/fd/*|/dev/stdin) ;;
        *) return 0 ;;
    esac

    log_step "Refreshing installer (cache-bust)..."

    if ! command_exists curl && ! command_exists wget; then
        return 0
    fi

    local refresh_url="$GITHUB_RAW/$REPO_OWNER/$REPO_NAME/main/install.sh"
    refresh_url=$(append_query_param "$refresh_url" "ru_cb" "${RU_CACHE_BUST_TOKEN}.$$")

    local temp_dir=""
    if ! temp_dir=$(mktemp_dir); then
        return 0
    fi

    RU_INSTALLER_TEMP_DIR="$temp_dir"
    local dest="$temp_dir/install.sh"

    if command_exists curl; then
        if ! curl -fsSL "$refresh_url" -o "$dest" 2>/dev/null; then
            log_warn "Installer self-refresh failed; continuing with current installer"
            cleanup_temp_dir
            RU_INSTALLER_TEMP_DIR=""
            return 0
        fi
    else
        if ! wget -q "$refresh_url" -O "$dest" 2>/dev/null; then
            log_warn "Installer self-refresh failed; continuing with current installer"
            cleanup_temp_dir
            RU_INSTALLER_TEMP_DIR=""
            return 0
        fi
    fi

    local first_line=""
    IFS= read -r first_line < "$dest" 2>/dev/null || true
    if [[ "$first_line" != "#!/usr/bin/env bash" ]]; then
        log_warn "Installer self-refresh downloaded unexpected content; continuing with current installer"
        cleanup_temp_dir
        RU_INSTALLER_TEMP_DIR=""
        return 0
    fi

    RU_INSTALLER_REFRESHED=1 bash "$dest" "$@"
    local rc=$?
    cleanup_temp_dir
    RU_INSTALLER_TEMP_DIR=""
    exit "$rc"
}

# Attempt to detect the latest release tag without GitHub's API (avoids rate limits/proxies).
# Returns:
#   0 with version on stdout - success
#   1 - no releases exist (redirect resolves to /releases)
#   2 - request failed
get_latest_release_from_redirect() {
    local latest_url="$GITHUB_RELEASE_HOST/$REPO_OWNER/$REPO_NAME/releases/latest"
    local effective_url=""

    if command_exists curl; then
        if ! effective_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$latest_url" 2>/dev/null); then
            return 2
        fi
    elif command_exists wget; then
        # wget doesn't expose a direct "effective URL" format, so read the Location header.
        # We intentionally avoid following redirects here so we can capture the tag URL.
        effective_url=$(
            wget -qS --spider --max-redirect=0 "$latest_url" 2>&1 \
                | awk '/^  Location: /{print $2}' \
                | tail -1 \
                | tr -d '\r'
        )
        if [[ -z "$effective_url" ]]; then
            return 2
        fi
    else
        return 2
    fi

    if [[ "$effective_url" != *"/tag/"* ]]; then
        return 1
    fi

    local tag="${effective_url##*/tag/}"
    tag="${tag%%\?*}"
    printf '%s\n' "${tag#v}"
}

# Get the default shell config file
get_shell_config() {
    local shell_name
    shell_name=$(basename "${SHELL:-/bin/bash}")

    case "$shell_name" in
        zsh)
            if [[ -f "$HOME/.zshrc" ]]; then
                echo "$HOME/.zshrc"
            else
                echo "$HOME/.zprofile"
            fi
            ;;
        bash)
            if [[ -f "$HOME/.bashrc" ]]; then
                echo "$HOME/.bashrc"
            elif [[ -f "$HOME/.bash_profile" ]]; then
                echo "$HOME/.bash_profile"
            else
                echo "$HOME/.profile"
            fi
            ;;
        fish)
            echo "$HOME/.config/fish/config.fish"
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

# Determine install directory
get_install_dir() {
    if [[ -n "${DEST:-}" ]]; then
        echo "$DEST"
    elif [[ -n "${RU_SYSTEM:-}" ]] && [[ "$RU_SYSTEM" == "1" ]]; then
        echo "/usr/local/bin"
    else
        echo "$HOME/.local/bin"
    fi
}

# Check if directory is in PATH
in_path() {
    local dir="$1"
    [[ ":$PATH:" == *":$dir:"* ]]
}

# Download a file with cache-busting
# Adds a timestamp query parameter to bypass CDN/proxy caches
# Returns: 0 on success, 1 on failure
download_file() {
    local url="$1"
    local dest="$2"
    local final_url
    final_url=$(maybe_cache_bust_url "$url")

    if command_exists curl; then
        curl -fsSL "$final_url" -o "$dest" || return 1
    elif command_exists wget; then
        wget -q "$final_url" -O "$dest" || return 1
    else
        log_error "Neither curl nor wget found"
        return 1
    fi
}

# Verify SHA256 checksum
verify_checksum() {
    local file="$1"
    local expected="$2"
    local actual

    if command_exists sha256sum; then
        actual=$(sha256sum "$file" | cut -d' ' -f1)
    elif command_exists shasum; then
        actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
    else
        log_warn "No checksum tool found (sha256sum or shasum). Skipping verification."
        return 0
    fi

    if [[ "$actual" != "$expected" ]]; then
        log_error "Checksum verification failed!"
        log_error "Expected: $expected"
        log_error "Got:      $actual"
        return 1
    fi

    return 0
}

#==============================================================================
# INSTALLATION FUNCTIONS
#==============================================================================

# Install latest release without using the GitHub API.
# Uses the stable /releases/latest/download/<asset> endpoints to avoid API rate limits
# and to work better in restricted network environments.
# Returns:
#   0 - success
#   2 - no releases exist (caller may fall back to main)
#   1 - other failure
install_from_latest_release() {
    local install_dir="$1"
    local temp_dir

    if ! temp_dir=$(mktemp_dir); then
        log_error "Failed to create temp directory (mktemp)"
        return 1
    fi
    RU_INSTALLER_TEMP_DIR="$temp_dir"
    trap cleanup_temp_dir EXIT

    local latest_base="https://github.com/$REPO_OWNER/$REPO_NAME/releases/latest/download"
    local script_url="$latest_base/$SCRIPT_NAME"
    local checksum_url="$latest_base/checksums.txt"

    log_step "Downloading ru (latest release)..."
    if ! download_file "$script_url" "$temp_dir/$SCRIPT_NAME"; then
        # Download failed - either no releases exist OR the release doesn't have the artifact.
        # In either case, fall back to main branch.
        log_warn "Could not download ru from latest release (artifact may not be uploaded yet)"
        cleanup_temp_dir
        RU_INSTALLER_TEMP_DIR=""
        return 2
    fi

    # Sanity check: ensure we downloaded a Bash script, not an HTML error page.
    local first_line=""
    IFS= read -r first_line < "$temp_dir/$SCRIPT_NAME" 2>/dev/null || true
    if [[ "$first_line" != "#!/usr/bin/env bash" ]]; then
        # Downloaded something but it's not the script (likely HTML error page).
        # Fall back to main branch.
        log_warn "Downloaded unexpected content from release (not a bash script)"
        cleanup_temp_dir
        RU_INSTALLER_TEMP_DIR=""
        return 2
    fi

    log_step "Downloading checksums..."
    if download_file "$checksum_url" "$temp_dir/checksums.txt"; then
        local expected_checksum
        expected_checksum=$(grep -E "^[a-f0-9]{64}[[:space:]]+\\*?$SCRIPT_NAME$" "$temp_dir/checksums.txt" | cut -d' ' -f1)

        if [[ -n "$expected_checksum" ]]; then
            log_step "Verifying checksum..."
            if ! verify_checksum "$temp_dir/$SCRIPT_NAME" "$expected_checksum"; then
                return 1
            fi
            log_success "Checksum verified"
        else
            log_warn "No checksum found for $SCRIPT_NAME in checksums.txt"
        fi
    else
        log_warn "Could not download checksums.txt. Proceeding without verification."
    fi

    install_script "$temp_dir/$SCRIPT_NAME" "$install_dir"
}

# Install from GitHub Release (with checksum verification)
install_from_release() {
    local version="$1"
    local install_dir="$2"
    local temp_dir

    if ! temp_dir=$(mktemp_dir); then
        log_error "Failed to create temp directory (mktemp)"
        return 1
    fi
    RU_INSTALLER_TEMP_DIR="$temp_dir"
    trap cleanup_temp_dir EXIT

    local release_base="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/v$version"
    local script_url="$release_base/$SCRIPT_NAME"
    local checksum_url="$release_base/checksums.txt"

    log_step "Downloading ru v$version from release..."
    if ! download_file "$script_url" "$temp_dir/$SCRIPT_NAME"; then
        log_error "Failed to download ru from release"
        return 1
    fi

    log_step "Downloading checksums..."
    if download_file "$checksum_url" "$temp_dir/checksums.txt"; then
        # Extract expected checksum for ru
        local expected_checksum
        expected_checksum=$(grep -E "^[a-f0-9]{64}[[:space:]]+\\*?$SCRIPT_NAME$" "$temp_dir/checksums.txt" | cut -d' ' -f1)

        if [[ -n "$expected_checksum" ]]; then
            log_step "Verifying checksum..."
            if ! verify_checksum "$temp_dir/$SCRIPT_NAME" "$expected_checksum"; then
                return 1
            fi
            log_success "Checksum verified"
        else
            log_warn "No checksum found for $SCRIPT_NAME in checksums.txt"
        fi
    else
        log_warn "Could not download checksums.txt. Proceeding without verification."
    fi

    # Install
    install_script "$temp_dir/$SCRIPT_NAME" "$install_dir"
}

# Install from main branch (development only)
install_from_main() {
    local install_dir="$1"
    local temp_dir

    if ! temp_dir=$(mktemp_dir); then
        log_error "Failed to create temp directory (mktemp)"
        return 1
    fi
    RU_INSTALLER_TEMP_DIR="$temp_dir"
    trap cleanup_temp_dir EXIT

    log_warn "Installing from main branch. This is NOT RECOMMENDED for production use."
    log_warn "The main branch may contain untested or breaking changes."
    echo "" >&2

    local script_url="$GITHUB_RAW/$REPO_OWNER/$REPO_NAME/main/$SCRIPT_NAME"

    log_step "Downloading ru from main branch..."
    if ! download_file "$script_url" "$temp_dir/$SCRIPT_NAME"; then
        log_error "Failed to download ru from main branch"
        return 1
    fi

    # No checksum verification for main branch
    install_script "$temp_dir/$SCRIPT_NAME" "$install_dir"
}

# Install the script to destination
install_script() {
    local source="$1"
    local install_dir="$2"
    local dest="$install_dir/$SCRIPT_NAME"

    # Create directory if needed
    if [[ ! -d "$install_dir" ]]; then
        log_step "Creating directory: $install_dir"
        if [[ "$install_dir" == "/usr/local/bin" ]]; then
            if ! command_exists sudo; then
                log_error "sudo is required to create $install_dir"
                return 1
            fi
            if ! sudo mkdir -p "$install_dir"; then
                log_error "Failed to create directory: $install_dir"
                return 1
            fi
        else
            if ! mkdir -p "$install_dir"; then
                log_error "Failed to create directory: $install_dir"
                return 1
            fi
        fi
    fi

    # Install with proper permissions
    log_step "Installing to $dest"
    if [[ "$install_dir" == "/usr/local/bin" ]]; then
        if ! command_exists sudo; then
            log_error "sudo is required to install to $install_dir"
            return 1
        fi
        if ! sudo cp "$source" "$dest"; then
            log_error "Failed to install: $dest"
            return 1
        fi
        if ! sudo chmod +x "$dest"; then
            log_error "Failed to make executable: $dest"
            return 1
        fi
    else
        if ! cp "$source" "$dest"; then
            log_error "Failed to install: $dest"
            return 1
        fi
        if ! chmod +x "$dest"; then
            log_error "Failed to make executable: $dest"
            return 1
        fi
    fi

    log_success "Installed ru to $dest"
}

# Add directory to PATH in shell config
add_to_path() {
    local dir="$1"
    local shell_config
    shell_config=$(get_shell_config)
    local shell_config_dir
    shell_config_dir=$(dirname "$shell_config")
    if [[ -n "$shell_config_dir" && ! -d "$shell_config_dir" ]]; then
        mkdir -p "$shell_config_dir" 2>/dev/null || true
    fi

    # Check if already configured
    # Use grep -F (fixed string) to avoid regex issues with dots in paths like .local
    if grep -qF "export PATH=\"$dir:" "$shell_config" 2>/dev/null; then
        log_info "$dir already in $shell_config"
        return 0
    fi

    log_step "Adding $dir to PATH in $shell_config"

    # Add to shell config with error checking
    if {
        printf '\n'
        printf '%s\n' "# Added by ru installer"
        printf '%s\n' "export PATH=\"$dir:\$PATH\""
    } >> "$shell_config" 2>/dev/null; then
        log_success "Added to $shell_config"
        log_info "Run 'source $shell_config' or start a new shell to update PATH"
    else
        log_error "Failed to write to $shell_config (check permissions)"
        return 1
    fi
}

#==============================================================================
# MAIN
#==============================================================================

main() {
    maybe_self_refresh_installer "$@"

    printf '\n' >&2
    printf '%b\n' "${BOLD}ru Installer${RESET}" >&2
    printf '%s\n' "────────────────────" >&2
    printf '\n' >&2

    # Determine install directory
    local install_dir
    install_dir=$(get_install_dir)

    # Check for required tools
    if ! command_exists curl && ! command_exists wget; then
        log_error "Either curl or wget is required. Please install one and try again."
        exit 1
    fi

    # Determine version and installation source
    if [[ -n "${RU_UNSAFE_MAIN:-}" ]] && [[ "$RU_UNSAFE_MAIN" == "1" ]]; then
        # Install from main branch (explicit request)
        log_info "Installing from main branch (RU_UNSAFE_MAIN=1)"
        install_from_main "$install_dir" || exit 1
    else
        # Install from release
        if [[ -n "${RU_VERSION:-}" ]]; then
            local version="${RU_VERSION#v}"
            log_info "Installing version: $version"
            install_from_release "$version" "$install_dir" || exit 1
        else
            log_step "Installing latest release..."
            install_from_latest_release "$install_dir"
            local rc=$?
            if [[ "$rc" -ne 0 ]]; then
                if [[ "$rc" -eq 2 ]]; then
                    log_warn "No releases found for this repository."
                    log_warn "Falling back to installation from main branch."
                    log_warn "This is equivalent to RU_UNSAFE_MAIN=1."
                    log_info "Tip: If you suspect caching, run: curl -fsSL \"$GITHUB_RAW/$REPO_OWNER/$REPO_NAME/main/install.sh?ru_cb=$RU_CACHE_BUST_TOKEN\" | bash"
                    printf '\n' >&2
                    install_from_main "$install_dir" || exit 1
                else
                    exit 1
                fi
            fi
        fi
    fi

    # Offer to install ntm for agent-sweep support
    maybe_install_ntm

    # Check PATH and offer to add if needed
    if ! in_path "$install_dir"; then
        log_warn "$install_dir is not in your PATH"

        # Check if we can prompt
        if [[ -t 0 ]]; then
            printf '\n' >&2
            printf 'Add %s to PATH? [y/N] ' "$install_dir" >&2
            IFS= read -r response
            case "$response" in
                [yY]|[yY][eE][sS])
                    add_to_path "$install_dir"
                    ;;
                *)
                    log_info "Skipped adding to PATH"
                    log_info "You can manually add it with:"
                    log_info "  export PATH=\"$install_dir:\$PATH\""
                    ;;
            esac
        else
            log_info "Add it to your PATH with:"
            log_info "  export PATH=\"$install_dir:\$PATH\""
        fi
    fi

    # Verify installation
    printf '\n' >&2
    local installed_path="$install_dir/$SCRIPT_NAME"
    if [[ -x "$installed_path" ]]; then
        log_success "Installation complete!"
        printf '\n' >&2

        if in_path "$install_dir" || [[ -n "${RU_UNSAFE_MAIN:-}" ]]; then
            log_info "Get started with:"
            log_info "  ru --help        Show all commands"
            log_info "  ru init          Initialize configuration"
            log_info "  ru add owner/repo  Add a repository"
            log_info "  ru sync          Sync all repositories"
        else
            log_info "Get started with:"
            log_info "  $installed_path --help"
        fi

        printf '\n' >&2
        log_info "Documentation: https://github.com/$REPO_OWNER/$REPO_NAME"
    else
        log_error "Installation may have failed. Check the output above."
        exit 1
    fi
}

main "$@"
