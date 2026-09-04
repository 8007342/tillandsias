#!/usr/bin/env bash
# @trace order:998-3z6g, order:975-rsgm
#
# check-ca-bind-migration.sh — does any existing container bind a CA directory
# that is no longer the declared one?
#
# WHY THIS IS NEEDED AT ALL, and why it is separate from changing the value.
# Podman records a bind SOURCE in the container's stored definition at CREATION.
# Changing images/default/ca-path.txt makes every NEW container correct and
# leaves every EXISTING one binding a path that will not be there. `podman
# start` then fails with:
#
#   crun: cannot stat `<old>/intermediate.crt`: No such file or directory
#
# — which is the exact failure 975-rsgm is about, reintroduced by its own fix.
# So the relocation is not a constant change: it needs affected containers
# RECREATED, not restarted, and it needs to KNOW which ones are affected rather
# than assuming a fresh host.
#
# REPORTS, NEVER ACTS. Recreating a container is a mutation with a blast radius
# (the proxy is the enclave's only egress path), and a check that silently
# rebuilt containers would be a worse failure than the one it fixes. It names
# what must be recreated and stops.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:ca-bind-current:[0-9]+|migrate:ca-bind-stale:[0-9]+|skip:[a-z0-9-]+)$
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-ca-path.sh"

command -v podman >/dev/null 2>&1 || { echo "skip:no-podman"; exit 0; }

checked=0
stale=0
detail=""

# Every container, not just the proxy: remote_projects.rs mounts the same
# bundle into the git-login containers, and a migration that fixed only the
# proxy would leave those failing on a path nobody looks at.
names="$(podman ps -a --format '{{.Names}}' 2>/dev/null)" || {
    echo "skip:podman-unreadable"; exit 0; }

while IFS= read -r c; do
    [ -n "$c" ] || continue
    binds="$(podman inspect "$c" --format '{{range .HostConfig.Binds}}{{println .}}{{end}}' 2>/dev/null)" || continue
    case "$binds" in
        *tillandsias-ca*) : ;;
        *) continue ;;
    esac
    checked=$((checked + 1))
    case "$binds" in
        *"$TILLANDSIAS_CA_DIR/"*) : ;;
        *)
            stale=$((stale + 1))
            _src="$(printf '%s' "$binds" | grep -o '[^ ]*tillandsias-ca[^:]*' | head -1)"
            detail="${detail}  ${c}: binds ${_src:-<unparsed>} but the declared directory is ${TILLANDSIAS_CA_DIR}"$'\n'
            ;;
    esac
done <<EOF
$names
EOF

if [ "$stale" -gt 0 ]; then
    echo "migrate:ca-bind-stale:$stale"
    {
        printf '%s' "$detail"
        echo "  These containers bind a CA directory that is no longer declared."
        echo "  podman recorded the bind SOURCE at creation, so 'podman start' will"
        echo "  fail with a crun stat error naming a path nobody chose — the very"
        echo "  failure 975-rsgm exists to remove."
        echo "  REMEDY: RECREATE them through the enclave orchestration. Restarting"
        echo "  cannot work: the stale source is baked into the stored definition."
    } >&2
    exit 1
fi

echo "ok:ca-bind-current:$checked"
