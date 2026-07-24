# PRINCIPLE + P2: every forge stack MUST be enclave-isolated and push via the git:// mirror relay on ALL platforms (uniform container stack)

- **Date:** 2026-07-23
- **Class:** security + architecture
- **Area:** forge isolation / enclave network / git-mirror push relay
- **Severity:** P2 — architecture + security-principle codification. The feared **P1** ("the Linux forge runs on the host network with host credentials → the isolation boundary is broken on Linux") is **REFUTED at HEAD** (evidence below), so this is not a live P1. The live P1 in this area is the macOS no-push-route packet (cross-ref). The residual isolation-reduction item (the opt-in `TILLANDSIAS_FORGE_HOST_MOUNT=1` escape hatch) is **medium**.
- **Owner:** operator (Tlatoāni) directive; Linux/forge to converge macOS + guard the host-mount escape hatch.
- **Discovered by:** operator directive ("a forge's WHOLE POINT is running untrusted agent code in an isolated enclave; all platforms must fire the SAME isolated container stack, not per-platform shortcuts") + a read-only cross-platform trace commissioned to confirm/refute it.

---

## 1. THE PRINCIPLE (operator directive — authoritative, durable)

A forge exists to run **untrusted agent code inside an isolated enclave**. Isolation is not a nicety — it is the forge's *entire purpose* **and** its security boundary. Therefore, on **every** platform (Linux native, Windows/WSL2, macOS VZ), the forge stack MUST:

1. **Run inside the enclave network** — attached to `tillandsias-enclave` (`--internal`, no NAT egress), never the host network, never the default bridge.
2. **Have egress only through the squid proxy** — `http(s)_proxy=http://proxy:3128`; no direct internet route is assumed.
3. **Hold no host credentials** — host `~/.ssh`, `~/.config/gh`, `~/.config/git`, and the native keyring are unreachable; the forge carries no GitHub token.
4. **Persist agent work by pushing through the internal `git://` mirror relay** — `TILLANDSIAS_GIT_SERVICE=tillandsias-git` → `git://tillandsias-git/<project>` → `relay-refs.sh` → `git-credential-tillandsias.sh` → a **Vault-issued** GitHub token injected only at the relay, never in the forge.
5. **Fire the SAME container stack on all platforms** — one forge image, one `--network tillandsias-enclave`, one proxy egress leg, one mirror push relay. Per-platform behaviour is allowed ONLY in the *source-staging transport* (how a fresh working tree is materialised), never in the isolation posture or the push route.

Per-platform divergence in isolation posture or push route is **accidental shortcut-taking, not principled design**, and any such shortcut MUST be treated as a regression against this principle.

---

## 2. INVESTIGATION — is the Linux-native forge enclave-isolated? (confirm/refute, with file:line)

**Operator's hypothesis:** the Linux-native forge SKIPPED the enclave network as a hacky quick-fix — it runs on the *host* network and pushes *directly* to GitHub with the *host's* git credentials (because Linux native *is* the host, so that was the easy path).

**Finding: REFUTED at HEAD (osx-next).** The Linux forge is enclave-isolated on every axis. It is the SAME isolated stack the VMs run.

### 2a. Network — the forge attaches to the enclave, never the host

- Both forge run-arg builders hard-wire `--network tillandsias-enclave`:
  - OpenCode CLI/Web forge: `crates/tillandsias-headless/src/main.rs:4664-4665` (`"--network".into(), ENCLAVE_NET.into()`).
  - Claude/Codex/agent forge: `crates/tillandsias-headless/src/main.rs:10684` (`.network(ENCLAVE_NET)`).
- `ENCLAVE_NET = "tillandsias-enclave"` and it is created `--internal` (no NAT egress): `main.rs:999-1010`; `ensure_enclave_network` `main.rs:1908`. Only the **proxy** and **git-service** are dual-homed onto `tillandsias-egress` to retain a single allowlisted egress leg (`ENCLAVE_EGRESS_NETS` `main.rs:1011-1014`, `ensure_egress_network` `main.rs:2075`, git-service attach `main.rs:2842`).
- The **only** `.network("host")` in the crate is the Chromium **browser** container (`build_project_browser_spec`, `main.rs:9424`) — NOT the forge. There is **no host-network forge path anywhere**.
- The spec mandates exactly this: `openspec/specs/enclave-network/spec.md:43-46` — *"Forge container attached to enclave only … MUST NOT have access to the default bridge network."*

→ The Linux forge is **not** on the host network. It **is** enclave-isolated. This is platform-independent by construction: the `tillandsias-headless` crate builds identical forge args whether it runs on a Linux host, inside WSL2, or inside the macOS VZ VM.

### 2b. Egress — proxy-only

- Every forge gets the canonical proxy env (`http_proxy/https_proxy/…=http://proxy:3128`, `NODE_USE_ENV_PROXY=1`): `proxy_env_args` / `apply_proxy_env` `main.rs:1040-1084`. The `--internal` enclave has no external DNS/NAT, so the squid proxy is the ONLY external route. Governed by `openspec/specs/security-privacy-isolation/spec.md` "Zero-tolerance network boundary" → *"Forge traffic is proxied … no direct internet route is assumed."*

### 2c. Credentials — none in the forge

- Host credential surfaces are masked by empty tmpfs on every forge: `.ssh` + `.config/gh` at `main.rs:10738-10739` and `main.rs:4718-4721`; `.config/git` quarantined likewise. Provider-free/maintenance forges get no secret mount at all.
- The forge holds **no** GitHub token. The git-service **mirror** owns the token and reads it from **Vault** only at push time: `images/git/relay-refs.sh:62-99` (`vault-cli read -field=token secret/github/token`), credential helper `images/git/git-credential-tillandsias.sh`. Governed by `openspec/specs/security-privacy-isolation/spec.md:17-33` ("Zero-tolerance credential boundary" + "Provider-free forge and terminal containers remain credential-free").

### 2d. Push lane — git:// mirror by DEFAULT (order 437), never direct-push

- **Default = clone-only**, which sets `TILLANDSIAS_GIT_SERVICE=tillandsias-git` → the entrypoint clones a fresh tree from the enclave mirror and pushes back over `git://`: `main.rs:10749` and `main.rs:4794`. Landed by `fbe7ce7b feat(437): forge launches clone-only by default — isolation + obsoletes facade`; `ed9f91d4 plan(437): DONE — operator live-verified clone-only forges`. (Both commits are in osx-next's history.)
- **Even the opt-in legacy host-mount does NOT direct-push.** `TILLANDSIAS_FORGE_HOST_MOUNT=1` (`main.rs:4191-4201`, branch `main.rs:4767-4781` / `10692-10701`) rewrites origin onto the mirror via `rewrite_origin_for_enclave_push` (`images/default/lib-common.sh:397-457`) precisely because *"the forge has zero credentials and no DNS for github.com — direct push fails"* (`lib-common.sh:375`). `git push origin` silently routes to `git://tillandsias-git/<project>`.

→ There is **no** "direct-push to GitHub with host credentials" path in the Linux forge. **REFUTED.**

### 2e. WHY the operator's belief is understandable (and where it still has teeth)

- **Historical truth, since remediated.** *Before order 437*, the shared **host-mount was the DEFAULT** on Linux native — the operator's "quick-fix" memory is the pre-437 era. Order 437 explicitly demoted it to an opt-in escape hatch *for isolation* ("obsoletes facade"). So the shortcut was real; it has been fixed as the default.
- **The residual with teeth:** the opt-in `TILLANDSIAS_FORGE_HOST_MOUNT=1` still bind-mounts the operator's real checkout **rw** and installs the gitdir facade (`main.rs:4767-4781`, `append_forge_repo_gitdir_mount_args`). That **reduces workspace isolation** (agent edits become host-visible without a commit; facade data-loss surface) even though it still mirror-pushes. It is opt-in, not default — but it is the last place a Linux forge can silently run less-isolated than the principle requires.

### 2f. The cross-referenced macOS packet's Linux row is INACCURATE — this packet corrects it

`plan/issues/macos-forge-no-push-route-lane-decision-2026-07-23.md:24-30` asserts *"Linux native | NOT enclave-isolated — it is the host | Pushes directly to GitHub with the host's own git credentials. No mirror needed."* That predates/overlooks order 437 and is **wrong at HEAD**: the Linux forge is enclave-isolated and mirror-pushes by default. The correct comparison is the table in §3.

---

## 3. THE ACTUAL CURRENT DIVERGENCE (residual, with file:line)

Network isolation itself **never diverged** — it is uniform (`tillandsias-enclave`) on all platforms because all three run the same headless crate. What diverged is the per-platform **source-staging lane**, and one of those lanes (macOS) dropped the push half:

| Platform | Enclave-isolated? | Push route today | Divergence |
| --- | --- | --- | --- |
| **Linux native** | **YES** (`ENCLAVE_NET` `main.rs:4664`/`10684`) | git:// mirror **by default** (437; `GIT_SERVICE` `main.rs:10749`/`4794`) | Opt-in `TILLANDSIAS_FORGE_HOST_MOUNT=1` escape hatch remains: rw host-checkout + gitdir facade (`main.rs:4767-4781`). Still mirror-push, but reduced *workspace* isolation. **Guard/retire.** |
| **Windows / WSL2** | **YES** (same crate in WSL2) | git:// mirror relay (`GIT_SERVICE` / filesystem `GIT_MIRROR_PATH`) | **None — the correct reference.** |
| **macOS (VZ VM)** | **YES** (SRC-ISOLATION clone lane; sets `GIT_MIRROR_PATH` `main.rs:4765`) | **NONE** — the SRC-ISOLATION lane sets `GIT_MIRROR_PATH` but **never** `GIT_SERVICE` (`main.rs:4753-4766`), so no `git://` push relay is installed; agent commits are stranded in the `--rm` overlay. | **P1 gap** (own packet). Same enclave situation as Windows, solved a different way (order 342), and that lane skipped the push half. |

So the real divergence is **not** isolation posture (uniform) but push-route wiring: **macOS has no push relay**, and **Linux retains an opt-in escape hatch that can reduce workspace isolation**.

---

## 4. CONVERGENCE TARGET (all platforms, uniform stack)

Every platform's forge stack converges on the identical isolated posture:

1. **Enclave network** — `--network tillandsias-enclave` (`--internal`); proxy + git-service the only dual-homed egress leg. *(Already uniform.)*
2. **Proxy-only egress** — `http(s)_proxy=http://proxy:3128`. *(Already uniform.)*
3. **git:// mirror push relay** — `TILLANDSIAS_GIT_SERVICE=tillandsias-git` → `relay-refs.sh` → `git-credential-tillandsias.sh`. *(Linux default + Windows have it; **macOS must add it**.)*
4. **Vault-token credential injection at the relay only** — never in the forge. *(Already the design; macOS inherits it by wiring #3.)*
5. **One container stack** — same forge image, same enclave, same proxy, same relay. Per-platform code confined to source-staging transport (git-daemon vs filesystem-mirror vs read-only virtiofs clone), never isolation or push route.
6. **Ram-disk (tmpfs) working checkout cloned from the mirror** (operator target, 2026-07-23) — the working tree materialized on tmpfs, not the disk-backed container overlay, for speed + ephemerality + isolation. **Status: NET-NEW on every platform** — today all three lanes clone into the container overlay at `/home/forge/src/<project>` (`images/default/lib-common.sh:477`); no lane uses a tmpfs checkout (existing tmpfs mounts are `/tmp`, `/run/user`, credential-quarantine, and the host-mount gitdir facade only). An enhancement on top of the existing clone-from-mirror, uniform across platforms.

**Concrete steps:**
- **macOS:** wire `TILLANDSIAS_GIT_SERVICE` into the SRC-ISOLATION lane (`main.rs:4753-4766`) so the read-only clone forge pushes the SAME way Windows/Linux-default already do → the macOS no-push-route packet's **Option B**.
- **Linux:** guard/retire the opt-in `TILLANDSIAS_FORGE_HOST_MOUNT=1` escape hatch so it cannot silently run a less-isolated forge; if kept for the solo live-edit workflow, it must be loud + opt-in-only, never a default and never reachable by an untrusted-agent launch.
- **All platforms (ram-disk, net-new):** materialize the cloned working tree on a sized tmpfs (`--tmpfs /home/forge/src` or a checkout-specific mount) instead of the overlay, so `clone_project_from_mirror` (`lib-common.sh:472-477`) lands on ram-disk. Applies to the Linux/Windows clone-only default and the macOS lane alike.
- **Docs:** ~~correct the Linux row in `macos-forge-no-push-route-lane-decision-2026-07-23.md:24-30`~~ — **DONE** (corrected + the ram-disk net-new finding added).

---

## 5. THIS SETTLES THE macOS PUSH-ROUTE DECISION → OPTION B

The uniform-isolation principle **decides** the open macOS lane choice in `macos-forge-no-push-route-lane-decision-2026-07-23.md`:

- **OPTION B (wire the `git://` mirror push into the macOS SRC-ISOLATION lane) — CORRECT.** It is exact **parity** with the isolated stack Linux (order 437) and Windows already run: enclave network + read-only clone + mirror push + Vault-token relay. It **preserves** the isolation macOS deliberately chose and satisfies every clause of the principle.
- **OPTION A (switch macOS to the host-mount lane) — WRONG DIRECTION.** It bind-mounts the operator checkout rw and re-installs the gitdir facade — it **reduces isolation** and resurrects exactly the facade that order 437 *obsoleted* on Linux. Choosing A would repeat the pre-437 Linux shortcut on macOS, moving *away* from convergence. Reject it.
- **OPTION C** remains recovery-only.

**Decision recorded here:** macOS → **Option B**. The forge's isolation is its whole purpose and a security boundary; the push route must be added **without** trading isolation away.

---

## 6. SECURITY FRAMING

- **Governing specs:** `openspec/specs/security-privacy-isolation/spec.md` (zero-tolerance credential + network + runtime-leakage boundaries), `openspec/specs/forge-as-only-runtime/spec.md` (no host-side execution surface; exhaustive mount categories; no host `$HOME` bind-mounts; no host-side credential exposure), `openspec/specs/enclave-network/spec.md` (forge attached to enclave only).
- **Boundary status at HEAD:** intact on Linux, Windows, macOS for *network* + *credentials* (the feared P1 break is refuted). The two open items are (a) macOS cannot persist work (availability, not a leak) and (b) the Linux opt-in host-mount escape hatch reduces *workspace* isolation when explicitly enabled.
- **Why this stays high-priority despite the refutation:** the principle must be *codified and enforced* so the next per-platform lane (or a re-defaulted escape hatch) cannot silently drop isolation again. A forge that is not enclave-isolated is not a forge — it is untrusted agent code with host reach.

---

## 7. Cross-references

- `plan/issues/macos-forge-no-push-route-lane-decision-2026-07-23.md` — the macOS no-push-route P1; **this packet settles it toward Option B and corrects its Linux comparison row (lines 24-30).**
- `plan/issues/mirror-readiness-gate-seeded-not-reachable-2026-07-23.md` — mirror readiness gate (Option B relay reachability).
- `plan/issues/forge-launch-must-guarantee-fresh-checkout-idempotency-2026-07-20.md` — the order-437 fresh-checkout / clone-only default.
- `openspec/specs/enclave-network/spec.md` (forge-enclave-only), `openspec/specs/security-privacy-isolation/spec.md`, `openspec/specs/forge-as-only-runtime/spec.md`.
- Code anchors: `crates/tillandsias-headless/src/main.rs:4664`, `:10684` (forge → enclave); `:999-1014` (`--internal` enclave + egress leg); `:1040-1084` (proxy env); `:4753-4796` (source-routing branches: SRC-ISOLATION / host-mount / clone-only); `:10738-10739`, `:4718-4721` (credential quarantine). `images/default/lib-common.sh:370-457` (`rewrite_origin_for_enclave_push`). `images/git/relay-refs.sh:62-99`, `images/git/git-credential-tillandsias.sh` (Vault-token relay).
