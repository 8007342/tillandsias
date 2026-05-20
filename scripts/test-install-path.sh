#!/usr/bin/env bash
# @trace spec:install-progress, spec:linux-native-portable-executable
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_file_contains_once() {
    local file="$1"
    local needle="$2"
    local count

    count="$(grep -F "$needle" "$file" | wc -l | tr -d '[:space:]')"
    if [[ "$count" != "1" ]]; then
        echo "expected one '$needle' entry in $file, found $count" >&2
        exit 1
    fi
}

test_persists_profile_path_once() {
    local tmp home
    tmp="$(mktemp -d -t tillandsias-install-path.XXXXXX)"
    home="$tmp/home"
    mkdir -p "$home"

    (
        export TILLANDSIAS_INSTALL_TEST_MODE=1
        export HOME="$home"
        export PATH="/usr/bin:/bin"
        export SHELL="/bin/bash"
        # shellcheck disable=SC1091
        source "$ROOT/scripts/install.sh"

        INSTALL_DIR="$HOME/.local/bin"
        persist_path_setup
        persist_path_setup

        assert_file_contains_once "$HOME/.profile" "# >>> tillandsias PATH >>>"
        assert_file_contains_once "$HOME/.profile" "export PATH=\"$INSTALL_DIR:\$PATH\""
        assert_file_contains_once "$HOME/.bashrc" "# >>> tillandsias PATH >>>"
        assert_file_contains_once "$HOME/.bashrc" "export PATH=\"$INSTALL_DIR:\$PATH\""
    )

    rm -rf "$tmp"
}

test_prefers_safe_user_bin_on_path() {
    local tmp home selected
    tmp="$(mktemp -d -t tillandsias-install-path.XXXXXX)"
    home="$tmp/home"
    mkdir -p "$home/bin"

    (
        export TILLANDSIAS_INSTALL_TEST_MODE=1
        export HOME="$home"
        export PATH="$home/bin:/usr/bin:/bin"
        # shellcheck disable=SC1091
        source "$ROOT/scripts/install.sh"

        selected="$(resolve_install_dir)"
        if [[ "$selected" != "$HOME/bin" ]]; then
            echo "expected HOME/bin install dir, got $selected" >&2
            exit 1
        fi
    )

    rm -rf "$tmp"
}

test_fish_path_block_is_idempotent() {
    local tmp home
    tmp="$(mktemp -d -t tillandsias-install-path.XXXXXX)"
    home="$tmp/home"
    mkdir -p "$home/.config/fish"

    (
        export TILLANDSIAS_INSTALL_TEST_MODE=1
        export HOME="$home"
        export PATH="/usr/bin:/bin"
        export SHELL="/usr/bin/fish"
        # shellcheck disable=SC1091
        source "$ROOT/scripts/install.sh"

        INSTALL_DIR="$HOME/.local/bin"
        persist_path_setup
        persist_path_setup

        assert_file_contains_once "$HOME/.config/fish/conf.d/tillandsias.fish" "# >>> tillandsias PATH >>>"
        assert_file_contains_once "$HOME/.config/fish/conf.d/tillandsias.fish" "set -gx PATH \"$INSTALL_DIR\" \$PATH"
    )

    rm -rf "$tmp"
}

test_persists_profile_path_once
test_prefers_safe_user_bin_on_path
test_fish_path_block_is_idempotent

echo "installer PATH tests passed"
