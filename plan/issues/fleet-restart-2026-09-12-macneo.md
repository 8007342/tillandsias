# Fleet restart drill — macneo (tlatoanis-macbook-neo, macos, osx-next)

Per-host drill file. The coordinator folds these; the main drill file has a
single writer.

## 2026-09-13 — the gh keychain dialog was a WEDGE, and the standing operator ask is wrong

**CORRECTION TO THE MAIN DRILL'S OPERATOR ASK.** The main drill tells the
operator, for this host, to run a command and "when macOS asks whether to allow
access to the github.com credential choose ALWAYS ALLOW." The operator did
exactly that, repeatedly, and it did not work. The instruction is incomplete in
a way that sends the next host down the same dead end, so it is corrected here
rather than repeated.

**What actually happens.** The dialog carries a PASSWORD FIELD, and Always Allow
authenticates nothing unless the LOGIN KEYCHAIN PASSWORD is typed into it first.
Operator report, verbatim in substance: they clicked Always Allow, Allow and
Deny, the dialog kept respawning, and "most of those clicks the password field
was empty." No grant was ever written. That is corroborated from the item
itself, not from the report alone — `gh:github.com` acct 8007342 carried
`cdat == mdat == 2026-09-06T04:22:01Z` before, during and after the whole
episode. An authenticated Always Allow would have had to change something.

**Root cause: a wedged SecurityAgent plus accumulating orphans — NOT a
deny-by-default ACL, and NOT a backlog of queued prompts.** Both of those were
proposed during diagnosis and both are wrong. Evidence:

- `SecurityAgent` was alive for 21h45m (since the previous day), ignored
  SIGTERM, and respawned instantly on SIGKILL.
- Requester caught in the act by polling: `/usr/bin/security
  find-generic-password -s gh:github.com -wa 8007342` with **PPID 1**. The `-w`
  forces the decrypt; PPID 1 means its parent was already gone.
- Mechanism: `check-credential-channel.sh` bounds `gh` with `_ccc_timeout`. The
  timeout kills `gh` and its `security` CHILD SURVIVES, still holding a dialog
  no later timeout can reap. Every gate run added another.
- After the operator restarted the host: no `SecurityAgent`, no orphans, and a
  bare `security find-generic-password -s gh:github.com -a 8007342 -w` returns
  **rc 0 silently**. Two full `./build.sh --check` runs since, both reaching the
  real keychain (`ok  without timeout, check-credential-channel.sh reports
  blocked:gh-cli-only`), neither prompting.

**Remedy, corrected:** restart the host, or type the login keychain password
before clicking Always Allow. Do NOT edit the ACL, do NOT run `gh auth login`
(1025-a896), and do NOT kill SecurityAgent — it respawns and the orphans remain.

**Same family as 1145-iigx.** The reaper there no-ops on darwin because
`tillandsias_marked_pids()` reads `/proc/<pid>/environ`, which macOS does not
expose; here `_ccc_timeout` kills a parent and leaves its child. Both are
"termination does not propagate across a process tree on darwin", and the
fleet's wrappers were authored where it does.

## 2026-09-13 — what the gate actually touches, and what it does not

The keychain read is a FIXTURE, not the credential guard doing operational work:
`./build.sh --check` -> `test-host-tools.sh` -> the prover row
`timeout|binary|gate|macos|check-credential-channel.sh|blocked:gh-cli-only` ->
the real `check-credential-channel.sh`, TWICE (the 1004-x9ua control run at
test-host-tools.sh:149 is unconditional, then again with the tool hidden). So a
build depends on the operator's GitHub login state in order to prove that
COREUTILS is installed. 1004-x9ua's own comment already records that coupling
misfiring on this host — it "was reporting the OPERATOR'S gh login state as a
fact about coreutils, and its remedy told them to install a package they had."

The build.sh:2054 credential fixture is NOT the caller: it writes a stub `gh` to
a temp dir and puts it first on PATH. Hermetic. An earlier diagnosis blamed it
and was wrong.

**End-user runtime does NOT read the host GitHub credential** — checked because
the operator drew that line explicitly. The shipped tray touches the keychain
only in its own namespace (`installation_uuid.rs`, service `tillandsias`), and
`build-macos-tray.sh` invokes `gh` nowhere.

## 2026-09-13 — open question: two specs, one component boundary

`openspec/specs/native-secrets-store/spec.md` says the host Rust process is the
SOLE consumer of the keyring, MUST store and retrieve the GitHub OAuth token
there, and sanctions extracting it via `gh auth token` for `--github-login`.
`host-shell-architecture.security.no-host-credentials@v1` (MUST) says the host
shell process SHALL NOT load or cache GitHub tokens. These conflict only if
"host shell process" and "host Rust process" denote the same component, and
`tillandsias-host-shell` is its own crate, so they may not.

Live instance rather than a hypothetical: `crates/tillandsias-core/src/secrets.rs`
`read_github_token()` shells to `gh auth token`; its only caller
`check_and_refresh_github_token()` has ZERO callers repo-wide, but its doc
comment says "This should be called at application startup." Wiring it up would
put a host GitHub credential read into end-user startup. Whether that violates a
MUST or satisfies a different one depends on the boundary above, which wants a
ruling rather than an assertion. Flagged, not claimed.

## 2026-09-13 — check-host-tools.sh reports a false MISSING under an agent PATH

`check-host-tools.sh:243` resolves rustup with a bare `command -v`, so when
rustup is not on the CURRENT PATH it concludes no targets are installed. Same
host, same minute, only PATH differing:

    agent non-login PATH   ok:host-tools:macos:gate:5 present; tray-build:4 present, missing aarch64-unknown-linux-musl,x86_64-unknown-linux-musl
    PATH + ~/.cargo/bin    ok:host-tools:macos:gate:5 present; tray-build:6 present

Both targets are installed (`rustup target list --installed`). Reproduced on
macbookair by narrowing PATH to `/usr/bin:/bin:/usr/sbin:/sbin`, byte-identical
verdict. SCOPE, stated narrowly: the GATE reads 6 and is correct — this misleads
agents and hand invocations, not the build. The remedy it prints is
confidently wrong (`rustup target add <target>` on a host that has it, a no-op).
Same class as 1004-x9ua one level down: the binary probes were taught to search
prefixes beyond PATH, the tool that ENUMERATES targets was not.
