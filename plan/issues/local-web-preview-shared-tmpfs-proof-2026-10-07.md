# Shared preview source — proof boundary and bounded HOT-store obligation

- **Status**: in_progress; architecture proposal, successful sharing unproven
- **Owner**: Sol runtime 1552-238z; Terra probe/image-MCP 1552-mqvf;
  parent acceptance 1552-e3wf
- **Specs**: `local-web-preview` draft; active `forge-hot-cold-split`
- **Current parent branch**: `work/1552-e3wf` (reported by parent)
- **Historical design receipt**: linux-next at `95350b0c8` remains historical,
  not rewritten to describe the subsequent work-ref.
- **Scope of this follow-up**: Astra read-only architectural review plus this
  checkpoint, draft spec and ledger notes; no code, runtime probe, CA or push.

## Evidence supplied by Terra through parent

Disposable rootless Podman probes reported:

| Mechanism | Observed result |
|---|---|
| `--volumes-from` with source in overlay rootfs | `NOT_VISIBLE` |
| `--volumes-from` with source tmpfs | warning `Unable to match /share`, `NOT_VISIBLE` |
| rootless `podman mount` | requires unshare; exposes storage overlay root, not the live tmpfs |

These are negative export results, relayed evidence rather than a second Astra
execution. They do NOT prove shared runtime bind success. Exact disposable
commands/version/log artifact should be attached by Terra/parent before these
results serve as reproducible acceptance evidence. No production container or
unrelated ollama instance should be touched for the next probe.

Terra recommends a 0700 per-lane runtime workspace at
`$XDG_RUNTIME_DIR/tillandsias/lanes/<project>-<instance>/workspace`, mounted rw
at the forge's normal `/home/forge/src` so normal clone populates the live source;
then narrowly expose config/assets/Worker paths read-only to the sibling, with
private sibling state. Parent accepted that direction IN PRINCIPLE and Sol is
implementing with that steering. The host checkout
`/var/home/tlatoani/opencode/tillandsias.org` and HOST/src remain forbidden
substitutes. There is no observed success for the recommended shared bind yet.

## Blocking semantic difference

Canonical `openspec/specs/forge-hot-cold-split/spec.md`, requirements
"HOT tier — RAM-backed tmpfs for finely curated paths", "Per-mount size caps",
"--memory ceiling pairs with tmpfs caps" and "Per-launch project source budget",
requires four kernel tmpfs roots, a per-launch `compute_hot_budget()` source
mount, kernel size cap/ENOSPC, and equal memory/memory-swap ceilings of
`8 + budget + 256 + 64 + 256` MB. A 0700 DIRECTORY under the user's `/run/user`
tmpfs has only its parent's shared filesystem limit. It has no independent
per-lane ENOSPC boundary and may charge writes outside the forge cgroup.
RAM backing is necessary but not sufficient. Container OOM, usage polling or
host tmpfs exhaustion cannot substitute for a lane filesystem returning ENOSPC.

Exact proposed exception: change only the mechanism for `/home/forge/src` from
per-container `--tmpfs=...` to a shared per-lane **independently bounded kernel
tmpfs** mounted at the same root. Preserve all four root paths/modes, computed
caps, preflight, no-swap accounting and cleanup/restart isolation. Canonical
`forge-hot-cold-split` is NOT amended by this checkpoint. Mechanism reconciliation
and measured equivalence are required before activating preview spec. An
unbounded runtime directory is not a temporarily approved implementation.

## Read-only vendor-doc exploration (2026-10-07)

1. Podman volume-create docs:
   https://docs.podman.io/en/latest/markdown/podman-volume-create.1.html
   document `--opt device=tmpfs --opt type=tmpfs --opt o=size=...` for a named
   tmpfs volume. They also state local-driver mount options beyond UID/GID
   require root privileges. Thus this is a candidate bounded filesystem shape,
   NOT proof that the installed rootless runtime can provision it. Default local
   volumes are disk-backed and are inadmissible here. `--ignore` does not apply
   new options to an existing volume: generation identity and size inspection
   are essential. Do not turn this doc reference into a request for host sudo.
2. Podman unshare docs:
   https://docs.podman.io/en/latest/markdown/podman-unshare.1.html
   confirm a rootless user namespace and that unprivileged `podman mount`
   requires it; unshare is unavailable to remote Podman clients. These docs do
   NOT establish mount propagation from a helper into separately launched
   containers or retention/lifetime of a mounted tmpfs.

A bounded named tmpfs volume, if the actual supported rootless stack permits
it, or a controller-owned persistent user/mount namespace with a size-limited
tmpfs are investigation candidates only. A namespace design must prove both
containers can receive the same mount through sanctioned control paths, with
correct UID/SELinux policy and cgroup charging. No privileged host helper,
new ambient mount authority or production `unshare` side channel is approved
by naming the candidate. If neither works, return a precise unsupported
shared-source-provisioning result and propose the necessary architecture change;
do not weaken the HOT contract to get a serving page.

## Next proof / acceptance obligations

Sol and Terra coordinate ONE disposable experiment on the installed rootless
runtime, with artifacts naming Podman/kernel versions, generation and arguments:

1. Real source mount reports tmpfs and computed per-lane size from inside both
   relevant views; four forge HOT roots/caps and unchanged agent-visible paths.
2. Forge writes uncommitted nonce and atomic-replace edit; sibling sees each
   through narrow read-only views, cannot write or escape selected paths.
3. Disposable small-bound test produces ENOSPC at filesystem cap, not OOM or
   shared host exhaustion. Other lane remains usable. Do not fill host tmpfs.
4. Actual memory charging/growth and reclaim stay attributable/enforceable for
   owner; memory/swap ceilings and RAM preflight remain effective. Record
   cgroup/controller availability; argv alone is insufficient evidence.
5. Preview restart/stop preserves live source; forge teardown stops sibling,
   releases all references and removes source. Relaunch same names has fresh
   source/budget. Helper crash and failed launch leave no stale mounted source
   or cross-lane cleanup; ownership guards are tested.

Current residual: no proven source-sharing mechanism simultaneously satisfies
visibility, kernel per-lane ENOSPC cap, accounting and lifecycle. Track this under
1552-238z, not a duplicate implementation packet. Parent 1552-e3wf cannot close
or activate the draft on an HTTP/HTTPS smoke alone. Future preview litmus must
include these bounds; existing hot/cold controls remain regression obligations.

## Superseding memory-policy resolution (parent follow-up)

The earlier no-swap/equal-ceiling wording above records the stale canonical text
used at initial review, not the resolved policy for implementation. Parent read
the explicit order437 ruling in
`plan/issues/forge-memory-swap-architecture-design-2026-09-26.md` and approved
delta `openspec/changes/forge-swap-backed-memory-ceiling/specs/forge-hot-cold-split/spec.md`:
THIS feature preserves existing positive-swap tier `ForgeBudget` unchanged.
Accounting equivalence means shared tmpfs allocations remain bounded/charged
under that approved budget; it does not mean disabling swap. No host swap
provision changes, persistent source, disk filesystem source fallback or new
UX approval. Four HOT roots, per-lane cap/ENOSPC, mode0777 source root and
generation cleanup remain obligations. Canonical spec-sync is a pre-existing
residual on 1552-e3wf; this checkpoint does not sync the whole swap change.
