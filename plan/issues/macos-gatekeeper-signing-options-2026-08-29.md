# macOS Gatekeeper: why releases are blocked, and what is actually available

<!-- @trace spec:macos-tray-build-and-release, spec:macos-native-tray -->
<!-- # freshness: auditor=macos-tlatoanis-macbook-air-claude-20260829t155859z date=2026-08-29 verdict=created scope=operator-directed research after Apple Developer Program enrollment stalled several weeks with no response; web research + repo verification -->

Order 935-6fzk (Apple lane). Research record with the decision, the costs, and
the structural question answered.

## The finding that changes the problem

`com.apple.quarantine` is applied by the **downloading application**, not by
the OS, the network, or the file's origin. An app opts in via
`LSFileQuarantineEnabled` / the LaunchServices quarantine API. Safari, Chrome,
Firefox and Mail do. `curl`, `wget`, `git`, `scp` and `tar(1)` do **not**.

So an ad-hoc-signed, **non-quarantined** app launches with **no Gatekeeper
dialog at all** on macOS 14 through 26. Our `curl | bash` installer already
produces exactly that. The wall users hit comes from the **browser** route —
`Tillandsias.dmg`, or a `.tar.gz` opened with Archive Utility, which propagates
the attribute to extracted contents where `tar(1)` does not.

That reframes the packet: we were not blocked on Apple. We were leading users
to the one channel that breaks.

## The entitlement question, answered

**`com.apple.security.virtualization` is NOT a restricted entitlement.** It
works under ad-hoc signing, which is what this repo does today and what
`vfkit`, `lima` and `Code-Hex/vz` all ship. No provisioning profile is
required. One DevForums thread (698220) reads otherwise but its evidence is
confounded; our own working build is the counter-evidence.

**`com.apple.vm.networking` IS genuinely restricted** — provisioning profile,
paid membership, Apple approval. It is required for
`VZBridgedNetworkDeviceAttachment`. **We use `VZNATNetworkDeviceAttachment`**
(vz.rs), so it does not apply to us. If bridged networking is ever wanted, that
is a hard paid-membership blocker and should be re-costed then.

## What requires paid membership, and what does not

| Step | Needs paid membership? |
|---|---|
| Developer ID Application certificate | **Yes** — no free-tier equivalent. A free Apple ID issues only *Apple Development* certs: device-local, not accepted by Gatekeeper, cannot be notarized. |
| Hardened runtime (`--options runtime`) | No — already set |
| `--timestamp` | No, but an ad-hoc signature cannot carry one |
| `notarytool submit` | **Yes** |
| `stapler staple` | **Yes** (needs a ticket) |
| Running VZ via `com.apple.security.virtualization` | **No** |

## Options without a credential, ranked by user friction

1. **`curl | bash` (current default).** Zero friction. No quarantine, no
   dialog. **Chosen primary path.**
2. **Strip the attribute when it is present.** `xattr -dr com.apple.quarantine`
   — never `-cr`, which strips every xattr from every bundle member. Does not
   touch the signature; quarantine is a filesystem attribute. Implemented in
   `install-macos.sh`.
3. **Build from source.** No quarantine, high toolchain friction.
4. **"Open Anyway" recovery.** Documented for the stuck, not relied upon.

### Dead ends, with dates — do not spend effort here

- **`spctl --master-disable`**: removed in macOS 15. `--global-disable` at most
  reveals the "Anywhere" option and is unreliable on 26. The supported
  fleet-wide mechanism is now an MDM profile with `EnableAssessment: false`.
- **Homebrew cask**: `--no-quarantine` is deprecated and Homebrew ends support
  for casks failing Gatekeeper on **2026-09-01** (Homebrew/brew#20755). Not an
  escape hatch.
- **Right-click → Open**: no longer bypasses on macOS 15 Sequoia / 26 Tahoe.
  The first dialog offers only Done / Move to Trash; recovery is System
  Settings → Privacy & Security → Open Anyway, reportedly within a short window
  after the refusal. *(Third-party reports; not Apple-documented — flagged.)*
- **A locally-trusted self-signed root**: no Gatekeeper benefit whatsoever.
  Gatekeeper wants a chain to Apple's Developer ID CA plus a notarization
  ticket. It *does* buy a stable designated requirement, which keeps keychain
  ACLs and TCC grants across rebuilds — a real benefit, but for a different
  problem.

## App Store: the structural question

**Closed, and not for a fixable reason.** App Store distribution requires the
App Sandbox. Virtualization.framework needs `com.apple.security.virtualization`
plus disk-image and device access that the sandbox does not grant to a
general-purpose VM manager, and the app also manages files outside its
container (`~/Library/Application Support/tillandsias/`, the guest rootfs) and
opens vsock devices. No shipping App Store app runs arbitrary Linux guests this
way; the VM-managing tools that exist (UTM's direct build, Parallels, VMware,
vfkit, lima) all ship **outside** the App Store or with a materially reduced
App Store variant. **Direct distribution + Developer ID + notarization is the
only viable channel for this app.** Recorded so nobody re-costs the App Store
lane later.

## Enrollment: what is known

Individual enrollment is normally same-day to two days; organization involves a
verification call and takes 1–2+ weeks. **Weeks of silence on an individual
application is anomalous.** Multiple 2026 DevForums threads report 2–7 week
waits (818021, 821717, 822540); no Apple system-status or news post
acknowledges a backlog.

**Diagnostic worth running first: was the card actually charged?** If not, the
enrollment never left review, which is a different problem from being stuck
inside it.

Channels: developer.apple.com/contact → Membership and Account → Program
Enrollment → phone callback (regionally gated, intermittently absent — retry).
Apple Developer Forums under *Apple Developer Program*, where Apple support
staff do respond. Reply on the **existing** email thread; new tickets restart
the queue. Have the Enrollment ID ready. *(Escalation practice is
community-reported, not documented Apple policy — flagged.)*

## Decision

Primary path: **direct distribution, Developer ID + notarytool + staple**, once
enrollment completes. The seam is pre-wired and inert until then
(`TILLANDSIAS_MACOS_SIGN_IDENTITY`, `TILLANDSIAS_NOTARY_KEY{,_ID}`,
`TILLANDSIAS_NOTARY_ISSUER`), so the switch is configuration, not a code
change, and `scripts/test-macos-signing-seam.sh` pins both modes.

Until then the `curl` channel is not a workaround — it is a channel that
genuinely does not trigger the wall.

## Operator asks (credentials; not implementable here)

- Check whether the enrollment payment was charged.
- Request the enrollment phone callback; keep the existing email thread alive.
- On completion: create the Developer ID Application certificate, an App Store
  Connect API key (`.p8` + key id + issuer), and set the five env vars in the
  release workflow's secrets.

## Sources

Apple: [notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[enrollment support](https://developer.apple.com/support/enrollment/),
[contact](https://developer.apple.com/contact/).
Community: [Eclectic Light, running non-notarised code (2026-08-11)](https://eclecticlight.co/2026/08/11/how-can-you-run-code-that-hasnt-been-notarised/),
[Michael Tsai on Sequoia spctl/csrutil](https://mjtsai.com/blog/2024/09/23/sequoias-spctl-and-csrutil/),
[Homebrew/brew#20755](https://github.com/Homebrew/brew/issues/20755).
Ecosystem precedent for ad-hoc VZ signing: [vfkit vf.entitlements](https://github.com/crc-org/vfkit/blob/main/vf.entitlements), [Code-Hex/vz](https://github.com/Code-Hex/vz).
