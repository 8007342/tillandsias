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

### Requirement: The model is chosen from a hardware tier table

The default model MUST be chosen without asking from a declarative tier
table (I0–I3) keyed on the accel envelope's VRAM, unified memory and RAM.
Every row MUST name its model, licence, default resolution and steps, and a
quality model. A model whose licence is non-commercial MUST NOT appear in
any row.

#### Scenario: Floor host gets the small model
- **WHEN** the envelope reports `accel_class=cpu-only` and RAM below 16 GB
- **THEN** the tier is I0 and the default model is the I0 row's model

#### Scenario: No non-commercial model is shippable
- **WHEN** the tier table is loaded
- **THEN** no row names a licence marked non-commercial

### Requirement: Models live in the reusable cache

Model files MUST be stored under `cache_root()/models/imagegen/`, fetched
on first use from a pinned URL and verified against a pinned sha256. Models
MUST NOT be baked into any image and MUST NOT be placed on a tmpfs or
ramdisk. The cache MUST survive a reset like the LLM model cache.

#### Scenario: A digest mismatch is refused
- **WHEN** a downloaded model's sha256 differs from the pin
- **THEN** the file is discarded and the call fails naming the model

### Requirement: Results are files with metadata, never inline images

`image.generate` MUST return the shared image-result schema (1871-47ex):
saved `path`, `width`, `height`, `has_alpha`, `thumbnail_path`, plus
`model`, `licence`, `tier`, `backend`, `seed`, `steps`, `elapsed_s`. The
text result MUST NOT contain a base64 run longer than 256 characters.

#### Scenario: Result carries no base64
- **WHEN** an image is generated
- **THEN** the result names an existing PNG file and contains no base64 run over 256 characters

### Requirement: A long or larger run needs the user's consent

A request that selects the quality model, OR is estimated to exceed 120
seconds, OR needs more than 2 GB of uncached download MUST NOT run without
a consent token. It MUST instead return `status: consent_required` with the
estimate, download size, model, licence, a `consent_token`, and one plain
`ask` sentence for the user. A default-model request under the threshold
MUST NOT ask.

#### Scenario: Quality run asks first
- **WHEN** `image.generate` is called with `quality: high` and no token
- **THEN** nothing is generated and the result is `consent_required` with a token

#### Scenario: Fast run never asks
- **WHEN** a default-model request is estimated under 120 seconds with the model cached
- **THEN** the image is generated without a consent round-trip

### Requirement: Consent tokens are host-minted and single-use

The consent token MUST be minted by the host, bound to the request hash and
lane, usable once, and expire after 10 minutes.

#### Scenario: Token is single-use
- **WHEN** the same token is presented twice
- **THEN** the second call is refused
