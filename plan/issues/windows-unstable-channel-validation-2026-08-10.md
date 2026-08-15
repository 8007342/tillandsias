# Windows UNSTABLE channel + portable downloads — validation report (624-su5r)

- Date: 2026-08-10
- Host: windows (windows-next), meta-orchestration cycle 7
- Packet: `624-su5r` p0 `windows-unstable-channel-validation`
- Releases under test: `v0.4.260810.1` (published 01:55Z as **pre-release**),
  `unstable` (rolling), and `latest` (still `v0.4.260809.2`)
- Verdict: **steps 1, 3, 4, 5 PASS; step 2's substantive question answered.**
  Only the GUI-visual observation remains, tracked as `646-qde5`.

> **Header corrected 2026-08-10.** This originally read "steps 1 and 4 PASS,
> steps 2 and 3 NOT RUN", which was accurate when written and went stale as the
> work landed: `644-a3wj` answered step 2 (the bare alias IS usable standalone)
> and step 3 (alias/versioned zips share a digest), and step 5 ran in cycle 9.
> The "What is NOT covered" section below is preserved as written rather than
> rewritten — it records what was true at the time, and the addendum at the end
> narrows the remaining ask. A report whose summary drifts from its own contents
> is the same measuring-the-wrong-thing problem this session has been chasing,
> so it is fixed rather than left.

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

---

## Addendum 2026-08-10 — structural evidence for the "no flashing consoles" half (646-qde5)

The GUI half of this validation still needs a human, but one of its two questions
has a checkable structural answer, and narrowing the ask is worth more than
restating that it is open.

**The tray process cannot flash a console at startup.** Reading the PE header of
the published `tillandsias-tray.exe` (the unversioned alias, from the `unstable`
channel):

```
pe_sig=PE  optional_magic=0x20B (PE32+)
subsystem=2  ->  IMAGE_SUBSYSTEM_WINDOWS_GUI
```

Subsystem 2 means Windows does not allocate a console for the process. A
console-subsystem binary (3, `WINDOWS_CUI`) is what produces the classic flash;
this is not one.

**Child processes are spawned hidden, except where a terminal is the point.**

- `crates/tillandsias-vm-layer/src/lib.rs` applies `CREATE_NO_WINDOW`
  (`0x0800_0000`) to background commands on Windows.
- `wsl_lifecycle.rs:119` builds background `wsl.exe` commands with it applied.
- `transport_windows.rs:131` records the regression that motivated it: *"without
  CREATE_NO_WINDOW each retry flashed a console (2026-07-12)"* — so this exact
  failure mode was already found and fixed once.
- The two `CREATE_NEW_CONSOLE` sites (`notify_icon.rs:3644`, `:3729`) are the
  interactive PTY launches — Attach and GitHub Login — where a visible terminal
  is the intended behaviour, not a flash.

**What this does and does not settle.** It settles that no *incidental* console
window is expected from the tray or its background children, and it is evidence
a reader can re-derive rather than a claim to trust. It does not settle that the
tray **icon appears**, which has no structural proxy — a GUI process can start
cleanly and still fail to register a notification-area icon.

So the remaining human check is now one question, not two: **does the tray icon
appear in the notification area when the bare exe is run?** If it does, and no
console flashes, `646-qde5` closes.
