# v56.10.16.2 prerelease smoke on yoga (Fedora Silverblue 44), 2026-10-17

Verdict: **FAIL** — install, cold provision and the 1751-ipuw arm PASS; the
empty-project onboarding check FAILS before an agent starts (filed as
1759-6z2m). A Silverblue datapoint beside lenovinha's.

| Step | Result | Evidence |
|---|---|---|
| Install | PASS | published `install.sh` (sha256 `0aa886be…`, matches release `SHA256SUMS`), pinned with `TILLANDSIAS_RELEASE_BASE=…/download/v56.10.16.2`; soft `--reset-state` ran inside it; rc=0, `PENDING: none`; `tillandsias --version` → `v56.10.16.2` |
| Cold provision to Ready | PASS | `tillandsias --tray --debug`: Vault `unsealed (v=1.18.5)`, `cloud refresh: loaded 17 repos from gh`; `tillandsias --status-check` rc=0 `status-check:ok` |
| Onboarding (start-a-new-project in OpenCode) | **FAIL** | both a `git init`-ed empty dir and a plain empty dir: `tillandsias . --opencode --prompt …` rc=1, `[forge] FATAL: git clone … produced an EMPTY checkout (no HEAD) after 12 attempts … (unborn-HEAD mirror defect)`, `Refusing to launch an agent on an empty working tree`. The skill listing was never reached. |
| 1751-ipuw arm (quit during Securing Vault, relaunch) | PASS | after a soft `--reset-state`, tray SIGTERMed while its last line was `launching container tillandsias-vault` (the `vault` stage, labelled "Securing Vault" by the tray); `Graceful shutdown completed`. Relaunch: `podman secret tillandsias-vault-unseal already exists; reusing it unchanged`, `vault healthy (initialized=true sealed=false)`, `cloud refresh: loaded 18 repos from gh`. |

Side observations (not filed, below threshold):

- First tray boot after install logged `gh … HTTP 401: Bad credentials` twice,
  then recovered on the next refresh to 17 repos. Transient, self-healed.
- `blocked:github-token-rotation-failed:read:vault-unavailable` prints at every
  tray start before Vault is up; it reads as a failure but is only ordering.

Kill precision caveat: the kill was keyed on log lines, not on the menu label,
so it landed during the vault container launch rather than strictly after the
Ready label appeared. The unseal-survives property is what was measured.
