# Black-box audit checklist (read-only)

For an auditor with the operator's account on a live install, at least one
forge running, and at least one GitHub, one model-provider and one Cloudflare
binding active. Every check is observation only: no writes, no pushes, no
deploys, no container starts, no stops.

Invariant IDs refer to `credential-design.md` §2.

## Rules of the audit

1. **Assert the population first.** Every scan reports how many objects it
   examined. "0 hits over 0 containers" is `NOT RUN`, never `PASS`.
2. **Three verdicts:** `PASS`, `FAIL`, `NOT RUN (reason)`. A check that could
   not execute is not a pass.
3. **Never print a match.** Secret scans print file/object, pattern name and a
   count — not the matching bytes — so the audit report is not itself a leak.
   (`grep -c` / `grep -l`, never bare `grep`.)
4. **Do not copy secrets out** to "verify they work". Liveness of a found
   token is the operator's job after the audit.
5. Names below (`<forge>`, `<relay>`, paths) are placeholders: the blind
   design does not know the real ones. Step 0 discovers them.
6. Run on each platform. macOS/Windows checks marked (VM) run inside the
   podman machine via `podman machine ssh`.

Token patterns used throughout (`$PAT`), from public provider formats [K1]:
`gh[pousr]_[A-Za-z0-9]{36,}`, `github_pat_[A-Za-z0-9_]{60,}`,
`sk-ant-[A-Za-z0-9_-]{20,}`, `sk-(proj-)?[A-Za-z0-9_-]{32,}`,
`hf_[A-Za-z0-9]{30,}`, `-----BEGIN [A-Z ]*PRIVATE KEY-----`,
`"(access|refresh)_token"\s*:\s*"[^"]{20,}"`, `Authorization: Bearer [A-Za-z0-9._-]{20,}`.
Cloudflare tokens have no reliable prefix in older formats [Q11]; additionally
search for the key names `CLOUDFLARE_API_TOKEN`, `CF_API_TOKEN`, `api_token`.
Pattern scans have false negatives — supplement with the structural checks.

## 0. Inventory (prerequisite; all later counts refer to this)

| # | Command | Record |
|---|---------|--------|
| 0.1 | `podman ps --format '{{.ID}} {{.Names}} {{.Image}} {{.Networks}}'` | N containers; classify each as forge / relay / gateway / inference / other |
| 0.2 | `podman images --digests` | N images |
| 0.3 | `podman volume ls`, `podman network ls`, `podman secret ls` | counts |
| 0.4 | `podman machine list` / `wsl -l -v` | substrate |
| 0.5 | Tray: list of projects, bindings, standing approvals, I2 exceptions | counts |
| 0.6 | Locate product state/config/cache dirs (from `podman inspect` mounts, tray "about", OS conventions) | paths |

Any container classified "other" is itself a finding to explain.

## 1. I1 — no plaintext credential at rest

| # | Check | Pass when |
|---|-------|-----------|
| 1.1 | `grep -rIlE "$PAT"` over the product's state/config/cache dirs (count files scanned) | 0 files match, N > 0 scanned |
| 1.2 | Same over each named volume's mountpoint (`podman volume inspect -f '{{.Mountpoint}}'`) | 0 |
| 1.3 | Same over the operator home's usual token locations **as existence checks only**: `~/.config/gh/hosts.yml`, `~/.git-credentials`, `~/.netrc`, `~/.claude/.credentials.json`, `~/.codex/auth.json`, `~/.local/share/opencode/auth.json`, `~/.wrangler/`, `~/.config/.wrangler/`, `~/.cache/huggingface/token` | None was created by the product (compare mtime/owner with install date; a pre-existing personal file is out of scope but noted) |
| 1.4 | `podman secret ls`; if any exist, `podman secret inspect` for driver | No secret uses the `file` driver (it stores data unencrypted) [K2] |
| 1.5 | Identify the vault file; `file`/`xxd | head` on it; run `$PAT` and `strings | wc -l` | High-entropy, no patterns, no readable JSON/YAML keys |
| 1.6 | Vault file mode and owner; parent dir mode | 0600 / 0700, operator-owned (Windows: ACL lists only the user and SYSTEM) |
| 1.7 | Keystore holds the wrapping key: macOS `security find-generic-password -s <service>` (metadata only, no `-w`); Linux `secret-tool search --all <attr> <val>` shows an item in the login collection; Windows `cmdkey /list` or documented DPAPI blob | Item exists; access is bound to this device/user |
| 1.8 | For every image: `podman history --no-trunc <img>` and `podman inspect -f '{{json .Config.Env}} {{json .Config.Labels}}' <img>`, piped to pattern **count** | 0 over N images |
| 1.9 | Layer scan: `podman save <img> | <secret scanner> ` (e.g. trufflehog/gitleaks in read-only, no-verify mode) | 0 over N images |
| 1.10 | (VM) repeat 1.1 inside the podman machine root filesystem | 0 |
| 1.11 | Swap/hibernation posture: `swapon --show` + FDE status (`lsblk -f`, `fdesetup status`, `manage-bde -status`) | Recorded; unencrypted swap without FDE is a finding |

## 2. I2 / I5 — nothing credential-shaped inside a forge

Run for **every** forge in the inventory; report "k of N forges checked".

| # | Check | Pass when |
|---|-------|-----------|
| 2.1 | `podman inspect -f '{{json .Config.Env}}' <forge>` → pattern count, and list of variable **names** matching `TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL|AUTH` | 0 pattern hits; every such-named variable holds a documented public placeholder or a URL |
| 2.2 | `podman exec <forge> sh -c 'cat /proc/*/environ 2>/dev/null | tr "\0" "\n" | grep -cE "<PAT>"'` | 0 (and count of processes read > 0) |
| 2.3 | `podman exec <forge>` existence test for agent credential files: `~/.claude/.credentials.json`, `~/.codex/auth.json`, `~/.local/share/opencode/auth.json`, `~/.config/gh/hosts.yml`, `~/.config/github-copilot/`, `~/.git-credentials`, `~/.netrc`, `~/.ssh/id_*`, `~/.wrangler`, `~/.npmrc` with `_authToken` | None exists, or forge is listed in the tray as an I2 exception (then: FAIL-with-waiver, and check 2.9) |
| 2.4 | `podman exec <forge> git config --show-origin --get-regexp 'credential|url\..*insteadof|http\..*extraheader'` and `git -C <project> remote -v` | No credential helper, no extraheader; remote is the local relay, contains no `user:token@` |
| 2.5 | `podman exec <forge> grep -rIlE "<PAT>" $HOME /tmp /run 2>/dev/null | wc -l` | 0 |
| 2.6 | Shell history in the forge and on the host (`~/.bash_history`, `~/.zsh_history`, fish, PowerShell `ConsoleHost_history.txt`) → pattern count | 0 |
| 2.7 | Agent transcripts/session logs inside the forge and wherever they persist on the host → pattern count | 0 over N files |
| 2.8 | `podman inspect -f '{{json .Mounts}}' <forge>` | No mount of broker socket, engine socket, vault dir, audit dir, host `$HOME`, `~/.ssh`, keyring/D-Bus socket, `$XDG_RUNTIME_DIR` |
| 2.9 | Tray list of I2 exceptions vs. forges found holding credential files in 2.3 | Sets are equal; each exception has an approval event in the audit log |
| 2.10 | If a placeholder key is present in the forge, note its value and compare across two forges/installs | Identical constant (proves it is not a secret) — or it is a per-forge handle; then confirm from the design docs that it is network-position-bound (I5 cannot be fully proven read-only → mark `PARTIAL`) |

## 3. I3 — egress only through the gateway

| # | Check | Pass when |
|---|-------|-----------|
| 3.1 | `podman network inspect <net>` for each forge network | `internal: true` (or equivalent: no gateway/masquerade) |
| 3.2 | `podman inspect -f '{{.HostConfig.NetworkMode}}' <forge>` | Never `host`, never `slirp4netns`/`pasta` with outbound, never `container:` of a relay |
| 3.3 | `podman exec <forge> ip route` ; `cat /etc/resolv.conf` | Default route absent or pointing at the gateway; resolver is the gateway |
| 3.4 | `podman exec <forge> env | grep -iE '^(https?|no|all)_proxy=|_BASE_URL='` | Provider base URLs / proxies point to project-local names, no credentials embedded in URLs |
| 3.5 | Gateway configuration or its tray view | An explicit allowlist exists per project; default is deny. (Probing a blocked host would be an active test — out of scope; request the operator's permission for a single DNS-only probe if needed.) |
| 3.6 | Gateway/relay logs (sample) → pattern count; look for `Authorization`, `x-api-key`, `Cookie` header names | No header values, no bodies; 0 pattern hits over N lines |

## 4. I4 / I12 — isolation and identity

| # | Check | Pass when |
|---|-------|-----------|
| 4.1 | `podman info -f '{{.Host.Security.Rootless}}'` | `true` |
| 4.2 | Per forge: `podman inspect -f '{{.HostConfig.Privileged}} {{.HostConfig.CapAdd}} {{.HostConfig.SecurityOpt}} {{.HostConfig.PidMode}} {{.HostConfig.IpcMode}} {{.HostConfig.UsernsMode}}'` | Not privileged; no added caps; `no-new-privileges`; no host PID/IPC; seccomp not `unconfined`; SELinux label not disabled where SELinux is enforcing |
| 4.3 | Per forge: devices and sockets — `podman inspect -f '{{json .HostConfig.Devices}}'`; `podman exec <forge> sh -c 'find / -xdev -type s 2>/dev/null'` | No `podman.sock`/`docker.sock`; every socket found is a documented relay endpoint |
| 4.4 | Two projects A and B: compare networks, volumes, relay container IDs | Disjoint networks and volumes; relays not shared, or sharing is documented with per-forge socket identity |
| 4.5 | `podman exec <forgeA> getent hosts <relay-of-B>` | Does not resolve |
| 4.6 | Relay containers: `podman inspect` mounts, env, `ReadonlyRootfs`, image digest | Broker socket mounted only into relays; read-only root; env pattern count 0; digest matches release manifest |
| 4.7 | (Windows) in the product's WSL distro: `cat /etc/wsl.conf`; `ls /mnt`; `ls /proc/sys/fs/binfmt_misc` | `[interop] enabled=false`, `appendWindowsPath=false`, `[automount] enabled=false`; no Windows drives; no WSLInterop handler [K3] |
| 4.8 | (macOS) `podman machine inspect` → Mounts | Only project directories; not `/Users`, not `$HOME` |
| 4.9 | (VM) `podman machine ssh -- sudo find / -xdev -name '*.pem' -o -name '*token*' -o -name '*credential*'` → names only | Nothing product-related persisted in the VM |

## 5. I13 — not reachable by other users or the LAN

| # | Check | Pass when |
|---|-------|-----------|
| 5.1 | Listening sockets: `ss -Hltnp` / `lsof -nP -iTCP -sTCP:LISTEN` / `Get-NetTCPConnection -State Listen`, filtered to product processes and `podman ps --format '{{.Ports}}'` | No listener on `0.0.0.0`, `::`, or a LAN address |
| 5.2 | Each loopback listener found in 5.1 | Documented, and documented as authenticating every request. An unauthenticated loopback relay/broker port is a FAIL (other local users can connect) |
| 5.3 | Broker socket path: `stat` socket and parent | 0600 socket in a 0700 user-owned dir; not in world-traversable `/tmp`; not an abstract socket (`ss -Hlx | grep '@'`) |
| 5.4 | (Windows) named pipe ACLs (`accesschk \\.\pipe\<name>` or PowerShell) | User + SYSTEM only |
| 5.5 | `ps -eo args` / `Get-CimInstance Win32_Process` for product processes → pattern count | 0 (no secrets in argv, which other users can read) |
| 5.6 | Modes of state, config, cache, log, audit dirs | No group/other access |
| 5.7 | From a second unprivileged account, if the operator provides one: `ls` the state dir, `stat` the socket | Permission denied. (Connect attempts are active tests → not run.) |

## 6. I6 / I14 — lifetimes and revocation (observational)

| # | Check | Pass when |
|---|-------|-----------|
| 6.1 | Audit log: `token.minted` events — distribution of `ttl` per service | GitHub ≤ 1 h (or ≤ 8 h user-to-server); Cloudflare child tokens minutes; no `ttl: null` except documented API-key providers |
| 6.2 | Provider-side, by the operator in their browser (auditor observes): GitHub → Settings → Applications (authorized/installed GitHub Apps), repository access list; fine-grained PAT list | Access is via a GitHub App limited to selected repositories; no classic PAT or SSH key created by the product |
| 6.3 | Cloudflare dashboard → API Tokens (operator shows) | Parent token is scoped (not Global API Key), has an expiry; no pile-up of unexpired child tokens |
| 6.4 | Provider consoles for model keys | Dedicated key/workspace with a spend limit, where the provider offers one |
| 6.5 | Audit log: for a forge that was stopped before the audit, events after `forge.stopped` with its ID | None allowed |
| 6.6 | Audit log: every `grant.revoked` has a matching upstream success or an open `revocation_failed` visible in the tray | No silent failures |

## 7. I7 — approvals

| # | Check | Pass when |
|---|-------|-----------|
| 7.1 | Audit log: every event whose verb is cost/destructive-class (prod deploy, resource create/delete, DNS, force-push, binding widened, licence accepted, I2 exception) | Has an `approval_ref` to an `approval.granted` with a verifier method that is an OS user verification, dated ≤ 60 s before, with matching action digest |
| 7.2 | Count of approval-class events with `method` = click/none/"auto" | 0 |
| 7.3 | Standing approvals listed in the tray | Each names one verb and one target and has an expiry; none is "all" |
| 7.4 | Host capability: is a verifier enrolled (`bioutil -c`/Touch ID settings, Windows Hello enrolment, `fprintd-list $USER` or a registered FIDO2 key)? | If none: approval-class verbs must show as unavailable in the tray, not as click-through |
| 7.5 | Approval rate: approvals per active day from the audit log | Recorded. A high rate is a usability finding that predicts blind approval |
| 7.6 | Ask the operator to show (not trigger) the most recent prompt's recorded rendering, if retained | Fixed template; agent-supplied text clearly delimited |

## 8. I8 — vault failure behaviour (documentary; destructive test not run)

| # | Check | Pass when |
|---|-------|-----------|
| 8.1 | Search the install for recovery artefacts: files named `*backup*`, `*recovery*`, `*.bak`, `*export*`, key-share files, a second copy of the vault | None |
| 8.2 | CLI/tray help text and strings in the binary for `export`, `recover`, `--insecure`, `plaintext`, `--no-encrypt`, env overrides that disable the keystore | None; or each is inert in release builds |
| 8.3 | Audit log history: any `vault.wiped` is followed by fresh `login.completed`, never by `vault.opened` of older content | Holds |
| 8.4 | Behaviour without a keystore (read the docs / tray state on a host with no keyring) | Session-only memory mode or refusal — never a plaintext file |

## 9. I9 — audit log

| # | Check | Pass when |
|---|-------|-----------|
| 9.1 | Log exists, non-empty, mode 0600, not mounted in any container (cross-check 2.8/4.6) | Holds |
| 9.2 | Recompute the hash chain over all records | Unbroken; head matches the anchored value if the product exposes it |
| 9.3 | Pattern count over the whole log | 0 |
| 9.4 | Coverage: for each running forge and relay in the inventory, a `forge.created` / `token.minted` exists | Every live object is accounted for (a live relay with no mint event means a credential arrived some other way) |
| 9.5 | Cross-correlate: the provider's own audit/security log (GitHub security log, Cloudflare audit log), shown by the operator, vs. local events for the same hour | No upstream action without a local event |

## 10. I10 — artefact provenance

| # | Check | Pass when |
|---|-------|-----------|
| 10.1 | Every running container's image is referenced by digest: `podman inspect -f '{{.ImageDigest}} {{.Config.Image}}'` | Digest is in the release manifest (forges may be local builds — then a local build record exists) |
| 10.2 | The policy file of the product's podman store (`policy.json`) | Default `reject`; product registries require `sigstoreSigned` with pinned identity; no `insecureAcceptAnything` for remote transports [K4] |
| 10.3 | Independent verification: `cosign verify --certificate-identity-regexp … --certificate-oidc-issuer … <image@digest>` and `cosign verify-attestation --type slsaprovenance1 …` (network read only) | Verifies; provenance names the expected repo/workflow [K5] |
| 10.4 | `registries.conf` | No `insecure = true`; no unqualified-search surprises |
| 10.5 | Model store: recompute `sha256` of every weight file; compare with manifest/records | All match; N > 0 |
| 10.6 | Model formats: list extensions / magic bytes | Only safetensors/GGUF; no `.pkl`, `.pt`, `.bin` pickle, `.ckpt` |
| 10.7 | Inference container: mounts read-only, env pattern count 0, network has no egress | Holds |
| 10.8 | Docs/cheatsheet bundle: digest vs manifest; mounted read-only in forges; each doc has provenance fields (source URL, retrieved date, source hash) | Holds for N of N docs |
| 10.9 | Tray binary: `codesign -dv --verbose=4` / `Get-AuthenticodeSignature` / package signature; update metadata has expiry and version monotonicity | Signed; metadata not expired |

## 11. I11 — licence records

| # | Check | Pass when |
|---|-------|-----------|
| 11.1 | For each project, list restricted-class artefacts mounted into its forges (from mounts + manifest classes) | Count recorded |
| 11.2 | For each, a record exists for **that project**, naming the artefact digest actually mounted and a licence text hash | N of N |
| 11.3 | Recompute the licence text hash from the stored text | Matches |
| 11.4 | Verify the record signature against the committed public key; verification method is an OS user verification | Valid |
| 11.5 | A restricted artefact mounted in project B whose only record is in project A | Must not occur |
| 11.6 | Records are append-only in git history (`git log --follow` — no rewritten or deleted records) | Holds |

## 12. Report shape

For every row: `ID | verdict | population examined | evidence location`.
Summarise per invariant; an invariant passes only if all its rows are `PASS`
and none is `NOT RUN`. State explicitly which invariants this read-only method
**cannot** establish:

- I2 against process *memory* of the forge (only files/env/proc are sampled);
- I5 (handle uselessness elsewhere) — needs an active replay test;
- I3 enforcement (as opposed to configuration) — needs an active egress probe;
- I8 wipe behaviour — needs a destructive test on a disposable install;
- I14 timing — needs a stop/revoke during observation.

These five are the agenda for a follow-up *active* audit on a throwaway
install.

## References

- [K1] GitHub, supported secret scanning patterns — https://docs.github.com/en/code-security/secret-scanning/introduction/supported-secret-scanning-patterns
- [K2] `podman secret create` — https://docs.podman.io/en/latest/markdown/podman-secret-create.1.html
- [K3] WSL advanced settings — https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- [K4] `containers-policy.json(5)` — https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md
- [K5] cosign verify — https://docs.sigstore.dev/cosign/verifying/verify/
