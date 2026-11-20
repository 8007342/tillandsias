## REMOVED Requirements

### Requirement: Pre-push hook auto-regenerates README
**Reason**: Never wired. No image, skill, crate or hook installs or calls scripts/install-readme-pre-push-hook.sh, and the repository's real pre-push hook (scripts/hooks/pre-push-local-gate.sh) does not regenerate READMEs. The script is deleted (order 2118-kaeq, coordinator ruling 2026-11-20).
**Migration**: None needed; nothing ran it. README regeneration stays available through the /bootstrap-readme skill and regen-trigger lines. An automatic hook, if wanted, is new work in the real hook chain.
