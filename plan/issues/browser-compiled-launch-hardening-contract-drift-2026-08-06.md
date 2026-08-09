# Compiled project-browser launch diverges from its hardened contract

Date: 2026-08-06 (America/Los_Angeles)
Status: ready
Plan: `browser-compiled-launch-hardening-contract-drift` (order 615-x3b8)
Release: v0.5

## Finding

The active browser specifications describe the Chromium framework as inheriting
a read-only root, no external network, and reduced capabilities. The tray
integration contract additionally names `CAP_DROP=ALL`, no-new-privileges, and
a read-only root for the safe browser window.

The compiled product path in
`crates/tillandsias-headless/src/main.rs::build_project_browser_spec` currently
constructs a different boundary:

- `.network("host")`;
- `.cap_add("SYS_CHROOT")`; and
- an intentionally writable root filesystem.

The code comment explains that an earlier read-only attempt made Chromium's
crashpad fail, but it does not reconcile the broader permissions with the
active specs. The direct image acceptance for order 612-nvf3 is intentionally
hardened and therefore cannot be described as the exact compiled product shape
until this drift is resolved.

`plan/issues/network-architecture-audit-2026-07-09.md` already inventories the
host-network/SYS_CHROOT behavior. No dedicated live work packet was found for
closing or ratifying the mismatch.

## Required design decision

The browser must reach the project-local OpenCode route and the graphical
display without receiving general host-network reachability. Before changing
flags, choose and specify the smallest viable route, such as attachment to the
internal project network with an explicit router address/alias, or another
allowlisted path that cannot become ambient host access. Do not silently claim
that `network=none` can reach the application.

Crashpad/profile writes must be redirected into the existing bounded tmpfs or
profile mount so read-only root can be restored. Establish whether Chromium
still requires any added capability after order 612's direct acceptance probe;
the default target is no added capabilities and an explicit all-capability
drop.

## Exit contract

- Reconcile `browser-isolation-framework` and
  `browser-isolation-tray-integration` with one implementable network and
  filesystem boundary; any weakening needs an explicit operator decision.
- The compiled `ContainerSpec` and its focused unit test pin the chosen network,
  read-only setting, capability set, no-new-privileges, user namespace, and
  bounded writable mounts.
- A real product-path launch reaches only its intended project route and emits
  expected DOM while the browser cannot reach an unrelated host listener or an
  external address.
- X11 and Wayland paths remain functional without broadening the browser's
  filesystem access.
- No menu, label, notification, dialog, or other user-visible UX is changed.

Order 612-nvf3 remains the owner of the entrypoint's `--no-sandbox` acceptance
probe. This packet owns the outer compiled launch boundary and must not absorb
that smaller fix.

## 2026-08-06 isolated runtime evidence

Order 608-ijbt reproduced the filesystem half of this boundary with the actual
freshly loaded chromium-framework image. Under network-none, read-only root,
CAP_DROP=ALL, no-new-privileges, keep-id and explicit internal `--no-sandbox`,
mounting `/home/chromium` as a root-owned mode-0700 tmpfs made the non-root
browser exit 133 with:

```text
chrome_crashpad_handler: --database is required
```

Keeping the same outer boundary but setting `HOME=/tmp`,
`XDG_CONFIG_HOME=/tmp/chromium-config`,
`XDG_CACHE_HOME=/tmp/chromium-cache`, and
`--user-data-dir=/tmp/chromium-profile` on the existing bounded `/tmp` tmpfs
returned zero and emitted the expected DOM. The workaround was then held
constant for both layer policies across two warmups plus 15 measured starts;
all 34 Chromium launches passed.

This proves a writable root is not required for the headless acceptance shape
and gives this packet a concrete bounded-state direction. It does **not** prove
the compiled GUI/X11/Wayland product path, choose its least-authority network,
or authorize a runtime change; those exit criteria remain open.
