#!/bin/sh
# git-askpass-tillandsias.sh — GIT_ASKPASS helper for the tillandsias-git image.
#
# Git invokes `$GIT_ASKPASS <prompt>` whenever an HTTPS remote challenges for
# credentials. The argument is a free-text prompt like "Username for
# 'https://github.com':" or "Password for 'https://x-access-token@github.com':".
# We respond deterministically based on which prompt type git is asking for.
#
# The host tray has already bind-mounted the GitHub OAuth token at
# /run/secrets/github_token (mode 0600/0644, :ro). We read that file and
# echo either the username literal ("x-access-token") or the token itself.
# GitHub's HTTPS auth accepts `x-access-token:<TOKEN>` for OAuth-app and
# user-to-server tokens alike.
#
# Fatal behavior: if the token file is missing, print to stderr and exit
# non-zero so git surfaces a clear error rather than silently sending an
# empty password.
#
# @trace spec:secrets-management, spec:git-mirror-service, spec:native-secrets-store

set -eu

TOKEN_FILE="${TILLANDSIAS_GITHUB_TOKEN_FILE:-/run/secrets/github_token}"
PROMPT="${1:-}"

case "$PROMPT" in
    Username*|username*|"User"*)
        printf 'x-access-token'
        ;;
    Password*|password*)
        if [ ! -r "$TOKEN_FILE" ]; then
            echo "[git-askpass-tillandsias] FATAL: token file not found or unreadable at $TOKEN_FILE" >&2
            echo "[git-askpass-tillandsias] The host tray must inject the GitHub OAuth token." >&2
            exit 1
        fi
        # `cat` prints the exact file bytes. The token file is written
        # without a trailing newline by secrets::prepare_token_file.
        cat -- "$TOKEN_FILE"
        ;;
    *)
        # Unknown prompt shape — refuse rather than leak. Git will fall back
        # to its usual "could not read" error, which tells the user something
        # unusual is happening.
        echo "[git-askpass-tillandsias] Unknown prompt: $PROMPT" >&2
        exit 1
        ;;
esac
