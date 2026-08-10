# git-mirror egress vs enclave-network spec — divergence audit (2026-08-10)

Classification: `research/`
Packet: 606-9wqd (`git-mirror-egress-network-spec-drift`), a dependency of the
only `release-blocker-v0.5` packet (451).

Closes exit criterion 1 — *"implementation and enclave-network spec agree on
whether the mirror may attach directly to egress"* — by establishing that they
**do not**, and by locating the divergence exactly so the decision in criteria
2/3 can be made without re-deriving it.

This is a static audit. It does NOT reproduce the attachment at runtime and does
not decide the outcome.

## What the spec says

`openspec/specs/enclave-network/spec.md` is unambiguous, in four places:

| line | text |
|---|---|
| 10 | "Only the proxy container has external access (dual-homed). All other containers communicate exclusively through the enclave." |
| 39 | "**Only the proxy container MUST** additionally be attached to the default bridge network for external access." |
| 46 | a non-proxy container "MUST NOT have access to the default bridge network" |
| 78 | "Enclave network is isolated; no egress to host network without proxy" |

There is no exception clause for the git mirror.

## What the implementation does

`ENCLAVE_EGRESS_NETS = "tillandsias-enclave,tillandsias-egress"`
— `crates/tillandsias-headless/src/main.rs:1117`, used at `:2516`, `:2953`, `:7483`.

The git image is run dual-homed at two sites in
`crates/tillandsias-headless/src/remote_projects.rs`:

- **:321** (`run_git_image_shell`) — comment: *"Dual-homed: enclave leg (internal
  DNS) + managed egress leg for the direct GitHub push."*
- **:651** — same attachment, referring back to the first.

So the mirror is dual-homed **deliberately and with a stated reason**: a direct
GitHub push. This is not an accident or a leftover; it is a design choice that
was never reconciled with the spec.

## The part that decides the packet

The spec's constraint is not "proxy is special" for its own sake — it is that
egress passes through one auditable, CA-terminating chokepoint. The mirror's
egress leg bypasses that chokepoint, and:

**`tillandsias-egress` is a plain NAT network with no destination scoping.**
`ensure_egress_network` creates it; nothing in `remote_projects.rs` applies an
allowlist, and there is no allowlist enforcement at that boundary. So the
attachment does not grant "GitHub push" — it grants **arbitrary outbound
network access** to a container whose stated need is one destination.

That distinction is what makes exit criterion 3 meaningful: an exception, if
ratified, must be destination-scoped, and today's implementation is not scoped
at all. The gap between "needs api.github.com" and "has the internet" is the
finding.

## Disposition — for the decision, not decided here

Criterion 2 (preferred): route the mirror's upstream Git through the proxy and
remove its egress leg. The open question is whether the proxy chain preserves
push semantics — the comment at :318 hints the original attempt used `bridge`
and failed to resolve on clean rootless, which is a *resolution* failure, not
evidence that proxying push is impossible. That needs a runtime reproduction.

Criterion 3 (fallback): ratify a destination-scoped exception. On today's
implementation this is strictly more work than it sounds, because the scoping
does not exist yet — it would need enforcement at the network boundary plus the
negative test the criterion demands (arbitrary direct egress refused).

**Recommendation: attempt criterion 2 first**, and only fall back to 3 if a
runtime reproduction shows proxied push genuinely cannot preserve
clone/fetch/push parity and credential isolation (criterion 4). Ratifying an
unscoped exception because scoping is work would invert the packet's intent.

## The packet is scoped too narrowly — but not as narrowly as it first looked

`ENCLAVE_EGRESS_NETS` has **7 uses in `main.rs`** plus 2 literal sites in
`remote_projects.rs`. Resolving the enclosing function at each shows they are
not all the same case, and that distinction matters:

| site | container | spec verdict |
|---|---|---|
| `main.rs:2516` | `build_proxy_run_args` — **the proxy** | **COMPLIANT.** The spec explicitly requires the proxy to be dual-homed (line 39, line 50). |
| `main.rs:2953` | `tillandsias-git-{project}` — the mirror | violation, this packet |
| `remote_projects.rs:321`, `:651` | the git image shell | violation, this packet |
| `main.rs:7483` | `run_provider_login` | **unresolved — needs a verdict.** A login container reaching an identity provider is plausibly the same "needs one destination, has the internet" shape as the mirror. |

So the first instinct — "everything is dual-homed, the spec is fiction" — is
wrong: the proxy's attachment is exactly what the spec mandates. The real
picture is a spec with one sanctioned exception and at least two unsanctioned
ones sharing the same constant.

**That shared constant is itself part of the defect.** `ENCLAVE_EGRESS_NETS` is
used identically by the compliant proxy and the non-compliant mirror, so nothing
in the code distinguishes "dual-homed because the spec says so" from
"dual-homed because it was expedient". Any fix should make that difference
visible at the call site, or the next reader re-derives this audit.

## Residual

- **No runtime reproduction.** Criteria 2–4 all need one, on a host with podman.
  Nothing here has been observed; it is all read from source.
- **`run_provider_login` (`main.rs:7483`) has no verdict.** It should get one in
  the same pass, or it becomes the next 606-9wqd.
- This audit did not check the other `ENCLAVE_EGRESS_NETS` uses in `main.rs`
  beyond the three resolved above; 7 uses exist and 3 were located.

---

## Runtime reproduction attempt (same day, linux_mutable) — INCONCLUSIVE

Criteria 2–4 need a runtime reproduction. This host attempted one and the
environment cannot support it. Recording the attempt because the near-miss is
more instructive than the result.

### Measured

| posture | DNS | HTTPS (curl, 3 destinations) |
|---|---|---|
| `tillandsias-enclave` only | FAIL | `000` — no connection |
| `tillandsias-enclave,tillandsias-egress` (the mirror's actual posture) | RESOLVED | `000` — no connection |
| **CONTROL: default podman network** | — | **`000` — no connection** |
| **CONTROL: the host itself** | — | **`200`** |

`tillandsias-egress` inspects as `internal: false`, bridge driver, one subnet,
DNS enabled — configured as intended. `tillandsias-enclave` is correctly
`internal: true`.

### Why this proves nothing about the packet

The control is what matters: **the DEFAULT podman network also fails**, while
the host reaches GitHub fine. Container egress is unavailable on this host
altogether — an environment condition, not a property of `tillandsias-egress`.

So the reproduction cannot distinguish "the egress leg grants arbitrary
outbound access" from "nothing has outbound access here", and criteria 2–4
remain open. It needs a host with working rootless container egress.

### The wrong conclusion this nearly produced

Read without the control, the first two rows say: *dual-homing grants no working
egress, therefore the spec divergence is harmless and 606-9wqd can be closed as
theoretical.* That is comfortable, it matches the numbers, and it is **wrong** —
it would have closed a security packet on an artifact of the test environment.

It is also the exact failure class this session keeps finding: an environment
fault wearing the costume of a real result (631-* missing jq read as a drained
ledger; 643-bnag branching on output volume rather than exit code; a reclaimer
reporting `reclaimed=0` because it looked in the wrong place). The instrument
was wrong twice in this one probe before the control caught it — the first pass
used `/dev/tcp`, which is a bash feature, and `/bin/sh` in that image is
busybox, so both initial "TCP-BLOCKED" readings were pure instrument error.

**Verify the instrument, then the control, then believe the measurement.**

### What the next host needs

Run the two postures plus BOTH controls (default network, and the host) on a
machine with working rootless container egress. Only if the default-network
control returns 200 does the enclave/egress comparison mean anything.

---

## Runtime reproduction, second attempt (same host, same day) — CONCLUSIVE

The section above is **wrong in its diagnosis**, and the correction is the
finding. This host has working rootless container egress. What it did not have
was a valid instrument.

### Why the first attempt's control failed

`~/.config/containers/containers.conf` sets, in a global `env` list:

    http_proxy=http://proxy:3128   https_proxy=http://proxy:3128   (+ upper-case)

Podman injects those into **every container it launches and every image pull**,
on every network. The hostname `proxy` is an alias that exists only inside the
enclave pod network, so anywhere else it does not resolve and all egress dies
with `proxyconnect tcp: dial tcp: lookup proxy: no such host`.

That poisoned the test arm and the control arm *identically*, which is precisely
why the control looked like "this host has no container egress at all".

This is a known class — `crates/tillandsias-podman/src/client.rs:709` calls it
the "Proxy-exemption class (orders 116/118/119; 4th instance 2026-07-11)", and
`scripts/with-tillandsias-builder.sh:78` carries the documented neutralization.
The first reproduction attempt was the next instance, and it landed inside a p0
security audit's control.

### Measured, with the neutralization applied

Neutralize first (empty value overrides `[engine] env`; an operator-set proxy is
left untouched):

    for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY; do
        [ -z "${!v+x}" ] && export "$v="
    done

| posture | api.github.com | example.com | pypi.org |
|---|---|---|---|
| **CONTROL: default podman network** | **REACHED** | — | — |
| `tillandsias-enclave` only | blocked | blocked | blocked |
| `tillandsias-enclave,tillandsias-egress` (the mirror's posture) | **REACHED** | **REACHED** | **REACHED** |

The control now passes, so the comparison means something.

### What it establishes

1. **Enclave isolation genuinely works.** Enclave-only reaches nothing. The spec's
   containment property holds where it is applied.
2. **The egress leg grants arbitrary unscoped outbound access.** `example.com`
   and `pypi.org` have nothing to do with a GitHub push. The audit's central
   claim — the gap between *"needs api.github.com"* and *"has the internet"* —
   is now observed, not inferred.

Note the proxy env vars were neutralized for the measurement **deliberately**:
env vars are not a security boundary. A compromised process in the mirror simply
unsets `http_proxy`. The measurement is of the network path, which is what the
spec constrains.

So criterion 1 is closed by observation as well as by reading, and criteria 2–4
are unblocked on this host.

### Residual now resolved: every `ENCLAVE_EGRESS_NETS` use has a verdict

| site | function | verdict |
|---|---|---|
| `main.rs:1117` | const definition | n/a |
| `main.rs:2516` | `build_proxy_run_args` | **COMPLIANT** — spec mandates it |
| `main.rs:2953` | `build_git_run_args` | violation |
| `main.rs:7486`, `:7522` | `run_provider_login` | **violation** — verdict was open; same "needs one destination, has the internet" shape |
| `remote_projects.rs:320` | `run_git_image_shell` | violation |
| `remote_projects.rs:650` | `clone_project_from_github_with_debug` | violation |
| `main.rs:15545-6` | test fixtures | n/a |

**One sanctioned dual-homing, five unsanctioned runtime sites**, all sharing one
constant that records no difference between them.

### The lesson, restated because it recurred one level up

The previous section warned *"verify the instrument, then the control, then
believe the measurement"* — and then trusted a control that its own project
config had poisoned. Verifying the instrument is not a step you complete once;
the second attempt only worked because the failure changed shape (`lookup proxy:
no such host` instead of a silent `000`) and named its own cause.

---

## Independent cross-host corroboration (2026-08-10T08:45Z, macOS VZ guest)

Run CONCURRENTLY and blind to the section above (merge reconciled after the
fact), by the macOS host on the coordinator's 648-dvzd ask #3. This guest has
PROVEN working container egress (the tillandsias-inference ollama
self-install downloaded through it hours earlier), so the controls anchor.
Probe container: the versioned inference image with `--entrypoint sh`;
HTTPS = `curl -s -o /dev/null -w "%{http_code}"` against github.com,
api.github.com, objects.githubusercontent.com (404 on a bare GET of the
third is an HTTP ANSWER — connectivity proven; `000` is no-connection).

| posture | DNS | HTTPS |
|---|---|---|
| `tillandsias-enclave` only | FAIL | `000 000 000` |
| `tillandsias-enclave,tillandsias-egress` (mirror posture) | RESOLVED | **`200 200 404`** |
| CONTROL: default podman network | RESOLVED | `200 200 404` |
| CONTROL: the guest host itself | — | `200 200 404` |

Network inspects: `tillandsias-egress internal=false driver=bridge`,
`tillandsias-enclave internal=true driver=bridge` — same shapes as the
Linux attempt.

**Both controls return 200, so the comparison is valid — and the mirror's
dual-homed posture has outbound reach byte-identical to the unrestricted
default network.** The audit's central claim is now OBSERVED, not just read
from source: the egress leg does not grant "GitHub push", it grants the
internet. The enclave-only row simultaneously confirms the spec's isolation
mechanism works as designed (`internal: true` really is airtight here).

Criteria 2–4 are now unblocked for the decision owner: the reproduction
shows scoping is absent at runtime, so criterion 2 (route mirror upstream
through the proxy, drop the egress leg) or a genuinely destination-scoped
criterion-3 exception must be implemented — closing as "theoretical" is no
longer available.

**Cross-host agreement note (merge reconciliation):** this macOS run and the
Linux second attempt above were executed concurrently, blind to each other,
on different hosts with different probe images and different destination
sets — and reached byte-equivalent verdicts on both properties (enclave
isolation airtight; egress leg = unrestricted internet). Criterion 1 is
closed by two independent observations.
