#!/usr/bin/env bash
# @trace spec:error-message-localization
# lib-localized-errors.sh — Localized error message templates
# Provides error functions that detect locale via L_* variables and emit
# localized error messages with recovery hints.
#
# Usage: source this file, then call error_* functions
# Example: error_container_failed "Failed to start container my-app"
#
# Locale detection: Assumes L_* variables are already loaded from locale bundle
# (e.g., via forge-welcome.sh). Falls back to English if not available.

# Detect if locale has been loaded (check for a known locale variable)
# If not, load English defaults
if [ -z "${L_BANNER_FORGE:-}" ]; then
    _LOCALE_RAW="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
    _LOCALE="${_LOCALE_RAW%%_*}"
    _LOCALE="${_LOCALE%%.*}"
    _LOCALE_FILE="/etc/tillandsias/locales/${_LOCALE}.sh"
    [ -f "$_LOCALE_FILE" ] || _LOCALE_FILE="/etc/tillandsias/locales/en.sh"
    [ -f "$_LOCALE_FILE" ] && source "$_LOCALE_FILE" 2>/dev/null
    unset _LOCALE_RAW _LOCALE _LOCALE_FILE
fi

# Set default error messages if not in locale bundle (English fallback)
L_ERROR_CONTAINER_FAILED="${L_ERROR_CONTAINER_FAILED:-ERROR: Container failed to start}"
L_ERROR_CONTAINER_HINT="${L_ERROR_CONTAINER_HINT:-Try restarting the container or checking logs for details.}"

L_ERROR_IMAGE_MISSING="${L_ERROR_IMAGE_MISSING:-ERROR: Container image not found}"
L_ERROR_IMAGE_HINT="${L_ERROR_IMAGE_HINT:-Rebuild the image or check that it exists. Verify disk space for large images.}"

L_ERROR_NETWORK="${L_ERROR_NETWORK:-ERROR: Network error}"
L_ERROR_NETWORK_HINT="${L_ERROR_NETWORK_HINT:-Check proxy settings (HTTPS_PROXY env) and that network services are running.}"

L_ERROR_GIT_CLONE="${L_ERROR_GIT_CLONE:-ERROR: Git clone failed}"
L_ERROR_GIT_HINT="${L_ERROR_GIT_HINT:-Verify credentials, SSH keys, or restart the git service. Check git config.}"

L_ERROR_AUTH="${L_ERROR_AUTH:-ERROR: Authentication failed}"
L_ERROR_AUTH_HINT="${L_ERROR_AUTH_HINT:-Re-setup credentials with 'gh auth login' or check git config.}"

# error_container_failed — container failed to start
# Usage: error_container_failed "details about the failure"
error_container_failed() {
    local details="${1:-unknown error}"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "$L_ERROR_CONTAINER_FAILED"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "Details: $details"
    echo ""
    echo "$L_ERROR_CONTAINER_HINT"
    echo ""
}

# error_image_missing — container image is missing or inaccessible
# Usage: error_image_missing "image:tag"
error_image_missing() {
    local image="${1:-unknown image}"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "$L_ERROR_IMAGE_MISSING: $image"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "$L_ERROR_IMAGE_HINT"
    echo ""
}

# error_network — network-related failure (proxy, DNS, connection timeout)
# Usage: error_network "operation" (e.g., "proxy cache", "git clone")
error_network() {
    local operation="${1:-network request}"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "$L_ERROR_NETWORK: $operation"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "$L_ERROR_NETWORK_HINT"
    echo ""
}

# error_git_clone — git clone operation failed
# Usage: error_git_clone "project-name" "reason" (e.g., auth, network)
error_git_clone() {
    local project="${1:-unknown project}"
    local reason="${2:-unknown reason}"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "$L_ERROR_GIT_CLONE: $project"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "Reason: $reason"
    echo ""
    echo "$L_ERROR_GIT_HINT"
    echo ""
}

# error_auth — authentication failure (git, GitHub, etc.)
# Usage: error_auth "operation" "service" (e.g., "push", "gh")
error_auth() {
    local operation="${1:-operation}"
    local service="${2:-service}"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "$L_ERROR_AUTH: $operation ($service)"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "$L_ERROR_AUTH_HINT"
    echo ""
}
