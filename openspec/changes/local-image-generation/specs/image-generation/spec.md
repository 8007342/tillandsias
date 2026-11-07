## ADDED Requirements

### Requirement: Image generation runs locally on stable-diffusion.cpp

Tillandsias MUST provide local text-to-image generation backed by a pinned
stable-diffusion.cpp release. The engine image MUST be built on first use,
never at init, and MUST run with no egress. On macOS the engine MUST run as
a host-native Metal helper; on Linux and WSL2 it MUST run in the `imagegen`
container with the backend the accel probe proves usable (CUDA, Vulkan),
falling back to CPU.

#### Scenario: First use builds the image
- **WHEN** `image.generate` is called on a host that has never built `imagegen`
- **THEN** the image is built through the on-demand build path and the result reports `first_use: true`

#### Scenario: An unusable GPU backend falls back to CPU visibly
- **WHEN** the selected GPU backend fails to place the model
- **THEN** generation completes on CPU and the result's `backend` is `cpu`

### Requirement: Models form a ladder of permissive licences under a hardware ceiling

The tier table (I0–I3) MUST be declarative and ordered smallest first; the
accel envelope MUST set only the host's ceiling tier, the highest tier the
host may run. The floor tier I0 MUST be runnable on every host and its
files MUST be fetched on first use without asking. A tierless request MUST
run on the highest tier within the ceiling that is available (files
present, or their download already granted on this host); it MUST NOT walk
the ladder from I0 (operator ruling 2026-11-01, 1957-5m8g). Every row MUST
name its model and licence, and every licence MUST be permissive or open
with no revenue cap and no non-commercial term. Models under the Stability
AI Community Licence (SD-Turbo, SD3.5) MUST NOT appear.

#### Scenario: A fresh host runs the floor unasked
- **WHEN** a host with no imagegen model files makes its first tierless `image.generate` call
- **THEN** I0 is fetched and the image is generated on tier I0 with no consent asked

#### Scenario: A tierless call runs the biggest model already here
- **WHEN** a host whose ceiling is I3 has the I3 files present and makes a tierless `image.generate` call
- **THEN** the image is generated on tier I3 with no token and no I0 run first

#### Scenario: A smaller tier stays available by name
- **WHEN** a host with I3 present requests tier I1
- **THEN** the image is generated on tier I1

#### Scenario: No capped or non-commercial licence is shippable
- **WHEN** the tier table is loaded
- **THEN** no row names a non-commercial licence or one with a revenue cap

### Requirement: Models live in the reusable cache

Model files MUST be stored under `cache_root()/models/imagegen/`, fetched
on first use from a pinned URL and verified against a pinned sha256. Models
MUST NOT be baked into any image and MUST NOT be placed on a tmpfs or
ramdisk. The cache MUST survive a reset like the LLM model cache.

#### Scenario: A digest mismatch is refused
- **WHEN** a downloaded model's sha256 differs from the pin
- **THEN** the file is discarded and the call fails naming the model

### Requirement: Images are generated exactly as requested

`image.generate` MUST honour the requested `width`, `height`, `steps`,
`seed` and `count`, rounding only to the engine's size grid and reporting
the rounding. Tier defaults apply only to omitted fields.

#### Scenario: Requested size is honoured
- **WHEN** an agent requests 640x384
- **THEN** the saved PNG is 640x384

### Requirement: Output goes to a shared scratch dir destroyed on teardown

Images MUST be written to a shared scratch directory mounted into both the
`imagegen` container and the forge, never into the project tree by
default. The tool description and every result (`ephemeral: true`) MUST
say the directory is destroyed on forge teardown.

#### Scenario: Output is ephemeral and says so
- **WHEN** an image is generated
- **THEN** the result's path is under the shared scratch dir and `ephemeral` is true

### Requirement: Results are files with metadata, never inline images

The result MUST follow the shared image-result schema (1871-47ex) plus
`model`, `licence`, `tier`, `backend`, `seed`, `steps`, `elapsed_s`, and
MUST NOT contain a base64 run longer than 256 characters.

#### Scenario: Result carries no base64
- **WHEN** an image is generated
- **THEN** the result names an existing PNG file and contains no base64 run over 256 characters

### Requirement: The consent gate is a one-time download gate per host

The only thing `image.generate` MUST ask consent for is downloading a
tier's model files the first time on a host (operator ruling 2026-11-01:
"the bigger models gate should be asked only for downloading models the
first time"). Any tier up to the host ceiling MAY be requested directly;
there MUST be no I0 → I1 → I2 walk and no per-session re-asking. A tier
whose pinned files are present, or whose download was already granted on
this host, MUST run with no token. A request for a tier whose files are
missing, with no valid token, MUST return `consent_required` carrying a
download offer (`tier`, `model`, `download_bytes`, `ask`, `consent_token`,
`how`) and generate nothing. Redeeming the token MUST record a standing
host grant (`kind: download`, `scope: host`, `expiry: none`) for that tier,
so the tier never asks again on this host; the result MUST name the grant
it ran under. A tier with no pinned files MUST never be offered and a
direct request for it MUST fail as `tier_unavailable`.

#### Scenario: A present tier needs no token
- **WHEN** `image.generate` requests tier I3 with no token and the I3 files are present
- **THEN** the image is generated on I3 and the result carries no `consent_required`

#### Scenario: A missing tier asks once, then never again
- **WHEN** `image.generate` requests tier I3 with no token and the I3 files are not on this host
- **THEN** nothing is generated and the result is `consent_required` with a download offer for I3
- **WHEN** the call is repeated with that `consent_token`
- **THEN** I3 is downloaded and run, the result's `grant` names tier I3 with `scope: host`
- **WHEN** a later call requests I3 with no token
- **THEN** it runs with no offer and no `consent_required`

#### Scenario: Direct request skips no rungs
- **WHEN** a host with only I0 present and ceiling I3 requests tier I3
- **THEN** the download offer names I3, not I1

#### Scenario: An unpinned tier is never offered
- **WHEN** a result is produced on a host whose next tier above what is present has no pinned files
- **THEN** `bigger_tier_offer` skips to the next installable tier or is null

### Requirement: The download ask states its cost honestly

The `ask` for a tier whose files must be fetched MUST say the download is
one-time, and MUST carry its size in GB and an estimated minutes figure
derived from the pinned sizes (1957-8hkf), so the user can decide on the
cost to this computer. A result at a tier below the ceiling MAY carry
`bigger_tier_offer` for the next installable tier not yet present; the
offer is informational and MUST be the same download offer, never a
quality claim.

#### Scenario: Ask carries the download cost
- **WHEN** any download offer or `consent_required` result is produced
- **THEN** its `ask` names a GB figure and a minutes figure and says the download is one-time

### Requirement: Only free metered services are recommended

The tool, its docs and agent overlays MUST NOT recommend any metered
service other than free Cloudflare and free GitHub.

#### Scenario: No paid service in the docs
- **WHEN** the tool description and overlays are scanned
- **THEN** they name no hosted image API or paid service

### Requirement: Consent tokens are host-minted and single-use

The consent token MUST be minted by the host, bound to the request hash and
lane, usable once, and expire after 10 minutes.

#### Scenario: Token is single-use
- **WHEN** the same token is presented twice
- **THEN** the second call is refused
