## ADDED Requirements

### Requirement: An optional ComfyUI studio image

Tillandsias MAY provide an `imagegen-studio` image running ComfyUI with
ComfyUI-Manager, built on first use only when a project enables it, and
opened in a browser window. It MUST share the imagegen model cache, MUST
NOT be built or started for projects that did not enable it, and MUST NOT
bundle a component whose licence is non-commercial (RMBG-1.4/2.0,
InsightFace weights, FLUX.1-dev).

#### Scenario: Studio is off by default
- **WHEN** a project without the studio enabled starts a forge
- **THEN** no `imagegen-studio` image is built or container started
