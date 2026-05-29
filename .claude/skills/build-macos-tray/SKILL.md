---
name: build-macos-tray
description: Full macOS-host build + autonomous-smoke + install-locally cycle for tillandsias-macos-tray. Captures structured findings to plan/issues/macos-build-findings-<DATE>.md so other hosts see whether the macOS build is green and what regressed. Runs unattended; iteration-friendly — refine the skill itself between calls based on what each run surfaces.
---

# /build-macos-tray

Run a full macOS-host build + autonomous-smoke + install-locally cycle of
`tillandsias-macos-tray`. Capture structured findings into a shared
plan/issues file so sibling hosts (linux, windows) see whether macOS is
green and what regressed without having to be on the host.

This skill MUST run on macOS (Apple Silicon). The host is `osx-next`
worker per CLAUDE.md canon §2.

---

## 0 — Pre-flight

1. **Branch + sync**:
   ```bash
   git fetch origin --prune
   git checkout osx-next 2>/dev/null || true
   git pull --ff-only origin osx-next 2>/dev/null \
     || git pull --ff-only origin linux-next   # fallback if osx-next is FF behind
   ```
2. **Capture build prelude** — these go in the findings entry:
   - `BUILD_RUN_ID = $(date -u +%Y%m%dT%H%M%SZ)`
   - `HEAD_SHA = $(git rev-parse --short HEAD)`
   - `VERSION = $(cat VERSION | tr -d '[:space:]')`
   - `BUILD_DATE_UTC = $(date -u +%Y-%m-%d)`
3. **Findings file** path: `plan/issues/macos-build-findings-${BUILD_DATE_UTC}.md`
   (one file per UTC day; multiple runs in a day append sections).
   - If the file doesn't exist, create it with a header (see §6 schema).

---

## 1 — Build

```bash
scripts/build-macos-tray.sh
```

Capture: full stdout+stderr to a temp file (e.g. `/tmp/build-macos-tray-${BUILD_RUN_ID}.log`).
Capture: `cargo build` wall-clock + the final summary line (`built <name>
(<MiB> MiB, sha256 <sha>)`).

**Failure handling**: if exit ≠ 0, jump to §5 "file failure finding" with
section_kind=`build-failed`. Do NOT proceed to install/smoke.

**Success criteria**:
- `dist/Tillandsias.app/Contents/MacOS/tillandsias-tray` exists + executable
- `dist/tillandsias-tray-${VERSION}-macos-arm64.tar.gz` exists
- `dist/SHA256SUMS` has the new line
- `codesign --verify` exited 0 (the script already runs this; presence of
  the success "built …" line implies it passed)

---

## 2 — Autonomous smoke (no user interaction)

This is the m8-autonomous portion: prove the .app launches + diagnose works,
without requiring a user to click menubar items.

```bash
# 2a. In-tree --diagnose --json (sanity that the binary works at all).
DIAG_JSON=$(./dist/Tillandsias.app/Contents/MacOS/tillandsias-tray --diagnose --json 2>&1 || true)
DIAG_EXIT=$?

# 2b. Detached launch + SIGTERM round-trip (proves the menubar item registers
#     and that Quit drains cleanly without a click).
./dist/Tillandsias.app/Contents/MacOS/tillandsias-tray &
TRAY_PID=$!
sleep 3
if kill -0 "$TRAY_PID" 2>/dev/null; then
    LAUNCH_STATUS="alive-after-3s"
    kill -TERM "$TRAY_PID"
    sleep 2
    if kill -0 "$TRAY_PID" 2>/dev/null; then
        kill -KILL "$TRAY_PID" 2>/dev/null || true
        QUIT_STATUS="hung-required-SIGKILL"
    else
        QUIT_STATUS="clean-SIGTERM-exit"
    fi
else
    LAUNCH_STATUS="died-before-3s"
    QUIT_STATUS="n/a"
fi
```

Capture: `DIAG_EXIT` (must be 0=provisioned or 2=degraded; 1=hard-failure
is a build regression), parsed `DIAG_JSON` keys (use `jq` if available),
`LAUNCH_STATUS`, `QUIT_STATUS`.

Per macos-native-tray.invariant.diagnose-exit-codes: exit 1 from
`--diagnose --json` is a failure mode worth surfacing — file as
`section_kind=diagnose-hard-failure` even if build itself was green.

---

## 3 — Install locally

Install to `~/Applications/Tillandsias.app` (avoid sudo'ing
`/Applications/` in an unattended skill — the dev host has user-scoped
preferences for where dev builds go).

```bash
INSTALL_DIR="$HOME/Applications"
mkdir -p "$INSTALL_DIR"
# Stop any running tray instance first (graceful, then force).
pkill -TERM -f 'Tillandsias.app/Contents/MacOS/tillandsias-tray' 2>/dev/null || true
sleep 2
pkill -KILL -f 'Tillandsias.app/Contents/MacOS/tillandsias-tray' 2>/dev/null || true
# Atomic replace via .new + mv (avoid mid-write app corruption).
rm -rf "$INSTALL_DIR/Tillandsias.app.new"
cp -R dist/Tillandsias.app "$INSTALL_DIR/Tillandsias.app.new"
rm -rf "$INSTALL_DIR/Tillandsias.app.bak"
[[ -d "$INSTALL_DIR/Tillandsias.app" ]] && mv "$INSTALL_DIR/Tillandsias.app" "$INSTALL_DIR/Tillandsias.app.bak"
mv "$INSTALL_DIR/Tillandsias.app.new" "$INSTALL_DIR/Tillandsias.app"
```

**Post-install sanity**: re-run `--diagnose --json` against the installed
copy (`$INSTALL_DIR/Tillandsias.app/Contents/MacOS/tillandsias-tray
--diagnose --json`) and assert the JSON shape matches the in-tree copy.
Per `litmus:macos-tray-diagnose-cli-surface` (slice 26), the schema is
stable across builds; a divergence here means install corrupted the
bundle.

---

## 4 — Validate against shipped litmuses

Run the macOS-tray-bound pre-build litmus (if `scripts/run-litmus-test.sh`
works on macOS — bash 3 quirk caveat from the work-queue):

```bash
# Optional: skip on macOS if the runner errors with `declare: -A invalid`.
scripts/run-litmus-test.sh litmus:macos-tray-diagnose-cli-surface --phase pre-build --size instant --compact 2>&1 | tail -5
```

If the runner skips on macOS (bash 3 limitation), record that as a known
limitation in the findings entry and link the Linux integration loop
ledger which DOES run these tests.

---

## 5 — File findings (success OR failure)

Append a new section to
`plan/issues/macos-build-findings-${BUILD_DATE_UTC}.md`. Use this exact
schema (so sibling hosts + future iterations can grep it):

```markdown
### ${BUILD_RUN_ID} — ${SECTION_KIND}

- agent_id: macos-${HOSTNAME}-claude-opus-${BUILD_RUN_ID}
- head_sha: ${HEAD_SHA}
- version: ${VERSION}
- build_run_id: ${BUILD_RUN_ID}

**Build**:
- duration: <seconds>
- tarball: <name> (<MiB> MiB, sha256 <hash>)
- codesign verify: <pass|fail>
- entitlement com.apple.security.virtualization: <present|absent>

**Autonomous smoke**:
- `--diagnose --json` exit: <0|1|2>
- `--diagnose --json` keys present: [<comma-separated list>]
- detached launch: <alive-after-3s|died-before-3s>
- SIGTERM round-trip: <clean-SIGTERM-exit|hung-required-SIGKILL|n/a>

**Install**:
- target: ~/Applications/Tillandsias.app
- backup made: <yes|no — .bak present>
- post-install diagnose schema match: <yes|no>

**Findings** (free-form; what regressed, what surprised, what to investigate):
- ...

**Cross-host visibility note** (when SECTION_KIND ≠ ok):
- (sibling-host-impact paragraph: does this affect linux or windows? E.g.
  "build-failed on a Cargo.lock conflict that came from linux — windows
  builds likely fail same way until linux ships a fix")

**Next iteration ask** (when SECTION_KIND ≠ ok):
- (concrete next-step for the next /build-macos-tray run; or a coordination
  ask for sibling host)
```

`SECTION_KIND` is one of:
- `ok` — full build + smoke + install succeeded
- `ok-with-warnings` — succeeded but produced unexpected log noise / install warnings
- `build-failed` — `scripts/build-macos-tray.sh` exited non-zero
- `diagnose-hard-failure` — `--diagnose --json` exited 1 (per spec invariant)
- `launch-failed` — detached launch died before 3s
- `quit-hung` — SIGTERM didn't reach a clean exit within 2s
- `install-corrupted` — post-install diagnose JSON differs from in-tree

---

## 6 — Findings-file template (when creating a fresh daily file)

```markdown
# macOS tray build findings — ${BUILD_DATE_UTC}

Generated by `/build-macos-tray`. One section per build run. Sibling hosts
should grep `SECTION_KIND` to see whether the macOS build is green on a
given day; section bodies surface anything that affects cross-host work
(rare unattended regressions, install-script edge cases, smoke surprises).

trace: .claude/skills/build-macos-tray/SKILL.md (the skill that wrote this)
       plan/steps/20-macos-tray-v0_0_1.md (the macOS tray v0.0.1 ledger)
       plan/issues/osx-next-work-queue-2026-05-25.md (work queue)
```

---

## 7 — Commit + push (per CLAUDE.md canon §2)

The findings file is under `plan/` → push directly to `linux-next`.
The skill itself is under `.claude/skills/` (not platform-specific code)
→ push to `osx-next` AND `linux-next` so all hosts can use the same SKILL.

Skill iteration: when you update the skill body itself (refine flow,
add a check, fix a wording issue), commit it separately from any findings
update so the skill-iteration history is greppable.

```bash
git add plan/issues/macos-build-findings-${BUILD_DATE_UTC}.md
git commit -m "chore(macos-build-findings): ${BUILD_RUN_ID} ${SECTION_KIND}"
git push origin osx-next:linux-next  # plan/ → linux-next
git push origin osx-next:osx-next    # keep branches symmetric
```

If push fails (merge race), `git fetch && git pull --ff-only` and retry up
to 3 times. Per CLAUDE.md: never `--force`, never amend, never push to
`main`.

---

## 8 — Skill self-refinement loop

This skill is invoked daily by `/loop 24h /build-macos-tray`. Between
calls, look at the most recent finding section:

- If `SECTION_KIND=ok` for several days in a row, the skill is doing its
  job — leave alone.
- If a section surfaces a NEW failure mode the skill didn't cleanly
  classify (it ended up under "Findings: free-form" and not a SECTION_KIND),
  add a new SECTION_KIND to the enum in §5 and an explicit detection step
  earlier in the flow.
- If a sibling host posts a follow-up in the same findings file (rare —
  most coordination goes through the work-queue), respond inline.
- If the build script `scripts/build-macos-tray.sh` itself changes the
  output schema (e.g. adds a new artifact, drops the SHA file), update §1
  success criteria.

Refinements go to a separate skill-iteration commit:
```bash
git add .claude/skills/build-macos-tray/SKILL.md
git commit -m "chore(skill): refine /build-macos-tray — <what changed>"
git push origin osx-next:linux-next
git push origin osx-next:osx-next
```

---

## Hard guardrails

- NEVER `git push --force`.
- NEVER push to `main`.
- NEVER `sudo` in the install step (use `~/Applications/`, not
  `/Applications/`).
- NEVER kill a tray PID that isn't the one this skill just spawned (the
  `pgrep -f 'Tillandsias.app/Contents/MacOS/tillandsias-tray'` could match
  a user's manually-launched tray). Prefer killing by exact PID from
  `$TRAY_PID` for the autonomous-smoke half; the install §3 `pkill` is a
  necessary trade-off for the install replace and is best-effort.
- When the worktree is dirty, only stage `plan/issues/macos-build-
  findings-*` files explicitly by path — never `git add -A`.
- If the skill fails partway through (e.g. build crash), still try to
  write a findings entry summarizing what got far enough to record.
