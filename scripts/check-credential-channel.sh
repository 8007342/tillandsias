#!/bin/bash
# freshness: refreshed 2026-07-24 forge-bigpickle-20260724
set -uo pipefail

if grep -qi "microsoft" /proc/version 2>/dev/null && pwd | grep -q '^/mnt/[c-z]/'; then
  echo "[check-credential-channel] WARNING: Running in WSL but directory is on Windows host. Host credentials may be unavailable. On Windows, use Git Bash instead." >&2
fi
# @trace spec:meta-orchestration
# check-credential-channel.sh: executable Credential Channel Guard (plan order 61).
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
#   ok:gh-keyring                  `gh auth status` green
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
    echo "ok:gh-keyring"
    return 0
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

# Standalone mode: print the single verdict line and exit with its pass/fail code.
verdict="$(credential_channel_verdict)" && rc=0 || rc=$?
echo "$verdict"
exit "$rc"
