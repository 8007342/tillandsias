# Tillandsias Codex launcher profile.
#
# This file is source controlled and loaded by ./codex.
# It standardizes launch defaults for this repository, but it does NOT grant
# sandbox privileges or bypass approval policy.

codex_profile_args=(
  -c
  "profiles.tillandsias.writable_roots=[\"${CODEX_PROJECT_ROOT}\",\"${HOME}/.local/bin\",\"${HOME}/.local/share/tillandsias\",\"/run/user/$(id -u)\"]"
)

codex_profile_add_dirs=(
  "${HOME}/.local/bin"
  "${HOME}/.local/share/tillandsias"
  "${CODEX_PROJECT_ROOT}"
)
