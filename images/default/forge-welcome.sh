#!/usr/bin/env bash
# forge-welcome.sh — colorful welcome message for Tillandsias Forge
# Called by fish's config.fish on interactive startup.
# Uses ANSI escape codes for portability across terminals.

set -euo pipefail

# ── Colors (bright variants for dark backgrounds) ────────────
RST=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
ITAL=$'\033[3m'
B_RED=$'\033[1;91m'        # bright red
B_GREEN=$'\033[1;92m'      # bright green
B_YELLOW=$'\033[1;93m'     # bright yellow
B_BLUE=$'\033[1;94m'       # bright blue
B_MAGENTA=$'\033[1;95m'    # bright magenta
B_CYAN=$'\033[1;96m'       # bright cyan
B_WHITE=$'\033[1;97m'      # bright white
D_GREEN=$'\033[32m'        # dim green
D_RED=$'\033[31m'          # dim red
D_BLUE=$'\033[34m'         # dim blue

# ── Environment ──────────────────────────────────────────────
PROJECT="${TILLANDSIAS_PROJECT:-unknown}"
HOST_OS="${TILLANDSIAS_HOST_OS:-Unknown OS}"

# ── Guest OS detection ────────────────────────────────────────
GUEST_OS="Nix (Minimal)"
if [ -f /etc/os-release ]; then
    _name="" _version="" _variant=""
    while IFS='=' read -r key value; do
        value="${value%\"}" ; value="${value#\"}"
        case "$key" in
            NAME)       _name="$value" ;;
            VERSION_ID) _version="$value" ;;
            VARIANT)    _variant="$value" ;;
        esac
    done < /etc/os-release
    [ -n "$_variant" ] && GUEST_OS="${_name} ${_version} (${_variant})"
    [ -z "$_variant" ] && [ -n "$_name" ] && GUEST_OS="${_name} ${_version}"
fi

# ── Rotating tips ─────────────────────────────────────────────
tips=(
    "Type ${B_WHITE}help${RST} to learn about the Fish shell"
    "Try Midnight Commander with ${B_WHITE}mc${RST}"
    "Browse files with ${B_WHITE}eza --tree${RST}"
    "Use ${B_WHITE}Tab${RST} for autocomplete suggestions"
    "Search history with ${B_WHITE}Ctrl+R${RST}"
    "Smart directory jump with ${B_WHITE}z <partial-name>${RST}"
    "Preview files with ${B_WHITE}bat <filename>${RST}"
    "Find files fast with ${B_WHITE}fd <pattern>${RST}"
    "Fuzzy-find anything with ${B_WHITE}fzf${RST}"
    "View processes with ${B_WHITE}htop${RST}"
    "Show directory tree with ${B_WHITE}tree${RST}"
    "Edit files with ${B_WHITE}vim${RST} or ${B_WHITE}nano${RST}"
    "Fish highlights ${B_WHITE}valid commands${RST} in green as you type"
    "Fish suggests from ${B_WHITE}history${RST} — press ${B_WHITE}→${RST} to accept"
    "Use ${B_WHITE}..${RST} to go up a directory"
    "List files in detail with ${B_WHITE}ll${RST}"
    "Switch to bash anytime: type ${B_WHITE}bash${RST}"
    "Switch to zsh anytime: type ${B_WHITE}zsh${RST}"
    "Check git status with ${B_WHITE}git status${RST}"
    "GitHub CLI: ${B_WHITE}gh repo view${RST}, ${B_WHITE}gh pr list${RST}"
)
tip="${tips[$((RANDOM % ${#tips[@]}))]}"

# ── Arrow ─────────────────────────────────────────────────────
A="${DIM}←${RST}"

# ── Print ─────────────────────────────────────────────────────
echo ""
printf "  ${B_GREEN}🌱 Tillandsias Forge${RST}\n"
echo ""
printf "  ${B_WHITE}Project${RST}   ${B_CYAN}%s${RST}\n" "$PROJECT"
printf "  ${B_WHITE}Forge${RST}     ${ITAL}%s${RST}  ${DIM}+${RST}  ${ITAL}%s${RST}\n" "$GUEST_OS" "$HOST_OS"
echo ""
printf "  ${B_WHITE}Mounts${RST}\n"
printf "    ${B_GREEN}%-38s${RST} ${A} ${DIM}%-26s${RST} ${B_GREEN}rw${RST}\n" \
    "/home/forge/src/$PROJECT"  "~/src/$PROJECT"
printf "    ${B_GREEN}%-38s${RST} ${A} ${DIM}%-26s${RST} ${B_GREEN}rw${RST}\n" \
    "/home/forge/.cache/tillandsias"      "~/.cache/tillandsias"
printf "    ${D_RED}%-38s${RST} ${A} ${D_BLUE}%-26s${RST} ${B_RED}ro${RST}\n" \
    "/home/forge/.config/gh"              "secrets/gh"
printf "    ${D_RED}%-38s${RST} ${A} ${D_BLUE}%-26s${RST} ${B_RED}ro${RST}\n" \
    "/home/forge/.config/tillandsias-git" "secrets/git"
echo ""
printf "  ${B_YELLOW}→${RST} Project at ${B_WHITE}/home/forge/src/%s${RST}\n" "$PROJECT"
echo ""
printf "  💡 %b\n" "$tip"
echo ""
