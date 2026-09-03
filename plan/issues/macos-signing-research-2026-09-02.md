# macOS signing + notarization for the GitHub-release channel: Developer ID decided; the Mac App Store is closed to Tillandsias as architected

- classification: research
- filed: 2026-09-02 (macos/tlatoanis-macbook-air, unattended cycle)
- status: research complete — **primary path decided (Developer ID + notarization)**;
  the Store question is answered **structurally closed, with the citation**, and
  the two routes that would reopen it are named
- packet: 935-6fzk (macos-signing-notarization-and-app-store-path)
- shape deliberately imitates `plan/issues/windows-signing-research-2026-08-16.md`
  (the Windows twin): dated facts with provenance, costs named, a decided primary
  path with a recorded fallback, operator asks separated from agent work.

## The decision

**Developer ID Application signing + Apple notarization is the path for the
GitHub-release channel (DMG + tar.gz).** It is the Authenticode-equivalent first
rung and the only channel that clears the Gatekeeper wall for a direct download.

**The Mac App Store is CLOSED to Tillandsias as currently architected**, and the
blocker is not virtualization. See "The Store question" below — this is the
answer the packet asked for, and it is a structural one with a guideline
citation, not a cost or effort judgement.

## Costs (verified 2026-09-02)

| Item | Cost | Note |
|---|---|---|
| Apple Developer Program | **$99/yr** (individual or organization) | Required for BOTH Developer ID and notarization |
| Notarization service | **$0** | Unlimited submissions; the $99 membership is what gates access |
| Developer ID certificate | included | Valid ~5 years, unlike Windows Artifact Signing's 3-day certs |
| Apple Developer Enterprise Program | $299/yr | **Not applicable** — in-house distribution only, cannot be used for public release |

**No fee waiver applies here.** Apple waives the $99 for nonprofit
organizations, accredited educational institutions, and government entities in
eligible regions — the applicant must be a **legal entity**, explicitly **not an
individual, sole proprietor, or single-person business**, and must distribute
only free apps. An individual open-source developer does not qualify on the
entity test alone. This is the sharpest contrast with the Windows lane, where
SignPath Foundation signs qualifying OSS projects for **$0**: **there is no
free-for-OSS signing tier on macOS.** The $99 is unavoidable for any signed
macOS release.

## The Store question — answered, and the answer is a blocker

The packet asks whether a menu-bar app that manages VMs can be sandboxed at all,
noting that a named structural blocker is a complete answer. It can be. That is
not what stops us.

**Virtualization is NOT the blocker, and the existence proof is on the Store
today.** UTM Virtual Machines (id1538878817) ships on the Mac App Store,
sandboxed, running VMs. So `com.apple.security.virtualization` inside a sandbox
is demonstrably shippable, and any research that stopped at "a VM app cannot be
sandboxed" would have been wrong.

**What closes the Store for us is App Review Guideline 2.4.5(iv), for macOS
apps**, verbatim:

> They may not download or install standalone apps, kexts, additional code, or
> resources to add functionality or significantly change the app from what we
> see during the review process.

reinforced by 2.4.5(ii):

> They must be packaged and submitted using technologies provided in Xcode; no
> third-party installers allowed. They must also be self-contained, single app
> installation bundles and cannot install code or resources in shared locations.

and by the general 2.5.2:

> Apps should be self-contained in their bundles […] nor may they download,
> install, or execute code which introduces or changes features or functionality
> of the app, including other apps.

Tillandsias' tray does exactly the prohibited thing, by design and as its
central feature: on first `Start VM` it **fetches `tillandsias-rootfs-aarch64.img`
from a GitHub release** and boots a guest whose agent stack IS the product's
functionality. `install-macos.sh` additionally places a CLI in a shared location.

**Why UTM passes and we do not, stated precisely, because the distinction is the
whole finding:** UTM's VM images are **user-supplied content** — the user brings
an ISO. Ours are **our own code, shipped out of band, that adds the app's
functionality.** 2.4.5(iv) is about provenance and reviewability, not about
virtualization. The same framework, the same entitlement, opposite verdicts.

**The only two routes that reopen the Store**, both product changes rather than
packaging changes, neither recommended now:

1. Ship the rootfs **inside** the app bundle so review sees it. Costs a
   multi-hundred-MB bundle and makes every guest update an App Store
   resubmission — which defeats the release cadence the fleet runs on.
2. Make guest images **user-supplied**, UTM-style. That is a different product.

**Recommendation: do not pursue the Mac App Store.** Unlike the Windows twin,
where the Store MSIX channel is a $0 re-signing path worth taking (776-g6r3),
the macOS Store offers no signing saving — we would still pay $99 — and demands
an architecture change. The two lanes look symmetric and are not.

## Direct channel: what signing actually requires

- **Developer ID Application** certificate signs the `.app`; **Developer ID
  Installer** would be needed only for a `.pkg`, which we do not ship.
- **Hardened Runtime is mandatory for notarization.** The tray needs
  `com.apple.security.virtualization`; entitlements are drafted in
  `build/macos/entitlements.plist` (added by this packet) with each one
  justified inline, since an unjustified entitlement is a notarization and
  review risk and a security regression.
- **Sign inside-out, then notarize, then staple.** Nested code (helpers,
  frameworks, the `tillandsias` CLI if bundled) signs BEFORE the outer `.app`;
  the `.app` signs BEFORE the DMG is built. Signing a DMG whose payload is
  unsigned produces an artifact that passes `codesign -v` on the container and
  fails Gatekeeper on the contents — the macOS analogue of the
  sign-before-package ordering 722-qvqb pinned on Windows.
- **`xcrun stapler staple`** the ticket onto the DMG so a first launch works
  offline. Notarization without stapling still works online-only; the failure is
  invisible on a developer machine that has already talked to Apple.
- **`--timestamp` is required.** Same reasoning as the Windows lane: validation
  asks whether the certificate was valid at signing time.

## CI: the OIDC asymmetry (decision-relevant)

The Windows job signs with **federated OIDC** — no long-lived secret on the
runner. **Apple has no equivalent.** `notarytool` authenticates with either:

- an **App Store Connect API key** (Issuer ID + Key ID + a `.p8` private key
  that can be **downloaded exactly once**), or
- an Apple ID + **app-specific password** + Team ID.

Both are **long-lived secrets that must live in GitHub repository secrets**, and
the Developer ID certificate itself must be imported into a temporary keychain
on the runner. So the macOS release job **cannot** reproduce the Windows job's
credential-free posture. The API key is the CI-appropriate of the two (scoped,
revocable, not tied to a person's Apple ID). **This asymmetry is inherent to
Apple's tooling, not a gap in our wiring** — worth recording so a future cycle
does not go looking for the federation that does not exist.

## What this packet actually needed — and what it did NOT

**THE SEAM ALREADY EXISTED.** The packet's context block lists the signing seam
in build-macos-tray.sh / build-macos-dmg.sh — parameterized identity, loud
UNSIGNED warning, sign-before-package ordering, a fixture proving both modes —
as implementable-without-credentials work. That was written before the 739-6r6n
lineage landed it. At HEAD, `scripts/build-macos-tray.sh` ALREADY has:
parameterized `TILLANDSIAS_MACOS_SIGN_IDENTITY`, an entitlements file at
`crates/tillandsias-macos-tray/assets/Tillandsias.entitlements`, the hardened
runtime in both arms, `--timestamp` only where it is legal, notarize+staple
gated on credentials, and stapling BEFORE packaging — with
`scripts/test-macos-signing-seam.sh` (8 arms) proving it, including the
`get-task-allow` strip, which is a subtler hazard than the ordering one.

This cycle began re-implementing all of it from the context block before reading
the tree, then deleted the duplicate. **Recorded because the waste is the
reusable lesson: check the tree, not the packet's prose, for what already
exists.** It is the same failure 702-6jza's next_action now warns about.

**The one genuine gap was the DMG**, and this record closes it: the `.app` was
signed and stapled while `build-macos-dmg.sh` shipped the container holding it
unsigned and unstapled.

## An entitlement I did NOT add, and why

The tray drives Terminal.app through `osascript` (terminal_attach.rs). Under the
hardened runtime, sending Apple events is restricted, so
`com.apple.security.automation.apple-events` LOOKS required — and discovering
that at notarization time would break the attach path 702-6jza just verified.

**I could not demonstrate that it is required, so it is not in the file.** A
hardened-runtime, ad-hoc-signed test binary carrying no automation entitlement
sent an Apple event to Terminal.app and got a correct reply (measured
2026-09-02). That test **cannot settle the question**: `osascript` is a separate
Apple-signed process, TCC attributes automation consent to the RESPONSIBLE
process, and this host has already granted that consent to the parent chain — so
the pass is equally consistent with "not needed" and with "needed, but already
consented here".

Adding an entitlement on a hunch is exactly what the entitlements file's own
policy forbids: every key is a hole and must carry a demonstrated cause. **It is
recorded as a named risk instead** (operator ask 5). The first Developer-ID
signed and notarized build must be launched on a machine that has never granted
Tillandsias automation consent; if the attach opens no window, that key is the
fix and the cause will finally be demonstrated.

## Operator asks (one line each, independently markable)

1. Enrol in the Apple Developer Program at $99/yr, as an individual — no waiver applies.
2. After enrolment, create a **Developer ID Application** certificate and provide it as a base64 `.p12` plus its password.
3. Create an **App Store Connect API key** (Team Key, Developer role or higher) and provide Issuer ID, Key ID, and the one-time `.p8`.
4. Confirm the Mac App Store is **not** being pursued, per the 2.4.5(iv) finding above.
5. On the first notarized build, launch it on a Mac that has never granted Tillandsias automation consent and report whether Open Shell opens a Terminal window (settles the entitlement question above).

## Provenance

| Source | Retrieved | Fact it carries |
|---|---|---|
| developer.apple.com/programs/ | 2026-09-02 | $99/yr membership; $299 Enterprise |
| developer.apple.com/help/account/membership/fee-waivers/ | 2026-09-02 | Waiver limited to nonprofit / accredited educational / government legal entities in eligible regions; explicitly not individuals or sole proprietors |
| developer.apple.com/support/developer-id | 2026-09-02 | Developer ID requires Program membership; notarization required |
| developer.apple.com/app-store/review/guidelines/ | 2026-09-02 | 2.4.5(ii), 2.4.5(iv), 2.5.2 — the Store blocker |
| apps.apple.com/us/app/utm-virtual-machines/id1538878817 | 2026-09-02 | A sandboxed VM app ships on the Mac App Store — virtualization is not the blocker |
| keith.github.io/xcode-man-pages/notarytool.1.html | 2026-09-02 | notarytool auth: API key or app-specific password; no OIDC |
| Apple Developer Forums thread 742476 | 2026-09-02 | App-specific-password auth path confirmed alongside API keys |
