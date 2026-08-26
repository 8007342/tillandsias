#!/bin/bash
# freshness: refreshed 2026-07-24 forge-bigpickle-20260724
set -uo pipefail

if grep -qi "microsoft" /proc/version 2>/dev/null && pwd | grep -q '^/mnt/[c-z]/'; then
  echo "[check-credential-channel] WARNING: Running in WSL but directory is on Windows host. Host credentials may be unavailable. On Windows, use Git Bash instead." >&2
fi
# @trace order:61, order:756-2jnj, order:860-g798
# check-credential-channel.sh: executable Credential Channel Guard (plan order 61;
# forge upstream-auth consumption 756-2jnj; push-verified gh arm 860-g798).
# The former `spec:meta-orchestration` trace here was a ghost — no such spec
# file exists — flagged by the 874 retrospective and re-pointed to the orders
# that actually own this guard's behavior.
#
# Makes the meta-orchestration start-of-cycle Credential Channel Guard a
# verifiable check that returns a pass/fail exit code, instead of advisory prose
# that only an attentive agent honors (philosophy.yaml requires falsifiable
# verification claims; a guard nothing enforces is a suggestion, not a
# constraint).
#
# A usable git push credential channel is present when ANY of these holds:
#   - <git-dir>/.gh-credentials exists and is non-empty (repo-local store), or
#   - GH_TOKEN or GITHUB_TOKEN is set in the environment, or
#   - `gh auth status` succeeds (reachable, unlocked keyring).
#
# Emits exactly one line on stdout matching the falsifiable grammar
#   ^(ok:[a-z0-9-]+|blocked:[a-z0-9-]+|missing:no-credential-channel)$
# and exits 0 (channel present) or 1 (channel absent or blocked).
#
#   ok:gh-credentials-store        repo-local store helper file present + non-empty
#   ok:gh-token-env                GH_TOKEN set
#   ok:github-token-env            GITHUB_TOKEN set
#   ok:gh-keyring-push-verified    `gh auth status` green AND a bounded
#                                  non-interactive `git push --dry-run`
#                                  authenticated (860-g798: gh holding a token
#                                  proves nothing about git's helper chain; a
#                                  fresh clone resolves to the interactive Git
#                                  Credential Manager and hangs forever)
#   ok:gh-keyring-push-verified-hook-refused  the push probe was refused by
#                                  THIS CHECKOUT'S OWN pre-push hook (a gate
#                                  stamp gone stale behind a fetch, a claim
#                                  fragment, or the previous cycle's
#                                  attestation commit), and the credential
#                                  authenticated with the hook out of the way.
#                                  NOT a credential fault, so NOT blocked:* —
#                                  the skill hard-stops on those, and the tree
#                                  is validated at Finalization, not here
#                                  (order 876-exg2)
#   ok:gh-keyring-push-verified-refstate-refused  the push probe was refused by
#                                  the REMOTE'S REF STATE — the local branch is
#                                  behind origin, so `push origin HEAD` is a
#                                  non-fast-forward. Start-Of-Cycle fetches
#                                  (step 2) BEFORE fast-forwarding (step 5), so
#                                  any host whose siblings pushed enters this
#                                  arm. A create to a fresh unique ref under
#                                  refs/tillandsias/cred-probe/ authenticated
#                                  fine, which is the question this guard asks.
#                                  NOT a credential fault, so NOT blocked:*
#                                  (order 886-qmdz)
#   blocked:interactive-credential-helper  gh has a token but git's configured
#                                  helper is interactive-only; remedy printed
#   blocked:gh-cli-only            gh has a token, the push probe failed, no
#                                  interactive helper explains it — seed the
#                                  repo-local store before committable work
#   ok:forge-git-mirror            TILLANDSIAS_HOST_KIND=forge AND the mirror is
#                                  reachable AND the mirror's published upstream
#                                  write-authorization verdict is FRESH and
#                                  authorized (or local-only) — order 756-2jnj
#   blocked:upstream-push-unauthorized  mirror reachable, but its credential is
#                                       currently REFUSED by upstream (the
#                                       2026-08-15 GitHub 403 state)
#   blocked:upstream-no-credential      mirror reachable, Vault ANSWERS it, but
#                                       holds no GitHub token — GitHub Login
#                                       is the remedy
#   blocked:upstream-agent-unauthenticated
#                                       mirror reachable, but its OWN Vault
#                                       client token is dead, so no credential
#                                       can be read and the GitHub token's
#                                       state is UNKNOWN. Do NOT run GitHub
#                                       Login; repair the Agent's AppRole
#                                       login (order 828-k3mq)
#   blocked:upstream-auth-stale         mirror's verdict is older than
#                                       TILLANDSIAS_CRED_AUTH_MAX_AGE (default
#                                       900s) — yesterday's token epoch proves
#                                       nothing about today's
#   blocked:upstream-auth-unpublished   mirror publishes no verdict at all
#                                       (image predates the probe, or the probe
#                                       is failing) — authorization unproven
#   blocked:upstream-auth-error         mirror's probe could not determine
#                                       authorization (network/transport)
#   missing:no-credential-channel  none of the above
#
# `blocked:*` is distinct from `missing:*` on purpose: the channel EXISTS
# (forge -> mirror works) but the mirror -> upstream half is not currently
# write-authorized, so worker drain must not start (order 756-2jnj: on
# 2026-08-15 a forge lost two commits because this fact surfaced only at the
# first push, hours in). Both exit 1; forge-validate reports the verdict.
#
# NOTE: anonymous reads (`git fetch`/`git ls-remote`) succeeding on a public
# repo is NOT evidence of a credential channel. This check verifies the
# prerequisites for write capability only; it deliberately does not perform a
# network push.
#
# Testability seam: set TILLANDSIAS_CRED_SKIP_GH=1 to suppress the `gh auth
# status` probe so a scrubbed-environment fixture fails closed deterministically
# regardless of the host's ambient gh keyring state (used by
# litmus:credential-channel-check-shape).

# @trace spec:git-mirror-service
# Order 756-2jnj: consume the mirror-published upstream write-authorization
# verdict. The mirror's probe (images/git/probe-upstream-auth.sh) runs a
# non-mutating `git push --dry-run` against the upstream with the mirror's
# Vault credential and publishes refs/tillandsias/upstream-auth/<state>/<epoch>
# in the mirror repo — a namespace the git daemon advertises but clones,
# sweeps, and relays never touch. Reading it here uses git ls-remote over the
# SAME transport a push takes, so no new channel is invented.
#
# Args: $1 = source to ls-remote for the verdict refs (production: the
# effective origin; fixtures: TILLANDSIAS_CRED_AUTH_PROBE_URL pointing at a
# local bare repo). Prints exactly one verdict line and returns its exit code.
forge_upstream_auth_verdict() {
  local auth_src="$1"
  local auth_lines _sha refname rest state epoch best_state best_epoch now age max_age
  auth_lines="$(timeout 10 git ls-remote "$auth_src" 'refs/tillandsias/upstream-auth/*' 2>/dev/null || true)"
  best_state=""
  best_epoch=-1
  while read -r _sha refname; do
    [ -n "$refname" ] || continue
    rest="${refname#refs/tillandsias/upstream-auth/}"
    [ "$rest" != "$refname" ] || continue
    state="${rest%%/*}"
    epoch="${rest##*/}"
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    [ -n "$state" ] || continue
    if [ "$epoch" -gt "$best_epoch" ]; then
      best_epoch="$epoch"
      best_state="$state"
    fi
  done <<< "$auth_lines"
  if [ -z "$best_state" ]; then
    # Order 783-6rik: DISTINGUISH the two causes, because the obvious
    # remediation is futile for one of them and every host that follows it
    # wastes a cycle discovering that.
    #
    # If the running mirror image simply has no probe, "rebuild the container"
    # only works when the rebuild can SEE a probe — i.e. when the running
    # binary's embedded assets carry one. A host on a release older than the
    # probe rebuilds from those embedded assets and gets another probe-less
    # image, overwriting any image built by hand from the checkout (measured
    # on yoga 2026-08-17: a checkout build was replaced by the tray's within
    # 30 seconds). Telling that host to rebuild is telling it to repeat what
    # just failed.
    #
    # So probe the image directly and say which case this host is in.
    # ORDER 798-c4mq. Publishing a verdict has THREE preconditions — image
    # built, container created, service healthy — and this block used to
    # collapse the last two: it read only `podman ps` (RUNNING containers), so
    # a host with no mirror container at all fell into the "could not inspect
    # the image" arm and was told to go look at the image. On macuahuitl that
    # was actively wrong: the image was two days NEWER than the probe that
    # introduced it and carried the probe byte-for-byte, while there was no
    # tillandsias-git container in the stack at all. Rebuilding the image
    # cannot affect any link in "no container -> no service -> no probe run ->
    # no refs", so the advice sent the reader to the one place that was fine.
    #
    # Report which precondition is unmet, in order, rather than letting every
    # absence look like the last one somebody debugged.
    _ccc_state="unknown"
    _ccc_detail=""
    if ! command -v podman >/dev/null 2>&1; then
      _ccc_state="no-podman"
    else
      _ccc_running="$(podman ps --filter 'name=tillandsias-git' --format '{{.Image}}' 2>/dev/null | head -1)"
      # -a: an ABSENT container and a STOPPED one are different faults, and the
      # difference is the whole point of this packet.
      _ccc_any="$(podman ps -a --filter 'name=tillandsias-git' --format '{{.Names}} {{.Status}}' 2>/dev/null | head -1)"
      _ccc_img_any="$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -m1 'tillandsias-git' || true)"
      if [ -n "$_ccc_running" ]; then
        if podman run --rm --entrypoint ls "$_ccc_running" /usr/local/share/git-service/ 2>/dev/null |
            grep -q '^probe-upstream-auth'; then
          _ccc_state="running-probe-present"
        else
          _ccc_state="running-probe-absent"
        fi
      elif [ -n "$_ccc_any" ]; then
        _ccc_state="container-stopped"; _ccc_detail="$_ccc_any"
      elif [ -n "$_ccc_img_any" ]; then
        _ccc_state="image-only"; _ccc_detail="$_ccc_img_any"
      else
        _ccc_state="no-image"
      fi
    fi
    echo "[check-credential-channel] The git mirror is reachable but publishes NO upstream write-authorization verdict (refs/tillandsias/upstream-auth/*). Authorization is UNPROVEN, so worker drain must not start (order 756-2jnj)." >&2
    case "$_ccc_state" in
      running-probe-absent)
        echo "[check-credential-channel] CAUSE: the running mirror image carries NO probe-upstream-auth, so it CANNOT publish a verdict. If this host runs a published release older than the probe, rebuilding the container does NOT help — the tray rebuilds the image from the assets embedded in the installed binary and overwrites any hand-built image (order 783-6rik). Remedy: install a build/release that contains images/git/probe-upstream-auth.sh. Note the mirror relay still ACCEPTS pushes, so this blocks worker drain, not fail-loud bookkeeping." >&2
        ;;
      running-probe-present)
        echo "[check-credential-channel] CAUSE: PRECONDITION 3 (service). The mirror container is RUNNING and its image HAS probe-upstream-auth, so the probe exists and is not publishing — it is failing or has not run. Remedy: inspect the tillandsias-git container logs; if it still publishes nothing, repair the mirror's Vault GitHub token. Do NOT rebuild the image; it is not the missing link." >&2
        ;;
      container-stopped)
        echo "[check-credential-channel] CAUSE: PRECONDITION 2 (container). A tillandsias-git container EXISTS but is not running: ${_ccc_detail}. A stopped service publishes nothing. Remedy: start it and read its exit reason; rebuilding the image will not start a container." >&2
        ;;
      image-only)
        echo "[check-credential-channel] CAUSE: PRECONDITION 2 (container). The image ${_ccc_detail} exists but there is NO tillandsias-git container in this stack, running or exited. The chain is: no container -> no service -> no probe run -> no refs, and rebuilding the image cannot affect any link in it (order 798-c4mq, measured on macuahuitl where the image was two days NEWER than the probe and carried it byte-for-byte). Remedy: bring the stack up so the mirror service is created." >&2
        ;;
      no-image)
        echo "[check-credential-channel] CAUSE: PRECONDITION 1 (image). No tillandsias-git image exists on this host at all, so no mirror container can be created. Remedy: build or install one, then bring the stack up." >&2
        ;;
      no-podman)
        echo "[check-credential-channel] CAUSE: podman is not on PATH here, so none of the three preconditions (image built / container created / service healthy) can be inspected. This says nothing about the mirror." >&2
        ;;
      *)
        echo "[check-credential-channel] CAUSE: could not determine which precondition is unmet (image built / container created / service healthy). Inspect podman state directly rather than assuming staleness." >&2
        ;;
    esac
    echo "blocked:upstream-auth-unpublished"
    return 1
  fi
  now="$(date +%s)"
  age=$((now - best_epoch))
  max_age="${TILLANDSIAS_CRED_AUTH_MAX_AGE:-900}"
  if [ "$age" -gt "$max_age" ]; then
    echo "[check-credential-channel] The mirror's upstream write-authorization verdict is ${age}s old (max ${max_age}s). A stale 'authorized' proves nothing about the CURRENT token epoch — the 2026-08-15 loss happened exactly because authorization was assumed rather than fresh. Check the mirror's probe loop (images/git/entrypoint.sh) before draining workers." >&2
    echo "blocked:upstream-auth-stale"
    return 1
  fi
  case "$best_state" in
    authorized|local-only)
      echo "ok:forge-git-mirror"
      return 0
      ;;
    denied)
      echo "[check-credential-channel] The mirror is reachable but upstream currently REFUSES its credential (mirror-published verdict: denied). This is the 2026-08-15 403 state: a push at end of cycle WILL fail, so stop BEFORE worker drain. Fix the GitHub credential in Vault (secret/github/token) or its repo permission; do NOT import host credentials." >&2
      echo "blocked:upstream-push-unauthorized"
      return 1
      ;;
    no-credential)
      echo "[check-credential-channel] The mirror is reachable but has NO upstream credential readable from Vault (mirror-published verdict: no-credential). A push would fail with 'run GitHub Login' — stop BEFORE worker drain and restore the Vault-provided GitHub token." >&2
      echo "blocked:upstream-no-credential"
      return 1
      ;;
    agent-unauthenticated)
      # Order 828-k3mq. Deliberately NOT folded into no-credential above: the
      # remedies are opposite. There, Vault answered and holds no GitHub token,
      # so GitHub Login is the fix. Here the mirror's OWN Vault client token is
      # dead, the GitHub token's state is UNKNOWN, and running GitHub Login
      # treats a symptom the operator can see for a cause they cannot.
      echo "[check-credential-channel] The mirror is reachable but its OWN Vault client token is dead (mirror-published verdict: agent-unauthenticated), so it cannot read ANY credential and the GitHub token's state is UNKNOWN. Do NOT run GitHub Login — that repairs a different failure. Inspect the mirror's [vault-agent] log: if its AppRole login is failing with 'invalid role or secret ID', the SecretID was destroyed while this mirror kept running (order 828-k3mq) and the fix is to recreate the mirror, not to touch the GitHub credential. Repeated failed logins also trip Vault's user-lockout, so quiesce the retry loop before re-issuing anything." >&2
      echo "blocked:upstream-agent-unauthenticated"
      return 1
      ;;
    *)
      echo "[check-credential-channel] The mirror's upstream write-authorization probe reported '$best_state' — it could not determine authorization (network/transport failure?). Authorization is unproven; stop BEFORE worker drain and inspect the mirror's [upstream-auth] log." >&2
      echo "blocked:upstream-auth-error"
      return 1
      ;;
  esac
}

credential_channel_verdict() {
  local git_dir cred_file
  if git_dir="$(git rev-parse --git-dir 2>/dev/null)"; then
    cred_file="${git_dir}/.gh-credentials"
    if [ -s "$cred_file" ]; then
      echo "ok:gh-credentials-store"
      return 0
    fi
  fi
  if [ -n "${GH_TOKEN:-}" ]; then
    echo "ok:gh-token-env"
    return 0
  fi
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "ok:github-token-env"
    return 0
  fi
  if [ "${TILLANDSIAS_CRED_SKIP_GH:-0}" != "1" ] \
     && command -v gh >/dev/null 2>&1 \
     && gh auth status >/dev/null 2>&1; then
    # ORDER 860-g798 — `gh auth status` PROVES THE WRONG THING. It proves the
    # gh CLI holds a token; it says nothing about whether GIT can use it. On a
    # fresh clone git's credential.helper resolves to the system default —
    # often Git Credential Manager, which authenticates by opening an
    # INTERACTIVE PROMPT. Measured on esmeraldinha 2026-08-23: this arm
    # returned ok, the cycle proceeded into committable work, and the first
    # push hung >10 minutes on a prompt no unattended session can answer. The
    # guard's own docstring names this exact category error for reads
    # ("public-repo reads are anonymous — verify write capability
    # explicitly"); this arm made it one level up: a token that exists
    # somewhere is not a channel git can use.
    #
    # So prove the actual thing: an authenticated PUSH negotiation, dry-run
    # (contacts the remote, authenticates, updates nothing), with every
    # interactive escape hatch closed and a hard time bound. .gh-credentials
    # does not survive a re-clone while gh auth stays green globally, so EVERY
    # fresh checkout enters through this arm — the fleet restart from fresh
    # checkouts is exactly when it must not lie.
    _probe_cmd="${TILLANDSIAS_CRED_PROBE_CMD:-git push --dry-run origin HEAD}"
    if GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS=/bin/false \
       timeout 45 $_probe_cmd >/dev/null 2>&1; then
      echo "ok:gh-keyring-push-verified"
      return 0
    fi
    # ORDER 876-exg2. THE PROBE RUNS OUR OWN PRE-PUSH HOOK, AND THAT HOOK
    # REFUSES FOR REASONS THAT HAVE NOTHING TO DO WITH CREDENTIALS.
    #
    # 860-g798 was right to stop trusting `gh auth status` and start proving an
    # authenticated push. What it did not account for is that `git push` — even
    # `--dry-run` — executes the local pre-push chain first, and
    # pre-push-local-gate.sh refuses whenever the worktree has changed since
    # `./build.sh --check` last stamped it. Every one of these leaves the tree
    # in that state, and all of them are NORMAL:
    #
    #   - a fetch/fast-forward, which is what Start-Of-Cycle does immediately
    #     BEFORE running this guard (skill step 2);
    #   - the previous cycle's own Finalization step 9, which commits
    #     plan/mo-full-attestations.d/<host>.md through the hook's plan-only
    #     lane and therefore never refreshes the stamp;
    #   - minting a claim fragment, which the skill mandates before any work.
    #
    # So the guard reported `blocked:gh-cli-only` — "seed the repo-local store"
    # — on a host whose credential was fine, and the skill hard-stops the cycle
    # on any `blocked:*`. Measured on pirria 2026-08-25 on two consecutive
    # cycles (clean tree, HEAD == origin, the stale path being the attestation
    # file the previous cycle was REQUIRED to write), and independently on yoga
    # ten minutes before the first of those. The printed remedy could not have
    # helped in any of these cases.
    #
    # THE FIX IS TO ASK THE QUESTION THIS GUARD IS ACTUALLY ASKING. "Can this
    # credential authenticate to the remote" is answered by a probe with the
    # local hook out of the way; "would this tree pass the gate" is a DIFFERENT
    # question, asked and enforced at Finalization step 4, and it must stay
    # asked there. A guard that conflates them fails the cycle for the wrong
    # reason and names a remedy that does not apply.
    #
    # The retry runs ONLY on the failure path, so the healthy case costs
    # nothing and the true positive 860-g798 caught is untouched: an
    # interactive-helper hang fails BOTH probes and still reaches the verdicts
    # below.
    if [ -z "${TILLANDSIAS_CRED_PROBE_CMD:-}" ]; then
      if GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS=/bin/false \
         timeout 45 git push --dry-run --no-verify origin HEAD >/dev/null 2>&1; then
        # The credential authenticated. The refusal was ours.
        echo "  note: the push probe was refused by this checkout's own pre-push" >&2
        echo "  hook, not by the remote — the credential authenticated fine with" >&2
        echo "  the hook out of the way. Usually a gate stamp gone stale behind a" >&2
        echo "  fetch, a claim fragment, or the previous cycle's attestation" >&2
        echo "  commit. This is NOT a credential fault and must not stop the" >&2
        echo "  cycle; the tree is validated at Finalization by:" >&2
        echo "    TILLANDSIAS_SKIP_VERSION_BUMP=1 ./build.sh --check" >&2
        echo "ok:gh-keyring-push-verified-hook-refused"
        return 0
      fi
    fi
    # The push cannot authenticate non-interactively. Name the interactive
    # helper if one is configured — the failure must be legible the FIRST
    # time, not on the second diagnosis pass (exit criterion 2).
    # ORDER 886-qmdz. THE PROBE ALSO CARRIES THE REF STATE OF THE BRANCH,
    # AND A BEHIND BRANCH IS REJECTED FOR REASONS THAT HAVE NOTHING TO DO
    # WITH CREDENTIALS.
    #
    # 876-exg2 took the local pre-push hook out of the probe, on the
    # principle that this guard asks ONE question — can this credential
    # authenticate a push — and must not fail the cycle for any other.
    # The same conflation survives one layer down: `git push origin HEAD`
    # names a CONCRETE branch, so it is refused as a non-fast-forward
    # whenever the local branch is behind its remote counterpart. That
    # refusal happens AFTER the credential authenticated, and it is the
    # single most normal state a cycle can be in: Start-Of-Cycle runs
    # `git fetch` (skill step 2) and this guard IMMEDIATELY after it,
    # before the fast-forward in step 5. Any host whose siblings pushed
    # since its last cycle enters this arm by construction.
    #
    # Measured on lenovinha 2026-08-25: the guard printed
    # `blocked:gh-cli-only` with a clean tree and a green keyring; the
    # remote had answered `Updates were rejected because the tip of your
    # current branch is behind its remote counterpart` — which only a
    # remote that had ALREADY authenticated us could say. Fast-forwarding
    # and re-running the same guard returned `ok:gh-keyring-push-verified`
    # with nothing about the credential having changed. The 876-exg2
    # retry does not rescue this: `--no-verify` removes the hook, not the
    # non-fast-forward, so both probes fail and the cycle hard-stops on a
    # `blocked:*` whose printed remedy (seed the repo-local store) is
    # inert.
    #
    # THE FIX IS TO TAKE THE REF STATE OUT OF THE QUESTION. Probe a
    # unique ref under refs/tillandsias/cred-probe/ that cannot already
    # exist: a CREATE is always fast-forwardable, so the only thing left
    # that can fail it is authentication — exactly what this guard is for.
    # `--dry-run` means the ref is never created; verified on lenovinha
    # that `git ls-remote origin refs/tillandsias/cred-probe/*` stays
    # empty after the probe returns 0.
    #
    # Like 876-exg2 this runs ONLY on the failure path, so the healthy
    # case costs nothing, and it weakens no true positive: a credential
    # that cannot authenticate fails a create exactly as it fails an
    # update.
    if [ -z "${TILLANDSIAS_CRED_PROBE_CMD:-}" ]; then
      _cred_probe_ref="refs/tillandsias/cred-probe/$(hostname -s 2>/dev/null | tr "A-Z" "a-z" || echo host)-$$"
      if GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS=/bin/false \
         timeout 45 git push --dry-run --no-verify origin "HEAD:$_cred_probe_ref" >/dev/null 2>&1; then
        # The credential authenticated. The refusal was this branch's ref state.
        echo "  note: the push probe was refused by the REMOTE's ref state, not by" >&2
        echo "  the credential — a create to a fresh ref authenticated fine. Usually" >&2
        echo "  this branch is behind origin because Start-Of-Cycle fetched before" >&2
        echo "  fast-forwarding it (skill step 2 runs before step 5). This is NOT a" >&2
        echo "  credential fault and must not stop the cycle; update the branch with:" >&2
        echo "    git merge --ff-only origin/\$(git symbolic-ref --short HEAD)" >&2
        echo "ok:gh-keyring-push-verified-refstate-refused"
        return 0
      fi
    fi
    _helpers="$(git config --get-all credential.helper 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    case ",$_helpers," in
      *,manager,*|*,manager-core,*|*"\\Git Credential Manager"*)
        echo "blocked:interactive-credential-helper:${_helpers:-unknown}" >&2
        echo "  gh holds a token but git's helper chain is interactive-only — an" >&2
        echo "  unattended push hangs forever on a prompt. REMEDY (measured 18s" >&2
        echo "  on esmeraldinha after a 10-minute hang):" >&2
        echo "    gh auth token | git credential-store --file \"\$(git rev-parse --git-dir)/.gh-credentials\" store  # seed repo-local" >&2
        echo "    git config --local --replace-all credential.helper ''         # empty entry DROPS the system manager" >&2
        echo "    git config --local --add credential.helper \"store --file=\$(git rev-parse --git-dir)/.gh-credentials\"" >&2
        echo "blocked:interactive-credential-helper"
        return 1
        ;;
    esac
    # ORDER 894-scxy — NAME THE LAYER THAT FAILED, NOT THE LAYER WE OBSERVED.
    #
    # gh prints "The token in keyring is invalid". The keyring is the layer it
    # OBSERVED; GitHub is the layer that FAILED. MEASURED on pirria 2026-08-25:
    # the secret-service entry was present (service=gh:github.com, created
    # 08-18, modified 23:17:35 by the operator's own refresh), the login
    # collection was UNLOCKED (`Locked` -> `b false`), the token came back
    # intact at 40 chars — and GitHub answered 401 on it 27 minutes later. The
    # keyring was healthy in every component.
    #
    # THREE HOSTS DIAGNOSED THE WRONG SUBSYSTEM FROM THAT ONE STRING. One built
    # a mechanism on the premise; another relayed a keyring direction
    # fleet-wide. A missing signal leaves a reader searching; a MISATTRIBUTED
    # one leaves them searching confidently, in the wrong place, and stopping
    # when they find nothing there. That is why this is worse than silence.
    #
    # We cannot reword gh's output — it is upstream. What we can do is refuse to
    # inherit its misattribution and pass it on, since THIS guard runs on every
    # host before any committable work.
    #
    # NEVER MATERIALISE THE SECRET TO DECIDE THIS. `secret-tool search --all`
    # prints the value inline; two hosts put live gho_ tokens into their own
    # transcripts learning that. `gh api user` gives the same 200/401
    # discrimination and prints no secret: 200 means GitHub ACCEPTED the stored
    # credential, 401 means it REJECTED it. Every keyring probe below is
    # read-only and touches only metadata.
    _ccc_gh_failure_layer() {
      # THE PLAINTEXT-FALLBACK STATE FIRST, because it makes every keyring probe
      # irrelevant rather than merely negative — pirria's third state, which
      # neither the filing host nor the coordinator had named, and which a
      # two-state classifier silently mis-buckets into "keyring healthy".
      if [ -r "${HOME:-}/.config/gh/hosts.yml" ] \
         && grep -q '^[[:space:]]*oauth_token:' "${HOME}/.config/gh/hosts.yml" 2>/dev/null; then
        printf 'plaintext'
        return 0
      fi
      # Does GitHub accept the stored credential? This is the discriminator and
      # nothing else is.
      local _api_err _api_rc=0
      _api_err="$(GH_PROMPT_DISABLED=1 timeout 20 gh api user 2>&1 >/dev/null)" || _api_rc=$?
      if [ "$_api_rc" -eq 0 ]; then
        printf 'accepted'
        return 0
      fi
      case "$_api_err" in
        *401*|*"Bad credentials"*|*"Requires authentication"*)
          printf 'rejected'
          return 0 ;;
      esac
      # Not accepted, not a clean 401. Now — and only now — is the keyring worth
      # asking about, because "could not retrieve" is the remaining shape.
      if ! busctl --user list 2>/dev/null | grep -q 'org\.freedesktop\.secrets'; then # sigpipe-ok: safe pipeline
        printf 'unretrievable-no-service'
        return 0
      fi
      local _locked
      _locked="$(busctl --user get-property org.freedesktop.secrets \
                   /org/freedesktop/secrets/collection/login \
                   org.freedesktop.Secret.Collection Locked 2>/dev/null)"
      case "$_locked" in
        *true*) printf 'unretrievable-locked'; return 0 ;;
      esac
      printf 'indeterminate'
    }

    case "$(_ccc_gh_failure_layer)" in
      rejected)
        echo "[check-credential-channel] THE TOKEN WAS REJECTED BY GITHUB — the keyring is not the problem." >&2
        echo "  \`gh api user\` returned 401 against the stored credential. The secret was" >&2
        echo "  retrieved fine; GitHub refused it. Look at the ACCOUNT, not the keyring:" >&2
        echo "  the token is expired, revoked, or had its scopes/SSO authorisation withdrawn." >&2
        echo "  gh's own message says \"The token in keyring is invalid\", which names the" >&2
        echo "  layer it OBSERVED rather than the one that FAILED (894-scxy). Three hosts" >&2
        echo "  diagnosed the keyring from that string on 2026-08-25; the keyring was healthy." >&2
        echo "  REMEDY:  gh auth refresh   # or: gh auth login" >&2
        echo "  Then re-run this guard. Do NOT go looking at secret-service." >&2
        echo "blocked:credential-rejected-by-github"
        return 1 ;;
      unretrievable-no-service)
        echo "[check-credential-channel] THE CREDENTIAL COULD NOT BE RETRIEVED — org.freedesktop.secrets is not on the session bus." >&2
        echo "  This is a LOCAL retrieval failure, not an account problem. gh cannot reach" >&2
        echo "  the secret store at all, so nothing has been presented to GitHub yet." >&2
        echo "  Common in a headless/cron/ssh session with no session keyring." >&2
        echo "  REMEDY: run inside a session with a keyring, or inject GH_TOKEN for this run." >&2
        echo "blocked:credential-unretrievable-no-keyring-service"
        return 1 ;;
      unretrievable-locked)
        echo "[check-credential-channel] THE CREDENTIAL COULD NOT BE RETRIEVED — the login keyring collection is LOCKED." >&2
        echo "  A LOCAL retrieval failure. The token may be perfectly valid; nothing has" >&2
        echo "  been presented to GitHub. Unlock the collection and re-run." >&2
        echo "blocked:credential-unretrievable-keyring-locked"
        return 1 ;;
      plaintext)
        echo "[check-credential-channel] gh is using a PLAINTEXT token in ~/.config/gh/hosts.yml, not the keyring." >&2
        echo "  Reported because it changes where to look: keyring probes say nothing about" >&2
        echo "  this host, and a keyring-shaped diagnosis would be misattribution (894-scxy)." >&2
        echo "  The push probe still failed, so the stored token is bad or lacks push rights." >&2
        echo "  REMEDY: gh auth login  (and consider moving off the plaintext fallback)" >&2
        echo "blocked:credential-plaintext-token-rejected"
        return 1 ;;
      accepted)
        echo "[check-credential-channel] GitHub ACCEPTS this credential (\`gh api user\` 200), but the PUSH probe failed." >&2
        echo "  So this is neither a keyring fault nor a dead token: the identity is good and" >&2
        echo "  something about the PUSH is not. Usually repository push permission, SSO" >&2
        echo "  authorisation not granted for this org, or a scope missing from the token." >&2
        echo "  REMEDY: check the token's repo scope and any org SSO authorisation." >&2
        echo "blocked:credential-accepted-but-push-refused"
        return 1 ;;
    esac

    # gh has a token, git cannot push with it, and no interactive helper
    # explains it: a distinct verdict the cycle must RESOLVE before any
    # committable work, never a bare ok (exit criterion 1).
    echo "  gh auth is green but a bounded non-interactive push probe failed" >&2
    echo "  (${_probe_cmd}). Seed the repo-local store before committable work." >&2
    echo "blocked:gh-cli-only"
    return 1
  fi
  if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
    # The forge uses a transparent git mirror service for authenticated pushes.
    # But HOST_KIND=forge being SET does not prove the mirror is REACHABLE for
    # this checkout: a shared-host-checkout or misconfigured-DNS forge can have
    # the env var set while every fetch/push through the mirror fails ("access
    # denied or repository not exported", "unable to look up tillandsias-git").
    # That false-positive made a Codex forge cycle accrete a commit it could
    # never push — the exact velocity-killer this guard exists to prevent. See
    # plan/issues/forge-shared-host-checkout-mirror-alias-2026-07-04.md. So VERIFY
    # the mirror actually answers for `origin` before declaring the channel
    # present. Unlike a direct anonymous GitHub read, an ls-remote THROUGH the
    # mirror exercises the same rewrite path a push takes and proves the mirror
    # sidecar is up for this repo; a failure is definitive evidence it is unusable.
    local effective_origin
    effective_origin="$(git ls-remote --get-url origin 2>/dev/null || true)"
    case "$effective_origin" in
      # Order 659-8faj: mirrors answer at per-project names (git-<project>),
      # which git://git-*/* covers (it also matches the retired git-service).
      # git://tillandsias-git/* stays accepted for configs written before the
      # rename.
      git://git-*/*|git://tillandsias-git/*) ;;
      *)
        echo "[check-credential-channel] TILLANDSIAS_HOST_KIND=forge but origin does not resolve to the enclave git mirror (effective origin: ${effective_origin:-<missing>}): no usable push channel. Fix the forge gitconfig injection or provide a forge credential channel; do NOT import host credentials." >&2
        echo "missing:no-credential-channel"
        return 1
        ;;
    esac
    if [ "${TILLANDSIAS_CRED_SKIP_MIRROR_PROBE:-0}" = "1" ]; then
      # Fixture seam: verify URL rewriting first, then skip the live network
      # probes (reachability AND authorization consult, which both ls-remote
      # the origin) so host pre-build litmus does not depend on forge DNS.
      # When a fixture supplies an explicit local verdict source, the
      # authorization consult still runs against it — that is how
      # litmus:forge-upstream-auth-gate pins the consult hermetically.
      if [ -n "${TILLANDSIAS_CRED_AUTH_PROBE_URL:-}" ]; then
        forge_upstream_auth_verdict "$TILLANDSIAS_CRED_AUTH_PROBE_URL"
        return $?
      fi
      echo "ok:forge-git-mirror"
      return 0
    fi
    if timeout 10 git ls-remote "$effective_origin" HEAD >/dev/null 2>&1; then
      # Order 756-2jnj: reachability is only HALF the channel. The 2026-08-15
      # incident reached this exact point with a mirror whose credential
      # GitHub 403'd — 'ok' here let a forge accrete commits it could never
      # push. Require the mirror's fresh, non-mutating upstream
      # write-authorization verdict before declaring the channel usable.
      if [ "${TILLANDSIAS_CRED_SKIP_AUTH_PROBE:-0}" = "1" ]; then
        # Emergency valve only (e.g. a fleet-wide stale-mirror-image rollout
        # window): reachability alone, authorization UNVERIFIED. Loud on
        # stderr so a transcript never mistakes this for the proven state.
        echo "[check-credential-channel] WARNING: TILLANDSIAS_CRED_SKIP_AUTH_PROBE=1 — upstream write authorization is UNVERIFIED; a push may still 403 (order 756-2jnj)." >&2
        echo "ok:forge-git-mirror"
        return 0
      fi
      forge_upstream_auth_verdict "${TILLANDSIAS_CRED_AUTH_PROBE_URL:-$effective_origin}"
      return $?
    fi
    echo "[check-credential-channel] TILLANDSIAS_HOST_KIND=forge but the git mirror is unreachable for this checkout (git ls-remote origin failed): no usable push channel. Fix the mirror export/DNS or provide a forge credential channel; do NOT import host credentials." >&2
    echo "missing:no-credential-channel"
    return 1
  fi
  echo "missing:no-credential-channel"
  return 1
}

# ORDER 892-aw9p — A CORRECT VERDICT HAS A SHELF LIFE.
#
# This guard runs ONCE, at Start-Of-Cycle, before any committable work. It
# cannot see a credential that dies afterwards. MEASURED on calmecacpilli
# 2026-08-25: the guard returned ok:gh-keyring-push-verified, two pushes
# succeeded on that credential, and ~50 minutes later the third failed with
# `remote: Invalid username or token`. `gh auth status` then said "The token in
# keyring is invalid."
#
# Nothing the guard MEASURED was wrong — the verdict was true when issued. The
# defect is that its result is consumed far from where it was produced, and
# nothing tracks the gap. The failure therefore surfaces at the most expensive
# possible moment: after the implementation, after a 142-276s local gate, and
# with the Non-Negotiable Exit Contract forbidding an exit that leaves the work
# unpushed. The host is wedged, not merely delayed.
#
# This is structurally the stale-gate-stamp problem (887-bz88): a check whose
# result outlives the thing it checked. The CLASS is filed separately; this is
# the cheap instance, landed on its own so a five-line fix is not held hostage
# to a taxonomy (calmecacpilli's request, coordinator endorsed).
#
# THE STAMP IS WRITTEN ONLY ON A PASS, and only records that a pass happened.
# It exists so `reverify` can tell "this credential DIED" apart from "this host
# never had one" — two conditions with the same repair cost but very different
# diagnoses, and the guard previously reported both as
# missing:no-credential-channel.
_ccc_stamp_path() {
    printf '%s/tillandsias-credential-verified' "$(git rev-parse --git-dir 2>/dev/null || echo .)"
}

_ccc_record_pass() {
    local f; f="$(_ccc_stamp_path)"
    [ -n "$f" ] || return 0
    printf '%s %s\n' "$(date -u +%s)" "$1" > "$f" 2>/dev/null || true
}

case "${1:-}" in
  reverify)
    # RE-PROBE BEFORE THE EXPENSIVE STEP. The skill calls this at Finalization
    # immediately BEFORE `./build.sh --check`, so a dead credential costs the
    # gate's wall-clock rather than being discovered after it.
    #
    # NOT called per push: the healthy path must not pay a network round trip
    # for every git operation. A guard slow enough to notice is a guard that
    # gets bypassed, and a bypassed guard protects nothing — so this runs once,
    # at the one point where the remaining cost is still worth saving.
    verdict="$(credential_channel_verdict)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
      _ccc_record_pass "$verdict"
      echo "$verdict"
      exit 0
    fi
    _stamp="$(_ccc_stamp_path)"
    if [ -s "$_stamp" ]; then
      _then="$(cut -d' ' -f1 < "$_stamp" 2>/dev/null)"
      _was="$(cut -d' ' -f2 < "$_stamp" 2>/dev/null)"
      case "$_then" in
        ''|*[!0-9]*) _age="unknown" ;;
        *) _age="$(( $(date -u +%s) - _then ))s" ;;
      esac
      echo "[check-credential-channel] THE CREDENTIAL DIED DURING THIS CYCLE." >&2
      echo "  It verified ${_age} ago (${_was:-ok}) and does not verify now." >&2
      echo "  This is NOT an absent channel and NOT a ref-state refusal (886-qmdz):" >&2
      echo "  it worked, and then stopped. A keyring token expiring mid-cycle is the" >&2
      echo "  measured shape (calmecacpilli, 2026-08-25, ~50 minutes in)." >&2
      # ORDER 892-aw9p, corrected by calmecacpilli — the host this happened to.
      # YOUR WORK IS NOT LOST, AND THAT IS THE HEADLINE, NOT A FOOTNOTE. What a
      # dead credential costs is not the implementation (committed, gate-green,
      # on a local branch) but the ability to FINISH: no push, so no MO-FULL
      # marker, so a cycle that cannot attest. The expensive thing is the BLOCKED
      # STATE, and the tempting wrong move is to discard and start clean. So the
      # preservation path is printed FIRST.
      echo "  YOUR WORK IS RECOVERABLE. Do NOT discard it to get unstuck:" >&2
      echo "    scripts/salvage-dirty-worktree.sh <slug>   # pushes a COPY, cannot touch the worktree" >&2
      echo "  Commits already made are safe on the local branch; they need a push, not a redo." >&2
      echo "  Report blocked with the salvage ref rather than exiting clean." >&2
      echo "  REMEDY for the credential itself:" >&2
      echo "    gh auth refresh        # or: gh auth login" >&2
      echo "    gh auth token | git credential-store --file \"\$(git rev-parse --git-dir)/.gh-credentials\" store" >&2
      echo "blocked:credential-expired-mid-cycle"
      exit 1
    fi
    echo "$verdict"
    exit "$rc"
    ;;
esac

# Standalone mode: print the single verdict line and exit with its pass/fail code.
verdict="$(credential_channel_verdict)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && _ccc_record_pass "$verdict"
echo "$verdict"
exit "$rc"
