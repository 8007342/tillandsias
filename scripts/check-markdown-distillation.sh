#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

fail=0

# THE ALLOWLIST IS HERE, IN BASH. It is NOT read from
# methodology/markdown-distillation.yaml — that file is an ARCHIVE RECORD of
# what was distilled in 2026-06, and its `canonical_markdown_roots:` list has
# already drifted from this one (it lacks .claude/commands, the SKILL.md
# surfaces, and images/default/cheatsheets). Editing the YAML changes nothing
# here. The refusal below used to send readers there anyway; see the note on it.
allowed_path() {
  case "$1" in
    README.md|TRACES.md|CLAUDE.md) return 0 ;;
    # ORDER 865-q4wp — AGENT-RUNTIME INSTRUCTION ENTRYPOINTS, the same class as
    # CLAUDE.md directly above. AGENTS.md is the file; GEMINI.md and
    # .github/copilot-instructions.md are SYMLINKS to it (verified: all three
    # share sha 44d7c24f2ea6, and `ls -l` shows the links). One document, three
    # names, because each agent runtime looks for its own. The policy's own
    # validation_rule already permits these — "new Markdown outside canonical
    # roots is allowed only for runtime command or skill surfaces" — but the
    # allowlist never learned about them, so the gate failed on a file class it
    # was written to allow.
    AGENTS.md|GEMINI.md|.github/copilot-instructions.md) return 0 ;;
    # A RUNTIME SURFACE IN THE STRICTEST SENSE: inject_startup_context() appends
    # this file VERBATIM into .forge-startup-context.md at every forge launch,
    # read from the MOUNTED CHECKOUT (743-y5wh), and it carries its own litmus.
    # It is executable context, not prose about the project.
    images/default/startup-context-addendum.md) return 0 ;;
    # A README documenting the scripts it sits beside. Narrower than the
    # `crates/*` entry below, which admits ALL markdown anywhere under crates/:
    # this admits only a README, only one level down.
    scripts/*/README.md) return 0 ;;
    docs/*|cheatsheets/*|openspec/*|plan/*|skills/*|crates/*) return 0 ;;
    methodology/specs/*) return 0 ;;
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
  # THE REMEDY THIS LINE USED TO GIVE DOES NOT WORK, and that is worth more
  # than the paths it blocked. It said "Add an inventory row to
  # methodology/markdown-distillation.yaml" — but this script never reads that
  # file. A reader following the instruction edits a YAML, re-runs, and is
  # refused identically, with no clue why. An error that names a remedy it
  # cannot honour costs more than one that names none, because it spends the
  # reader's trust as well as their time (865-q4wp; same shape as
  # promote-stable.sh's demotion comment, 864-mk2p).
  printf 'Fix ONE of these — the allowlist is in THIS script, not in any YAML:\n' >&2
  printf '  (a) if it is a runtime/skill surface, add its path to allowed_path() above;\n' >&2
  printf '  (b) otherwise distill it into a canonical root (docs/, cheatsheets/,\n' >&2
  printf '      openspec/, plan/, methodology/specs/) and archive the original under\n' >&2
  printf '      plan/archive/, recording it in methodology/markdown-distillation.yaml.\n' >&2
  printf '  The YAML is an archive RECORD of past distillations; editing it alone\n' >&2
  printf '  changes nothing this check sees.\n' >&2
  exit 1
fi

printf 'ok: markdown distillation paths\n'
