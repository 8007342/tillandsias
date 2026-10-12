## ADDED Requirements

### Requirement: SLOT-9 — The llama-server slot runs exactly one pinned backend and only digest-pinned models

The llama-server slot MUST select exactly one backend: Vulkan when a DRM render
node in the container is readable and writable, otherwise CPU. CUDA MAY be
selected only on request and only when the CUDA lane is delivered to the
container; ROCm MUST be refused while the engine payload carries no ROCm backend.
The selected backend MUST be pinned explicitly (`GGML_BACKEND_PATH`) and MUST
agree with the engine set recorded in `.engine-set`. A payload carrying more
backends than the selection, without that pin, MUST be refused.

The slot MUST serve a model only when its file, size and sha256 are pinned, and
MUST verify the bytes before serving them and at every start. An unpinned tier
row MUST be refused by name (`engine-integrity-refused:gguf-unpinned:<id>`) and
never downloaded unverified; bytes that do not match MUST be refused and deleted
(`engine-integrity-refused:gguf-digest-mismatch:<id>`).

> Delta: order 482b, 2026-10-12. The payload's llama-server loads only the
> backend that `GGML_BACKEND_PATH` names, so the pin decides the backend, and
> llama.cpp's `-hf` download carries no integrity check.

@trace spec:inference-engine-slots

#### Scenario: Usable render node selects Vulkan, its absence selects CPU
- **WHEN** the container has a readable and writable render node
- **THEN** the slot selects Vulkan and pins exactly its library
- **AND** with no usable render node it selects CPU and the launch still succeeds

#### Scenario: Unpinned multi-backend payload is refused
- **GIVEN** an installed payload carrying a second backend beside the selected one
- **WHEN** no backend pin names the selected library
- **THEN** the slot refuses to start with `engine-integrity-refused:multi-backend-unpinned`

#### Scenario: Unpinned model is refused, not downloaded
- **WHEN** a tier row has no sha256 pin
- **THEN** the slot refuses it with `engine-integrity-refused:gguf-unpinned:<id>`
- **AND** nothing is downloaded for it
