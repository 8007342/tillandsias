#!/bin/sh
# GIT_ASKPASS helper for Tillandsias forge containers.
# Reads a GitHub token from the mounted secrets path and returns it
# as the password when git asks for credentials.
#
# @trace spec:secret-rotation
case "$1" in
  *assword*) cat /run/secrets/github_token 2>/dev/null || echo "" ;;
  *sername*) echo "x-access-token" ;;
esac
