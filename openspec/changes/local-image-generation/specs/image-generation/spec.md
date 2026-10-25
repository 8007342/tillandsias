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

### Requirement: Models form a smallest-first ladder of permissive licences

The tier table (I0–I3) MUST be declarative and ordered smallest first.
Every request MUST start on the smallest tier available (I0 on first use)
regardless of hardware; the accel envelope MUST set only the host's ceiling
tier. Every row MUST name its model and licence, and every licence MUST be
permissive or open with no revenue cap and no non-commercial term. Models
under the Stability AI Community Licence (SD-Turbo, SD3.5) MUST NOT appear.

#### Scenario: Every host starts at the floor
- **WHEN** a host with a 24 GB VRAM GPU makes its first `image.generate` call
- **THEN** the image is generated on tier I0

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

### Requirement: A larger tier is offered one step at a time

When the host ceiling is above the tier just used, the result MUST offer
exactly the next tier (never two steps) with a host-minted
`consent_token` and one curated `ask` sentence. A request for a tier above
the last accepted one without a token MUST return `consent_required` and
generate nothing.

#### Scenario: Offer is one tier up
- **WHEN** an I0 image is generated on a host whose ceiling is I3
- **THEN** the result offers I1 only, with a token and an ask sentence

#### Scenario: Larger tier without a token asks first
- **WHEN** `image.generate` requests tier I1 with no token and I1 was never accepted
- **THEN** nothing is generated and the result is `consent_required`

### Requirement: User-facing text is curated and honest

User-facing `ask` text MUST NOT contain raw download sizes or time
estimates. When the offered tier is not yet downloaded, it MUST say that
big files are downloaded only if the user is OK waiting longer for better
results.

#### Scenario: Ask carries no sizes
- **WHEN** any offer or consent_required result is produced
- **THEN** its `ask` contains no byte, GB or seconds figure

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
