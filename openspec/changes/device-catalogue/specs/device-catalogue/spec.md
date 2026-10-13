## ADDED Requirements

### Requirement: A vendored device catalogue with recorded provenance

Tillandsias MUST ship a committed device catalogue. Every device MUST carry:
- an id, brand, family, model and aliases;
- a form (phone, tablet, foldable, laptop or desktop);
- an OS name and version;
- an engine (webkit, blink or gecko);
- a screen, a viewport and a devicePixelRatio;
- a user agent, and mobile/touch flags with max touch points;
- where known, a release month, safe-area insets and UA client-hint metadata;
- a source record naming its kind, URL and licence.

For a mobile device the viewport MUST be the portrait CSS screen; for a desktop
it MUST be the browser window. The catalogue MUST be built only from
redistributable sources: Playwright (Apache-2.0), Chrome DevTools
(BSD-3-Clause), and a hand-written overlay citing each manufacturer's spec page.
Values the manufacturer does not publish (the CSS viewport and DPR) MUST be
labelled as derived, with the derivation stated. The catalogue MUST be
reproducible: regenerating it from the vendored inputs MUST yield the committed
bytes.

#### Scenario: Every device names its licence
- **WHEN** the catalogue is loaded
- **THEN** every device has a non-empty source URL and licence

#### Scenario: The committed catalogue is fresh
- **WHEN** `scripts/lua/build-device-catalogue.lua -- --check` runs
- **THEN** it reports `ok:device-catalogue:fresh:<n>`

### Requirement: Free-form device queries resolve deterministically, never across brands

A device query MUST be normalised:
- lowercase;
- `+` becomes "plus";
- glued tokens are split (`iphone12` becomes "iphone 12");
- `s24u` becomes "s24 ultra";
- sony, google and samsung become xperia, pixel and galaxy.

A trailing "landscape" MUST swap the viewport and screen and select the
landscape safe area. Resolution MUST then apply these rules in order:
1. An exact alias or id wins.
2. A bare brand or family gives its newest dated base flagship, never an e, mini, fold, flip or cover model.
3. Every requested token present, the fewest extra tokens winning. Any modifier extra (pro, max, plus, ultra, mini, e, fold, flip, cover) outweighs any other extra.
4. A near miss is allowed only inside one brand: the brand the query named, or the only brand whose models carry its model tokens. A near miss returns the best match plus alternatives, flagged as approximated.

A query that names no brand and matches no device MUST be "no match". A
resolution MUST NOT change brand.

#### Scenario: A specific model
- **WHEN** "iphone 12 pro max" is resolved
- **THEN** the result is a 428×926 portrait viewport and screen, dpr 3, engine webkit

#### Scenario: Siblings stay distinct
- **WHEN** "iphone 12", "iphone 12 pro" and "iphone 12 pro max" are resolved
- **THEN** they are three distinct devices

#### Scenario: A bare brand
- **WHEN** "iphone" is resolved
- **THEN** the result is the newest dated iPhone flagship in the catalogue

#### Scenario: Overlay brands
- **WHEN** "xperia" or "oneplus" is resolved
- **THEN** the result comes from the manufacturer overlay

#### Scenario: Nonsense
- **WHEN** a query matches no device and names no brand
- **THEN** the result is no match, never another brand's device

### Requirement: A devices command

`tillandsias devices resolve <query...>` MUST print the resolution as JSON and
exit 0, or print `{"match": false, …}` and exit 1. `tillandsias devices list`
MUST list every catalogue device. Neither command touches containers or
the network.
