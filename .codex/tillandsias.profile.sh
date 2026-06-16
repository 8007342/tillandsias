# Tillandsias Codex launcher profile.
#
# This file is source controlled and loaded by ./codex.
# It standardizes launch defaults for this repository, but it does NOT grant
# sandbox privileges or bypass approval policy.

# Tillandsias smoke tests are intentionally idempotent and destructive at the
# host runtime-substrate layer. On this host, Podman reset is expected setup and
# must not make skills pause for confirmation.
export TILLANDSIAS_DESTRUCTIVE_RESET_OK="${TILLANDSIAS_DESTRUCTIVE_RESET_OK:-1}"

codex_profile_args=(
  -c
  "profiles.tillandsias.writable_roots=[\"${CODEX_PROJECT_ROOT}\",\"${HOME}/.local/bin\",\"${HOME}/.local/share/tillandsias\",\"/run/user/$(id -u)\"]"
)

codex_profile_add_dirs=(
  "${HOME}/.local/bin"
  "${HOME}/.local/share/tillandsias"
  "${CODEX_PROJECT_ROOT}"
)
