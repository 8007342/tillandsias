#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/../.." && pwd)"
log_dir="$root/target/litmus-podman"
log_file="$log_dir/github-login.log"
calls_file="$log_dir/calls.log"
state_home="${TMPDIR:-/tmp}/tillandsias-credential-home"

mkdir -p "$log_dir"
rm -rf "$log_dir/.fake-podman-state" "$log_file" "$calls_file"

export HOME="$state_home"
export PATH="$root/target/litmus-runtime/bin:$PATH"
export LITMUS_PODMAN_MODE=fake
export LITMUS_PODMAN_CALLS_FILE="$calls_file"
export LITMUS_FAKE_GITHUB_TOKEN="${LITMUS_FAKE_GITHUB_TOKEN:-mock-github-token}"

podman_bin="$root/target/litmus-runtime/bin/podman"
container_name="tillandsias-gh-login-shape"

# Seed a fake vault token so vault-cli.sh has something to authenticate with
secret_dir="${LITMUS_PODMAN_STATE_DIR:-$(dirname "$calls_file")/.fake-podman-state}/secrets"
mkdir -p "$secret_dir"
printf 'mock-vault-token' >"$secret_dir/vault-token"

"$podman_bin" run --detach --rm --name "$container_name" \
  --cap-drop=ALL --security-opt=no-new-privileges --userns=keep-id \
  --entrypoint /bin/sh tillandsias-git:v0.1.260507.1 \
  -c "trap 'exit 0' TERM INT; while :; do sleep 3600 & wait \$!; done" \
  >"$log_file" 2>&1

"$podman_bin" exec --interactive --tty "$container_name" gh auth login \
  --hostname github.com --git-protocol https >/dev/null 2>&1

# Automation path: the caller's stdin flows directly into podman exec, without
# a pseudo-terminal or a host-side token read.
printf '%s\n' "$LITMUS_FAKE_GITHUB_TOKEN" | \
  "$podman_bin" exec --interactive "$container_name" /bin/bash -c \
  'IFS= read -r TOKEN; printf "%s" "$TOKEN" | gh auth login --hostname github.com --git-protocol https --with-token' \
  >/dev/null 2>&1

# Write token to Vault from inside the container (no host extraction)
"$podman_bin" exec "$container_name" /bin/sh -c \
  "TOKEN=\$(gh auth token --hostname github.com) || exit \$?; [ -n \"\$TOKEN\" ] || exit 1; printf '%s' \"\$TOKEN\" | vault-cli.sh write-stdin secret/github/token token" \
  >/dev/null 2>&1

"$podman_bin" rm -f "$container_name" >/dev/null 2>&1

grep -F 'podman run --detach --rm --name tillandsias-gh-login-shape' "$calls_file" >/dev/null
grep -F 'podman exec --interactive --tty tillandsias-gh-login-shape gh auth login --hostname github.com --git-protocol https' "$calls_file" >/dev/null
grep -F 'podman exec --interactive tillandsias-gh-login-shape /bin/bash -c' "$calls_file" | \
  grep -F -- '--with-token' >/dev/null
if grep -F 'podman exec --interactive --tty tillandsias-gh-login-shape /bin/bash -c' "$calls_file" >/dev/null; then
  printf 'stdin-token login unexpectedly allocated a TTY\n' >&2
  exit 1
fi
grep 'vault-cli.sh.*write-stdin.*secret/github/token' "$calls_file" >/dev/null

printf 'GitHub login smoke completed\n'
