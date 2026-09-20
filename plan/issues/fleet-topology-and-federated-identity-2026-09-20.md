# Fleet topology and federated identity — design exploration (2026-09-20)

**Status:** design exploration for the operator's refinement, not a spec. Filed by the coordinator (macuahuitl-fedora) from a four-agent design panel (three independent sketches: identity-first, topology-first, operations-first; one synthesis) run under the session's ultracode opt-in on 2026-09-20; 4 agents, about 200k sub-agent tokens, 3.5 minutes. The panel's context was the operator's own plan of 2026-09-20 (Pi 5 boards with old 8 TB disks as fleet servers; the headless binary on bare-metal aarch64; a GitHub App and possibly a "Login with GitHub" popup; a `.tillandsias` meta-repository for distributed persistent state, "might be a bit invasive"; production apps and infra services on the Pis; "set up once and my cloud lives forever, locally") plus the decisions already made (1288-5qpn: per-host credential-free push through the host's own mirror; 1290-5833: the Pi fleet server; 1289-ggsb: the shared expert; 1291-38mt: the aarch64 install path).

**Coordinator's annotations, read these before the panel's text.** (1) The panel recommends AGAINST two of the operator's floated ideas, the popup login flow and the `.tillandsias` meta-repository, with reasons; those are recommendations for the operator to accept or overrule, not decisions. (2) Where the panel names a one-time `gh auth login` for the operator, the fleet's device-flow ban (1025-a896) stands for every HOST: under a deploy-key design no host needs a gh token at all, and the one-time login lives only on the release host that runs the GitHub API. (3) The panel's Pi role (cache and pull-through, never on the push path) agrees with 1290-5833 as filed; its "no broker on the operator's desktop" agrees with the fleet-tier rule. (4) The Pi's unseal path with no desktop keychain is the panel's own open question and is the first thing 1290-5833's topology decision must answer.

---

# Fleet identity and topology: credential-free push, the Pi, and what not to build

## 1. Recommendation

Keep three credentials for three principals, and give each one the smallest home that still works. The host-to-its-own-mirror hop needs no credential at all (local socket, already decided in 1288-5qpn). The mirror-to-GitHub hop gets a **per-host ed25519 deploy key**, minted in-enclave at first provision, private half never leaving that host's Vault — shipping now, on the Linux hosts, with no new machinery. The operator-to-GitHub hop is a one-time act, done at a terminal with `gh auth login`'s device flow, never a recurring step. Per-host mirrors are the **permanent** architecture, not a stepping stone: the Pi 5 joins the fleet as an ordinary enclave host and earns a *cache* role (sccache, object-store pull-through, artifact store) that is never on any host's critical push path. A GitHub App is worth building later, for exactly one reason — short-lived, centrally revocable installation tokens for the one hop that faces GitHub — and when it is built, its private key lives on the Pi, not on macuahuitl. Do not build the "Login with GitHub" popup flow. Do not build the `.tillandsias` meta-repository.

## 2. Identity

**Why deploy keys first, App second.** A fine-grained PAT is a bearer secret carrying the operator's whole account blast radius, unscopeable per host and unrevocable per host — it is the documented cause of the gnome-keyring aborts and the device-flow eviction races. A deploy key is write-scoped to one repo, individually revocable (`gh repo deploy-key delete`), needs no refresh logic, and requires no browser — which matters, because the Pis are headless and the Windows and macOS paths are guests. At seven-to-ten hosts this is simpler and more inspectable than installation-token minting. A GitHub App becomes worth its complexity when the fleet passes roughly a dozen hosts, or when a compromised host must be cut off faster than a human can run `gh` — its installation tokens expire by construction in an hour, and refresh is a signed JWT exchange with no device flow at all.

**The sketches disagree on where the GitHub credential sits, and the disagreement is real.** One argues for a broker role on macuahuitl (already the coordinator, always on) vending short-lived tokens to peers over the LAN. Another argues the Pi holds it. The third argues every host holds its own key and nothing is brokered. Resolve it this way: **no broker on the operator's desktop.** macuahuitl is a daily driver that reboots, updates, and gets used for unrelated things; making it a dependency of the fleet's only path to GitHub recreates the single point of failure this redesign exists to remove, and it contradicts the fleet-tier rule. Per-host keys need no broker at all, which is why they ship first. If an App is later adopted, its key goes on the Pi — with the caveat that a Pi's old spinning disk will eventually fail, so the App private key must be backed up off-Pi (operator's password manager or offline) *before* that stage ships, or a disk failure costs a full re-auth and "set up once" is already broken.

**What Login-with-GitHub gates, and what it must not.** It gates exactly one action, once, ever: the operator installing the App on the repo. It must never be a per-host, per-boot or per-push step — a popup is a recurring manual step wearing onboarding's clothes, and it is unreachable on every headless member of this fleet. A browser OAuth flow also implies a callback endpoint, which is surface area defending against a threat a single-operator fleet does not have.

**The three flags.** `--github-status` prints, for the host it runs on: which hop that host terminates, credential kind and fingerprint (or installation ID), last successful relay timestamp, mirror container health, and the state of what it depends on downstream. Verdict grammar, one of: `ok` / `missing` (never minted) / `locked` (Vault sealed or keychain unavailable) / `rejected` (credential present, GitHub returned 401/403 — e.g. deploy key not yet registered) / `unreachable` (relay target down). `rejected` must be distinct from `missing`; a healthy local mirror in front of a dead relay must not print green — that is the same shape as the vault container that sat `Exited (143)` unnoticed for three days. `--github-logout` clears the credential from that host's Vault and, where the credential is revocable programmatically, revokes it; for a deploy key it must print that GitHub-side removal is still a manual `gh` step rather than silently claiming success. `--github-refresh` re-mints where refresh is meaningful; against a deploy-key host it prints "deploy keys do not expire; nothing to refresh" — the fail-loud contract applies to the *absence* of work too.

## 3. Topology

Per-host mirrors, permanently. A host's own mirror answers "can I push right now" and must depend on nothing but that host's container stack, so a wifi host pushes instantly even while the LAN is flaky; the mirror-to-upstream relay is a background sync with its own retry and its own `blocked:relay:<reason>` verdict, and it never blocks the developer's push. The Pi answers "did it reach GitHub" only if the operator later chooses the two-hop chain; until then, the Pi's job is cache and object-store pull-through, where its being down is a `warn`, never a `fail`. That asymmetry — critical path stays host-local, the Pi only ever helps — is the central topology decision, and it is the one thing all three sketches converge on when pushed.

Discovery: mDNS/avahi (`tillandsias-pi.local`) as default, since it works unmodified on a home router with one broadcast domain, plus a static host-registry file as an explicitly-labelled fallback for multicast that will not cross a wifi AP. `--github-status` must print `discovery: static fallback, N peers from file` rather than reporting zero peers as "none configured." No VPN, no mesh overlay, no service-discovery library.

Vault: one instance per enclave, host-local, keychain-anchored unseal, including on the Pi for its own mirror. Never centralized — a central Vault puts secrets in flight over an unencrypted, partly-wifi home LAN and makes one board a single target. The Pi's unseal path is an open question (§7): a headless board has no desktop keychain.

Failure verdicts: Pi down → `warn: cache endpoint unreachable, building cold`, pushes unaffected. Host mirror container unhealthy → non-ok immediately, distinct from "relay pending." Vault sealed → push refuses with `locked: vault sealed`, never hangs, never silently queues. Deploy key not yet registered → `rejected`. Relay non-fast-forward → name which host's ref lost, not "relay failed."

## 4. Persistent state

`.tillandsias` as a GitHub meta-repository would hold host registry, leases, heartbeats, index freshness, cross-host claim coordination. It is invasive for three compounding reasons: git gives permanent history, merge-conflict semantics and no TTL to data that is high-churn and disposable; it is a *second* credentialed GitHub surface stood up precisely while this design is trying to shrink that surface; and it duplicates governance `plan/index.yaml` already provides, creating a second authority that can drift from the first. It also makes LAN-local coordination depend on internet reachability, which cuts directly against "my cloud lives forever, locally."

The less invasive split: durable, audited decisions stay in the existing plan ledger, unchanged. Ephemeral coordination state goes into a small rebuildable LAN-local store on the Pi — etcd, consul, or litestream'd SQLite — which is itself ephemeral by design, exactly like every other guest, forge and cache. If a need later appears that the ledger structurally cannot serve, reopen it narrowly, as its own packet, not as a general meta-project.

## 5. Rollout

**A (this month, in flight, 1288-5qpn):** finish per-host credential-free push on the Linux hosts against the current Vault-held credential, with the three flags landed to the verdict grammar above. Independently useful: it ends the gnome-keyring aborts even if every later stage stalls.

**B (this month, 1291-38mt):** aarch64 headless build reaches the installer and the release pipeline, with the router sidecar's arch verified, proven by an operator `--init` on real Pi bare metal.

**C (this month):** replace the shared PAT with per-host ed25519 deploy keys — mint in-enclave, register once via `gh`, document the Vault path schema, extend the "forge cannot read the GitHub token" litmus to the new paths. The shared PAT retires here.

**Next:** one Pi online as an ordinary enclave host running mirror + sccache only; measure cold/warm build and relay latency from one wired host and one wifi host; write the topology recipe as a plan/issues file before implementing further.

**Later:** GitHub App (one-time install, key on the Pi, backed up off-Pi first); shared expert over the Pi's mirror; NAS/GlusterFS and production services, only after the Pi's roles have been boring for several weeks.

## 6. Rejected

- **Rotating the shared PAT faster** — narrows the race window, does not remove the standing bearer credential or the cross-host eviction.
- **Fleet-shared Pi mirror as the only mirror** — makes every push depend on one board with an old spinning disk.
- **A broker role on macuahuitl** — puts the fleet's GitHub path behind the operator's daily driver.
- **Per-host GitHub Apps** — every host holds a GitHub-scoped secret again, just a shorter-lived one.
- **Login-with-GitHub popup as an auth gate** — headless fleet, single operator, callback endpoint for nothing.
- **`.tillandsias` meta-repo now** — second ledger authority, second credentialed surface, wrong storage model.
- **VPN/mesh overlay** — one broadcast domain already; client management across WSL2/VM/bare-metal is new labour.

## 7. Open questions

1. How does the Pi's Vault unseal on a headless board with no desktop keychain — TPM, a typed passphrase at boot, or an operator-run unseal that makes reboots a manual step?
2. Should the two-hop chain (host mirror → Pi mirror → GitHub) ever happen, or does the Pi stay cache-only permanently?
3. Where is the GitHub App private key backed up, given the Pi's disk will fail?
4. Do Windows and macOS hosts get per-host deploy keys in stage C, or stay on the current path until their guests are proven?
5. Is one Pi enough to start, or does the storage track need two boards before anything depends on it?
