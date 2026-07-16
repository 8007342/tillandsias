---
name: merge-to-main-and-release
description: Refresh linux-next, open/update the PR to main, merge once green, bump VERSION, tag, and trigger the workflow_dispatch release. Runs on a daily cadence so the latest linux-next work reaches a downloadable Linux release operators can smoke-test on a Fedora Silverblue host.
---

# Merge to Main and Release

This skill closes the loop between the work-loop (`/advance-work-from-plan`) and downloadable releases. It promotes the current `linux-next` HEAD to `main` via PR, bumps the version, tags, and triggers the `workflow_dispatch`-only release workflow that publishes the Linux musl binaries (and the macOS / Windows artifacts) on a GitHub Release.

The user's stated goal: keep a fresh Linux release available so they can install and smoke-test on a Fedora Silverblue host without needing to build locally. Daily cadence is the right balance — local CI catches regressions on every commit; this skill catches the "did all of today's work cohere into a shippable artifact" gate.

---

## 0 — Pre-flight

Establish identity and verify the environment is releasable:

```bash
date -u +%Y-%m-%dT%H:%MZ
git rev-parse --abbrev-ref HEAD              # MUST be linux-next
git fetch origin --prune
git pull --ff-only origin linux-next         # local linux-next == origin/linux-next
git status --short                           # MUST be clean
```

If the worktree is dirty, stop and file/update a plan blocker. Do not stash
release inputs or auto-artifact churn; local state is volatile and hidden stashes
make release evidence unrecoverable.

Also verify there are no local-only commits:

```bash
test "$(git rev-list --count origin/linux-next..HEAD)" -eq 0
```

If the branch is not `linux-next`, log + exit without escalating — the release flow only ships from the Linux integration branch.

### Tray-parity completeness (release-scoped gate — order 243 semantic split)

The per-build litmus (`litmus:tray-parity-matrix-complete`) only gates each
host's OWN column so sibling verification debt cannot block unrelated local
builds. The ALL-platform completeness requirement from
`plan/issues/tray-feature-parity-matrix-2026-06-28.md` ("the matrix should be
all-green on `required` rows before that release") lives HERE instead:

```bash
ruby -ryaml -e 'data = YAML.load_file(%q(openspec/tray-parity-matrix.yaml)); gaps = 0; data[%q(features)].each { |f| next unless f[%q(parity)] == %q(required); [%q(linux), %q(macos), %q(windows)].each { |p| (puts p + %q(: ) + f[%q(capability)].to_s + %q( status=) + f[p].to_s; gaps += 1) if f[p] != %q(done) } }; puts %q(parity gaps: ) + gaps.to_s; exit 1 if gaps > 0'
```

If this exits non-zero, the parity matrix has unverified/incomplete `required`
cells. This is an **advisory hold, operator-overridable**: record the gap list
in the cycle outcome (§8) and in `plan/loop_status.md`, and proceed ONLY if the
operator has recorded a release-with-parity-gaps approval for the cycle (The
Tlatoāni owns that call — releases shipped with parity gaps before this gate
existed, so a hard stop would strand the daily Linux release on macOS/Windows
verification debt; make the debt loud, not invisible).

---

## 1 — Compute the new version

The canonical format is `MAJOR.MINOR.YYMMDD.N` where:

- `MAJOR.MINOR` is the **current series, read from the `VERSION` file** — never hardcoded.
  As of the 2026-06 CalVer transition the series is `0.3`. Deriving it from VERSION
  means a future series bump (the operator edits VERSION's first two components) flows
  through automatically instead of desyncing main vs linux-next (the 2026-06-04 incident).
- `YYMMDD` is today's UTC date (e.g. `260605` for 2026-06-05).
- `N` is the daily sequence (1 for the first release of the day, 2 for the second, etc.).

```bash
series="$(cut -d. -f1-2 VERSION | tr -d '[:space:]')"   # e.g. "0.3"
today=$(date -u +%y%m%d)
prev_tag=$(git tag --list "v${series}.${today}.*" | sort -V | tail -1)
if [[ -z "$prev_tag" ]]; then
    seq=1
else
    seq=$(( $(echo "$prev_tag" | sed -E "s/v${series//./\\.}\.${today}\.([0-9]+)/\1/") + 1 ))
fi
new_version_computed="${series}.${today}.${seq}"

# Check if current VERSION is already ahead of the computed sequence
current_version=$(cat VERSION | tr -d '[:space:]')
if [[ "$current_version" =~ ^${series//./\\.}.${today}\.[0-9]+$ ]]; then
    if [[ "$(printf '%s\n%s' "$current_version" "$new_version_computed" | sort -V | tail -1)" == "$current_version" ]]; then
        new_version="$current_version"
    else
        new_version="$new_version_computed"
    fi
else
    new_version="$new_version_computed"
fi

new_tag="v${new_version}"
echo "Computed: $new_tag (series ${series} from VERSION, current ${current_version})"
```

This produces e.g. `v0.3.260605.1` for the first release of 2026-06-05, `v0.3.260605.2` for the second.

---

## 2 — Open or update the PR

GitHub has at most one open PR `linux-next → main` at a time. Reuse it if present; open a new one otherwise.

```bash
existing_pr=$(gh pr list --base main --head linux-next --state open --json number --jq '.[0].number')
if [[ -z "$existing_pr" ]]; then
    gh pr create --base main --head linux-next \
        --title "release: ${new_tag} — daily linux-next promotion" \
        --body "Automated daily promotion of linux-next → main by the \`merge-to-main-and-release\` skill. The follow-on tag + workflow_dispatch trigger publishes ${new_tag} for Linux Silverblue smoke-test."
    existing_pr=$(gh pr list --base main --head linux-next --state open --json number --jq '.[0].number')
fi
echo "PR #${existing_pr}"
```

Update the PR body with today's `${new_tag}` even if reusing — the human reviewer should see which version is being shipped.

---

## 3 — Wait for CI / merge when green

Poll the PR's `mergeable` + `statusCheckRollup` until either:

- ALL required checks pass → proceed to merge.
- ANY check fails → surface the failing run URL, exit without merging, write a ledger entry. The next 24-hour cycle retries.

```bash
gh pr checks ${existing_pr} --watch              # blocks until green or red
gh pr merge ${existing_pr} --merge --auto         # uses a merge commit (preserves linux-next history)
```

Use `--merge` (not `--squash`): the linux-next history is the audit log of the daily work-loop and integration cron cycles. Preserve it.

---

## 4 — Bump VERSION on main + push

```bash
git checkout main
git pull --ff-only origin main
echo "${new_version}" > VERSION
git add VERSION
git commit -m "release: bump VERSION to ${new_version}

The merge-to-main-and-release skill bumped VERSION as part of the
daily linux-next → main promotion. Tag ${new_tag} follows.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
git push origin main
```

If the push fails because main advanced concurrently (another release ran), pull + retry up to 3 times. If still failing, write an `ESCALATION:` line in `plan/issues/multi-host-integration-loop-2026-05-24.md` and stop.

---

## 5 — Tag + push

```bash
git tag -a "${new_tag}" -m "Release ${new_version}

Daily linux-next → main promotion via the merge-to-main-and-release
skill. See PR #${existing_pr} for the merged work range.
"
git push origin "${new_tag}"
```

The annotated tag carries the PR reference so the GitHub Release page links back to the merged work.

---

## 6 — Trigger the release workflow

`release.yml` is `workflow_dispatch`-only. The skill explicitly triggers it with the new tag, never via `on: push: tags:` (the workflow is intentionally manual to keep release authorship traceable).

```bash
gh workflow run release.yml --ref "${new_tag}"
sleep 5
gh run list --workflow=release.yml --branch="${new_tag}" --limit 1
```

(The old `recipe-publish.yml` custom-rootfs workflow was removed in the 2026-06 Fedora pivot — Windows/macOS now fetch official Fedora WSL/Cloud images directly, so there is no rootfs CI to coordinate with anymore.)

---

## 7 — Wait for the release build + surface artifacts

```bash
run_id=$(gh run list --workflow=release.yml --branch="${new_tag}" --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "${run_id}"                     # blocks until green or red
gh release view "${new_tag}" --json url,assets --jq '.url, .assets[].browserDownloadUrl'
```

The Linux Silverblue smoke-test artifact is the `tillandsias-linux-x86_64` musl binary. Surface its URL to the user.

---

## 8 — Record the cycle outcome

Append a one-line entry to `plan/issues/linux-next-work-queue-2026-05-25.md`:

```
- <UTC>  `<merge_sha>`  Release ${new_tag} — merged PR #${existing_pr} to main, tagged, workflow_dispatch triggered. Linux build: <nix_build_duration> (Nix cache: <hit|miss>), total run: <total_run_time>. Linux artifact: <browser_download_url>.
```

**Also append a row to the README release ledger** (operator directive
2026-07-16; order 380). The collapsible table under `## RELEASE LEDGER` in
README.md gets one new row at the TOP of the table body:

- `RELEASE`: `${new_tag} (daily)` — or `(**STABLE**)` when this release is a
  stable-channel promotion.
- `INTENDED FEATURES`: the planned work this release set out to ship
  (orders/features from the merged range), stated whether or not complete —
  incomplete intentions stay listed with their follow-on order.
- `BUGFIXES`: unplanned maintenance — regressions from previous milestones or
  breakage discovered during the day's development.

Keep rows honest and compact (the evidence trail lives in `plan/`); when the
table exceeds ~10 rows, distill the oldest rows into the `*Older releases*`
line per the semantic-distillation policy.

Push the ledger update to `linux-next` so other hosts and the next work-loop see the release happened.

Before success, confirm the release ledger update was pushed and the local
branch is not ahead of upstream.

---

## Hard guardrails

- **NEVER push directly to `main`** — always via PR, even though the skill creates and merges the PR for you.
- **NEVER `git push --force`** — main is protected.
- **NEVER skip the workflow_dispatch step**: the release workflow is manual-only by design. If the user wants automatic-on-tag, they edit release.yml first.
- **NEVER bump VERSION on linux-next**; only on main as part of the release commit. Sibling hosts (osx-next / windows-next) consume VERSION from their respective merge points; bumping it on linux-next desyncs them.
- The release ships three platform artifacts to ONE GitHub release with matching versions:
  Linux musl (`release` job), macOS arm64 thin tray (`macos-release`), Windows x64 thin tray
  (`windows-release`). The macOS/Windows jobs `needs: release` and upload via `--clobber`.
- **NEVER cancel an in-flight release** — let it complete or fail, then handle in the next cycle.

---

## Failure recovery

If any STEP fails:

- **STEP 3 CI fails**: surface the failing run URL, do NOT merge, do NOT tag. The next 24-hour cycle retries. The work-loop continues to land fixes meanwhile.
- **STEP 5 tag-push fails (existing tag)**: another run beat us. Skip release; cycle ends successfully (someone else released).
- **STEP 6 workflow trigger fails**: the tag is on main; user can manually run `gh workflow run release.yml --ref ${new_tag}`. Surface a clear next-step instruction.
- **STEP 7 release build fails**: the tag exists on main but no GitHub Release was published. Next cycle does NOT retry the tag — it bumps to N+1. The orchestrator deals with the failed build separately.

---

## Why daily, not on-every-commit?

- Every-commit releases would flood the GitHub Releases page and overwhelm the manual workflow_dispatch budget.
- Linux Silverblue smoke-tests cost the user real time — daily is enough granularity to catch regressions without churn.
- The work-loop + integration cron already enforce continuous green on every commit; this skill adds the "shippable artifact" gate on top.

---

## Orchestrator-steered cadence

The /loop / schedule that drives this skill is set up cloud-side via the `schedule` skill so it persists across user sessions. The orchestrator can re-cadence (e.g. to 12 hours for active development weeks, or pause via `gh workflow disable` + a coordination note) by editing the schedule out-of-band; the skill itself does not assume a particular cadence.

---

## File layout

The canonical file lives at `skills/merge-to-main-and-release/SKILL.md`. Each agent runtime (`.claude/`, `.opencode/`, `.codex/`, `.gemini/`, `.github/`) accesses it via a symlink under its `skills/` directory pointing at `../../skills/merge-to-main-and-release`, so there is exactly one source of truth. Editing the canonical file updates the skill for all runtimes simultaneously.
