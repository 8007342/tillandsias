## Cycle 2026-09-02T23:14Z — tlatoanis-macbook-air (osx-next)

935-6fzk COMPLETED. All three exit criteria met.

DECIDED: Developer ID + notarization for the GitHub-release channel. $99/yr,
no waiver (Apple's requires a nonprofit/educational/government legal ENTITY and
excludes individuals), and no free-for-OSS tier at all — the sharpest asymmetry
with the Windows lane, where SignPath Foundation signs for $0.

THE STORE IS CLOSED, and not for the obvious reason. Virtualization is fine —
UTM ships sandboxed on the Mac App Store today, so any research concluding "a VM
app cannot be sandboxed" is wrong. What closes it is App Review Guideline
2.4.5(iv): no downloading code or resources that add functionality. The tray
fetches the guest rootfs that IS the product. UTM passes the same guideline
because its images are user-supplied. Recommendation: do not pursue it.

CI: notarytool has no OIDC federation — API key (.p8, downloadable once) or
app-specific password, both long-lived repo secrets. Inherent to Apple's
tooling. Recorded so nobody hunts for the Windows posture on macOS.

I WASTED PART OF THIS CYCLE, and it is the reusable part. The packet's CONTEXT
block lists the signing seam as work to do; it already existed at HEAD (739-6r6n
lineage), including the get-task-allow strip, which is subtler than anything I
wrote. I re-implemented it before reading the tree and deleted the duplicate.
Read the tree, not the packet's prose, for what exists.

THE ONE REAL GAP WAS THE DMG. The .app was signed and stapled while the
container holding it shipped unsigned — and the container is what the user
downloads; Gatekeeper assesses the image first. Closed, gated identically to the
tray script. The DMG hash moved AFTER signing, since codesign and stapler
rewrite in place and hashing first published a SHA256SUMS line describing a file
nobody ships. Fixture 8 -> 11 arms.

AN ENTITLEMENT I DID NOT ADD: automation.apple-events LOOKS required for the
Terminal.app attach under the hardened runtime, but my test could not settle it
(osascript is a separate process; TCC attributes consent to the responsible
process, already granted on this host). Adding a key on a hunch is what the
entitlements policy forbids. Filed as operator ask 5 instead.

ALSO FIXED: check-long-running-view.sh passed its status map through `awk -v`.
A -v assignment is a string literal — gawk tolerates embedded newlines, BSD awk
rejects them — so the join produced nothing and the gate read stale=28 of 28
here while linux-next read 28 live. Third macOS dialect defect in two days;
scope note added to 964-zgga.

Gate green (166s). Next: 793-qc6q, the unified-memory accelerator measurement
routed here by lenovinha.
