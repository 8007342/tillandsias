#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

fail=0

allowed_path() {
  case "$1" in
    README.md|TRACES.md|CLAUDE.md) return 0 ;;
    docs/*|cheatsheets/*|openspec/*|plan/*|skills/*|crates/*) return 0 ;;
    methodology/events/README.md|methodology/specs/*) return 0 ;;
    .claude/commands/*|.opencode/commands/*|.opencode/command/*|.github/prompts/*) return 0 ;;
    .claude/skills/*/SKILL.md|.opencode/skills/*/SKILL.md|.codex/skills/*/SKILL.md|.gemini/skills/*/SKILL.md|.github/skills/*/SKILL.md) return 0 ;;
    images/default/cheatsheets/*|images/default/config-overlay/opencode/*) return 0 ;;
    @methodology/.opencode/*) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r path; do
  [[ -f "$path" ]] || continue
  if ! allowed_path "$path"; then
    printf 'noncanonical markdown: %s\n' "$path" >&2
    fail=1
  fi
done < <(git ls-files '*.md' | sort)

if [[ "$fail" -ne 0 ]]; then
  printf 'Add an inventory row to methodology/markdown-distillation.yaml and move/distill the file.\n' >&2
  exit 1
fi

printf 'ok: markdown distillation paths\n'
