# wt.exe semicolon bug in GitHub Login terminal launch

**Order 136** — filed 2026-06-30

## Root cause

`wt.exe` (Windows Terminal) uses `;` as its own command separator in its
command-line argument parser. When we invoke:

```
wt.exe new-tab --title "..." wsl.exe -d tillandsias -- /bin/bash -lc "<script>"
```

and `<script>` contains `; ` statement separators, wt.exe splits on each `;`
and tries to run the fragments AFTER the last `;` as a new Windows Terminal
subcommand. The last fragment was `exec tillandsias-headless --github-login`,
which Windows tried to launch as an executable → `ERROR_FILE_NOT_FOUND`
(0x80070002), displayed in the terminal as:

```
erreur 2147942402 (0x80070002) lors du lancement de `" exec tillandsias-headless --github-login"'
```

## Fix

Replace `;` with `&&` as the bash statement separator in the `GithubLogin`
`PtyIntent`'s `-lc` script in `tillandsias-host-shell::pty::launch_spec`.

`&&` is NOT a wt.exe command separator. The semantics are equivalent for our
use case because `export` and `install -d` always succeed, so `A && B` runs
the same as `A; B` in practice.

**Changed file**: `crates/tillandsias-host-shell/src/pty/mod.rs`

The test `launch_spec_maps_intents_to_in_vm_argv` now also asserts
`!github_cmd.contains(';')` as a regression guard.

## Why this matters for future scripts

Any `-lc` bash script passed through `wt_terminal_argv` in
`notify_icon.rs::spawn_wsl_terminal` MUST NOT contain bare `;` unless wt.exe
is known to handle them. The invariant to enforce: **use `&&` not `;` in all
bash scripts that flow through `wt.exe`**.

Once Phase 4 of the vsock plan (PTY-over-vsock via `PtyTarget::Container`)
is complete, the entire `spawn_wsl_terminal` function is replaced and this
constraint disappears.
