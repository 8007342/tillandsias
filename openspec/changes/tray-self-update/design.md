# Design — tray-self-update (2014-auup)

## 1. Discover, without a new poll

A check is an HTTPS GET of the stable release's `update-manifest.json`
(`/releases/latest/download/`), and runs on two events only:

- tray start (after Ready), and
- the operator opening the tray menu, at most once every 6 h (the result is
  cached; opening the menu twice is one request).

There is no background timer. A host that never opens its menu learns of a
release at its next start. **OPEN Q1:** the operator may want a daily check for
an unattended tray; that is a new cadence (1 wakeup/day) and needs their approval.

Prereleases (daily) are never offered by this path; a host on the daily channel
keeps installing by hand.

## 2. Verify: a signature, then the hashes

**What already exists.** `release.yml` signs every published artifact with
Sigstore cosign, keyless, through GitHub Actions OIDC, and uploads a
`<artifact>.cosign.bundle` beside each. The release gate already runs
`cosign verify-blob` against an anchored identity: SAN
`https://github.com/8007342/tillandsias/.github/workflows/release.yml@refs/heads/main`,
issuer `https://token.actions.githubusercontent.com` (1407-6jr8, 1953-jmvb). What
is missing is a CLIENT that checks: the installers check SHA256 only, and
`SHA256SUMS` itself is not signed (the signing loop skips it). So the gap is
verification on the user's machine, not signing.

**Recommendation: verify the existing Sigstore signatures; add no new key.**
`update-manifest.json` is one more release artifact, so the same signing step
gives it a `.cosign.bundle`. The tray verifies that bundle before anything else.

Comparison against a new Ed25519 (minisign) key:

| | Sigstore keyless (recommended) | New Ed25519 key |
|---|---|---|
| Key custody | None: no long-lived key exists. A signature means "release.yml ran on main of 8007342/tillandsias", issued per run by Fulcio and logged in Rekor. | A long-lived secret in Actions; its theft lets anyone sign updates until rotated. |
| Who can forge an update | Whoever can make release.yml run on main (repo write plus a workflow change), and it is publicly logged in Rekor. | Whoever holds the secret, with no public record. |
| Compiled into the tray | The expected identity (the SAN and issuer above, EXACT, not the docs' loose `.*/tillandsias/` regexp) and Sigstore's trusted root (Fulcio and Rekor public keys). | The public key, and rotation via a `next_public_key` chain. |
| Offline verification | Yes. A bundle carries the certificate, the signature and Rekor's inclusion proof and signed timestamp, so it verifies against the compiled-in trusted root with no Rekor lookup. | Yes, trivially. |
| What can go stale | The trusted root rotates (rarely). The tray refreshes it through Sigstore's TUF repository when it checks for an update (it is online then); a refresh that fails falls back to the compiled-in root and is reported, never skipped. | Nothing, until the key must rotate. |
| Client cost | A Rust Sigstore verifier (the `sigstore` crate's bundle verification); larger dependency tree, to be measured against the tray's size. | A few hundred lines and one small crate. |
| Same check as the gate | Yes: the tray and the release gate check one identity. | No: two trust paths to keep in step. |

So the tray: (1) verifies `update-manifest.json.cosign.bundle` with the
compiled-in identity and trusted root (TUF-refreshed); (2) reads each artifact's
SHA256 from the verified manifest; (3) downloads and hashes each artifact, and may
also verify that artifact's own bundle the same way (defence in depth, same code).
Refusals: `refused:update:signature` (bundle fails, identity mismatch, or the
certificate's workflow ref is not `refs/heads/main`), `refused:update:digest`, and
`refused:update:not-newer`. Nothing is replaced until every check passes; the
downgrade guard stays.

Fallback if the dependency cost is unacceptable: shell out to a bundled `cosign`
binary (also signed, verified by digest from the manifest of the release that
shipped it). An Ed25519 key is the last resort, not the plan.

Per platform, on top:

- **macOS** also requires the new `.app` to satisfy the running bundle's
  code-signing designated requirement (same Team ID), checked with
  `SecStaticCodeCheckValidity`; no user prompt. If the build is not notarized,
  the tray clears `com.apple.quarantine` itself (as the installer does now), only
  after the Sigstore and code-signing checks pass.
- **Windows** adds an Authenticode check once the binaries are Authenticode-signed
  (today they are not; then the Sigstore check is the only authenticity check, and
  the tray's details pane says so).
- **The installers** should verify the same bundles (out of scope here; filed
  separately so a first install is checked as strictly as an update).

## 3. What a release declares

`update-manifest.json` (signed):

```json
{
  "version": "56.11.7.1",
  "channel": "stable",
  "artifacts": {"macos-arm64": {"url": "...", "sha256": "..."}, "...": {}},
  "facilities": ["forge.update_status", "memory-protection"],
  "components": [
    {"name": "forge-image", "restart": "recommended",
     "reason": "openssl security fix", "recreate": "from-scratch"},
    {"name": "guest-os", "restart": "required", "reason": "kernel 7.2.13 oops fix",
     "upgrade": ["dnf -y upgrade --refresh"], "reboot": true},
    {"name": "vault", "restart": "none"}
  ],
  "min_tray": "56.11.0.0"
}
```

- `restart`: `none` (applies at the next natural start), `optional` (the forge may
  restart to get it), `recommended` (the tray and agent are told why), `required`
  (the component must restart before it is used again; see §5).
- `recreate`: `from-scratch`, or `snapshot:<name>`. A named snapshot is an IMAGE
  built from a Containerfile and keyed by its source digest (the 2004-qzem
  identity), never a `podman commit` of a running forge: a running forge holds
  `/run/secrets` and agent logins, and `litmus:forge-image-no-secrets` forbids
  committing one.
- `upgrade`: package steps run inside the reused component by the converge pass
  (`stable-upgrade-converge`), throw-away-and-rebuild on failure.

## 4. Apply, per platform

### Linux (bare metal)

Forges already outlive the tray and are adopted (1988-trkp):

1. The new binary is written beside the old (`tillandsias.new`), then renamed over
   it (atomic on one filesystem). The previous binary is kept as
   `tillandsias.previous`.
2. The running tray starts the new one with `--upgrade-handoff` (1490-gttj D1); the
   new one adopts the lanes and the old one exits without stopping containers.
3. The new tray runs the converge pass and tells each forge (§5).

### macOS (VZ guest): the forges live inside the tray's process

Quitting the tray stops the VM, so the Linux path would kill every forge. Two
ways keep them:

- **(A) freeze across the swap, recommended for the first version.** Measured on
  an M5 Air (1918-vzsr, #920): pause and save to a state file in 2.5 s
  (386 MB), restore to a working `podman info` in 1.5 s. The old tray: stop the
  Vault (a saved image must not hold an unsealed Vault: `save_permitted`), save
  the VM state, exit. The new `.app` is swapped in (backup-safe order, as
  1281-pgit's installer does), then launched; it restores and resumes the VM,
  re-delivers the Vault unseal share (the existing CLI credential exchange),
  and deletes the state file. Forges see a pause of seconds; open network
  connections may need to reconnect, and the agent is told (§5).
- **(B) the VM in its own process** (a launchd agent that owns the
  VZVirtualMachine and outlives the tray). Cleaner, and the tray could then
  update like Linux, but it is a large change (1490-gttj open question). Later.

The **guest binary** is the part that differs most:

- The new `.app` bundles a new `tillandsias-headless`. Today the guest installs
  the staged copy only at boot, and a restored VM has not booted, so it would
  keep running the OLD headless.
- The secure control wire's PSK is bound to the version, so a new tray and an old
  guest headless refuse each other (`crypto-disagreement`, seen live on
  2026-11-05). The new tray therefore cannot ask the old guest over the wire.
- Design: the new tray stages the new headless into the shared staging directory
  (signature and digest already checked, provenance written), and a systemd path
  unit in the guest (`tillandsias-headless-update.path`, watching the staged
  file's provenance sidecar) restarts `tillandsias-headless` on the new binary.
  That is an event, not a poll. Headless exit leaves its containers running
  (the guest side of 1988-trkp), so the forges keep running across the restart.
  The tray waits for the guest service on the new version before declaring Ready.
- Guest images rebuild on the new version tag as today (only what changed, with
  2004-qzem's narrower digests). A forge keeps its old image until it restarts.
- A `guest-os` component with `reboot: true` waits for zero running forges (or
  for each one's push, §5), as stable-upgrade-converge §6 already says.

### Windows (WSL)

The distro outlives `tillandsias-tray.exe` if the tray does not call
`graceful_shutdown` for an update. The update quit skips it (forges keep running
in the distro), the new tray adopts the lanes inside the distro, and the guest
headless is replaced like macOS (staged, then a path-unit restart in the distro).

## 5. Forges are told, and live work is never lost

- **Told:** a lane MCP tool `forge.update_status` answers
  `{running: "56.11.6.1", installed: "56.11.7.1", stale: true, facilities: [...],
  restart: "recommended", reason: "..."}` (2003-stbf's report, plus the release's
  declaration). The tray also writes one line into each lane's fleet inbox when an
  update lands, so an agent that never calls the tool still sees it.
- **May restart:** `forge.reload` (fleet-durable-instructions §3): the agent writes
  its resume slot, the host recreates the forge on the current image, the new
  forge reads the slot. Rate-limited to one per 10 min.
- **Required:** the tray asks the forge to push (a fleet message and the status
  tool both say `push-required-before-restart`). It restarts the forge only when
  its workspace is clean and has no commits ahead of its upstream, checked inside
  the container (`git status --porcelain` empty and `git rev-list @{u}..` empty).
  A forge with unpushed work is never killed: it keeps running on the old version
  and the tray shows it as waiting. There is no deadline that discards work.
  **OPEN Q2:** whether a `required` security fix may stop *accepting new prompts*
  in such a forge after some time, short of killing it.

## 6. Rollback

- The new tray must reach Ready, and its guest service answer on the new version,
  within 120 s of launch. If it does not, the launcher (the old binary on Linux;
  a small `update-helper` on macOS and Windows, since a bundle cannot replace
  itself while running) puts `previous` back and starts it.
- Only binaries roll back. Data (the Vault store, the model cache, projects) and
  images never do; images keep their version tags, so the previous tray finds its
  own. A rolled-back version is recorded and not offered again until a newer one
  ships (`refused:update:rolled-back:<version>`).
- This narrows stable-upgrade-converge §7 (fix-forward only) to **components**: a
  failed converge step is still fixed forward, but a tray that cannot start is
  rolled back, because no fix-forward is possible from a dead tray.

## 7. Opt out, delay, and what the tray shows

Setting `update.mode`: `auto` (default on stable), `notify` (download and verify,
apply only when the user clicks), `off` (never checks). A delay: "postpone until
tomorrow" or "until I quit the tray", from the menu.

Proposed tray text, **for operator review** (user-facing text is the operator's):

- menu row: `Update ready: 56.11.7.1 (2 forges will restart)` / `Updating…` /
  `Up to date (56.11.6.1)` / `Update paused: 1 forge has unpushed work`;
- the status chip gains a small badge while an update is ready;
- details pane: the signature check's result, the release's reasons, and each
  forge's state (current, stale, waiting for a push).

## 8. What is measured to close (row 2014-auup criterion 3)

On one Linux host, from one published stable release to the next, with a forge
running: the forge keeps working across the tray update, `forge.update_status`
reports it stale with both versions, and the tray shows it. macOS (path A) and
Windows are stated by this design and measured on their own hosts afterwards.

## 9. Open questions for the operator

1. A daily background check for an unattended tray (a new cadence), or only start
   and menu-open?
2. A `required` fix and a forge that never pushes: wait forever (default here),
   or stop accepting new prompts after a time?
3. macOS: path A (freeze across the swap) now and B (VM in its own process) later,
   or go straight to B?
4. Trust: verify the existing Sigstore keyless signatures (recommended: no key to
   keep, one identity shared with the release gate, publicly logged), accepting a
   Sigstore verifier's dependency size in the tray; or a dedicated Ed25519 key?
5. Default `update.mode` for an existing install: `auto` or `notify`?
