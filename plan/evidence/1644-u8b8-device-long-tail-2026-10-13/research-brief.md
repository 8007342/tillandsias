# Device-catalogue research brief (order 1644-u8b8)

You are adding devices to Tillandsias' device catalogue. The catalogue lets a
developer preview a web page "as a Galaxy S24 Ultra" (CSS viewport, devicePixelRatio,
engine). Accuracy and provenance matter more than count.

## Hard rules

1. **First-party sources only.** Every figure must come from a page on the
   MANUFACTURER's own domain that you actually fetched in this session (spec
   page, product page, newsroom/press release, support "tech specs" page, an
   official PDF spec sheet). Regional manufacturer sites are fine (e.g.
   samsung.com/uk, mi.com/global, oneplus.com/in, support.apple.com).
   **Never** use or cite GSMArena, PhoneArena, Wikipedia, WURFL, DeviceAtlas,
   Notebookcheck, Kimovil, retailers, or any third party, not even to "check".
   You MAY use web search to FIND the manufacturer's page, but the URL you cite
   and the figures you write must be from the manufacturer page you fetched.
2. **Never invent or recall figures.** If you could not fetch a first-party page
   that states the physical resolution, SKIP the device and list it under
   "skipped" in your final report with the reason (e.g. "samsung.com renders
   specs client-side; newsroom had no resolution").
3. `source.note` quotes the figures **as the page states them** (short: size,
   resolution, ppi if given). This is the audit trail.
4. Do not duplicate devices already in the catalogue: the ids in
   `target/work/devices/existing-ids.txt` exist already. Skip those.
5. Write ONLY your own output file (named in your task). Do not edit anything
   else in the repository. No git commands.

## Output format

Your file is a YAML list (no top-level key), one entry per device:

```yaml
- id: samsung-galaxy-s24-ultra          # <brand>-<model slug>, lowercase, hyphens
  brand: samsung                        # lowercase maker
  family: galaxy                        # the line token people type (see families below)
  model: Galaxy S24 Ultra               # the maker's own name, without the brand
  aliases: [galaxy s24 ultra, s24 ultra] # lowercase; what people type; NO brand-less ambiguous ones like "ultra"
  released: "2024-01"                   # YYYY-MM it went on sale, from the maker's announcement; OMIT if unsure
  flagship: true                        # ONLY the base model of the brand's numbered main line (Galaxy S24, not S24+/Ultra/FE); omit otherwise
  form: phone                           # phone | foldable | tablet | laptop
  os: {name: android, version: "14"}    # launch OS: android | ios | ipados | windows | macos | chromeos
  screen_px: {w: 1440, h: 3120}         # physical pixels; PORTRAIT (w < h) for phone/foldable/tablet, LANDSCAPE (w > h) for laptop
  panel: {inches: 6.8, ppi: 505}        # ppi only if the page states it
  source:
    url: https://news.samsung.com/global/...
    note: "6.8-inch QHD+ Dynamic AMOLED 2X, 3120 x 1440 (505 ppi)"
```

- Phones, foldables, Android tablets: do NOT write dpr or viewport; the
  generator derives them with a labelled rule.
- Foldables: one entry for the main (unfolded) screen. If the cover screen is
  a usable phone, add a second entry `<id>-cover`, `model: "<name> (cover screen)"`,
  form phone.
- **Apple iPhone/iPad:** Apple publishes logical points and scale. If you can
  fetch Apple's own statement of points (developer.apple.com HIG or
  documentation), add `published: true`, `dpr: <scale>`,
  `viewport: {w: <points w>, h: <points h>}` (portrait). Otherwise add
  `dpr: 2` (iPad) or `dpr: 3` (iPhone, Super Retina) plus
  `derivation: "Apple's Retina scale for this display class; viewport = physical resolution / dpr, rounded; not published per device"`.
- **Laptops:** give `dpr`, `viewport` (landscape CSS px, the full screen at
  the default scale) and a `derivation` string saying how. Macs: if Apple's
  tech-specs page states the default "looks like" scaled resolution, use it
  with dpr = physical/scaled. Windows: dpr = Windows' recommended scale for
  the panel (state the rule you used, e.g. "125% per 120 ppi, nearest 25% step").
  Also `touch: true` if the page says touchscreen.

Families to use: samsung → `galaxy`; google → `pixel`; xiaomi → `xiaomi`,
`redmi`, `poco` (the line); oneplus → `oneplus` or `nord`; sony → `xperia`;
motorola → `moto` (Moto G, Edge) or `razr`; honor → `honor` or `magic`;
oppo → `find`, `reno` or `oppo` (A series); vivo → `vivo` (X/V/Y) ; realme →
`realme`; nothing → `nothing`; asus → `zenfone` or `rog`; apple → `iphone`,
`ipad`, `macbook`; laptops: `xps`, `thinkpad`, `yoga`, `spectre`, `elitebook`,
`surface`, `chromebook` as fits. NEVER use the family `edge` (it collides with
the Edge browser).

## Final report (your last message)

- the path of your file and how many entries it holds;
- every skipped device with the reason;
- any page that blocked fetching, and what you did instead.
