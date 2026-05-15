#!/usr/bin/env bash
# Dependency Resolver: Forge Dependency Scanner
# @trace spec:forge-environment-discoverability, gap:ON-010
# Scans a project for missing dependencies before launch.
#
# Tools:
#   scan_dependencies  — detect dependency files and check for missing tools
#   check_rust_tools   — verify Rust toolchain (rustc, cargo)
#   check_node_tools   — verify Node.js toolchain (node, npm/yarn/pnpm/bun)
#   check_python_tools — verify Python toolchain (python3, pip)
#   check_go_tools     — verify Go toolchain (go)
#   check_make_tools   — verify Make toolchain (make)
#   check_nix_tools    — verify Nix toolchain (nix)
#   check_docker_tools — verify Docker toolchain (docker/podman)
#
# Output: JSON with missing dependencies, tool versions, and install recommendations
#
# @cheatsheet runtime/forge-environment-discoverability.md

set -euo pipefail

# ── Tool availability checks ────────────────────────────────────
# @trace gap:ON-010, spec:forge-environment-discoverability

# Check if a command exists in PATH
cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Get version string for a tool
get_version() {
    local tool="$1"
    local flag="${2:---version}"

    if cmd_exists "$tool"; then
        "$tool" "$flag" 2>&1 | head -1 | sed 's/^[^0-9]*//; s/[^0-9.].*//'
    else
        echo "not_installed"
    fi
}

# ── Rust toolchain checks ────────────────────────────────────────
# @trace gap:ON-010
check_rust_tools() {
    local project_dir="${1:-.}"
    local missing=""
    local tools=""

    # Check for Cargo.toml (Rust project marker)
    if [ ! -f "$project_dir/Cargo.toml" ]; then
        echo "[]"
        return
    fi

    # rustc (Rust compiler)
    if ! cmd_exists rustc; then
        missing="$missing rustc"
    else
        tools="$tools {\"tool\":\"rustc\",\"version\":\"$(get_version rustc)\"}"
    fi

    # cargo (Rust package manager)
    if ! cmd_exists cargo; then
        missing="$missing cargo"
    else
        tools="$tools {\"tool\":\"cargo\",\"version\":\"$(get_version cargo)\"}"
    fi

    # Format output
    if [ -n "$missing" ]; then
        echo "["
        local first=1
        for tool in $missing; do
            [ $first -eq 0 ] && echo ","
            echo -n "{\"tool\":\"$tool\",\"type\":\"rust\",\"install\":\"rustup\"}"
            first=0
        done
        echo "]"
    else
        echo "[]"
    fi
}

# ── Node.js toolchain checks ─────────────────────────────────────
# @trace gap:ON-010
check_node_tools() {
    local project_dir="${1:-.}"
    local missing=""
    local package_manager=""

    # Detect package manager from lock files
    if [ -f "$project_dir/package-lock.json" ]; then
        package_manager="npm"
    elif [ -f "$project_dir/yarn.lock" ]; then
        package_manager="yarn"
    elif [ -f "$project_dir/pnpm-lock.yaml" ]; then
        package_manager="pnpm"
    elif [ -f "$project_dir/bun.lockb" ]; then
        package_manager="bun"
    elif [ -f "$project_dir/package.json" ]; then
        package_manager="npm"  # default
    else
        echo "[]"
        return
    fi

    # node (JavaScript runtime)
    if ! cmd_exists node; then
        missing="$missing node"
    fi

    # package manager
    if [ -n "$package_manager" ] && ! cmd_exists "$package_manager"; then
        missing="$missing $package_manager"
    fi

    # Format output
    if [ -n "$missing" ]; then
        echo "["
        local first=1
        for tool in $missing; do
            [ $first -eq 0 ] && echo ","
            echo -n "{\"tool\":\"$tool\",\"type\":\"node\",\"install\":\"nvm or distro package manager\"}"
            first=0
        done
        echo "]"
    else
        echo "[]"
    fi
}

# ── Python toolchain checks ──────────────────────────────────────
# @trace gap:ON-010
check_python_tools() {
    local project_dir="${1:-.}"
    local missing=""
    local package_manager=""

    # Detect Python requirement files
    if [ ! -f "$project_dir/requirements.txt" ] && \
       [ ! -f "$project_dir/setup.py" ] && \
       [ ! -f "$project_dir/setup.cfg" ] && \
       [ ! -f "$project_dir/pyproject.toml" ] && \
       [ ! -f "$project_dir/poetry.lock" ] && \
       [ ! -f "$project_dir/Pipfile" ]; then
        echo "[]"
        return
    fi

    # python3 (Python interpreter)
    if ! cmd_exists python3; then
        missing="$missing python3"
    fi

    # Detect and check package manager
    if [ -f "$project_dir/poetry.lock" ]; then
        package_manager="poetry"
    elif [ -f "$project_dir/Pipfile" ]; then
        package_manager="pipenv"
    elif [ -f "$project_dir/requirements.txt" ]; then
        package_manager="pip"
    else
        package_manager="pip"  # default
    fi

    if [ -n "$package_manager" ] && ! cmd_exists "$package_manager"; then
        missing="$missing $package_manager"
    fi

    # Format output
    if [ -n "$missing" ]; then
        echo "["
        local first=1
        for tool in $missing; do
            [ $first -eq 0 ] && echo ","
            echo -n "{\"tool\":\"$tool\",\"type\":\"python\",\"install\":\"distro package manager or pyenv\"}"
            first=0
        done
        echo "]"
    else
        echo "[]"
    fi
}

# ── Go toolchain checks ──────────────────────────────────────────
# @trace gap:ON-010
check_go_tools() {
    local project_dir="${1:-.}"
    local missing=""

    # Check for go.mod (Go project marker)
    if [ ! -f "$project_dir/go.mod" ] && [ ! -f "$project_dir/go.sum" ]; then
        echo "[]"
        return
    fi

    # go (Go compiler)
    if ! cmd_exists go; then
        missing="$missing go"
    fi

    # Format output
    if [ -n "$missing" ]; then
        echo "["
        echo -n "{\"tool\":\"go\",\"type\":\"go\",\"install\":\"golang.org/dl or distro package manager\"}"
        echo "]"
    else
        echo "[]"
    fi
}

# ── Make toolchain checks ────────────────────────────────────────
# @trace gap:ON-010
check_make_tools() {
    local project_dir="${1:-.}"
    local missing=""

    # Check for Makefile (Make project marker)
    if [ ! -f "$project_dir/Makefile" ]; then
        echo "[]"
        return
    fi

    # make (Build tool)
    if ! cmd_exists make; then
        missing="$missing make"
    fi

    # Format output
    if [ -n "$missing" ]; then
        echo "["
        echo -n "{\"tool\":\"make\",\"type\":\"build\",\"install\":\"distro package manager\"}"
        echo "]"
    else
        echo "[]"
    fi
}

# ── Nix toolchain checks ─────────────────────────────────────────
# @trace gap:ON-010
check_nix_tools() {
    local project_dir="${1:-.}"
    local missing=""

    # Check for flake.nix (Nix project marker)
    if [ ! -f "$project_dir/flake.nix" ]; then
        echo "[]"
        return
    fi

    # nix (Nix package manager)
    if ! cmd_exists nix; then
        missing="$missing nix"
    fi

    # direnv (Environment manager, optional but recommended for Nix)
    if [ -f "$project_dir/.envrc" ] && ! cmd_exists direnv; then
        missing="$missing direnv"
    fi

    # Format output
    if [ -n "$missing" ]; then
        echo "["
        local first=1
        for tool in $missing; do
            [ $first -eq 0 ] && echo ","
            echo -n "{\"tool\":\"$tool\",\"type\":\"nix\",\"install\":\"https://nixos.org/download\"}"
            first=0
        done
        echo "]"
    else
        echo "[]"
    fi
}

# ── Docker/Podman toolchain checks ───────────────────────────────
# @trace gap:ON-010
check_docker_tools() {
    local project_dir="${1:-.}"
    local missing=""

    # Check for Dockerfile (Docker project marker)
    if [ ! -f "$project_dir/Dockerfile" ] && [ ! -f "$project_dir/Containerfile" ]; then
        echo "[]"
        return
    fi

    # docker or podman (container runtime)
    if ! cmd_exists docker && ! cmd_exists podman; then
        missing="docker_or_podman"
    fi

    # Format output
    if [ -n "$missing" ]; then
        echo "["
        echo -n "{\"tool\":\"container runtime\",\"type\":\"container\",\"install\":\"docker or podman (distro package manager)\"}"
        echo "]"
    else
        echo "[]"
    fi
}

# ── Main dependency scanner ──────────────────────────────────────
# @trace gap:ON-010, spec:forge-environment-discoverability
# Scans all project types and aggregates missing dependencies
scan_dependencies() {
    local project_dir="${1:-.}"

    # Collect all missing dependencies from all project types
    local all_missing=()

    # Check each project type
    local rust_missing=$(check_rust_tools "$project_dir")
    local node_missing=$(check_node_tools "$project_dir")
    local python_missing=$(check_python_tools "$project_dir")
    local go_missing=$(check_go_tools "$project_dir")
    local make_missing=$(check_make_tools "$project_dir")
    local nix_missing=$(check_nix_tools "$project_dir")
    local docker_missing=$(check_docker_tools "$project_dir")

    # Merge results into single JSON array
    # Simple approach: concatenate all and remove leading/trailing brackets
    echo "["

    local first=1

    for item in $(echo "$rust_missing" | grep -o '{[^}]*}' || true); do
        [ $first -eq 0 ] && echo ","
        echo -n "$item"
        first=0
    done

    for item in $(echo "$node_missing" | grep -o '{[^}]*}' || true); do
        [ $first -eq 0 ] && echo ","
        echo -n "$item"
        first=0
    done

    for item in $(echo "$python_missing" | grep -o '{[^}]*}' || true); do
        [ $first -eq 0 ] && echo ","
        echo -n "$item"
        first=0
    done

    for item in $(echo "$go_missing" | grep -o '{[^}]*}' || true); do
        [ $first -eq 0 ] && echo ","
        echo -n "$item"
        first=0
    done

    for item in $(echo "$make_missing" | grep -o '{[^}]*}' || true); do
        [ $first -eq 0 ] && echo ","
        echo -n "$item"
        first=0
    done

    for item in $(echo "$nix_missing" | grep -o '{[^}]*}' || true); do
        [ $first -eq 0 ] && echo ","
        echo -n "$item"
        first=0
    done

    for item in $(echo "$docker_missing" | grep -o '{[^}]*}' || true); do
        [ $first -eq 0 ] && echo ","
        echo -n "$item"
        first=0
    done

    echo "]"
}

# ── Usage and entry point ────────────────────────────────────────
# This script can be sourced or executed directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    # Direct execution: scan_dependencies <project_dir>
    project_dir="${1:-.}"
    scan_dependencies "$project_dir"
fi
