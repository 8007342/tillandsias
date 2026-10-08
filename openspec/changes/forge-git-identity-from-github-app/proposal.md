# Forge git identity derived from the GitHub App login

## Why

The Tlatoāni, 2026-09-28, relayed by macuahuitl-forge: "redesign how the git
identity gets derived, now that we login with a GitHub app we should have
access to the user's name and email. We just need to juggle host names, and
append some tillandsias names for randomness".

Today the host reads its OWN global gitconfig (`read_git_identity_defaults`,
crates/tillandsias-headless) and passes it into every forge as exported
`GIT_AUTHOR_*` / `GIT_COMMITTER_*`; `configure_git_identity`
(images/default/lib-common.sh) re-exports it and writes `user.name` /
`user.email`. Two consequences:

1. It contradicts the live requirement "The guest never inherits the host's
   git identity" — the forge commits as whatever the host's gitconfig says
   (measured: `Tlatoani <bulloncito@gmail.com>` in macuahuitl-forge), so the
   identity's shape depends on how each host was set up.
2. Because the identity is EXPORTED ENV, it overrides `-c user.name` in every
   scratch-repo fixture run inside a forge (test-discipline-derive failed 4/5
   in every forge; the 1446-xqi6 fixture hit the same).

## What Changes

- The identity is derived from the GitHub App's authenticated user (name,
  and the `<id>+<login>@users.noreply.github.com` address unless the operator
  rules otherwise), plus a host component and a Tillandsias-name component.
- It is written as git CONFIG in the guest, not exported env, so a fixture's
  own `-c user.*` / scratch config wins.
- Host attribution moves to a place consumers can read without an email
  domain (see Consumers).

## Consumers that must keep working

- `scripts/fleet-activity.sh` and `tillandsias-plan discipline derive`
  derive the committer HOST from the author-email domain (1223-wzc4). A
  noreply address has no host domain: they must read the host from the new
  component, and keep the old domain rule for historical commits.
- The `prepare-commit-msg` trailer hook (Co-Authored-By / Generated-By).
- Ledger `host:` fields do not read git identity, but readers correlate them.

## Open questions for the operator (answer before implementation)

1. Which part carries the host — the display name (e.g.
   `Tlatoāni (macuahuitl · tillandsia-xerographica)`), the email local-part
   (`<id>+<login>+macuahuitl@users.noreply…` is NOT valid for GitHub
   attribution), or a commit trailer (`Tillandsias-Host: macuahuitl`)?
2. Is the Tillandsias name per forge, per session, or per commit?
3. noreply address, or the account's primary email when the App can read it?

## Impact

- Spec: forge-git-identity-anonymization (MODIFIED + ADDED below).
- Code: crates/tillandsias-headless (identity source), images/default/
  lib-common.sh (`configure_git_identity`), scripts/fleet-activity.sh,
  the plan binary's discipline derive.
