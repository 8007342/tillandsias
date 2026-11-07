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

Today's SHA256 check proves the bytes match the checksum file from the same
release, not who published it. Added:

- The release workflow signs `update-manifest.json` with an Ed25519 key held as a
  GitHub Actions secret, producing `update-manifest.json.sig` (minisign format).
- The **public key is compiled into every tray build**. A tray verifies the
  manifest's signature with the key it already carries, so a compromised release
  page cannot swap the key. Key rotation ships the next key in the previous
  release (`next_public_key` in the manifest), signed by the current one.
- The manifest lists every artifact's SHA256. The tray downloads, hashes, and
  refuses on any mismatch: `refused:update:signature` / `refused:update:digest`.
  Nothing is replaced until every check passes.
- A manifest whose version is not newer than the running one is refused
  (`refused:update:not-newer`); the existing downgrade guard stays.
- **macOS adds** the platform's own check: the new `.app` must satisfy the running
  bundle's code-signing designated requirement (same Team ID), checked with
  `SecStaticCodeCheckValidity`. No user prompt is involved. If the build is not
  notarized, the tray clears `com.apple.quarantine` itself (as the installer does
  now), only after the Ed25519 and code-signing checks pass.
- **Windows adds** an Authenticode check when the binaries are signed (today they
  are not; then the Ed25519 check is the only authenticity check, and the design
  says so in the tray's details pane).

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
  "next_public_key": null
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
4. Signing key custody: the Actions secret alone, or also an offline second key
   for rotation?
5. Default `update.mode` for an existing install: `auto` or `notify`?
