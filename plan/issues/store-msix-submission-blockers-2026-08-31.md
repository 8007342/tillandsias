# The Store channel needs no certificate — but this MSIX cannot be submitted yet

776-g6r3 exit criterion 2, researched on yolanda 2026-08-31 against the
**actually shipped** `tillandsias-tray-0.4.260830.5-windows-x64.msix`.

## The finding that changes the decision

**Microsoft re-signs MSIX packages submitted to the Store, at $0.** From
Microsoft's own submission requirements:

> Your MSIX and AppX packages don't have to be signed with a certificate rooted
> in a trusted certificate authority when submitting to the Microsoft Store.
> The Microsoft Store will automatically re-sign your MSIX/AppX packages with a
> Microsoft certificate during the publishing process after your app passes
> certification.

- no CA-trusted code signing certificate to purchase
- no `.pfx`/`.cer` to supply
- no USB token or HSM
- the Store **replaces** any existing signature

It goes further: signing with your own certificate can *cause* validation
failures through mismatched publisher identity, so an unsigned package is the
**preferred** submission shape, not merely a tolerated one.

**Consequence for the pending signing decision.** The unsigned MSIX
(`0x800B0100`, packet 722-w7a2) blocks the **GitHub-release** channel only. It
does not block the Store channel at all. The two channels have genuinely
different requirements and should stop being reasoned about as one decision:

| channel | signing requirement |
|---|---|
| Microsoft Store, MSIX | none — Microsoft signs, $0 |
| GitHub release, MSIX sideload | must self-sign; unsigned is **uninstallable** |
| Store, EXE/MSI installer | Store does **not** re-sign; must Authenticode-sign yourself |

That last row also explains the redirect problem hit earlier: an EXE/MSI Store
submission requires a package URL on your own infrastructure, which is why
Partner Center wanted a stable non-redirecting URL. The MSIX path has no such
requirement — Microsoft hosts and CDN-serves it.

## What still blocks submission, verified against the shipped artifact

Three defects, none of them signing. The shipped manifest reads:

    Name="Tlatoani.Tillandsias"
    Publisher="CN=TillandsiasTestPublisher, OID.2.25.311729...=1"
    Version="0.4.2608.3005"

**1. The version's first field is `0`, and the Store forbids that.** The rule
is that every section is 0-65535 "except the first section, which cannot be 0".
This is structural, not a build-flag slip: `build-windows-tray.ps1:332` takes
`$vParts[0]` straight from `VERSION`, which is `0.4.260830.5`. **Every MSIX this
repo can currently produce is Store-invalid for this reason alone**, and no
existing switch changes it.

**2. The version's fourth field is `3005`, and the Store requires `0`.** The
fourth section "is reserved for Store use and must be left as 0". The build
already has `-MsixStoreRevisionZero` for exactly this, added when the packaging
landed — but `release.yml` never passes it (zero occurrences). The capability
exists and is simply unwired.

**3. Identity `Name` and `Publisher` are placeholders.** They must match the
values Partner Center assigns under *View app identity details* for the
reserved listing, and Microsoft warns the values are case-, space- and
punctuation-sensitive. `TillandsiasTestPublisher` is the unsigned-namespace test
publisher; it will not match.

## What each blocker needs

- **(1) and (2) are code**, but (1) is not a one-liner: a Store-valid version
  needs a leading field >= 1, so it needs a decided mapping from the repo's
  `0.4.YYMMDD.N` scheme onto a Store-legal quad. That is a versioning decision
  with release-wide consequences and it is **not** made here.
- **(3) is operator-only.** The Partner Center identity values exist solely in
  the operator's dashboard.

## Deliberately not done

No change to the release version encoding was made. `-MsixStoreRevisionZero`
carries a documented collision hazard — with the revision pinned to 0, two
builds on the same day produce the same version — and wiring it while a release
decision is pending would alter the pipeline underneath it. It is also useless
on its own, since blocker (1) fails the package regardless.

## Not established

No submission was attempted, so nothing here is confirmed by Partner Center
actually accepting or rejecting a package. Every claim above is from Microsoft's
published requirements checked against the shipped artifact's manifest. The
cheapest way to convert this from documentation-derived to observed is one
rejected submission, which needs the operator's dashboard.
