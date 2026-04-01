#!/usr/bin/env bash
# forge-welcome.sh — colorful welcome message for Tillandsias Forge
# Called by fish's config.fish on interactive startup.
# Uses ANSI escape codes for portability across terminals.

set -euo pipefail

# @trace spec:forge-welcome — bright colors for dark terminals, ramdisk distinction
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

# ── Locale detection ─────────────────────────────────────────
# Load locale bundle if not already loaded (forge-welcome.sh may be called
# directly by fish's config.fish, outside of the entrypoint context).
if [ -z "${L_WELCOME_TITLE:-}" ]; then
    _LOCALE_RAW="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
    _LOCALE="${_LOCALE_RAW%%_*}"
    _LOCALE="${_LOCALE%%.*}"
    _LOCALE_FILE="/etc/tillandsias/locales/${_LOCALE}.sh"
    [ -f "$_LOCALE_FILE" ] || _LOCALE_FILE="/etc/tillandsias/locales/en.sh"
    # shellcheck source=/dev/null
    [ -f "$_LOCALE_FILE" ] && source "$_LOCALE_FILE"
    unset _LOCALE_RAW _LOCALE _LOCALE_FILE
fi

# ── Locale string defaults (English fallback) ────────────────
L_WELCOME_TITLE="${L_WELCOME_TITLE:-🌱 Tillandsias Forge}"
L_WELCOME_PROJECT="${L_WELCOME_PROJECT:-Project}"
L_WELCOME_FORGE="${L_WELCOME_FORGE:-Forge}"
L_WELCOME_MOUNTS="${L_WELCOME_MOUNTS:-Mounts}"

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
# Load locale tips if available, fall back to English literals.
_tip1="${L_TIP_1:-Type help to learn about the Fish shell}"
_tip2="${L_TIP_2:-Try Midnight Commander with mc}"
_tip3="${L_TIP_3:-Browse files with eza --tree}"
_tip4="${L_TIP_4:-Use Tab for autocomplete suggestions}"
_tip5="${L_TIP_5:-Search history with Ctrl+R}"
_tip6="${L_TIP_6:-Smart directory jump with z <partial-name>}"
_tip7="${L_TIP_7:-Preview files with bat <filename>}"
_tip8="${L_TIP_8:-Find files fast with fd <pattern>}"
_tip9="${L_TIP_9:-Fuzzy-find anything with fzf}"
_tip10="${L_TIP_10:-View processes with htop}"
_tip11="${L_TIP_11:-Show directory tree with tree}"
_tip12="${L_TIP_12:-Edit files with vim or nano}"
_tip13="${L_TIP_13:-Fish highlights valid commands in green as you type}"
_tip14="${L_TIP_14:-Fish suggests from history — press → to accept}"
_tip15="${L_TIP_15:-Use .. to go up a directory}"
_tip16="${L_TIP_16:-List files in detail with ll}"
_tip17="${L_TIP_17:-Switch to bash anytime: type bash}"
_tip18="${L_TIP_18:-Switch to zsh anytime: type zsh}"
_tip19="${L_TIP_19:-Check git status with git status}"
_tip20="${L_TIP_20:-GitHub CLI: gh repo view, gh pr list}"

tips=(
    "$_tip1"
    "$_tip2"
    "$_tip3"
    "$_tip4"
    "$_tip5"
    "$_tip6"
    "$_tip7"
    "$_tip8"
    "$_tip9"
    "$_tip10"
    "$_tip11"
    "$_tip12"
    "$_tip13"
    "$_tip14"
    "$_tip15"
    "$_tip16"
    "$_tip17"
    "$_tip18"
    "$_tip19"
    "$_tip20"
)
tip="${tips[$((RANDOM % ${#tips[@]}))]}"

# ── Arrow ─────────────────────────────────────────────────────
A="${DIM}←${RST}"

# ── Print ─────────────────────────────────────────────────────
echo ""
printf "  ${B_GREEN}%s${RST}\n" "$L_WELCOME_TITLE"
echo ""
printf "  ${B_WHITE}%s${RST}   ${B_CYAN}%s${RST}\n" "$L_WELCOME_PROJECT" "$PROJECT"
printf "  ${B_WHITE}%s${RST}     ${ITAL}%s${RST}  ${DIM}+${RST}  ${ITAL}%s${RST}\n" "$L_WELCOME_FORGE" "$GUEST_OS" "$HOST_OS"
echo ""
printf "  ${B_WHITE}%s${RST}\n" "$L_WELCOME_MOUNTS"
printf "    ${B_GREEN}%-38s${RST} ${A} ${DIM}%-26s${RST} ${B_GREEN}rw${RST}\n" \
    "/home/forge/src/$PROJECT"  "~/src/$PROJECT"
printf "    ${B_GREEN}%-38s${RST} ${A} ${DIM}%-26s${RST} ${B_GREEN}rw${RST}\n" \
    "/home/forge/.cache/tillandsias"      "~/.cache/tillandsias"
# @trace spec:forge-welcome — mount table with ramdisk awareness
printf "    ${D_RED}%-38s${RST} ${A} ${B_BLUE}%-26s${RST} ${B_RED}ro${RST}\n" \
    "/home/forge/.config/gh"              "secrets/gh"
printf "    ${D_RED}%-38s${RST} ${A} ${B_BLUE}%-26s${RST} ${B_RED}ro${RST}\n" \
    "/home/forge/.config/tillandsias-git" "secrets/git"
if [ -f /run/secrets/github_token ]; then
    printf "    ${D_RED}%-38s${RST} ${A} ${B_MAGENTA}%-26s${RST} ${B_MAGENTA}ro*${RST}\n" \
        "/run/secrets/github_token"           "ramdisk"
fi
echo ""
printf "    ${B_MAGENTA}* ramdisk — never touches disk, RAM-only${RST}\n"
echo ""
printf "  ${B_YELLOW}→${RST} Project at ${B_WHITE}/home/forge/src/%s${RST}\n" "$PROJECT"
echo ""
printf "  💡 %b\n" "$tip"
echo ""
