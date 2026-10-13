# 1644-u8b8: the device catalogue grows to the long tail

Host: lenovinha. Date: 2026-10-13.

The catalogue goes from **127 to 513 devices**. Not counting the generic
desktop, laptop and generic entries, it now covers **20 makers**
(`coverage.txt`).

| source | devices |
|---|---|
| Playwright (Apache-2.0) | 107 |
| Chrome DevTools (BSD-3-Clause) | 16 |
| manufacturer pages (overlay) | 390, of which 386 are new |

## Exit criteria

1. **At least 500 devices across at least 12 brands.** Met: 513 devices and
   20 makers.
   - The generator now checks coverage itself:
     `--min-devices 500 --min-brands 12` reports
     `ok:device-catalogue:fresh:513:brands=20`.
   - Litmus step 3 of `device-catalogue-shape` asserts it. Its negative
     control is an unreachable floor, which the generator refuses.
2. **Every entry carries a source kind, URL and licence, and every derived
   value is labelled.**
   - Litmus step 2 still passes for all 513.
   - Every manufacturer entry carries its derivation text in
     `source.derivation`. The generator computes the derivation for phones,
     foldables and tablets. Apple iPads and laptops state their own.
   - The test
     `devices::tests::the_catalogue_covers_the_long_tail_with_labelled_derivations`
     checks that every manufacturer entry has a non-empty derivation, and
     that its viewport equals physical pixels divided by dpr.
3. **"galaxy s24 ultra" and "galaxy s25 ultra" resolve exactly.**
   - Both resolve through the alias rule, with `approximated: false`, to
     `samsung-galaxy-s24-ultra` and `samsung-galaxy-s25-ultra`. Each has a
     3120 x 1440 panel, giving dpr 3.5 and 411 x 891 CSS px.
   - Test `galaxy_s24_and_s25_ultra_resolve_exactly`.
   - The 1643-q3at resolver tests stay green. Two of them encoded the old
     gap: "galaxy s24 ultra" resolved approximately, and "s24u" was
     approximated. They now assert the exact match. The "a near miss never
     changes brand" property is kept, using "galaxy s99".

## Method

1. **Generator.** `scripts/lua/build-device-catalogue.lua` changed in these
   ways:
   - An overlay entry states only what the maker publishes: physical pixels,
     panel size, and optionally launch month, launch OS and ppi.
   - For phones and foldables, the generator derives dpr from the Android
     density bucket of the short side (<=720 → 2, <=1080 → 2.625,
     <=1280 → 3, else 3.5). This is the 1643-q3at rule, now applied by code
     instead of hand arithmetic. Tablets use the standard scale nearest to
     short side / 800.
   - The derivation text is recorded per device.
   - An entry may instead carry its own `dpr` plus `derivation`, or
     `published: true` if the maker publishes points and scale.
   - The UA follows the OS: Android phone or tablet Chrome, iOS or iPadOS
     Safari, or Windows, macOS or ChromeOS Chrome.
   - The four 1643 entries were reduced to this compact form. The catalogue
     regenerated **byte-identical** at 127 devices before any new data was
     added.
2. **Research.** Eight parallel researchers, one per brand group, followed
   `research-brief.md`:
   - Only first-party pages fetched in the session are allowed. No
     GSMArena, PhoneArena, Wikipedia, WURFL or DeviceAtlas.
   - Figures are never recalled. A device is skipped if no first-party page
     could be fetched.
   - The note quotes the page's figures.
   - They used:
     - spec pages on samsung.com, mi.com, oneplus.com, oppo.com,
       realme.com, vivo.com and asus.com;
     - en-us.support.motorola.com;
     - nothing.tech;
     - Sony's own Singapore store (sony.com blocks fetching);
     - support.apple.com and support.google.com tech specs;
     - Lenovo PSREF spec PDFs;
     - learn.microsoft.com Surface specs.
3. **Validation.** `validate.py.txt` checks that:
   - the source URL is on that brand's own domain, and no banned site is
     mentioned;
   - the note contains both resolution numbers (French "2 400" grouping is
     accepted);
   - orientation is portrait, or landscape for laptops;
   - a stated ppi is within 4% of the ppi implied by the resolution and
     diagonal;
   - phone ppi falls in a plausible range;
   - ids have the right shape and are unique against the catalogue;
   - no alias collides with an existing one;
   - a laptop or explicit dpr comes with a derivation, and its viewport
     equals px / dpr.
4. **Corrections.** `fixup.py.txt` applied 95 corrections, listed in
   `corrections.log`:
   - **Renames:** Redmi and POCO ids get the `xiaomi-` brand prefix.
   - **Dropped, iPad Pro 13-inch (M4):** a duplicate of the existing
     `apple-ipad-pro-13`.
   - **Dropped, Moto G75:** the cited page's body is headed "moto g55 5G".
   - **Blanked launch OS:** wherever the page did not state an Android
     version, the launch OS is now blank. That covers OPPO (ColorOS-only
     pages), OnePlus Pads (OxygenOS only), Nothing Phone (2) and (2a), whose
     pages give the current OS, not the launch OS, and the Galaxy S24+ and
     S24 Ultra.
   - After the corrections, all 386 new entries pass, with 0 problems.
5. **Provenance spot-check.** `provenance-spot-check.txt` covers 17 pages:
   - the two required Ultras, plus one random entry per brand;
   - each was re-fetched independently with curl, and PDFs were converted
     with pdftotext;
   - **17 of 17** contain the entry's width and height.

## Caveats, stated rather than hidden

- **Notes are WebFetch summaries.** Most researchers fetched pages with
  WebFetch, which returns a model summary of the page. So `source.note` is
  the summary's rendering of the page's figures, not a byte-exact quote. The
  resolution numbers are re-checked by the validator, and on a sample by the
  independent re-fetch.
- **Most new entries have no `released`.** Manufacturer spec pages rarely
  state a launch month, and the brief forbade recalling one. Undated devices
  resolve by name but are never chosen as "newest".
- **Many OS versions are blank** for the same reason, and the UA does not
  depend on them.
- **The phone dpr is the documented bucket rule,** not each maker's real
  default density. For example, Samsung's real Chrome CSS width is usually
  360 or 384, and the Chrome DevTools entries carry those real values. The
  rule is labelled on every entry.
- **The laptop Windows dpr rule is the researcher's own,** because
  Microsoft's recommended-scale table could not be sourced. It rounds ppi/96
  down to a 50% step, with a minimum of 100%. It is stated in each entry's
  derivation. Macs use dpr 2 at native/2, because Apple's pages state no
  default "looks like" resolution.
- **Skipped for lack of a fetchable first-party resolution:**
  - Galaxy S23 (base);
  - most Honor models (honor.com spec tabs render client-side);
  - Edge 20 and Edge 30 generation Motorolas;
  - Dell, HP, Acer and Asus laptops;
  - Surface Laptop 5 and 6, and Surface Laptop Go 3;
  - several Sony and OnePlus models.

  The researchers' reports list them. Honor therefore stays thin, at 7
  devices.
- **Resolver behaviour noticed, not changed.** "galaxy s23" resolves exactly
  to the S23 FE through the existing fewest-extras token rule, because FE is
  a modifier.
