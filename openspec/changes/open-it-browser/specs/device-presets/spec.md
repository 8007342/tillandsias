## ADDED Requirements

### Requirement: Mobile first is a first-class input to every browser window

A device preset is a resolved entry of the device catalogue
(`spec:device-catalogue`, order 1643-q3at). It is the input every browser
window is opened with. Phones, tablets and foldables MUST be first-class
presets, equal to desktops:
- every window-opening tool MUST accept a free-form device query;
- every engine MUST honour a preset's viewport, devicePixelRatio, mobile and
  touch flags and user agent;
- no code path may treat "desktop" as the only fully supported preset.

The default preset MUST come from the project's `.tillandsias` configuration
when it names one, and otherwise MUST be the desktop preset (1440×900 at
scale 1).

The catalogue MUST cover the long tail across many brands, not only flagship
iPhones and Pixels. That means hundreds of devices across a dozen or more
brands (order 1644-u8b8), including Galaxy, Xiaomi, Xperia and OnePlus.

@trace spec:device-presets, spec:device-catalogue

#### Scenario: A phone is as good as a desktop
- **WHEN** an agent asks to open the project "on an iphone 12 pro max"
- **THEN** the window opens with that device's viewport, devicePixelRatio,
  touch points and user agent
- **AND** no warning says that mobile presets are partially supported

#### Scenario: The project default
- **WHEN** `.tillandsias` names a default device and the agent names none
- **THEN** the window opens with the project's default device
- **AND** with no project default it opens with the desktop preset

### Requirement: Every preset carries the full schema and its own licence

Every catalogue entry MUST carry the following fields:
- id, brand, family, model and aliases[];
- released (YYYY-MM) where known;
- form (phone, tablet, foldable, laptop or desktop);
- os{name, version};
- engine (webkit, blink or gecko);
- screen{w, h};
- viewport{w, h}, in portrait CSS px for mobile devices;
- dpr, ua and ua_metadata;
- mobile, touch and max_touch_points;
- safe_area{portrait, landscape} where known;
- source{kind, url, license}.

The licence is recorded per entry, not per file. An entry whose source has no
redistributable licence MUST NOT enter the catalogue. Approved sources are
Playwright's device descriptors (Apache-2.0), Chrome DevTools' emulated devices
(BSD-3-Clause), and a hand-written overlay citing the manufacturer's spec page
for each entry. GSMArena scraping, `devices.json` (licence unverified), WURFL and
DeviceAtlas (proprietary) are excluded. Synthetic upstream values (for example
Playwright's synthetic iPhone UA strings) and derived values (CSS viewport and
DPR computed from a manufacturer's physical numbers) MUST be labelled as such.

@trace spec:device-presets, spec:device-catalogue

#### Scenario: A licence on every entry
- **WHEN** the catalogue is loaded
- **THEN** every entry has a non-empty `source.url` and `source.license`

#### Scenario: An unlicensed source is refused
- **WHEN** a generator input carries no redistributable licence
- **THEN** the generator fails and names the entry
- **AND** the committed catalogue is unchanged

### Requirement: Device queries resolve by fixed rules, never across brands

A preset query MUST resolve by the rules of `spec:device-catalogue`, in order:
1. Normalise: lowercase; `+` becomes "plus"; glued tokens are split
   (`iphone12`); shorthand is expanded (`s24u` becomes "s24 ultra"); brand
   synonyms apply (sony→xperia, google→pixel, samsung→galaxy).
2. An exact alias or id wins.
3. Otherwise every requested token must be present, and the fewest extra
   tokens wins. Modifiers (pro, max, plus, ultra, mini, e, fold, flip, cover)
   always count, so "iphone 12", "iphone 12 pro" and "iphone 12 pro max" are
   three distinct devices. A match that needed an extra modifier token is
   approximated, never exact (order 1652-p8xv).
4. A bare brand or family gives the newest dated base flagship, never an e,
   mini, fold, flip or cover model. "android" gives the newest base Pixel;
   "desktop" gives 1440×900 at scale 1.
5. Ties and near misses return the best match plus alternatives, flagged
   approximated. A resolution MUST NOT change brand.
6. A trailing "landscape" swaps the viewport and screen and selects the
   landscape safe area.

A query that matches nothing MUST be reported as no match. The window MUST
NOT open with a guessed device. An approximated match MUST be reported to the
agent with its alternatives.

@trace spec:device-presets, spec:device-catalogue

#### Scenario: Siblings stay distinct
- **WHEN** "iphone 12", "iphone 12 pro" and "iphone 12 pro max" are resolved
- **THEN** they are three different presets

#### Scenario: A near miss stays within one brand
- **WHEN** a query names a brand but matches none of its devices exactly
- **THEN** the result is that brand's best match, flagged approximated, with alternatives
- **AND** no other brand's device is returned

#### Scenario: Landscape
- **WHEN** "galaxy s24 landscape" is resolved
- **THEN** the viewport width and height are swapped relative to "galaxy s24"
