#!/usr/bin/env bash
#
# ru installer
# Downloads and installs ru (Repo Updater) to your system
#
# DEFAULT: Downloads from GitHub Release with checksum verification
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/repo_updater/main/install.sh | bash
#
# Options (via environment variables):
#   DEST=/path/to/dir      Install directory (default: ~/.local/bin)
#   RU_SYSTEM=1            Install to /usr/local/bin (requires sudo)
#   RU_VERSION=x.y.z       Install specific version (default: latest release)
#   RU_UNSAFE_MAIN=1       Install from main branch (NOT RECOMMENDED)
#
# Examples:
#   # Standard installation (recommended)
#   curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/repo_updater/main/install.sh | bash
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
GITHUB_API="https://api.github.com"
GITHUB_RAW="https://raw.githubusercontent.com"

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

# Get latest release version from GitHub
get_latest_release() {
    local url="$GITHUB_API/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    local response

    if command_exists curl; then
        response=$(curl -sS "$url" 2>/dev/null) || {
            log_error "Failed to fetch latest release from GitHub"
            return 1
        }
    elif command_exists wget; then
        response=$(wget -qO- "$url" 2>/dev/null) || {
            log_error "Failed to fetch latest release from GitHub"
            return 1
        }
    else
        log_error "Neither curl nor wget found. Please install one of them."
        return 1
    fi

    # Extract tag_name from JSON (simple grep approach for portability)
    local version
    version=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -z "$version" ]]; then
        log_error "Could not parse version from GitHub API response"
        return 1
    fi

    # Remove 'v' prefix if present
    echo "${version#v}"
}

# Download a file
download_file() {
    local url="$1"
    local dest="$2"

    if command_exists curl; then
        curl -fsSL "$url" -o "$dest"
    elif command_exists wget; then
        wget -q "$url" -O "$dest"
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

# Install from GitHub Release (with checksum verification)
install_from_release() {
    local version="$1"
    local install_dir="$2"
    local temp_dir

    if ! temp_dir=$(mktemp -d 2>/dev/null); then
        log_error "Failed to create temp directory (mktemp)"
        return 1
    fi
    trap 'rm -rf "$temp_dir"' EXIT

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
        expected_checksum=$(grep -E "^[a-f0-9]{64}[[:space:]]+\*?$SCRIPT_NAME$" "$temp_dir/checksums.txt" | cut -d' ' -f1)

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

    if ! temp_dir=$(mktemp -d 2>/dev/null); then
        log_error "Failed to create temp directory (mktemp)"
        return 1
    fi
    trap 'rm -rf "$temp_dir"' EXIT

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
    if grep -q "export PATH=.*$dir" "$shell_config" 2>/dev/null; then
        log_info "$dir already in $shell_config"
        return 0
    fi

    log_step "Adding $dir to PATH in $shell_config"

    # Add to shell config
    {
        printf '\n'
        printf '%s\n' "# Added by ru installer"
        printf '%s\n' "export PATH=\"$dir:\$PATH\""
    } >> "$shell_config"

    log_success "Added to $shell_config"
    log_info "Run 'source $shell_config' or start a new shell to update PATH"
}

#==============================================================================
# MAIN
#==============================================================================

main() {
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
        # Install from main branch
        log_info "Installing from main branch (RU_UNSAFE_MAIN=1)"
        install_from_main "$install_dir" || exit 1
    else
        # Install from release
        local version
        if [[ -n "${RU_VERSION:-}" ]]; then
            version="$RU_VERSION"
            log_info "Installing version: $version"
        else
            log_step "Fetching latest release version..."
            version=$(get_latest_release) || exit 1
            log_info "Latest version: $version"
        fi

        install_from_release "$version" "$install_dir" || exit 1
    fi

    # Check PATH and offer to add if needed
    if ! in_path "$install_dir"; then
        log_warn "$install_dir is not in your PATH"

        # Check if we can prompt
        if [[ -t 0 ]]; then
            printf '\n' >&2
            read -rp "Add $install_dir to PATH? [y/N] " response
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
