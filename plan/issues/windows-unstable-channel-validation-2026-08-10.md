# Windows UNSTABLE channel + portable downloads — validation report (624-su5r)

- Date: 2026-08-10
- Host: windows (windows-next), meta-orchestration cycle 7
- Packet: `624-su5r` p0 `windows-unstable-channel-validation`
- Releases under test: `v0.4.260810.1` (published 01:55Z as **pre-release**),
  `unstable` (rolling), and `latest` (still `v0.4.260809.2`)
- Verdict: **steps 1 and 4 PASS. Steps 2 and 3 NOT RUN** — see "What is not
  covered", which is the important half of this report.

## Step 4 — checksum integrity (the 623-iwq4 regression check): PASS

`623-iwq4` was a corrupt `SHA256SUMS-windows` that shipped Cosign-signed in
`v0.4.260809.1` — lines merged for want of a trailing newline. It was found by
verification rather than by reading code, which is why this packet exists.

Checked byte-level framing with `cat -A` on all three channels. Every file is
293 bytes, 3 lines, each line properly `\n`-terminated, no merged lines:

```
latest  (v0.4.260809.2)   3/3 OK
v0.4.260810.1             3/3 OK
unstable (= v0.4.260810.1) 3/3 OK
```

Each artifact was downloaded and verified with `sha256sum -c`, exit 0 in all
three cases:

```
tillandsias-tray-0.4.260810.1-windows-x64.zip: OK
tillandsias-windows-x64.zip:                   OK
tillandsias-tray.exe:                          OK
```

The alias `tillandsias-windows-x64.zip` and the versioned zip share a digest
(`c0b02ae4…`), confirming the alias is a true copy and not a re-zip. `unstable`
and `v0.4.260810.1` publish identical digests, so the rolling channel is
consistent with its underlying tag.

## Step 1 — UNSTABLE channel resolution: PASS (statically verified)

Fetched `install-windows.ps1` from the `unstable` channel and read it rather
than piping to `iex`. Executing an installer to find out what URL it resolves is
a worse test than reading the resolution, and it mutates the host.

The published script is **byte-identical** to `scripts/install-windows.ps1` in
the repo (`diff` after CRLF normalization), so the release pipeline is not
transforming it.

```powershell
$Channel = if ($env:TILLANDSIAS_CHANNEL) { $env:TILLANDSIAS_CHANNEL } else { 'stable' }
  'stable'   -> https://github.com/$Repo/releases/latest/download
  'unstable' -> https://github.com/$Repo/releases/download/unstable
  default    -> throw "Unknown TILLANDSIAS_CHANNEL '$Channel' (want stable or unstable)"
```

- Default (variable cleared) resolves `/releases/latest/download` — the channel
  default the packet requires.
- `unstable` resolves `/releases/download/unstable`.
- An unknown channel **throws** rather than silently falling back to stable.
  That is the right failure direction and worth keeping.
- The banner is emitted at lines 338–341; the first `Invoke-WebRequest` is at
  line 354. **Banner precedes download**, as required.

## Step 5 — `install-windows.ps1` is pure ASCII: PASS

The `v0.3.260723.1` regression class: a single non-ASCII byte makes the saved
`.ps1` parse as a *different program*.

```powershell
$b=[IO.File]::ReadAllBytes("scripts\install-windows.ps1"); ($b | ? {$_ -gt 127}).Count
```

```
repo copy              bytes=24426  non_ascii=0
published (unstable)   bytes=24426  non_ascii=0
```

Zero on both, and both are 24426 bytes — consistent with the byte-identity check
in step 1. The regression has not recurred.

Deliberately **not** flagged: `install.sh` (12 non-ASCII bytes) and
`install-macos.sh` (2028). The ASCII constraint exists because of PowerShell's
encoding sensitivity when a `.ps1` is saved and re-parsed; POSIX shell scripts
are UTF-8 and their non-ASCII bytes are ordinary output characters. Propagating
the Windows rule to them would manufacture two false positives.

## What is NOT covered, and why

**Steps 2 and 3 were not run.** They require downloading the portable
`tillandsias-tray.exe` and the zip, executing them, and confirming "tray appears,
no flashing consoles, WSL2 provisioning starts". Those are observations about a
GUI shell session — whether a tray icon appears, whether console windows flash —
that this loop cannot make from a non-interactive shell. Reporting them as
passing on the basis that a process exited 0 would be the exact
measuring-the-wrong-thing failure this session has been finding all evening.

So the packet's headline claim — *"this alias has NEVER been executed"* — is
**still true after this report**. That has not changed, and the p0 should not be
closed on the strength of steps 1 and 4.

What steps 1 and 4 do establish is that the artifacts are intact, correctly
digested, consistently aliased, and served by a resolver that picks the right
URL — i.e. if the exe fails when someone runs it, the cause is in the binary or
its packaging, not in the download path.

The remaining work needs a human at the Windows desktop, or an agent with a GUI
automation channel. It is a few minutes of clicking, not a large task.

## Secondary observations

- **`cosign` is absent on this host**, so the Cosign bundles could not be
  verified. `SHA256SUMS-windows.cosign.bundle` is present and well-formed
  (10566 bytes, `application/vnd.dev.sigstore.bundle.v0.3+json`). Since
  `623-iwq4` shipped a *validly signed corrupt file*, signature verification and
  content verification are independent checks — this report covers content only.
- **`TILLANDSIAS_VERSION` silently overrides `TILLANDSIAS_CHANNEL`.** With both
  set, the script prints `Pinned to v$Version` and never mentions that the
  channel was ignored. Correct precedence, quiet about it. Minor, and not filed
  as a packet — noted here in case it bites someone.
- **`latest` does not serve `v0.4.260810.1`.** It is published as a
  *pre-release*, so `/releases/latest/download` still resolves to
  `v0.4.260809.2`. That appears intended (the unstable channel is how the new
  build is reachable), but it means the landing page's primary Windows downloads
  are one release behind until promotion.
