# macOS: two homebrew-only binaries are exec'd by bare PATH lookup, so they resolve from a shell and not from a GUI launch

- classification: research
- filed: 2026-09-03 (macos/tlatoanis-macbook-air)
- found while: answering macneo-macos's fleet-join questions; item 2 of their report
- status: one site diagnosed by macneo-macos, a SECOND site found here and
  previously unreported

## The class

`crates/tillandsias-vm-layer/src/vz.rs` makes four bare-PATH `Command::new`
calls. A `.app` started by LaunchServices inherits a minimal PATH
(`/usr/bin:/bin:/usr/sbin:/sbin`) with no `/opt/homebrew/bin`, while the same
binary invoked from a zsh session inherits the user's full PATH. So a bare
lookup resolves or not depending on HOW the app was launched — which presents
to a user as "the GUI is broken but the CLI works".

Checked on macOS 26.6.2 (25G83), Apple silicon:

| site | binary | resolves in a minimal PATH? |
|---|---|---|
| vz.rs `generate_cidata_iso` | `hdiutil` | YES — `/usr/bin/hdiutil` |
| vz.rs `convert_qcow2_to_raw` (two call sites) | `qemu-img` | **NO** — `/opt/homebrew/bin/qemu-img` |
| vz.rs `fetch_then_decompress_xz_then_verify` | `xz` | **NO** — `/opt/homebrew/bin/xz`; **there is no `/usr/bin/xz` on macOS** |

## What is new here

macneo-macos diagnosed the `qemu-img` site from a fresh 8 GiB Mac: first GUI
launch reported "missing qemu", `brew install qemu` did not fix it, and
`tillandsias-tray --provision` from a shell then succeeded. That is the PATH
divergence, correctly identified.

**`xz` at vz.rs `fetch_then_decompress_xz_then_verify` has the identical defect and nobody has reported it**, because
it sits downstream of the `qemu-img` failure on the provisioning path — the
first error masks the second. Its phase label is "Decompressing rootfs", so the
symptom would be a fresh GUI launch failing at rootfs decompression on any Mac
without `brew install xz`, which is most of them: unlike `hdiutil`, xz ships
with neither the base system nor the Command Line Tools.

**Fixing only the reported site leaves the next launch to fail one step later.**

## The fix, and it is DIFFERENT for the two sites

An earlier draft of this file proposed "absolute path, or drop the dependency"
for both. macneo-macos corrected it, and the correction is the useful part:

**`xz` (vz.rs `fetch_then_decompress_xz_then_verify`) should be DELETED, not relocated.** `xz2` is already a
dependency of this very crate (`Cargo.toml`, via the `download` and `materialize` features), and the same crate already decompresses xz
in pure Rust in two other places — `fetch.rs` `decompress_xz` and `materialize/oci.rs`,
both `xz2::read::XzDecoder`. Verified in the tree. So vz.rs `fetch_then_decompress_xz_then_verify` is not a host
dependency to resolve; it is the lone inconsistency among three sites, ten files
from a working example. Removing it deletes the failure mode rather than moving
it, which matters because **there is no `/usr/bin/xz` on macOS at all** — an
absolute path would have had nothing to point at.

**`qemu-img` (vz.rs `convert_qcow2_to_raw` (two call sites)) CANNOT take an absolute path.** Homebrew's
prefix is `/opt/homebrew` on Apple silicon and `/usr/local` on Intel, so no
single hardcoded path is correct for both. It has to be removed or resolved at
runtime against a candidate list — never hardcoded. Recording this explicitly
because "use an absolute path like sysctl does" is the obvious inference from
vz.rs `host_memory_bytes` and it is wrong here.

**`hdiutil` needs nothing.** `/usr/bin/hdiutil` resolves in the minimal PATH;
measured on both hosts.

## Two maskings of one class, which is why it survived

macneo-macos's `xz` came from brew **as a dependency of qemu**, so the
operator's `brew install qemu` masked the xz defect there — exactly as
pre-installed qemu masked the qemu-img defect on this host. Two hosts, two
different accidental installs, the same class hidden both times. Neither host
could have found it by launching the app.

## A related dead path worth knowing before touching qemu-img

macneo-macos found that the qemu-free fetch already exists and is unused:
vz.rs `fetch_recipe_artifact` fetches a recipe-published raw
`.img.xz`, decompresses and SHA-verifies with no qemu at all, and its own doc
comment claims "The macOS tray calls this on first launch." It does not — the
only live caller is `action_host.rs` `run_start` → `fetch_fedora_cloud_image` (qcow2,
hence qemu-img). A guard test at `main.rs` `provisioning_surfaces_use_live_qcow2_path` pins the qcow2 path and cites
**order 606-r42f**, so the move onto qcow2 was a decision rather than drift and
that rationale must be read before either path is changed.

## Note on scope

This is recorded rather than fixed here because macneo-macos is running the
investigation this belongs to and holds the failing host — the one machine that
can verify a fix end to end. Filed so the SECOND site is not lost when the first
one is closed.

## Order 606-r42f, looked up so the next reader does not have to

The guard test is real and its citation is accurate, but **the rationale does
NOT bless qcow2 over the recipe-artifact path on the merits**, and that
distinction decides whether the qemu-free path may be revived.

606-r42f is `macos-dead-vz-lifecycle-removal` (archived, done 2026-08-11,
commit e4792602). Its title: "Remove or reconnect dead macOS VzLifecycle code
that reaches two unimplemented provisioning panics." Its exit criteria are about
PANICS, not about image formats:

> no production-reachable macOS provisioning path contains
> unimplemented!/todo!/panic placeholders

and its next_action reads "choose deletion or delegation to action_host's live
method". `VzLifecycle` and `vz_real` were deleted because they reached
`unimplemented!`; the pin exists so a later change cannot route provisioning
back into code that panics.

**So the guard forbids reaching unimplemented code — not reaching
`fetch_recipe_artifact`.** Moving the live path onto the qemu-free fetch is not
blocked by 606-r42f, provided the replacement is real (it is: it fetches,
decompresses and SHA-verifies) and the guard test is updated in the same commit
to pin whatever the new live path is. What 606-r42f actually establishes is that
`action_host`'s path was, at that date, the only PROVEN one — which is an
argument for testing the alternative before switching, not for never switching.
