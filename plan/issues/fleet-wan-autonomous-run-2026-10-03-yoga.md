# Fleet WAN autonomous run — yoga, 2026-10-03

- host: yoga (Fedora Silverblue laptop), coordinator: Claude Opus 5.5 session "yoga-silverblue"
- authorized by the operator 2026-10-03 for ~1 day: design + plan + specs + packets that need no operator action
- boundaries kept: no release, no `main`, no Cloudflare credentials/dashboard/DNS, no router/Pi/macuahuitl changes, no Codex-claimed files
- operator rulings for this layer: memory `fleet-wan-layer-operator-rulings`, distilled into
  `plan/issues/fleet-wan-rendezvous-design-2026-10-03.md` (rulings section)

## What landed / is queued

| item | branch | state |
|---|---|---|
| Design note, OpenSpec change `fleet-wan-rendezvous`, milestone 1548-9n28 + 20 packets, amendment events | `work/fleet-wan-rendezvous` | LANDED `4912fa470` (verified on origin/linux-next) |
| 1548-mhyk `is_ipv6_functional` defect (flow-label per-router probe; yoga measures `egress=1/2`) | `work/fleet-wan-batch1` | landing with this note |
| 1506-euvq rootless WARP sidecar measurement (`outcome:tun-denied-rootless` for the packet posture; repaired posture passes pre-enrollment) | `work/fleet-wan-batch1` | landing with this note |
| 1548-dylo `tillandsias-fleet-core` score + `plan/fleet/services.yaml` (macuahuitl preferred) | `work/fleet-wan-batch1` | landing with this note; wasm32 build UNPROVEN (target not installed on yoga) |

Packet status events (completed / measured) are NOT written by this run: each row's closure names
its own evidence, and 1506-euvq's needs an operator-minted service token to finish.

## Landing log (what the gate refused, and why)

1. `violation:scorable-obligation-missing:7` — ours: seven decision / measurement / operator / goal rows
   had no litmus and no `unscoreable:` reason. Fixed with explicit reasons.
2. `could-not-run:lua-decider:source-agreements.lua:no-script-runner` → 980-ja2m refused — HOST: the
   installed `~/.local/bin/tillandsias-plan` was stale (`build-id` 0.1.0+ee1c5cde… vs source
   0.1.0+4cc00de8…, no `script` capability). Rebuilt from linux-next 49a7669c7 and installed; both ids
   now equal.
3. `violation:issue-citation-line-numbers:5` — ours: the design note cited code by line; rewritten to
   cite by symbol (881-29me).
4. INVALID ATTEMPTS (coordinator error). `scripts/relay-preflight.sh HEAD --base origin/linux-next
   --plan` "returned rc=0 (16 deciders)", but `--plan` prints the selected deciders WITHOUT running
   them, and the script cuts `relay/<utc>` from the base and THEN resolves `HEAD`, so it merged the
   relay branch into itself (zero commits) and left it checked out. Attempts 4 and 5 therefore gated
   origin/linux-next's own tree. Attempt 4's refusal (a fixture "wrote into /tmp/tillandsias-timing.jsonl",
   1204-3s2s) was a SECOND coordinator error: a coding subagent was running its own `./build.sh --check`
   concurrently, and the gate attributes host-wide /tmp writes to whichever step is running (the step
   alone: rc=0, no leak). Attempt 5's push failed `refused:land:auth-failed` because a linked worktree
   cannot open the credential store's relative `.git/.gh-credentials` (the credential itself was fine).
5. Attempt 6 (main checkout, correct tree): `fail:test-baseline … new-red=1 first=lua_proc::managed_script::callbacks_cancel_owned_groups_even_when_caught_or_cpu_bound`
   — not ours (plan/spec-only diff). Alone it passes 3/3
   (`cargo test -q -p tillandsias-plan --test lua_proc callbacks_cancel_owned_groups_even_when_caught_or_cpu_bound`,
   ~10.8 s each): a CPU-timing test that reds under full-gate load. For the bash-to-lua owners (1538-pwdr).
6. Attempt 7: `ok:land:4912fa470:attempt-2`.

## Findings for the operator

### Decisions only you can make

1. **Per-host public DNS** (design note §5a). As drafted, every host's current IPv6 (and Mesh IP) is
   published in public DNS; for an off-LAN laptop that discloses its network. Recommended: publish only
   service names; per-host addresses in the signed roster only. Interim: none written for transient hosts.
2. **WARP sidecar posture** (1506-euvq outcome `tun-denied-rootless` for the packet's posture; every
   pre-enrollment step PASSES with two changes):
   - `--security-opt label=disable` on the warp sidecar (SELinux denies the TUN open otherwise; the router
     already runs with it);
   - `--userns=container:<owner>` instead of `keep-id` (separate userns ⇒ NET_ADMIN does not cover the
     shared netns) — today's policy refuses that value;
   - the router's network `tillandsias-enclave` is `internal=true`, so a sidecar in the ROUTER's netns
     cannot reach Cloudflare ("Network is unreachable"); the sidecar needs its own egress-capable netns
     or the router needs an egress network.
   1506-t97c's exit criterion names the `keep-id` flags that cannot work; it should name the OUTPUT
   (a TUN and a Mesh address) instead.
3. **Cloudflare account setup** (design note §5): private OAuth client `Tillandsias`, Zero Trust org,
   Mesh, device profile (Traffic+DNS, split tunnel not excluding `100.96.0.0/12` — the DEFAULT exclude of
   `100.64.0.0/10` contains it), `workers.dev` subdomain, zone-scoped DNS token as a Worker secret. Then
   a service token + `mdm.xml` lets `scripts/research-warp-sidecar-rootless.sh --throwaway --posture
   repaired --owner-network pasta --mdm <file>` finish the measurement.
4. **The Pi's router advertisements** (1548-i07i): it advertises a default IPv6 route but does not
   forward; about half of every LAN host's IPv6 flows black-hole. dnsmasq `ra-param=<iface>,0,0` or
   radvd `AdvDefaultLifetime 0`.

### Defects found on the way

- `is_ipv6_functional` never worked (unbracketed SocketAddr) ⇒ `--init` always wrote `--ipv4-only`
  (1548-mhyk, fixed on its branch). Review caught the first fix steering ECMP by source port:
  `fib_multipath_hash_policy` is 0 here, `ip -6 route get … sport P` sent 6/6 ports to the Pi while
  `flowlabel` split 3/3 — the probe now steers by flow label; yoga measures `ipv6 egress=1/2`.
- `plan_answer` refused its own answer about 1505-sm2j (citation check vs `obsoleted` spans) → 1548-twha.
- The four Cloudflare login rows (1505-svve/kyx8/iysn/kc5f) still fold `ready` though their code
  landed → 1548-8ii6.
- `resource_lock::tests::is_held_reflects_lock_lifecycle` failed once, passed on rerun (flaky).
- `scripts/relay-preflight.sh HEAD …` merges nothing and reports ok (it resolves `HEAD` after
  switching to its relay branch). It should resolve refs before the checkout, or refuse a merge that
  adds zero commits. Not filed as a packet by this run; recorded here for the coordinator.
- `lua_proc::managed_script::callbacks_cancel_owned_groups_even_when_caught_or_cpu_bound` is
  load-sensitive (above, landing log 5).

## Later landings

- `e889a1c0e` (1548-8ii6): completion events for 1505-svve/kyx8/iysn/kc5f/iky3 and 1548-mhyk/dylo, each
  from its own closure run on trunk 02c199aa6. kc5f's tray waiter is split to 1505-hfim (not an exit
  criterion). dylo's wasm32 criterion proven (`rustup target add wasm32-unknown-unknown` needed no sudo).
- 1506-32k5 (this commit's branch): per-host X25519 identity in Vault, `plan/fleet/peers/`, Noise XX with
  the directory lookup BEFORE any byte is read. Coordinator review blocked the first version: the
  lookup-after-read mutation seam was reachable in RELEASE builds whenever `TILLANDSIAS_MSG_ROOT` (a
  legitimate production store-root setting) was set — an authentication off-switch in a shipped
  binary. Now `cfg(debug_assertions)`-only, with a release-profile test proving the variable is
  ignored.
- Spec conflict for the operator/coordinator: the fingerprint field is `fp` in the fleet-messaging
  design + spec delta (1506-32k5's own wording) and `noise_fp` in fleet-wan-rendezvous Decision 6 /
  1548-cii8. The code uses `noise_fp` (cii8 owns the schema); the fleet-messaging delta must be
  reconciled before it is synced.
