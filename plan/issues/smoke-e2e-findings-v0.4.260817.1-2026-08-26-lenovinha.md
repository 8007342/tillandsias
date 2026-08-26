# Published-release curl-install e2e — v0.4.260817.1 on linux-immutable (lenovinha) — 2026-08-26

discovered_by: `/smoke-curl-install-and-test-e2e` (linux_immutable), meta-orchestration
cycle lenovinha-opus5-20260826t013712z.
Host: **lenovinha** (Fedora Silverblue, `linux_immutable`), branch `linux-next`,
channel **daily**, resolved `channel:daily tag:v0.4.260817.1`.
Evidence: `target/smoke-e2e/` (host-local).

## PARTIAL RUN — Steps 0-1 PASS, Steps 2-4 DELIBERATELY NOT RUN

**This is the first Linux evidence of any kind for v0.4.260817.1.** Until now the
release had exactly one conforming report (Windows), which is what the
platform-aware promotion gate (888-m75r) reports as `missing=linux,macos`.

### Step 0-1 — curl-install: **PASS**

- `curl -fsSL $BASE/install.sh | TILLANDSIAS_RELEASE_BASE=$BASE bash` → `install_exit=0`
- **Version assertion PASS** — `tillandsias --version` reports `Tillandsias v0.4.260817.1`,
  containing the resolved tag, so the artifact under test is provably the published one
  (order 727-kmks's assertion, not a comment). Installed to
  `/var/home/lenovinha/.local/bin/tillandsias`.
- The installer's bootstrap completed on this host: Vault initialised and every
  AppRole provisioned (GitMirror, Forge, Tray, Inference, GithubLogin,
  ClaudeLogin, CodexLogin, CodexForge, ClaudeForge, AntigravityForge,
  AntigravityLogin, OpenCodeForge), `bootstrap complete`, base_url
  `https://127.0.0.1:8201`, ending with `Init complete.`
- No errors, panics, or short-name-mode prompts in `01-install.log`.

**What this establishes:** the published installer works end to end on Fedora
Silverblue — an immutable-Linux host, which no previous report for this release
covered. A new release cut from trunk inherits this install path, so the result
is useful independently of which version is eventually promoted.

### Steps 2-4 — NOT RUN, and the reason is not risk aversion

`podman system reset --force` and the full re-init were deliberately **not**
performed on this artifact. The reason is timing, not fear of the wipe (the skill
is explicit that the wipe is the precondition, and
`TILLANDSIAS_DESTRUCTIVE_RESET_OK` is unset here, i.e. sanctioned):

- The coordinator is cutting **v0.4.260826.1** within minutes of this run — the
  first stable in 15 days, from a trunk with all three platforms merged and
  `--ci-full` green at 2014 checks.
- v0.4.260817.1 was already **decided against** for promotion, partly on the
  evidence survey that produced 888-m75r.
- The destructive half costs a full image rebuild (many minutes). Spending it on
  an artifact superseded mid-run, then repeating it on the new tag, is waste —
  and the NEW tag is the one that needs three-platform evidence before the gate
  will clear it.

**Committed follow-up:** the destructive half (Steps 2-4) runs on
**v0.4.260826.1** once published. This report is intentionally partial rather
than absent, so the install-path result is not lost and the gap is explicit.

### PASS entry

`v0.4.260817.1` — curl-install PASS on linux_immutable (install_exit=0, version
assertion PASS, Vault bootstrap clean). Substrate reset / fresh-init / forge lane
NOT exercised; deferred to v0.4.260826.1 by the reasoning above.

No findings filed: nothing anomalous was observed in the steps that ran.
