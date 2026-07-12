# Agent-Login flows: vault-backed credentials for Claude / Codex / Antigravity

- Date: 2026-07-12
- Class: enhancement (work packet — order 303/304)
- Filed by: linux_mutable meta-orchestration cycle (operator smoke-test feedback)
- Status: ready — DO NOT implement casually; operator declared the tree stable
  and asked for packets only. Implementation starts when an agent claims the
  order after the current release ships.

## Operator repro (2026-07-12, local build, fresh --init)

1. Launched Claude from the tray, signed in via the in-forge login, ran a
   full /meta-orchestration cycle. Exited. Relaunched Claude → **prompted to
   log in again**.
2. Same with Codex: device-flow login worked, but a relaunch prompted again.
3. Antigravity crashed instantly on launch (see
   `plan/issues/antigravity-launch-crash-2026-07-12.md`) — plausibly the
   no-credential path, since the operator never completed a Gemini/Antigravity
   login.

Root cause shape: agents run their own OAuth/device login INSIDE the forge
container and write tokens to container-local paths (`~/.config`, agent state
dirs). The forge is `podman run --rm` — every credential dies with the lane.
Nothing round-trips the token into the vault, and nothing re-injects it on the
next launch.

## What already exists (do not rebuild)

- `ensure_provider_auth` (crates/tillandsias-headless/src/main.rs) already
  implements exactly the desired decision ladder for the CLI lane
  (`run_forge_agent_cli_mode`): vault API key → vault OAuth blob → else run
  `run_provider_login` (`ProviderLoginConfig`, `AuthModel::OAuthDevice`,
  `get_generic_login_token_script`).
- **Gap A**: the TRAY lane (`launch_forge_agent`) never calls
  `ensure_provider_auth` — tray launches skip the vault check entirely.
- **Gap B**: `run_provider_login` captures a token, but the in-forge login the
  operator actually used (agent's own device flow inside the TUI) is invisible
  to it, so vault state stays empty even after a successful interactive login.
- `build_forge_agent_run_args` already injects `ANTHROPIC/OPENAI/GEMINI` API
  keys from the vault when present.
- The GitHub Login Flow (vault write at `secret/github/token` +
  `gh auth login --with-token` inside the git service) is the UX model.

## Operator amendment (2026-07-12, evening)

For Claude and Codex, REPLACE the "paste your token" login flow with the
**device login flow** (`--device` style): the provider prints a short code
plus an easy-to-copy URL the user opens in any browser themselves. Do NOT
rely on the agent's default interactive login, which tries to open a browser
window / render a clickable terminal URL — in the forge terminal that either
fails to render or spills escape garbage into the pasted OAuth token (the
operator has hit exactly this, and has logged in successfully with the
device flow before). Concretely: run the agent's regular login command with
its device-flow flag so it never attempts to open a browser. The existing
`AuthModel::OAuthDevice` in `run_provider_login` is the right shape; the
token_script for Claude/Codex must drive the device flow, not paste-token.

## Desired behavior (spec sketch)

For each of Claude / Codex / Antigravity, at launch (tray AND CLI lanes):

1. If a usable credential exists in the vault (API key or OAuth blob), inject
   it and launch the forge directly.
2. If not, run the agent's Login Flow FIRST (device-flow / browser OTP,
   mirroring the GitHub Login Flow UX), persist the resulting credential into
   the vault, THEN launch the forge.
3. Credentials captured by an in-forge interactive login must be exported
   back to the vault before the `--rm` teardown discards them (harvest hook on
   lane exit, or bind-mount the agent's credential path to a vault-synced
   location — design decision for the implementer).
4. OpenCode/Maintenance lanes stay credential-free (unchanged).

## Exit criteria (order 303 — tray-lane parity, small slice)

- Tray-initiated Claude/Codex/Antigravity launches run the same
  `ensure_provider_auth` ladder as the CLI lane before the terminal spawns.
- A vault-present credential launches with no login prompt.

## Exit criteria (order 304 — vault round-trip of in-forge logins)

- After ONE interactive login in any lane, exiting and relaunching that agent
  does not prompt again (credential survives `--rm` via the vault).
- Vault paths documented per provider; no credential is ever written to the
  project workspace or the shared image.
- Verifiable closure: a fixture/litmus asserting the harvest hook exports a
  synthetic token from a fake agent credential path into the vault and that
  the next launch injects it.
