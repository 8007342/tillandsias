# macOS `--opencode <path>`: host paths are passed verbatim to the guest and fail with "Project not found"

- Date: 2026-07-13
- Class: enhancement (UX / path translation)
- Filed by: macos-osx-next meta-orchestration cycle 2026-07-13T22:43Z
- Discovered by: /build-install-and-smoke-test-e2e (macos), §4 forge lane
- Related: order 257 (InteractiveStream parity cell), crates/tillandsias-macos-tray/src/diagnose.rs `opencode_main`
- Pickup: macos

## Repro (live, 2026-07-13, tray git 66d8b134)

```
$ ~/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray \
    --opencode /Users/tlatoani/src/tillandsias --prompt "Use the /meta-orchestration skill"
[opencode] starting VM…
[opencode] waiting for VM phase Ready…
[opencode] control wire ready; launching forge in guest…
Error: Project not found: /Users/tlatoani/src/tillandsias
{"status":"opencode-finished","exit_code":1}
```

Evidence: target/build-install-smoke-e2e/20260713T224400Z/04-bigpickle-meta-orchestration.log (first run).

## Cause

`opencode_main` (diagnose.rs:941-947) interpolates the CLI path directly
into `exec /usr/local/bin/tillandsias-headless --opencode {path}` executed
in the guest. The guest only sees host `~/src` as virtiofs at
`/home/forge/src` (vz.rs:479-491), so any absolute host path fails the
guest-side `Path::exists()` check. Passing `/home/forge/src/tillandsias`
works — but no user will guess that, and the `--help` text ("--opencode
<path>") implies a host path.

## Fix shape

In `opencode_main` (and sibling lanes taking a project path on macOS):

1. If the path is under the shared host dir (`$HOME/src/<name>[/…]`),
   rewrite to `/home/forge/src/<name>[/…]`.
2. If it already looks guest-absolute (`/home/forge/src/…`), pass through.
3. Otherwise fail fast **on the host, before booting the VM**, with an
   actionable message naming both accepted forms. (The current failure
   boots the VM for ~a minute just to print one line.)
4. Pin with a unit test on the pure translation function.
