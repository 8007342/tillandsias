# 1641-xbvq evidence: the browser container reaches the compositor through the Wayland socket file only (lenovinha, 2026-10-12)

Host: Fedora 44 Silverblue, GNOME on Wayland (`WAYLAND_DISPLAY=wayland-0`, with
XWayland's `DISPLAY=:0` also set), SELinux enforcing, rootless podman.

## The defect (p0)

`build_project_browser_spec` / `BrowserDisplayContext::from_env` and the dev
launcher `scripts/launch-chromium.sh` had two exposures:
- **Wayland:** they mounted the host's WHOLE `$XDG_RUNTIME_DIR` read-write.
- **X11:** they mounted all of `/tmp/.X11-unix`, and X11 won whenever `DISPLAY` was set, which is every XWayland session.

`probe-prefix/` is a live probe of the pre-fix code's Wayland branch (DISPLAY
unset so that branch runs). From inside the browser container, these were
VISIBLE:
- `/run/user/1000/bus` (the D-Bus session bus);
- `/run/user/1000/keyring`;
- `/run/user/1000/tillandsias`, with every lane's `mcp.sock`;
- the toolbox pkcs11 socket;
- libpod's rootlessport sockets.

35 host sockets in all. `podman.sock` was absent only because `podman.socket`
is not enabled on this host; on a host where it is, the browser gets host code
execution.

## The fix (operator decision 2026-10-12: Wayland only)

- `BrowserDisplayContext` carries no X11 fields. `wayland_socket()` resolves `WAYLAND_DISPLAY` (a socket name under `XDG_RUNTIME_DIR`, or an absolute path) to an existing socket file.
  - It refuses with a message naming why, and saying "Log in to a Wayland session". This covers a missing `WAYLAND_DISPLAY`, a missing `XDG_RUNTIME_DIR`, a missing socket, or a name that is not a socket name (e.g. `../podman/podman.sock`).
- The spec mounts ONLY that file: `-v <socket>:/run/user/browser/<name>:rw`, inside a private `--tmpfs /run/user/browser:size=1m,mode=0755`. It sets `XDG_RUNTIME_DIR=/run/user/browser`, `WAYLAND_DISPLAY=<name>` and `--ozone-platform=wayland`.
  - The mount is `-v …:rw`, not `--mount … relabel=shared`: a relabel would rewrite the live compositor socket's SELinux label on the host.
- `scripts/launch-chromium.sh` gets the same rule and the same refusals. `litmus:browser-ephemeral` now expects the Wayland flags and refuses any `--volume=/run/user/<uid>:` or `/tmp/.X11-unix` mount (passed 4/4 with the runner's fake podman).

## Criterion 1: unit test, red on the old code

`browser_spec_mounts_only_the_wayland_socket_file` sets DISPLAY AND
WAYLAND_DISPLAY, then asserts on the real argv:
- `--ozone-platform=wayland`, and no x11;
- exactly one mount of the socket file;
- no mount whose source is `$XDG_RUNTIME_DIR` or `/tmp/.X11-unix`;
- no `DISPLAY=`.

`browser_spec_refuses_without_a_wayland_session` covers the four refusals.
`unit-tests-red-on-prefix-code.txt`: both new tests run against the pre-fix
`main.rs` and FAIL ("Wayland must be the platform", and "no usable Wayland
socket must refuse" got a spec). `unit-tests-green.txt`: 3 passed.

## Criterion 2: live probe (`probe.sh`, scratch podman store; `probe-shipped/`)

The browser ran with the product's REAL argv, written by the `#[ignore]` helper
`browser_spec_live_probe_args`. The image `localhost/tillandsias-chromium-framework:v56.9.27.2`
was copied read-only from the operator store into a scratch store (graph under
`target/work`, runroot in a private `$XDG_RUNTIME_DIR` dir). The scratch store
was removed afterwards. `WAYLAND_DEBUG=client` was added for the probe only.

- **Inside the container:**
  - `/run/user/browser` holds only `wayland-0`.
  - podman.sock, bus, keyring, `tillandsias/`, `/run/dbus/system_bus_socket` and `/tmp/.X11-unix` are all ABSENT.
  - The only socket anywhere is chromium's own SingletonSocket. No `DBUS_SESSION_BUS_ADDRESS`, no `DISPLAY`.
  - An empty `/run/user/1000` directory exists only as the mountpoint path of the per-launch profile dir, which the product mounts at its own host path under `$XDG_RUNTIME_DIR/tillandsias/browser`. Its children are absent.
- **The window appears.** The compositor sent `xdg_toplevel.configure` (bounds 1920×1044). The client acked it, attached `wl_buffer`s and set the title "tillandsias-1641-probe": 4 configures and 6 attaches (`probe-shipped/browser.log`).

## SELinux spike: `label=disable` stays, scoped as before

| variant | result |
|---|---|
| `probe-labeled/`: shipped argv minus `--security-opt=label=disable` | exits 21 before Wayland: chromium cannot read its profile dir (`user_tmp_t`, not relabelled) |
| `probe-labeled-z/`: also give only the throwaway profile a private `:Z` label | exits 1: **"Failed to connect to Wayland display: Permission denied (13)"**, then "Failed to initialize Wayland platform" |

A confined `container_t` browser is denied connecting to the host compositor's
socket. Making that work would require one of two things:
- relabelling the live compositor socket on the host, which would change the operator's desktop session; or
- a custom SELinux policy module allowing `container_t` to connect to it, which needs root to install.

Neither is a change Tillandsias should make. The browser therefore keeps
`label=disable`. With the runtime-dir and X11 exposure removed, the container
now holds one socket and no host secret paths.

Note: `ContainerSpec` sets `label=disable` for EVERY container, not just the
browser. Narrowing that for the other containers is outside this row.
